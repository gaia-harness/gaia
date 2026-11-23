#!/usr/bin/env bash
# lint-git-path-quoting.sh: flag every executed `git diff --name-only` and every
# executed `git ls-files` that omits `-z`, across the scan surface the
# `scan_files` pathspec below declares and the comment above it explains. Exit
# 1 with a file:line report on any hit, exit 0 when clean. Run it directly from
# the repo root: `bash .gaia/scripts/lint-git-path-quoting.sh`.#
# These statuses say the gate never ran at all: 2 when guard-awk-lib.sh is
# missing beside this script, 5 when no awk interpreter is present at all, and
# 6 when GAIA_AWK resolves to an interpreter that identifies as neither mawk nor
# BWK one-true-awk. A scan surface that came back empty exits 1 with an ERROR
# line.
#
# TypeScript is not this script's surface. The CLI's git listing calls are argv
# arrays rather than shell words, and route through `gitZArgs` in
# .gaia/cli/src/util/git-z.ts instead.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-git-path-quoting.bats, which the `Audit CI
# Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-git-path-quoting.bats`.
# gaia:maintainer-only:end
#
# Why: under git's default `core.quotePath`, a path-listing command C-quotes any
# path carrying a non-ASCII byte, a control character, a double quote or a
# backslash -- it prints `"caf\303\251.txt"`, not `café.txt`. Every consumer
# that then matches the output against a path pattern silently stops matching,
# and in this repository every such consumer fails OPEN: a gate that decides
# "no relevant files changed", or that discovers the files it is about to scan,
# reports its required check green having run nothing. `-z` turns the quoting
# off and NUL-delimits instead.
#
# The class is why this gate exists rather than a review habit. It has been
# found and fixed by hand SEVEN times, every time by a human or an audit member
# reading the code and never once by a check (`#1032`, `#1115`, `#1213`,
# `#1224`, `#1225`, `#1228`, `#1230`). `#1229` is the issue that stopped paying
# that tax for `diff --name-only`, and `#1389` is the one that stopped paying it
# for `ls-files` -- a variant the guard's first shape could not see, which is how
# the class recurred in five discovery call sites INCLUDING this file's own.
#
# Fix a `diff --name-only` hit with the idiom the repository already uses
# throughout:
#
#   changed="$(git diff --name-only -z "${base}...HEAD" | tr '\0' '\n')"
#
# In a workflow `run:` block under `set -eu`, put the pipeline in a subshell
# that sets pipefail, so a git failure still aborts the step as it did before
# the pipe existed -- `$(...)` alone discards NUL bytes, so the `tr` cannot be
# moved out of the substitution:
#
#   changed=$(set -o pipefail; git diff --name-only -z "$B...HEAD" | tr '\0' '\n')
#
# Fix an `ls-files` hit by reading the NUL stream directly, which keeps every
# byte of the path intact rather than round-tripping it through newlines:
#
#   while IFS= read -r -d '' f; do
#     scan_files+=("$f")
#   done < <(git -c core.quotepath=false ls-files -z <pathspecs>)
#
# `-z` alone is what disables the quoting; `-c core.quotepath=false` is
# belt-and-braces for the reader. A `| LC_ALL=C sort` on such a stream must
# become `| LC_ALL=C sort -z`, or the sort re-joins the records on newlines and
# undoes the fix. Both BSD sort (macOS) and GNU sort accept `-z`.
#
# A consumer that COUNTS rather than iterates takes `| tr -cd '\0' | wc -c`,
# never the `| tr '\0' '\n' | wc -l` round-trip above. Translating the records
# back to newlines makes a path holding a literal newline count twice, so on a
# counting consumer the repair advertised for an iterating one REGRESSES the
# site it was applied to: the pre-repair quoted spelling counted correctly,
# because quoting never splits a record. `-z` fixes the byte fidelity; only
# counting the separators themselves fixes the arithmetic.
#
# Reference fixes: .gaia/scripts/resolve-audit-members.sh (the `changed`
# derivation) and .gaia/tests/shell-lint.sh (its discovery loops).
#
# Two `ls-files` shapes are deliberately NOT flagged, and each is a closed
# property of the call text rather than a judgment about its consumer:
#
#   --error-unmatch  -- the call is an existence assertion whose contract is its
#                       exit status, not its output; git's own documentation
#                       defines the flag that way. Every such call in this tree
#                       discards stdout. Demanding `-z` there would be a change
#                       with no failure mode behind it.
#   an option-less   -- `-z` is accepted anywhere in the call's OPTION region,
#   -z position         which ends at the first token not starting with `-` or
#                       at an explicit `--`. `ls-files` idiomatically carries
#                       selector options first (`--others --exclude-standard
#                       -z`), and `diff` carries `--cached` or `--staged` ahead
#                       of `--name-only`, so both halves read the region rather
#                       than a fixed position. Terminating the walk at the first
#                       non-option is what stops a pathspec carrying the token
#                       from vouching for a call that still quotes.
#
# `git status --porcelain` is the third member of this family and is deliberately
# OUT of the declared surface rather than merely unreached. Its dominant shape in
# this repository is an emptiness test (`[ -z "$(git status --porcelain)" ]`),
# where quoting cannot change the verdict.
# Claiming it here would red the gate on call sites that carry no failure mode,
# which is how a gate gets bypassed rather than fixed.
#
# A fenced code block on a tracked markdown page IS on the declared surface, and
# the reason is that several of them are executed instruction rather than
# illustration: an always-loaded rule tells the agent to run that page's steps as
# written, so the snippet is a live call site. Two carried this class at once,
# in the quality gate's own skip check and in the health runbook's staging-tree
# discovery, and no check could see either of them.
#
# The discriminator is FENCE STATE, never a path glob enumerating which pages are
# executed. A glob is an enumeration, and an enumeration goes one page short the
# same way a list of option spellings does; fence state is a closed property of
# the text. An illustrative mention of a path-listing command is idiomatically a
# code span, which the `inspan` rule in lint-git-path-quoting-detect.sh already treats as prose, so the two
# rules partition markdown between them: outside a fence nothing is scanned at
# all, and inside one nothing is prose. Swept across every tracked markdown page
# in this repository, that partition reported the live defects and nothing else,
# which is what makes the rule affordable as well as closed.
#
# What the fence rule reads is stated in the scanner beside the code that does
# it: a closer matches the opener's character and is at least as long, and a leading `>` is
# part of the delimiter's run. Its remaining blind spots:
#   - An illustrative fenced block that DELIBERATELY shows an unquoted call as a
#     counter-example is flagged. That is FAIL-CLOSED, and the repair is to write
#     the counter-example as a code span or to let it carry `-z`.
#   - A page whose fences do not balance inverts the polarity from the unclosed
#     delimiter onward. FAIL-OPEN past that point, and unlike the nesting case
#     a parity count over the page does detect it, because the page really is
#     unbalanced and renders wrong for its human reader too.
#   - An indented code block, the four-space form carrying no delimiter at all,
#     is never entered and so is never scanned. FAIL-OPEN. Nothing distinguishes
#     it from an indented continuation line without parsing the block structure
#     the delimiters make free, and no page in this tree executes one.
#
# So: the surface this file claims is at zero for `ls-files` and for every
# option spelling of `diff --name-only`, which is what the tests below pin. The
# `diff` half reads its option region rather than a fixed string, so an OPTION
# written between `diff` and `--name-only` -- `--cached`, `--staged`, or any
# other -- no longer hides the call. A positional REVISION in that position
# still does, and that limit is stated with the other blind spots in lint-git-path-quoting-detect.sh rather
# than left to be read out of this sentence.
#
# The sibling plumbing commands come along with that, and the reason is worth
# stating so a maintainer who meets the red does not read it as a misfire. The
# matched text is now the bare `diff`, so every `diff-*` plumbing spelling is
# reached on one mechanism: the tail (`-index`, `-tree`, `-files`) is dash-led,
# so the walk continues past it into the real options and finds `--name-only`
# there. The set is stated by that shared property rather than enumerated,
# because an enumeration of it goes one command short the same way a list of
# option spellings does. The demand is CORRECT on all of them: each quotes a
# path exactly as `git diff` does. None is invoked in this tree today, so this
# is reach the widening brought rather than coverage anyone asked for, and it
# is left in place because narrowing the match to exclude them would trade a
# fail-closed demand that is right for a blind spot that is not.

set -euo pipefail

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, and an unbracketed load
# would abort the script outright if the library were ever present but
# unparseable.
_gaia_guard_library_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_library_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_library_directory="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'lint-git-path-quoting: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-git-path-quoting: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-git-path-quoting: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENTITY" >&2
    exit 6
    ;;
esac

# Scan surface: tracked shell, the extensionless git hooks, the workflow YAML
# whose `run:` blocks are shell by another name, tracked markdown, whose
# fenced blocks are shell by another name on any page a rule tells the agent to
# execute, and tracked `*.bats`, collected as its own set below. `git ls-files`
# rather than a filesystem walk, so an untracked scratch script or a vendored
# dependency is never scanned; the same discovery that .gaia/tests/shell-lint.sh
# uses. Collected with a read loop rather than `mapfile`, which is bash 4+,
# because these scripts run on stock macOS /bin/bash (3.2.57).
#
# `*.bats` is a SEPARATE set from the one below, never folded into one widened
# pathspec: a pathspec matching `*.sh` but no `*.bats` would still pass clean,
# which is the exact silent-unarming a widened-but-broken discovery would
# produce. On a `*.bats` line, `guard-awk-lib.sh`'s shared discriminator tells a
# fixture literal, written through a recognized helper, from executed shell a
# suite runs through `bash -c` or `eval`; see
# wiki/decisions/Shell Guard Fixture Discrimination.md for the convention and
# the reasoning behind the argument-region rule and the suppression pragma.
scan_files=()
while IFS= read -r -d '' file_path; do
  scan_files+=("$file_path")
done < <(git -c core.quotepath=false ls-files -z '*.sh' '.githooks/*' '.github/workflows/*.yml' '.github/workflows/*.yaml' '*.md' | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is precisely the
# lie-green failure the gate itself exists to stop elsewhere. Every real tree
# carries tracked `*.sh`, so an empty result means the discovery is wrong rather
# than the tree. `.gaia/tests/shell-lint.sh` treats the identical condition as a
# hard error for its own discovery, and this is that reasoning applied here.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-git-path-quoting: ERROR: no tracked files matched the scan surface; nothing was scanned" >&2
  exit 1
fi
if [ -n "${GAIA_GUARD_DELTA_FILE:-}" ]; then
  gaia_guard_delta_intersect lint-git-path-quoting 'shell, git hook, workflow or Markdown' ${scan_files[@]+"${scan_files[@]}"} || exit 1
  scan_files=(${GAIA_GUARD_DELTA_KEPT[@]+"${GAIA_GUARD_DELTA_KEPT[@]}"})
fi

# The `*.bats` surface, discovered and hard-errored on separately by the shared
# library, for the same reason as above: a widened pathspec that quietly missed
# every suite would still pass this guard's own empty-set check.
gaia_guard_bats_files lint-git-path-quoting || exit 1

# The class-detection program lives beside this script, loaded under the same
# bracket as the guard library above.
# shellcheck source=.gaia/scripts/lint-git-path-quoting-detect.sh
set +e; [ -f "$_gaia_guard_library_directory/lint-git-path-quoting-detect.sh" ] && . "$_gaia_guard_library_directory/lint-git-path-quoting-detect.sh" 2>/dev/null; set -e
if [ -z "${OWN_AWK:-}" ]; then
  printf 'lint-git-path-quoting: lint-git-path-quoting-detect.sh is missing beside this script\n' >&2
  exit 2
fi

# scan_file <path>: print one `file:line: message` per unquoted call, on every
# non-bats surface. Single pass; is_bats=0 makes every gaia_scan_* accessor the
# library defines inert except the pragma reporter above.
scan_file() {
  local file_path="$1"
  # Fence gating applies to markdown alone. On every other file type is_markdown stays
  # 0, so infence never leaves 0 and both rules below are inert -- the shell and
  # YAML halves scan exactly the lines they always did.
  local is_markdown=0
  case "$file_path" in *.md) is_markdown=1 ;; esac
  "$GAIA_AWK" -v file="$file_path" -v is_markdown="$is_markdown" -v is_bats=0 -v scripts_directory="$_gaia_guard_library_directory" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$file_path"
}

# scan_bats_file <path>: two-pass invocation over a tracked `*.bats` suite, the
# file named twice so the prepass sees a fixture constant bound above the
# helper call that consumes it. is_markdown is always 0: a bats file has no markdown
# fence state to track.
scan_bats_file() {
  local file_path="$1"
  "$GAIA_AWK" -v file="$file_path" -v is_markdown=0 -v is_bats=1 -v scripts_directory="$_gaia_guard_library_directory" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$file_path" "$file_path"
}

report=""
for file_path in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$file_path" ] || continue
  hits=$(scan_file "$file_path")
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for file_path in ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}; do
  [ -f "$file_path" ] || continue
  hits=$(scan_bats_file "$file_path")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The class-remedy footer below names the repair for a class hit and for
  # nothing else. A run whose findings are all pragma hygiene (unused,
  # malformed, honored nowhere) or the desync ERROR would otherwise print a
  # remedy that has nothing to do with what actually went red, pointing the
  # operator at the wrong fix. Gate it on at least one non-blank finding that is
  # neither, rather than on the report merely being non-empty.
  # ONE awk pass, not a filtering grep feeding a quiet one. A quiet grep exits
  # at its first match and closes the pipe; the upstream grep then takes SIGPIPE
  # and returns 141, and `pipefail` promotes that to the pipeline's status, so
  # the test would answer FALSE on a report that does carry a class hit. A
  # single process cannot lose that race, and
  # .gaia/scripts/lint-sigpipe-readers.sh is the gate that keeps the shape out.
  if "$GAIA_AWK" '
      /gaia-lint-ignore/ { next }
      /: ERROR: /        { next }
      /[^[:space:]]/     { found = 1 }
      END { exit(found ? 0 : 1) }
    ' <<<"$report"; then
    # printf, not echo: the hint text carries backslash escapes (`tr` operands),
    # and echo may expand them depending on the shell (SC2028). The format string
    # is single-quoted so the `$(...)` and `${base}` inside it stay literal -- it
    # is sample code being printed, not code being run. Disabled on this line
    # rather than file-wide, so a genuine SC2016 anywhere else here still fires.
    # shellcheck disable=SC2016
    printf 'Fix a diff hit: changed="$(git diff --name-only -z "${base}...HEAD" | tr %s\\0%s %s\\n%s)"\n' "'" "'" "'" "'" >&2
    # The ls-files repair reads the NUL stream directly rather than translating it
    # back to newlines, so it needs no `tr` and survives a path containing one.
    # shellcheck disable=SC2016
    printf 'Fix an ls-files hit: while IFS= read -r -d %s%s f; do ...; done < <(git ls-files -z <pathspecs>)\n' "'" "'" >&2
  fi
  exit 1
fi

echo "lint-git-path-quoting: clean" >&2
exit 0
