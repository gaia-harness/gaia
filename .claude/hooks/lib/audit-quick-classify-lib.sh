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
# Reasons. Router-owned rows pre-empt the classifier on a first dispatch, except
# over-cap (after its paths stage) and fence-collision (after its lines stage); the
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
#   quick-element  a capitalized element added, removed or renamed, or a change on its element line other than the admitted one-line className change
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
# string literals and keep their count; the same className change on an
# existing capitalized element nested as the whole value of an attribute
# expression (render={<Button ... />}, optionally in one pair of parentheses),
# on its own attribute lines with its tag line unchanged and every enclosing
# attribute expression on the chain holding just one such element, its
# attributes read as that element's own; a one-line capitalized element (one
# opening, beginning and ending on the line, outside every attribute
# expression) whose two sides differ only in one static className string,
# added, changed or removed, the lines byte-identical once that attribute is
# removed; a language value change keeping key,
# placeholders, $t() references and HTML-free form, present in every sibling
# locale; a literal value change inside an existing story export's args object.
# Both className shapes run every check a top-level intrinsic element's
# className gets (tokens, class value, other attributes, codepoint, cn count).
#
# Honest limits. The line grammar is a lexer, not a TypeScript parser: it tracks
# strings, comments, template literals, regex literals, brackets and JSX
# nesting, and when that tracking goes inconsistent anywhere in an image it
# gives up on the whole image (every changed line in it is deep). A JSX `<`
# is recognized only after an operator, an opening bracket or `return`, so a
# generic arrow function written `<T,>(` reads as JSX and fails the image
# closed. A div wrapper added around text is a tag addition (deep), not a swap.
# A className added or removed whole on a capitalized element can replace a
# custom component's default className, and routes quick when its tokens pass.
# A className line inserted into or deleted from a multi-line capitalized
# element stays quick-unclassified. The deny lists above are the whole check,
# so the reveal and soft-hiding spellings they do not carry (display utilities
# such as block or flex, visible, opacity-* other than opacity-0,
# pointer-events-auto, h-0, w-0, max-h-0, max-w-0, scale-0, text-transparent,
# -translate-*-full) route quick on the nested and one-line shapes exactly as on
# a top-level intrinsic element.

# The stage siblings read these lists; shellcheck does not follow the loader.
# shellcheck disable=SC2034
QUICK_HIDING_TOKENS='sr-only not-sr-only hidden invisible collapse opacity-0 size-0 outline-none outline-hidden ring-0 pointer-events-none'
# shellcheck disable=SC2034
QUICK_PALETTE_UTILITIES='bg|text|border|ring|fill|stroke|from|via|to|outline|decoration|shadow|accent|caret|divide|placeholder'
# shellcheck disable=SC2034
QUICK_PALETTE_COLORS='slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|black|white'
# shellcheck disable=SC2034
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

# The stages and the awk program load from this file's own directory, never
# cwd. The awk fragments load before the line stage, which joins them. A
# sibling that is missing, fails to source, or leaves an entry point or the
# program undefined leaves the library unusable: the source prints why and
# returns 1, and the public entry points are removed so a caller that checks
# them with `command -v` refuses the classifier instead of trusting half of it.
_quick_load_siblings() {
  local directory="${BASH_SOURCE[0]%/*}" sibling
  [ "$directory" != "${BASH_SOURCE[0]}" ] || directory=.
  for sibling in paths awk-lexer awk-nested awk-helpers awk-main lines; do
    [ -f "$directory/audit-quick-classify-$sibling-lib.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$directory/audit-quick-classify-$sibling-lib.sh" || return 1
  done
  declare -F quick_classify_paths >/dev/null 2>&1 && declare -F quick_classify_lines >/dev/null 2>&1 &&
    [ -n "${_QUICK_LINE_PROGRAM:-}" ]
}

if ! _quick_load_siblings; then
  printf 'audit-quick-classify-lib.sh: a sibling library beside %s is missing or incomplete; the quick classifier is unusable\n' "${BASH_SOURCE[0]}" >&2
  unset -f quick_classify_paths quick_classify_lines quick_story_component quick_path_class
  return 1
fi
