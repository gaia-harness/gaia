#!/usr/bin/env bash
# audit-quick-classify-lines-lib.sh: the quick classifier's line stage, and the
# assembly of its awk line program from the fragment siblings. Sourced by
# audit-quick-classify-lib.sh after the fragments, whose header owns the line
# shapes and signals the program applies.

# _quick_language_siblings <root> <head> <path> <scratch> <out>: one
# `<locale><TAB>` line per sibling locale directory at <head>, then one
# `<locale><TAB><key path>` line per key of that locale's same relative file.
# A sibling without the file, or whose file does not parse, lists no keys, so
# every changed key reads as missing there (the deep direction).
_quick_language_siblings() {
  local root="$1" head="$2" path="$3" scratch="$4" out="$5" rest locale relative entry meta name sibling_locale sibling_path tab
  tab="$(printf '\t')"
  rest="${path#frontend/app/languages/}"
  locale="${rest%%/*}"
  relative="${rest#*/}"
  : >"$out"
  git -C "$root" ls-tree -z "$head" frontend/app/languages/ >"$scratch/locales" 2>/dev/null || return 2
  while IFS= read -r -d '' entry; do
    meta="${entry%%"$tab"*}"
    name="${entry#*"$tab"}"
    case "$meta" in
      *" tree "*) ;;
      *) continue ;;
    esac
    sibling_locale="${name##*/}"
    [ "$sibling_locale" != "$locale" ] || continue
    printf '%s\t\n' "$sibling_locale" >>"$out"
    sibling_path="frontend/app/languages/$sibling_locale/$relative"
    git -C "$root" cat-file -e "$head:$sibling_path" 2>/dev/null || continue
    git -C "$root" show "$head:$sibling_path" >"$scratch/sibling" 2>/dev/null || return 2
    LC_ALL=C awk -v mode=keys -v prefile="$scratch/sibling" "$_QUICK_LINE_PROGRAM" </dev/null >"$scratch/sibling-keys" || return 2
    LC_ALL=C awk -v locale="$sibling_locale" '{ print locale "\t" $0 }' "$scratch/sibling-keys" >>"$out" || return 2
  done <"$scratch/locales"
  return 0
}

_quick_lines_run() {
  local root="$1" from="$2" head="$3" scratch="$4" path class result bidi nonascii tab
  tab="$(printf '\t')"
  bidi="$(printf '\342\200[\213-\217\252-\256]|\342\201[\246-\251]')"
  nonascii="$(printf '[\200-\377]')"
  for path in ${QUICK_SELECTED_PATHS[@]+"${QUICK_SELECTED_PATHS[@]}"}; do
    class="$(quick_path_class "$path")"
    if [ "$class" = "none" ]; then
      if ! _quick_story_admitted "$path"; then
        printf 'deep\tquick-path\t%s\t-\n' "$path"
        return 0
      fi
      class="story"
    fi
    git -C "$root" show "$from:$path" >"$scratch/pre" 2>/dev/null || return 2
    git -C "$root" show "$head:$path" >"$scratch/post" 2>/dev/null || return 2
    light_route_diff "$root" -U0 "$from" "$head" -- "$path" >"$scratch/diff" 2>/dev/null || return 2
    : >"$scratch/siblings"
    if [ "$class" = "language" ]; then
      _quick_language_siblings "$root" "$head" "$path" "$scratch" "$scratch/siblings" || return 2
    fi
    result="$(LC_ALL=C awk -v mode=lines -v class="$class" \
      -v prefile="$scratch/pre" -v postfile="$scratch/post" -v siblingfile="$scratch/siblings" \
      -v bidi="$bidi" -v nonascii="$nonascii" -v hidingset="$QUICK_HIDING_TOKENS" \
      -v paletteutilities="$QUICK_PALETTE_UTILITIES" -v palettecolors="$QUICK_PALETTE_COLORS" \
      "$_QUICK_LINE_PROGRAM" "$scratch/diff")" || return 2
    case "$result" in
      ok) ;;
      quick-*"$tab"*) printf 'deep\t%s\t%s\t%s\n' "${result%%"$tab"*}" "$path" "${result#*"$tab"}"; return 0 ;;
      *) return 2 ;;
    esac
  done
  printf 'quick\n'
}

# quick_classify_lines <root> <from-tree> <head-sha> <paths-file>: the line
# stage over each path's -U0 hunks, with every changed line's lexical context
# taken from the full pre-image (deleted lines) or post-image (added lines).
# Prints `quick` or `deep<TAB><reason><TAB><path><TAB><pre:N|post:N|->`;
# returns 2 on any internal failure, printing nothing.
quick_classify_lines() {
  local scratch output status=0
  declare -F light_route_diff >/dev/null 2>&1 || return 2
  [ "$#" -eq 4 ] || return 2
  _quick_read_paths "$4" || return 2
  scratch="$(mktemp -d 2>/dev/null)" || return 2
  output="$(_quick_lines_run "$1" "$2" "$3" "$scratch")" || status=$?
  rm -rf "$scratch"
  _quick_emit "$status" "$output"
}

# The line program. mode=keys prints the key paths of the language file
# <prefile> (nothing when it does not parse). mode=lines reads one path's -U0
# diff on stdin plus its full images and prints `ok`, `<reason><TAB><side>:<N>`
# for the first deep line, `quick-unclassified<TAB>-` for a binary diff, or
# `ERROR` when an image cannot be read.
#
# The program is cut into fragments only to keep each file readable; awk sees
# one program, joined here in this order: lexer, nested-element pass, TSX line
# helpers, then story lines, language files, BEGIN and END. Each fragment keeps
# its own trailing newline, so the join is byte for byte the single program.
# An empty fragment means a sibling did not load, and the stage refuses to
# assemble a partial program.
if [ -z "${_QUICK_AWK_LEXER:-}" ] || [ -z "${_QUICK_AWK_NESTED:-}" ] ||
  [ -z "${_QUICK_AWK_HELPERS:-}" ] || [ -z "${_QUICK_AWK_MAIN:-}" ]; then
  return 1
fi
_QUICK_LINE_PROGRAM="$_QUICK_AWK_LEXER$_QUICK_AWK_NESTED$_QUICK_AWK_HELPERS$_QUICK_AWK_MAIN"
