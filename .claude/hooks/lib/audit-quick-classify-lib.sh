#!/usr/bin/env bash
# audit-quick-classify-lib.sh: the fail-closed classifier behind the light-review
# router's first-dispatch quick route. Sourced, never executed; does no work at
# source time. The caller sources audit-light-route-lib.sh first, because the
# delta is read through light_route_diff (literal pathspecs, no renames, no
# textconv), and every classifier entry point returns 2 when it is missing.
#
# A global rule: it decides whether a quick clearance, made with no full member
# having read the branch, is believed. A wrong `quick` lets the merge gate pass
# on content no full member read, so every uncertainty answers `deep`.
#
# Bash 3.2 compatible (macOS default), BWK awk safe (every awk runs under
# LC_ALL=C, so a byte is a character on every awk). Never `cd`. Reads no
# environment variable to decide anything.
#
# This header owns the lists below. Wiki pages and the reviewer definition point
# here and never copy them.
#
# Path classes (quick_path_class; path shape only):
#   component  frontend/app/components/<dirs>/index.tsx and
#              frontend/app/components/ui/<name>.tsx
#   page       frontend/app/pages/<dirs>/page.tsx and
#              frontend/app/pages/<dirs>/index.tsx
#   language   frontend/app/languages/<locale>/<path>.ts, except any index.ts
#   none       everything else, including every story. Component and page
#              exclude any path with a `hooks` or `tests` segment and anything
#              under frontend/app/components/document/ or
#              frontend/app/components/errors/.
# A story <dir>/tests/<base>.stories.tsx is admitted only by pairing: its
# component <dir>/<base>.tsx (quick_story_component) is in the selected set and
# is of class component.
#
# Always-deep content markers: a component or page whose full pre-image or
# post-image holds any of these (QUICK_CONTENT_MARKERS) is quick-path:
#   nonce, request (whole words, any case), process.env, import.meta.env
#
# Hiding and focus tokens (QUICK_HIDING_TOKENS), deep when added or removed,
# matched on the token after its variant prefixes (md:, focus-visible:,
# data-[...]:, group-hover: and the like) and any `!` or `-` are stripped:
#   sr-only not-sr-only hidden invisible collapse opacity-0 size-0 outline-none
#   outline-hidden ring-0 pointer-events-none
# plus any token whose variant prefix chain carries `focus` (focus:,
# focus-visible:, focus-within:, group-focus: and the rest).
#
# Motion and reorder tokens, deep when added or removed: animate-*, order-*,
# *-reverse, col-start-*, col-end-*, row-start-*, row-end-*.
#
# Raw palette tokens (QUICK_PALETTE_UTILITIES, QUICK_PALETTE_COLORS), deep when
# added: <utility>[-<side>]-<color>[-<shade>][/<alpha>].
#
# Arbitrary values, deep when added or removed: any token whose stripped form
# holds `[` (an arbitrary property such as [display:none] or an arbitrary value
# such as bg-[#ff0000], whatever it carries, so no spelling of a deny-listed
# family escapes by going arbitrary), or starts with `content-`.
#
# Reasons. Router-owned rows pre-empt the classifier on a first dispatch; the
# rest are the classifier's own, in evaluation order (paths stage, then lines
# stage; within a line the first matching row wins).
#
# quick-signals:start
#   anchor-unresolved  router-owned: the base reference, merge base or merge-base walk cannot be established
#   refusal-newer  router-owned: a refusal for the member sits on HEAD's tree or on any commit since the merge base
#   unclassifiable-path  router-owned: a path the router cannot classify, or a classifier internal failure
#   special-file  router-owned: a mode change between two non-zero modes, or a symlink or submodule row
#   machinery  router-owned: the delta touches audit gate machinery
#   ownerless  router-owned: a changed path no member owns
#   hard-full  router-owned: a path matching the hard-full floor or a roster hard-full glob, outside the own-story carve-out
#   no-delta  router-owned: nothing changed for the member
#   over-cap  router-owned: added plus deleted lines exceed the quick cap
#   fence-collision  router-owned: the reviewer input would collide with its own fence
#   quick-path  a path outside the allowlist, an unpaired story, or a component or page holding an always-deep content marker
#   quick-file-status  an added, deleted or renamed file, or a mode other than 100644 on either side
#   quick-codepoint  a bidi-control or zero-width codepoint on a changed line, or a non-ASCII byte in a className value
#   quick-block-comment  a changed line holding /* or */ or lying inside a block comment
#   quick-template-literal  a changed line holding a backtick or lying inside a template literal
#   quick-import  an import, export, require( or import(
#   quick-hook  a use<Name>( call
#   quick-handler  an on<Name>= prop
#   quick-spread  a spread or rest
#   quick-conditional  &&, ||, ??, ?., a ternary or =>
#   quick-map  a .map(, .filter( or other iteration call
#   quick-cva  a changed line inside a cva( call
#   quick-cn-argument  a cn() change other than a token change inside an existing static string-literal argument
#   quick-element  a capitalized element added, removed or renamed, or any change on its element line
#   quick-tag  an intrinsic tag added or removed, or swapped outside div, span and p
#   quick-attribute  any attribute other than className added, removed or changed
#   quick-hiding-token  a hiding or focus token added or removed
#   quick-motion-order-token  an animate, order, reverse or grid placement token added or removed
#   quick-palette  a raw palette color token added
#   quick-arbitrary-value  a token with an arbitrary property or value ([...] in its utility), or a content- token, added or removed
#   quick-language-shape  a language line that is not a single-quoted literal key value on both sides
#   quick-language-key  a language key added, removed or renamed, plural or context suffix included
#   quick-placeholder  the {{...}} token set of a language value differs
#   quick-nesting  a $t( reference added, removed or changed
#   quick-html  a < in the old or new language value
#   quick-empty-value  a new language value that is empty or whitespace-only
#   quick-locale-missing  the changed key absent from a sibling locale's same file at HEAD
#   quick-text-deleted  static JSX text deleted with no text line added in the same hunk
#   quick-story-play  a changed story line touching play, expect, userEvent, waitFor, within( or an assertion
#   quick-story-shape  a story change other than a literal value inside an existing story's args object
#   quick-unclassified  a changed line matching no allowed shape
# quick-signals:end
#
# Allowed line shapes (everything else is a deep signal): a blank line; a line
# wholly inside static JSX text (never the children of script, style,
# noscript, iframe, object or template, which the browser reads as code or
# markup); an intrinsic tag line whose only change is a
# swap among div, span and p and a className token change; a className static
# token change on an intrinsic element, on the className attribute line of an
# existing capitalized element whose element line is unchanged, or inside a
# string-literal argument of an existing cn() call whose arguments are all
# string literals and keep their count; a language value change keeping key,
# placeholders, $t() references and HTML-free form, present in every sibling
# locale; a literal value change inside an existing story export's args object.
#
# Honest limits. The line grammar is a lexer, not a TypeScript parser: it tracks
# strings, comments, template literals, regex literals, brackets and JSX
# nesting, and when that tracking goes inconsistent anywhere in an image it
# gives up on the whole image (every changed line in it is deep). A JSX `<`
# is recognized only after an operator, an opening bracket or `return`, so a
# generic arrow function written `<T,>(` reads as JSX and fails the image
# closed. A div wrapper added around text is a tag addition (deep), not a swap.

QUICK_HIDING_TOKENS='sr-only not-sr-only hidden invisible collapse opacity-0 size-0 outline-none outline-hidden ring-0 pointer-events-none'
QUICK_PALETTE_UTILITIES='bg|text|border|ring|fill|stroke|from|via|to|outline|decoration|shadow|accent|caret|divide|placeholder'
QUICK_PALETTE_COLORS='slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|black|white'
QUICK_CONTENT_MARKERS='(^|[^A-Za-z0-9_$])(nonce|request)([^A-Za-z0-9_$]|$)|process\.env|import\.meta\.env'

# quick_path_class <path>: the path's class from the allowlist above.
quick_path_class() {
  local path="$1" rest base
  case "$path" in
    frontend/app/languages/*/*.ts)
      rest="${path#frontend/app/languages/}"
      base="${path##*/}"
      if [ -n "${rest%%/*}" ] && [ "$base" != "index.ts" ]; then
        printf 'language\n'
        return 0
      fi
      printf 'none\n'
      return 0
      ;;
  esac
  case "/$path/" in
    */hooks/* | */tests/*)
      printf 'none\n'
      return 0
      ;;
  esac
  case "$path" in
    frontend/app/components/document/* | frontend/app/components/errors/*)
      printf 'none\n'
      ;;
    frontend/app/components/ui/*.tsx)
      rest="${path#frontend/app/components/ui/}"
      case "$rest" in
        */*) case "$path" in
               */index.tsx) printf 'component\n' ;;
               *) printf 'none\n' ;;
             esac ;;
        *) printf 'component\n' ;;
      esac
      ;;
    frontend/app/components/*/index.tsx)
      printf 'component\n'
      ;;
    frontend/app/pages/*/page.tsx | frontend/app/pages/*/index.tsx)
      printf 'page\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
  return 0
}

# quick_story_component <story-path>: the component a story is the own story
# of, by the storybook location rule <dir>/tests/<base>.stories.tsx ->
# <dir>/<base>.tsx; returns 1 with no output for any other shape.
quick_story_component() {
  local story="$1" base parent directory
  case "$story" in
    */tests/*.stories.tsx) ;;
    *) return 1 ;;
  esac
  base="${story##*/}"
  base="${base%.stories.tsx}"
  [ -n "$base" ] || return 1
  parent="${story%/*}"
  [ "${parent##*/}" = "tests" ] || return 1
  directory="${parent%/*}"
  [ -n "$directory" ] && [ "$directory" != "$parent" ] || return 1
  case "/$directory" in
    */tests) return 1 ;;
  esac
  printf '%s/%s.tsx\n' "$directory" "$base"
}

# The decision line both stages print; anything else is an internal failure.
_quick_emit() {
  local status="$1" output="$2" tab rest reason path location
  tab="$(printf '\t')"
  [ "$status" -eq 0 ] || return 2
  if [ "$output" = "quick" ]; then
    printf 'quick\n'
    return 0
  fi
  case "$output" in
    "deep$tab"*) ;;
    *) return 2 ;;
  esac
  rest="${output#deep"$tab"}"
  reason="${rest%%"$tab"*}"
  rest="${rest#*"$tab"}"
  path="${rest%"$tab"*}"
  location="${rest##*"$tab"}"
  case "$reason" in
    quick-[a-z]*) ;;
    *) return 2 ;;
  esac
  case "$path" in
    "" | *"$tab"*) return 2 ;;
  esac
  case "$location" in
    -) ;;
    pre:[1-9]* | post:[1-9]*)
      case "${location#*:}" in
        *[!0-9]*) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
  printf '%s\n' "$output"
}

# Reads <paths-file> into QUICK_SELECTED_PATHS. An empty set, or a path holding
# a tab or carriage return (which the output line cannot carry), is a usage
# failure the caller turns into exit 2.
_quick_read_paths() {
  local paths_file="$1" path tab carriage
  tab="$(printf '\t')"
  carriage="$(printf '\r')"
  QUICK_SELECTED_PATHS=()
  [ -f "$paths_file" ] || return 1
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    case "$path" in
      *"$tab"* | *"$carriage"*) return 1 ;;
    esac
    QUICK_SELECTED_PATHS[${#QUICK_SELECTED_PATHS[@]}]="$path"
  done <"$paths_file"
  [ "${#QUICK_SELECTED_PATHS[@]}" -gt 0 ]
}

# _quick_story_admitted <story>: 0 when the story's own component is in the
# selected set and is of class component.
_quick_story_admitted() {
  local component candidate
  component="$(quick_story_component "$1")" || return 1
  [ "$(quick_path_class "$component")" = "component" ] || return 1
  for candidate in ${QUICK_SELECTED_PATHS[@]+"${QUICK_SELECTED_PATHS[@]}"}; do
    [ "$candidate" = "$component" ] && return 0
  done
  return 1
}

# _quick_blob_has_marker <root> <rev> <path> <scratch>: 0 when the blob holds an
# always-deep content marker, 1 when it does not, 2 when it cannot be read.
_quick_blob_has_marker() {
  local status=0
  git -C "$1" show "$2:$3" >"$4/marker-blob" 2>/dev/null || return 2
  LC_ALL=C grep -Eiq -e "$QUICK_CONTENT_MARKERS" "$4/marker-blob" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

_quick_paths_run() {
  local root="$1" from="$2" head="$3" scratch="$4" path class meta row_path
  local source_mode target_mode change_status rows rest status
  for path in ${QUICK_SELECTED_PATHS[@]+"${QUICK_SELECTED_PATHS[@]}"}; do
    class="$(quick_path_class "$path")"
    if [ "$class" = "none" ]; then
      if ! _quick_story_admitted "$path"; then
        printf 'deep\tquick-path\t%s\t-\n' "$path"
        return 0
      fi
      class="story"
    fi
    light_route_diff "$root" --raw -z --no-abbrev "$from" "$head" -- "$path" >"$scratch/raw" 2>/dev/null || return 2
    rows=0
    source_mode=""
    target_mode=""
    change_status=""
    while IFS= read -r -d '' meta && IFS= read -r -d '' row_path; do
      rows=$((rows + 1))
      meta="${meta#:}"
      source_mode="${meta%% *}"
      rest="${meta#* }"
      target_mode="${rest%% *}"
      change_status="${meta##* }"
      [ "$row_path" = "$path" ] || return 2
    done <"$scratch/raw"
    case "$class" in
      component | page)
        if [ "$rows" -eq 0 ] || [ "$source_mode" != "000000" ]; then
          status=0
          _quick_blob_has_marker "$root" "$from" "$path" "$scratch" || status=$?
          [ "$status" -ne 2 ] || return 2
          if [ "$status" -eq 0 ]; then
            printf 'deep\tquick-path\t%s\t-\n' "$path"
            return 0
          fi
        fi
        if [ "$rows" -eq 0 ] || [ "$target_mode" != "000000" ]; then
          status=0
          _quick_blob_has_marker "$root" "$head" "$path" "$scratch" || status=$?
          [ "$status" -ne 2 ] || return 2
          if [ "$status" -eq 0 ]; then
            printf 'deep\tquick-path\t%s\t-\n' "$path"
            return 0
          fi
        fi
        ;;
    esac
    if [ "$rows" -ne 1 ] || [ "$source_mode" != "100644" ] || [ "$target_mode" != "100644" ] || [ "$change_status" != "M" ]; then
      printf 'deep\tquick-file-status\t%s\t-\n' "$path"
      return 0
    fi
  done
  printf 'quick\n'
}

# quick_classify_paths <root> <from-tree> <head-sha> <paths-file>: the path
# stage. Prints `quick` or `deep<TAB><reason><TAB><path><TAB>-`; returns 2 on
# any internal failure, printing nothing.
quick_classify_paths() {
  local scratch output status=0
  declare -F light_route_diff >/dev/null 2>&1 || return 2
  [ "$#" -eq 4 ] || return 2
  _quick_read_paths "$4" || return 2
  scratch="$(mktemp -d 2>/dev/null)" || return 2
  output="$(_quick_paths_run "$1" "$2" "$3" "$scratch")" || status=$?
  rm -rf "$scratch"
  _quick_emit "$status" "$output"
}

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
IFS= read -r -d '' _QUICK_LINE_PROGRAM <<'AWK' || true
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
function load(s, file,   line, n, r) {
  n = 0
  while ((r = (getline line < file)) > 0) { n++; sub(/\r$/, "", line); raw[s, n] = line }
  if (r < 0) failed = 1
  close(file)
  nlines[s] = n
}

# ---- TSX lexer -------------------------------------------------------------
function emit(x) { if (capdepth > 0) capbuf = capbuf x; else kbuf = kbuf x }
function cvadd(x) { cvbuf = cvbuf x }
function addseg(type, name, value,   n) {
  if (type != "K") flushK()
  n = ++segn[CS, CL]; sgt[CS, CL, n] = type; sgn[CS, CL, n] = name; sgv[CS, CL, n] = value
}
function flushK() { if (kbuf ~ /[^ \t]/) { addseg("K", "", trim(kbuf)) } kbuf = "" }
# Text inside these elements is code or markup to the browser, not copy.
function flushT() {
  if (tbuf ~ /[^ \t]/) {
    addseg("T", "", trim(tbuf)); hastext[CS, CL] = 1
    if (depth > 0 && fname[depth] ~ /^(script|style|noscript|iframe|object|template)$/) textunsafe[CS, CL] = 1
  }
  tbuf = ""
}
function cnmark(x) { if (depth > 0 && ft[depth] == "paren" && fname[depth] == "cn") fbuf[depth] = fbuf[depth] x }
function pushf(type, name,   p) {
  p = depth
  if (p > 0 && ft[p] == "paren" && fname[p] == "cn") fbuf[p] = fbuf[p] "N"
  depth++; frameseq++
  ft[depth] = type; fname[depth] = name; fline[depth] = CL; fid[depth] = frameseq
  fprop[depth] = ""; fattr[depth] = ""; fbuf[depth] = ""; fstory[depth] = ""
  if (type == "paren" && name == "cva") { cvadepth++; cvaany[CS, CL] = 1 }
  if (type == "paren" && name == "cn") { cndepth++; cnopen[CS, CL]++ }
  if (type == "brace" && p == 0 && pendstory != "" && prev == "=") { fstory[depth] = "story:" pendstory; pendstory = ""; pendstate = 0 }
  if (type == "brace" && p > 0 && fstory[p] ~ /^story:/ && fprop[p] == "args") fstory[depth] = "args"
}
function popf(   b) {
  if (ft[depth] == "paren" && fname[depth] == "cva") cvadepth--
  if (ft[depth] == "paren" && fname[depth] == "cn") {
    cndepth--
    b = fbuf[depth]
    cnstatic[CS, fid[depth]] = (b ~ /^Q(,Q)*,?$/) ? 1 : 0
    cnargs[CS, fid[depth]] = gsub(/Q/, "Q", b)
  }
  depth--
}
function fail_image() { err[CS] = 1 }
function startcap(kind, name) {
  if (capdepth == 0) { capdepth = depth + 1; capbuf = "{"; capkind = kind; capname = name } else emit("{")
}
function afterjsx() { if (depth == 0 || ft[depth] != "jsxchild") { prev = ")"; prevword = "" } }
function regex_allowed() {
  if (prev == "" || index("(,=:[!&|?{};", prev) > 0) return 1
  return (prev == "a" && (prevword == "return" || prevword == "typeof"))
}
function jsx_allowed(n) {
  if (n !~ /^[A-Za-z>]$/) return 0
  if (prev == "" || index("(,=:[!&|?{};>", prev) > 0) return 1
  return (prev == "a" && (prevword == "return" || prevword == "default"))
}
function scan_regex(line, i,   j, ch, inclass) {
  inclass = 0
  for (j = i + 1; j <= linelength; j++) {
    ch = substr(line, j, 1)
    if (ch == "\\") { j++; continue }
    if (ch == "[") inclass = 1
    else if (ch == "]") inclass = 0
    else if (ch == "/" && !inclass) {
      while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[a-z]/) j++
      return j
    }
  }
  return 0
}
function open_tag(line, i,   j, k, nm) {
  j = i + 1; k = j
  while (k <= linelength && substr(line, k, 1) ~ /[A-Za-z0-9_$.:-]/) k++
  nm = substr(line, j, k - j)
  if (capdepth == 0) { flushK(); flushT(); addseg("O", nm, "") } else emit("<" nm)
  cvadd(" <" nm)
  tagl = tagl " o:" nm
  if (nm == "") {
    if (substr(line, k, 1) != ">") { fail_image(); return linelength }
    pushf("jsxchild", "")
    if (capdepth == 0) addseg("E", "", ""); else emit(">")
    return k
  }
  pushf("jsxtag", nm)
  return k - 1
}
function jsx_tag_char(line, i, c,   k, j, nm, q, e, val) {
  if (c == " " || c == "\t") { if (capdepth > 0) emit(c); return i }
  if (c == "/" && substr(line, i + 1, 1) == ">") {
    if (capdepth > 0) emit("/>"); else addseg("S", "", "")
    popf(); afterjsx(); return i + 1
  }
  if (c == ">") { if (capdepth > 0) emit(">"); else addseg("E", "", ""); ft[depth] = "jsxchild"; return i }
  if (c == "{") { startcap("X", ""); pushf("attrexpr", ""); cvadd(" {"); return i }
  if (c ~ /[A-Za-z_$]/) {
    k = i
    while (k + 1 <= linelength && substr(line, k + 1, 1) ~ /[A-Za-z0-9_$:.-]/) k++
    nm = substr(line, i, k - i + 1)
    cvadd(" " nm)
    j = k + 1
    while (j <= linelength && substr(line, j, 1) ~ /[ \t]/) j++
    if (substr(line, j, 1) != "=") { if (capdepth > 0) emit(" " nm); else addseg("A", nm, ""); return k }
    cvadd("=")
    j++
    while (j <= linelength && substr(line, j, 1) ~ /[ \t]/) j++
    q = substr(line, j, 1)
    if (q == "\"" || q == "'") {
      cvadd("\"\"")
      e = index(substr(line, j + 1), q)
      if (e == 0) {
        inattrstr = q; attrname = nm
        if (capdepth > 0) emit(" " nm "=" substr(line, j)); else attrval = substr(line, j)
        return linelength
      }
      val = substr(line, j, e + 1)
      if (capdepth > 0) emit(" " nm "=" val); else addseg("A", nm, val)
      return j + e
    }
    if (q == "{") {
      if (capdepth > 0) emit(" " nm "=")
      startcap("A", nm); pushf("attrexpr", ""); fattr[depth] = nm; cvadd("{")
      return j
    }
    fail_image(); return linelength
  }
  fail_image(); return linelength
}
function jsx_child_char(line, i, c,   k, j, nm) {
  if (c == "{") { flushT(); startcap("X", ""); pushf("childexpr", ""); cvadd("{"); return i }
  if (c == "<") {
    if (substr(line, i + 1, 1) == "/") {
      k = i + 2
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      j = k
      while (k <= linelength && substr(line, k, 1) ~ /[A-Za-z0-9_$.:-]/) k++
      nm = substr(line, j, k - j)
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      if (substr(line, k, 1) != ">" || nm != fname[depth]) { fail_image(); return linelength }
      flushT()
      if (capdepth > 0) emit("</" nm ">"); else addseg("C", nm, "")
      tagl = tagl " c:" nm
      cvadd(" </" nm)
      popf(); afterjsx(); return k
    }
    if (substr(line, i + 1, 1) ~ /^[A-Za-z>]$/) { flushT(); return open_tag(line, i) }
    fail_image(); return linelength
  }
  if (capdepth > 0) emit(c); else tbuf = tbuf c
  return i
}
function code_char(line, i, c,   n, j, k, w, callee, t) {
  n = substr(line, i + 1, 1)
  if (c == " " || c == "\t") { emit(c); cvadd(c); return i }
  if (c == "/" && n == "/") { w = substr(line, i); emit(w); cvadd(w); return linelength }
  if (c == "/" && n == "*") { emit("/*"); inblock = 1; return i + 1 }
  if (c == "\"" || c == "'") { emit(c); instr = c; cvadd("\"\""); cnmark("Q"); return i }
  if (c == "`") { emit(c); cvadd("`"); cnmark("T"); pushf("tmpl", ""); return i }
  if (c == "/" && regex_allowed()) {
    j = scan_regex(line, i)
    if (j == 0) { fail_image(); return linelength }
    emit(substr(line, i, j - i + 1)); cvadd("/r/"); cnmark("R"); prev = ")"; prevword = ""
    return j
  }
  if (c == "<" && jsx_allowed(n)) return open_tag(line, i)
  if (c ~ /[A-Za-z_$]/) {
    j = i
    while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[A-Za-z0-9_$]/) j++
    w = substr(line, i, j - i + 1)
    emit(w); cvadd(w); cnmark("I")
    if (depth == 0) {
      if (w == "export") pendstate = 1
      else if (w == "const" && pendstate == 1) pendstate = 2
      else if (pendstate == 2) { pendstory = w; pendstate = 3 }
      else if (pendstate != 3) pendstate = 0
    }
    if (depth > 0 && ft[depth] == "brace" && (prev == "{" || prev == ",")) {
      k = j + 1
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      if (substr(line, k, 1) == ":") {
        fprop[depth] = w
        if (fstory[depth] ~ /^story:/ && w == "play") playany[CS, CL] = 1
      }
    }
    prev = "a"; prevword = w
    return j
  }
  if (c ~ /[0-9]/) {
    j = i
    while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[A-Za-z0-9_.]/) j++
    w = substr(line, i, j - i + 1)
    emit(w); cvadd(w); cnmark("D"); prev = "a"; prevword = ""
    return j
  }
  if (c == "{" || c == "(" || c == "[") {
    emit(c); cvadd(c)
    callee = (c == "(" && prev == "a") ? prevword : ""
    pushf(c == "{" ? "brace" : (c == "(" ? "paren" : "bracket"), callee)
    prev = c; prevword = ""
    return i
  }
  if (c == "}") {
    if (depth == 0) { fail_image(); return linelength }
    t = ft[depth]
    emit(c); cvadd(c)
    if (t == "tmplexpr") { popf(); return i }
    if (t == "attrexpr" || t == "childexpr") {
      if (depth == capdepth) { addseg(capkind, capname, capbuf); capdepth = 0; capbuf = "" }
      popf(); return i
    }
    if (t != "brace") { fail_image(); return linelength }
    popf(); prev = "}"; prevword = ""
    return i
  }
  if (c == ")" || c == "]") {
    if (depth == 0 || ft[depth] != (c == ")" ? "paren" : "bracket")) { fail_image(); return linelength }
    emit(c); cvadd(c); popf(); prev = c; prevword = ""
    return i
  }
  emit(c); cvadd(c); cnmark(c)
  if (c == ";" && depth == 0) { pendstate = 0; pendstory = "" }
  prev = c; prevword = ""
  return i
}
function mode_now(   t) {
  if (inblock) return "BLOCK"
  if (instr != "") return "STRING"
  if (inattrstr != "") return "ATTRSTR"
  t = (depth > 0) ? ft[depth] : ""
  if (t == "tmpl") return "TMPL"
  if (t == "jsxtag") return "JSXTAG"
  if (t == "jsxchild") return "JSXCHILD"
  return "CODE"
}
function line_start(s, L,   k) {
  ctx0[s, L] = mode_now()
  d0[s, L] = depth
  cnd0[s, L] = cndepth
  if (cvadepth > 0) cvaany[s, L] = 1
  for (k = depth; k >= 1; k--) if (ft[k] == "jsxtag") { tagname0[s, L] = fname[k]; tagline0[s, L] = fline[k]; tagin0[s, L] = 1; break }
  for (k = depth; k >= 1; k--) if (ft[k] == "attrexpr") { attr0[s, L] = fattr[k]; break }
  for (k = 1; k <= depth; k++) if (fstory[k] ~ /^story:/) { story0[s, L] = substr(fstory[k], 7); if (fprop[k] == "play") playany[s, L] = 1; break }
  argsdirect0[s, L] = (depth > 0 && fstory[depth] == "args") ? 1 : 0
  storytop0[s, L] = (depth > 0 && fstory[depth] ~ /^story:/) ? 1 : 0
  cnframe0[s, L] = (depth > 0 && ft[depth] == "paren" && fname[depth] == "cn") ? fid[depth] : 0
}
function line_end(s, L,   k, key, rest) {
  flushT()
  if (capdepth > 0 && capbuf != "") { addseg(capkind "~", capname, capbuf); capbuf = "" }
  if (inattrstr != "" && capdepth == 0) { addseg("A~", attrname, attrval); attrval = "" }
  flushK()
  cv[s, L] = cvbuf
  tagnames[s, L] = tagl
  d1[s, L] = depth
  cnd1[s, L] = cndepth
  for (k = 1; k <= depth; k++) if (fstory[k] ~ /^story:/) { if (fprop[k] == "play") playany[s, L] = 1; break }
  if (argsdirect0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ ARGLINE) {
    key = raw[s, L]; sub(/^[ \t]*/, "", key); sub(/[ \t]*:.*$/, "", key)
    argskey[s, story0[s, L], key] = 1
  }
  if (storytop0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ ARGINLINE) {
    argsinline[s, story0[s, L]] = inline_keys(raw[s, L])
  }
}
function inline_keys(t,   rest, keys, key) {
  rest = t; sub(/^[ \t]*args:[ \t]*\{[ \t]*/, "", rest); keys = ""
  while (match(rest, "^" ARGPAIR)) {
    key = substr(rest, 1, RLENGTH); sub(/[ \t]*:.*$/, "", key)
    keys = keys "," key
    rest = substr(rest, RLENGTH + 1); sub(/^[ \t]*,?[ \t]*/, "", rest)
  }
  return keys
}
function tokenize(s,   L, line, i, c, t) {
  depth = 0; instr = ""; inblock = 0; inattrstr = ""; prev = ""; prevword = ""
  cvadepth = 0; cndepth = 0; capdepth = 0; capbuf = ""; capname = ""; capkind = ""
  pendstate = 0; pendstory = ""; attrval = ""; attrname = ""
  CS = s
  for (L = 1; L <= nlines[s]; L++) {
    CL = L
    line = raw[s, L]; linelength = length(line)
    line_start(s, L)
    kbuf = ""; tbuf = ""; cvbuf = ""; tagl = ""
    for (i = 1; i <= linelength; i++) {
      c = substr(line, i, 1)
      if (inblock) {
        if (c == "*" && substr(line, i + 1, 1) == "/") { emit("*/"); i++; inblock = 0 } else emit(c)
        continue
      }
      if (instr != "") {
        emit(c)
        if (c == "\\") { emit(substr(line, i + 1, 1)); i++; continue }
        if (c == instr) { instr = ""; prev = "\""; prevword = "" }
        continue
      }
      if (inattrstr != "") {
        if (capdepth > 0) emit(c); else attrval = attrval c
        if (c == inattrstr) { inattrstr = ""; if (capdepth == 0) addseg("A~", attrname, attrval); attrval = "" }
        continue
      }
      t = (depth > 0) ? ft[depth] : ""
      if (t == "tmpl") {
        emit(c)
        if (c == "\\") { emit(substr(line, i + 1, 1)); i++; continue }
        if (c == "`") { popf(); prev = ")"; prevword = ""; continue }
        if (c == "$" && substr(line, i + 1, 1) == "{") { emit("{"); i++; pushf("tmplexpr", ""); continue }
        continue
      }
      if (t == "jsxtag") { i = jsx_tag_char(line, i, c); if (err[s]) break; continue }
      if (t == "jsxchild") { i = jsx_child_char(line, i, c); if (err[s]) break; continue }
      i = code_char(line, i, c)
      if (err[s]) break
    }
    line_end(s, L)
    if (err[s]) return
  }
  if (depth != 0 || instr != "" || inblock || inattrstr != "") err[s] = 1
}

# ---- TSX line helpers ------------------------------------------------------
function intrinsic(nm) { return nm ~ /^[a-z][a-z0-9]*$/ }
function has_nonintrinsic(tl,   n, parts, k, nm) {
  n = split(tl, parts, " ")
  for (k = 1; k <= n; k++) { if (parts[k] == "") continue; nm = substr(parts[k], 3); if (!intrinsic(nm)) return 1 }
  return 0
}
function swappable(nm) { return nm == "div" || nm == "span" || nm == "p" }
function tags_compatible(a, b,   na, nb, pa, pb, k, x, y) {
  na = split(a, pa, " "); nb = split(b, pb, " ")
  if (na != nb) return 0
  for (k = 1; k <= na; k++) {
    if (substr(pa[k], 1, 2) != substr(pb[k], 1, 2)) return 0
    x = substr(pa[k], 3); y = substr(pb[k], 3)
    if (x != y && !(swappable(x) && swappable(y))) return 0
  }
  return 1
}
function is_classname(s, L, k) { return (sgt[s, L, k] == "A" || sgt[s, L, k] == "A~") && sgn[s, L, k] == "className" }
function class_kind(v) {
  if (v ~ /^("[^"\\`]*"|'[^'\\`]*')$/) return "s"
  if (v ~ CNSTATIC) return "cn" gsub(LITERAL, "&", v)
  return "x"
}
function other_attrs(s, L,   k, out) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++)
    if ((sgt[s, L, k] == "A" || sgt[s, L, k] == "A~") && sgn[s, L, k] != "className") out = out "\034" sgn[s, L, k] "=" sgv[s, L, k]
  return out
}
function class_sig(s, L,   k, out, kind) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k)) {
    kind = (sgt[s, L, k] == "A~") ? "x" : class_kind(sgv[s, L, k])
    out = out "\034" (kind == "x" ? "x:" sgv[s, L, k] : kind)
  }
  return out
}
function static_cn_count(s, L,   k, n) {
  n = 0
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgt[s, L, k] == "A" && sgv[s, L, k] ~ CNSTATIC) n++
  return n
}
function skeleton(s, L,   k, out, t, nm) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++) {
    t = sgt[s, L, k]; nm = sgn[s, L, k]
    if (t == "T") continue
    if (is_classname(s, L, k)) continue
    if ((t == "O" || t == "C") && swappable(nm)) nm = "~"
    out = out "\034" t "\035" nm "\035" sgv[s, L, k]
  }
  return out
}
function add_tokens(str, set,   n, parts, k) {
  n = split(str, parts, /[ \t]+/)
  for (k = 1; k <= n; k++) if (parts[k] != "") set[parts[k]] = 1
}
function literal_tokens(v, set,   x) {
  while (match(v, LITERAL)) { x = substr(v, RSTART + 1, RLENGTH - 2); add_tokens(x, set); v = substr(v, RSTART + RLENGTH) }
}
function line_tokens(s, L, set, cat,   k) {
  if (cat == "cnlit") { literal_tokens(raw[s, L], set); return }
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgt[s, L, k] == "A") literal_tokens(sgv[s, L, k], set)
}
function class_nonascii(s, L, cat,   k) {
  if (cat == "cnlit") return raw[s, L] ~ nonascii
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgv[s, L, k] ~ nonascii) return 1
  return 0
}
function token_split(tok,   i, ch, d, last) {
  d = 0; last = 0
  for (i = 1; i <= length(tok); i++) {
    ch = substr(tok, i, 1)
    if (ch == "[") d++
    else if (ch == "]") d--
    else if (ch == ":" && d == 0) last = i
  }
  tokprefix = substr(tok, 1, last); tokbase = substr(tok, last + 1)
  sub(/^!/, "", tokbase); sub(/!$/, "", tokbase); sub(/^-/, "", tokbase)
}
function is_hiding(tok) { token_split(tok); if (tokprefix ~ /focus/) return 1; return index(" " hidingset " ", " " tokbase " ") > 0 }
function is_motion(tok) { token_split(tok); return tokbase ~ /^animate-/ || tokbase ~ /^order-/ || tokbase ~ /-reverse$/ || tokbase ~ /^(col|row)-(start|end)-/ }
function is_palette(tok) { token_split(tok); return tokbase ~ PALETTE }
function is_arbitrary(tok) { token_split(tok); return index(tokbase, "[") > 0 || tokbase ~ /^content-/ }
# own: tokens on this side's line that the paired line lacks.
function token_reason(s, L, cat, j, Lj, o,   mine, theirs, tok) {
  split("", mine); split("", theirs)
  line_tokens(s, L, mine, cat)
  if (j) line_tokens(o, Lj, theirs, category(o, Lj))
  for (tok in mine) if (!(tok in theirs) && is_hiding(tok)) return "quick-hiding-token"
  for (tok in mine) if (!(tok in theirs) && is_motion(tok)) return "quick-motion-order-token"
  if (s == "post") for (tok in mine) if (!(tok in theirs) && is_palette(tok)) return "quick-palette"
  for (tok in mine) if (!(tok in theirs) && is_arbitrary(tok)) return "quick-arbitrary-value"
  return ""
}
function only_text(s, L,   k) {
  if (segn[s, L] == 0) return 0
  for (k = 1; k <= segn[s, L]; k++) if (sgt[s, L, k] != "T") return 0
  return 1
}
function category(s, L,   x) {
  if ((s, L) in catcache) return catcache[s, L]
  x = ctx0[s, L]
  if (err[s]) x = "err"
  else if (raw[s, L] ~ /^[ \t]*$/ && (x == "CODE" || x == "JSXCHILD" || x == "JSXTAG")) x = "blank"
  else if (x == "CODE" && cnframe0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ CNLITLINE) x = "cnlit"
  else if (x == "JSXCHILD" && d1[s, L] == d0[s, L] && only_text(s, L)) x = "text"
  else if (x == "CODE" || x == "JSXCHILD" || x == "JSXTAG") x = "struct"
  else x = "other"
  catcache[s, L] = x
  return x
}
function generic_reason(c) {
  if (c ~ /^[ \t]*(import|export)([^A-Za-z0-9_$]|$)/ || c ~ /(^|[^A-Za-z0-9_$.])(import|require)[ \t]*\(/) return "quick-import"
  if (c ~ /(^|[^A-Za-z0-9_$])use[A-Z][A-Za-z0-9_$]*[ \t]*(<[^()]*>)?[ \t]*\(/) return "quick-hook"
  if (c ~ /(^|[^A-Za-z0-9_$])on[A-Z][A-Za-z0-9_$]*[ \t]*=/) return "quick-handler"
  if (index(c, "...") > 0) return "quick-spread"
  if (c ~ /&&|\|\||\?|=>/) return "quick-conditional"
  if (c ~ /\.(map|filter|flatMap|forEach|reduce)[ \t]*\(/) return "quick-map"
  return ""
}
function lexical_reason(s, L, t) {
  if (t ~ bidi) return "quick-codepoint"
  if (index(t, "/*") > 0 || index(t, "*/") > 0 || ctx0[s, L] == "BLOCK") return "quick-block-comment"
  if (index(t, "`") > 0 || ctx0[s, L] == "TMPL") return "quick-template-literal"
  return ""
}
function eval_tsx(i,   s, o, L, j, Lj, t, c, cat, r, f, g) {
  s = chs[i]; L = chl[i]; o = (s == "pre") ? "post" : "pre"; j = pairof[i]; Lj = j ? chl[j] : 0
  t = raw[s, L]
  cat = category(s, L)
  if (cat == "blank") return ""
  if (t ~ bidi) return "quick-codepoint"
  if (cat != "err" && class_nonascii(s, L, cat)) return "quick-codepoint"
  r = lexical_reason(s, L, t); if (r != "") return r
  c = (cat == "err") ? t : cv[s, L]
  r = generic_reason(c); if (r != "") return r
  if (cat == "err") return "quick-unclassified"
  if (cvaany[s, L] || c ~ /(^|[^A-Za-z0-9_$.])cva[ \t]*\(/) return "quick-cva"
  if (cat == "cnlit") {
    if (!j) return "quick-cn-argument"
    f = cnframe0[s, L]; g = cnframe0[o, Lj]
    if (!cnstatic[s, f] || !cnstatic[o, g] || cnargs[s, f] != cnargs[o, g]) return "quick-cn-argument"
    if (tagin0[s, L] && !intrinsic(tagname0[s, L]) && changed[s, tagline0[s, L]]) return "quick-element"
    if (attr0[s, L] != "" && attr0[s, L] != "className") return "quick-attribute"
    return token_reason(s, L, cat, j, Lj, o)
  }
  if (cnd0[s, L] > 0 || cnd1[s, L] > 0 || cnopen[s, L] > static_cn_count(s, L)) return "quick-cn-argument"
  if (textunsafe[s, L]) return "quick-unclassified"
  if (cat == "text") {
    if (s == "pre" && !hunkaddtext[chh[i]]) return "quick-text-deleted"
    return ""
  }
  if (cat != "struct") return "quick-unclassified"
  if (has_nonintrinsic(tagnames[s, L]) || (j && has_nonintrinsic(tagnames[o, Lj]))) return "quick-element"
  if (ctx0[s, L] == "JSXTAG" && tagin0[s, L] && !intrinsic(tagname0[s, L]) && changed[s, tagline0[s, L]]) return "quick-element"
  if (!j) { if (tagnames[s, L] != "") return "quick-tag" }
  else if (!tags_compatible(tagnames[s, L], tagnames[o, Lj])) return "quick-tag"
  if (attr0[s, L] != "" && attr0[s, L] != "className") return "quick-attribute"
  if (other_attrs(s, L) != (j ? other_attrs(o, Lj) : "")) return "quick-attribute"
  if (j) { r = class_value_reason(class_sig(s, L), class_sig(o, Lj)); if (r != "") return r }
  r = token_reason(s, L, cat, j, Lj, o); if (r != "") return r
  if (s == "pre" && hastext[s, L] && !hunkaddtext[chh[i]]) return "quick-text-deleted"
  if (!j) return "quick-unclassified"
  if (skeleton(s, L) != skeleton(o, Lj)) return "quick-unclassified"
  return ""
}
# Two className value signatures that differ: a non-static value differing, a
# cn() call gained, lost or changing its literal count, or a static string
# turned into cn() is not a token change. A className added or removed as a
# static string is (its tokens go through the token checks).
function class_value_reason(a, b,   na, nb, pa, pb) {
  if (a == b) return ""
  if (index(a, "x:") > 0 || index(b, "x:") > 0) return (index(a b, "cn(") > 0) ? "quick-cn-argument" : "quick-unclassified"
  na = split(a, pa, "\034"); nb = split(b, pb, "\034")
  if (na == nb || index(a b, "cn") > 0) return "quick-cn-argument"
  return ""
}

# ---- story lines -----------------------------------------------------------
function eval_story(i,   s, o, L, t, c, cat, r, key) {
  s = chs[i]; L = chl[i]; o = (s == "pre") ? "post" : "pre"
  t = raw[s, L]
  cat = category(s, L)
  if (cat == "blank") return ""
  r = lexical_reason(s, L, t); if (r != "") return r
  c = (cat == "err") ? t : cv[s, L]
  r = generic_reason(c); if (r != "") return r
  if (c ~ PLAYWORDS || index(c, "within(") > 0 || playany[s, L]) return "quick-story-play"
  if (cat == "err") return "quick-story-shape"
  if (argsdirect0[s, L] && d1[s, L] == d0[s, L] && t ~ ARGLINE) {
    key = t; sub(/^[ \t]*/, "", key); sub(/[ \t]*:.*$/, "", key)
    if ((o, story0[s, L], key) in argskey) return ""
    return "quick-story-shape"
  }
  if (storytop0[s, L] && d1[s, L] == d0[s, L] && t ~ ARGINLINE) {
    if (((o, story0[s, L]) in argsinline) && argsinline[o, story0[s, L]] == argsinline[s, story0[s, L]]) return ""
    return "quick-story-shape"
  }
  return "quick-story-shape"
}

# ---- language files ----------------------------------------------------------
function key_text(k) { if (k ~ /^'/) return substr(k, 2, length(k) - 2); return k }
function key_path(n, last,   k, out) {
  out = ""
  for (k = 1; k <= n; k++) out = out lkeystack[k] "\036"
  return out last
}
function lang_record(s, L, kind, K, value) {
  lkind[s, L] = kind
  if (K == "") return
  lkey[s, L] = K
  if (kind == "value" || kind == "wrapvalue") {
    if ((s, K) in lhas) { lerr[s] = 1; return }
    lhas[s, K] = 1; lval[s, K] = value
  }
}
function langparse(s,   L, t, d, root, closed, wrap, wrapkey, k, v, K) {
  d = 0; root = 0; closed = 0; wrap = 0
  for (L = 1; L <= nlines[s]; L++) {
    t = raw[s, L]
    if (t ~ /^[ \t]*$/) { lkind[s, L] = "blank"; if (wrap) lerr[s] = 1; continue }
    if (wrap) {
      if (t ~ /^[ \t]*'[^'\\]*',[ \t]*$/) {
        v = t; sub(/^[ \t]*'/, "", v); sub(/',[ \t]*$/, "", v)
        lang_record(s, L, "wrapvalue", wrapkey, v); wrap = 0; continue
      }
      lerr[s] = 1; lkind[s, L] = "other"; wrap = 0; continue
    }
    if (closed) { lerr[s] = 1; lkind[s, L] = "other"; continue }
    if (t ~ /^[ \t]*\/\//) { lkind[s, L] = "comment"; continue }
    if (d == 0) {
      if (!root && t ~ /^export default \{[ \t]*$/) { root = 1; d = 1; lkind[s, L] = "root"; continue }
      lerr[s] = 1; lkind[s, L] = "other"; continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*'[^'\\\\]*',[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      v = t; sub(/^[^']*'/, "", v); if (t ~ /^[ \t]*'/) { v = t; sub(/^[ \t]*'[^']*'[ \t]*:[ \t]*'/, "", v) }
      sub(/',[ \t]*$/, "", v)
      lang_record(s, L, "value", key_path(d - 1, k), v); continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      wrapkey = key_path(d - 1, k); wrap = 1; lang_record(s, L, "wrapkey", wrapkey, ""); continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*\\{[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      lang_record(s, L, "open", key_path(d - 1, k), ""); lkeystack[d] = k; d++; continue
    }
    if (d > 1 && t ~ /^[ \t]*\},[ \t]*$/) { d--; lang_record(s, L, "close", key_path(d - 1, lkeystack[d]), ""); continue }
    if (d == 1 && t ~ /^\}( as const)?;[ \t]*$/) { d = 0; closed = 1; lkind[s, L] = "root"; continue }
    lerr[s] = 1; lkind[s, L] = "other"
  }
  if (d != 0 || !closed || wrap) lerr[s] = 1
}
function sorted_matches(v, re,   n, list, k, m, x, out) {
  n = 0
  while (match(v, re)) { list[++n] = substr(v, RSTART, RLENGTH); v = substr(v, RSTART + RLENGTH) }
  for (k = 2; k <= n; k++) { x = list[k]; m = k - 1; while (m >= 1 && list[m] > x) { list[m + 1] = list[m]; m-- } list[m + 1] = x }
  out = ""
  for (k = 1; k <= n; k++) out = out "\034" list[k]
  return out
}
function eval_lang(i,   s, o, L, t, c, r, kind, K, oldv, newv, loc) {
  s = chs[i]; L = chl[i]; o = (s == "pre") ? "post" : "pre"
  t = raw[s, L]
  kind = lkind[s, L]
  if (t ~ /^[ \t]*$/ && !lerr[s]) return ""
  r = lexical_reason(s, L, t); if (r != "") return r
  c = t; gsub(/'[^']*'/, "''", c)
  r = generic_reason(c); if (r != "") return r
  if (lerr[s] || lerr[o]) return "quick-language-shape"
  if (kind == "open" || kind == "close") return "quick-language-key"
  if (kind != "value" && kind != "wrapvalue" && kind != "wrapkey") return "quick-language-shape"
  K = lkey[s, L]
  if (!((o, K) in lhas)) return "quick-language-key"
  if (s == "pre" && (K in postchangedkey)) return ""
  oldv = lval["pre", K]; newv = lval["post", K]
  if (sorted_matches(oldv, "\\{\\{[^}]*\\}\\}") != sorted_matches(newv, "\\{\\{[^}]*\\}\\}")) return "quick-placeholder"
  if (sorted_matches(oldv, "\\$t\\([^)]*\\)") != sorted_matches(newv, "\\$t\\([^)]*\\)")) return "quick-nesting"
  if (index(oldv, "<") > 0 || index(newv, "<") > 0) return "quick-html"
  if (newv ~ /^[ \t]*$/) return "quick-empty-value"
  for (loc in sibloc) if (!((loc, K) in sibhas)) return "quick-locale-missing"
  return ""
}

BEGIN {
  LITERAL = "(\"[^\"\\\\`]*\"|'[^'\\\\`]*')"
  CNSTATIC = "^\\{[ \t]*cn\\([ \t]*" LITERAL "([ \t]*,[ \t]*" LITERAL ")*[ \t]*,?[ \t]*\\)[ \t]*\\}$"
  CNLITLINE = "^[ \t]*" LITERAL ",?[ \t]*$"
  STORYLIT = "('[^'\\\\`]*'|\"[^\"\\\\`]*\"|-?[0-9]+(\\.[0-9]+)?|true|false)"
  ARGLINE = "^[ \t]*[A-Za-z_$][A-Za-z0-9_$]*:[ \t]*" STORYLIT ",?[ \t]*$"
  ARGPAIR = "[A-Za-z_$][A-Za-z0-9_$]*:[ \t]*" STORYLIT
  ARGINLINE = "^[ \t]*args:[ \t]*\\{[ \t]*" ARGPAIR "([ \t]*,[ \t]*" ARGPAIR ")*[ \t]*,?[ \t]*\\},?[ \t]*$"
  PLAYWORDS = "(^|[^A-Za-z0-9_$])(play|expect|userEvent|waitFor|assert[A-Za-z0-9_$]*)([^A-Za-z0-9_$]|$)"
  PALETTE = "^(" paletteutilities ")(-[a-z]+)?-(" palettecolors ")(-[0-9]+)?(/.*)?$"
  LKEY = "([A-Za-z_$][A-Za-z0-9_$]*|'[^'\\\\]*')"
  if (mode == "keys") {
    load("pre", prefile)
    if (!failed) {
      langparse("pre")
      if (!lerr["pre"]) for (k in lhas) { split(k, kp, SUBSEP); print kp[2] }
    }
    exit
  }
  load("pre", prefile); load("post", postfile)
  if (class == "language") {
    langparse("pre"); langparse("post")
    while ((r = (getline sline < siblingfile)) > 0) {
      tab = index(sline, "\t")
      if (tab == 0) continue
      sloc = substr(sline, 1, tab - 1); skey = substr(sline, tab + 1)
      sibloc[sloc] = 1
      if (skey != "") sibhas[sloc, skey] = 1
    }
    if (r < 0) failed = 1
    close(siblingfile)
  } else {
    tokenize("pre"); tokenize("post")
  }
  started = 0; hunks = 0; nchg = 0
}
mode == "keys" { next }
/^@@ / {
  field = $2; sub(/^-/, "", field); split(field, parts, ","); prenext = parts[1] + 0
  field = $3; sub(/^\+/, "", field); split(field, parts, ","); postnext = parts[1] + 0
  hunks++; started = 1; next
}
/^Binary files / || /^GIT binary patch/ { binary = 1; next }
!started { next }
/^\\/ { next }
/^-/ { nchg++; chs[nchg] = "pre"; chl[nchg] = prenext++; chh[nchg] = hunks; next }
/^\+/ { nchg++; chs[nchg] = "post"; chl[nchg] = postnext++; chh[nchg] = hunks; next }
END {
  if (mode == "keys") exit
  if (failed) { print "ERROR"; exit }
  if (binary) { print "quick-unclassified\t-"; exit }
  for (i = 1; i <= nchg; i++) {
    if (chl[i] < 1 || chl[i] > nlines[chs[i]]) { print "ERROR"; exit }
    changed[chs[i], chl[i]] = 1
  }
  if (class == "language") {
    for (i = 1; i <= nchg; i++) if (chs[i] == "post" && (("post", chl[i]) in lkey)) postchangedkey[lkey["post", chl[i]]] = 1
    for (i = 1; i <= nchg; i++) { r = eval_lang(i); if (r != "") { print r "\t" chs[i] ":" chl[i]; exit } }
    print "ok"; exit
  }
  for (i = 1; i <= nchg; i++) {
    s = chs[i]; L = chl[i]
    if (hastext[s, L]) { if (s == "pre") hunkdeltext[chh[i]] = 1; else hunkaddtext[chh[i]] = 1 }
    cat = category(s, L)
    if (cat != "struct" && cat != "cnlit") continue
    key = chh[i] SUBSEP cat
    if (s == "pre") { dn[key]++; position[i] = dn[key]; delq[key, dn[key]] = i }
    else { an[key]++; position[i] = an[key]; addq[key, an[key]] = i }
  }
  for (i = 1; i <= nchg; i++) {
    if (!(i in position)) continue
    key = chh[i] SUBSEP category(chs[i], chl[i])
    if (chs[i] == "pre" && ((key, position[i]) in addq)) pairof[i] = addq[key, position[i]]
    if (chs[i] == "post" && ((key, position[i]) in delq)) pairof[i] = delq[key, position[i]]
  }
  for (i = 1; i <= nchg; i++) {
    r = (class == "story") ? eval_story(i) : eval_tsx(i)
    if (r != "") { print r "\t" chs[i] ":" chl[i]; exit }
  }
  print "ok"
}
AWK
