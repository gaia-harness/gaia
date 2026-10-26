#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk program below is single-quoted
# precisely so every `$` and awk field reference reaches awk as literal
# program text. shellcheck's built-in awk heuristic, which exempts a literal
# single-quoted program handed to a bare `awk` command word, does not extend
# to one handed to a variable command word ("$GAIA_AWK"), so this file needs
# the directive that a bare-`awk` invocation would not have.
# shellcheck disable=SC2016
#
# lint-jq-as-binding.sh: flag every jq `as` binding with an unparenthesized
# operator to its left. Run it directly from the repo root:
# `bash .gaia/scripts/lint-jq-as-binding.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. These statuses say the gate never ran at
# all: 2 when guard-awk-lib.sh is missing beside this script, 3 when the
# scan-surface discovery failed, 5 when no awk interpreter is present at all,
# and 6 when GAIA_AWK resolves to an interpreter
# that identifies as neither mawk nor BWK one-true-awk.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite .gaia/scripts/tests/lint-jq-as-binding.bats,
# which the `Audit CI Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh
# so every shell-lint caller enforces the class.
# gaia:maintainer-only:end
#
# Why: jq 1.8 changed how far left an `as` binding reaches. jq 1.7 binds only
# the operand next to `as`, so `A and X as $v | body` is `A and (X as $v |
# body)`; jq 1.8 binds the whole operator expression, `(A and X) as $v | body`.
# The same program runs under both and returns different values with no error,
# so the defect is invisible on whichever version the author tested with. It
# holds for every binary operator, `//` and the assignment family (`=`, `|=`,
# `+=`, `//=` and the rest) included, and for unary `-`. A boundary that ends
# the expression (`|`, `,`, `;`, `:`, an open bracket, a keyword such as `then`)
# reads the same under both, so only an operator between such a boundary and
# `as` is a hit. Parenthesizing either reading makes the program mean one thing
# everywhere.
#
# Why a static lint rather than a test run on jq 1.8: CI and the maintainer's
# machine both carry jq 1.7, so only a check that does not depend on the
# installed jq runs everywhere, and it reaches programs no test exercises.
#
# How: the file is read whole and each `as` that starts a binding (`as $x`,
# `as [`, `as {`) is walked leftwards, stepping over balanced brackets and
# double-quoted strings, until a boundary (clean) or an operator (hit).
#
# Honest limits, all false negatives:
#   - Full-line `#` comments are blanked first; a trailing comment is read as
#     code, so an apostrophe in one can end the walk early.
#   - A single quote ends the walk, because it is where a shell-quoted program
#     begins. A program in a double-quoted shell string reads its `\"` as a
#     string edge, and a string the walk cannot close on the same line ends the
#     walk rather than guessing.
#   - Standalone `.jq` files and bats suites are not scanned: the only `.jq`
#     files are test fixtures, and in a bats suite jq is assertion plumbing whose
#     sed and awk strings read as jq to this walk.

set -euo pipefail

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, and an unbracketed load
# would abort the script outright if the library were ever present but
# unparseable. This gate reads none of the library's awk, only its
# scan-surface discovery.
_gaia_guard_library_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_library_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_library_directory="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf 'lint-jq-as-binding: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-jq-as-binding: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-jq-as-binding: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENTITY" >&2
    exit 6
    ;;
esac

gaia_guard_scan_files lint-jq-as-binding shell githooks workflows || exit $?

# scan_file <path>: print one `file:line: message` per hit.
scan_file() {
  local file_path="$1"
  "$GAIA_AWK" -v file="$file_path" '
    BEGIN { text = "\n" }
    {
      line = $0
      if (line ~ /^[ \t]*#/) line = ""
      text = text line "\n"
      line_end[FNR] = length(text)
    }
    # word_start <i>: index just before the run of word characters ending at i.
    function word_start(i) {
      while (i > 0 && substr(text, i, 1) ~ /[A-Za-z0-9_]/) i--
      return i
    }
    # walk <i>: from i leftwards, the operator that makes this binding parse
    # differently between jq versions, or "" when a boundary comes first. The
    # step cap bounds a walk that never meets a boundary; giving up is clean.
    function walk(i,   character, depth, start, word, steps, previous) {
      depth = 0
      steps = 0
      while (i > 0 && steps++ < 4000) {
        character = substr(text, i, 1)
        if (character ~ /[)\]}]/) { depth++; i--; continue }
        if (character ~ /[(\[{]/) { if (depth == 0) return ""; depth--; i--; continue }
        if (character == "\"") {
          i--
          while (i > 0 && !(substr(text, i, 1) == "\"" && substr(text, i - 1, 1) != "\\")) {
            if (substr(text, i, 1) == "\n") return ""
            i--
          }
          i--
          continue
        }
        if (character == "\047") return ""
        if (depth > 0) { i--; continue }
        if (character ~ /[|,;:]/) return ""
        if (character == "=") {
          previous = substr(text, i - 1, 1)
          if (previous == "/" && substr(text, i - 2, 1) == "/") return "//="
          if (previous ~ /[=!<>|+*\/%-]/) return previous "="
          return "="
        }
        if (character == "/") {
          if (substr(text, i - 1, 1) == "/") return "//"
          return "/"
        }
        if (character ~ /[<>+*%-]/) return character
        if (character ~ /[A-Za-z0-9_]/) {
          start = word_start(i)
          word = substr(text, start + 1, i - start)
          if (substr(text, start, 1) ~ /[$.@]/) { i = start - 1; continue }
          if (word == "and" || word == "or") return word
          if (word ~ /^(then|else|elif|if|reduce|foreach|def|label|try|catch|as|import|include)$/) return ""
          i = start
          continue
        }
        i--
      }
      return ""
    }
    END {
      offset = 0
      line_number = 1
      rest = text
      while (match(rest, /[^A-Za-z0-9_$.@]as[ \t\n]+(\$[A-Za-z_]|\[|\{)/)) {
        position = offset + RSTART + 1
        offset += RSTART + RLENGTH - 1
        rest = substr(text, offset + 1)
        operator = walk(position - 1)
        if (operator == "") continue
        while (line_number < NR && line_end[line_number] < position) line_number++
        printf "%s:%d: `%s` left of `as` binds differently in jq 1.7 and 1.8; parenthesize the reading you mean\n", file, line_number, operator
      }
    }
  ' "$file_path"
}

report=""
for file_path in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
  [ -f "$file_path" ] || continue
  hits=$(scan_file "$file_path")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  printf 'Fix each by parenthesizing: `A op (X as $v | body)` keeps the jq 1.7 reading, `(A op X) as $v | body` the jq 1.8 one\n' >&2
  exit 1
fi

echo "lint-jq-as-binding: clean" >&2
exit 0
