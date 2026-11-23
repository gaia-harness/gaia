#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` expansions inside it reach the fixture file as literal text. An
# unrooted path versus a `${BASH_SOURCE[0]}`-rooted one IS the distinction under
# test, so letting this shell expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-hook-cwd-relative-loads.sh: the static gate that
# flags a hook locating framework code by a bare repository-root-relative path,
# which resolves against the process working directory rather than against the
# hook checkout, so a single `cd` makes a moved working directory
# indistinguishable from a missing library and buys the fail-open written for
# the missing one.
#
# THIS SUITE IS THE BLOCKING RUNNER. shell-lint.sh invokes the gate a second,
# advisory way, but a gate run against a tree that is already clean reports
# clean whether its predicate works or not, so a broken predicate is
# indistinguishable from an honest tree there. Every test below drives the gate
# against a fixture tree shaped one way at a time.
#
# Three jobs. Prove the detector fires on each position the gate header
# enumerates; prove it stays quiet on every shape the header lists as
# deliberately not a hit, which for this gate includes the repair it advertises,
# since a gate that reds on its own advice cannot ship; and assert the real
# scanned tree is clean so a regression fails CI.
#
# The quiet tests carry more weight here than in a sibling gate, because this
# class is spelled the same way in code and in the prose that documents it. Each
# of the three context trackers (heredoc bodies, multi-line double-quoted
# strings, comment words) has a test naming the construct it protects, and the
# tree carries a live instance of each: without them the gate would red on the
# operator-facing deny messages that quote the very repair it recommends.
#
# One test is load-bearing beyond coverage. "reds against the historical
# blocking-hook shape" carries the line gaia-react/gaia#1854 was
# filed against with only the library name changed (the original hook is gone),
# so the gate is proven to reach that shape.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-hook-cwd-relative-loads.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_repo_bare: an initialized git repo in $TEMPORARY_DIRECTORY with an empty hooks
# directory and a COPY of the gate staged at its own repo-relative path, so the
# discovery comes back empty. Point a test that needs a short surface here.
#
# The staged copy is what makes every test below mean anything. The gate roots
# its scan surface at its OWN on-disk location rather than at the working
# directory, so running $LINTER with cwd set to the fixture would scan the real
# repository and report it clean, no matter what the fixture holds. Only a copy
# living inside the fixture reads the fixture. The empty `.claude/hooks` is
# deliberate too: the gate refuses (exit 2) when it cannot see that directory
# at its root, so creating it is what leaves the short-surface arm reachable.
fixture_repo_bare() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t hookcwd-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks" "$TEMPORARY_DIRECTORY/.gaia/scripts"
  STAGED_LINTER="$TEMPORARY_DIRECTORY/.gaia/scripts/lint-hook-cwd-relative-loads.sh"
  cp "$LINTER" "$STAGED_LINTER"
}

# fixture_repo: fixture_repo_bare plus enough benign tracked hooks to clear the
# gate own surface floor, so a test reaches class detection rather than the
# short-surface error. The seeds are named `seed-N.sh` so fixture_hook below can
# write `check.sh` without shrinking the surface. The count is read from the
# gate itself rather than restated, so raising the floor there cannot leave this
# helper seeding too few and every test failing for the wrong reason.
fixture_repo() {
  local floor seed_index
  fixture_repo_bare
  floor="$( sed -n 's/^readonly SURFACE_FLOOR=\([0-9]*\)$/\1/p' "$LINTER" )"
  [ -n "$floor" ] || return 1
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks"
  seed_index=0
  while [ "$seed_index" -lt "$floor" ]; do
    printf '#!/usr/bin/env bash\ntrue\n' > "$TEMPORARY_DIRECTORY/.claude/hooks/seed-$seed_index.sh"
    seed_index=$(( seed_index + 1 ))
  done
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# fixture_hook <body>: a tracked hook carrying <body>. Line 1 is the shebang and
# line 2 the `set`, so a one-line body reports at line 3.
fixture_hook() {
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks"
  printf '%s\n' "#!/usr/bin/env bash
set -uo pipefail
$1" > "$TEMPORARY_DIRECTORY/.claude/hooks/check.sh"
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# run_linter: run the fixture's own staged copy of the gate. cwd is set to the
# fixture only so a failure here reads naturally; the gate no longer consults it.
run_linter() {
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$STAGED_LINTER' 2>&1"
}

# refuse_case <label> <hook body> <expected substring>...: the hook must be refused
# (exit 1) and the report must carry every substring. The label is echoed first so
# a red case names itself. Reuses the repo fixture_repo built; only check.sh is
# rewritten per case.
refuse_case() {
  local label="$1" body="$2" needle
  echo "case: $label"
  fixture_hook "$body"
  run_linter
  [ "$status" -eq 1 ]
  shift 2
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$output" || return 1
  done
}

# quiet_case <label> <hook body>: the hook must pass (exit 0) and the report must
# not name check.sh.
quiet_case() {
  echo "case: $1"
  fixture_hook "$2"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  return 0
}

# --- the class fires, one case per position the header enumerates -----------

@test "reds against the historical blocking-hook shape" {
  fixture_repo
  fixture_hook '[ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh
type worthiness_ledger_path >/dev/null 2>&1 || exit 0'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "a file-test operand names a bare repo-relative path" <<<"$output"
}

# bats test_tags=protected
@test "flags a bare source operand" {
  fixture_repo
  fixture_hook '. .gaia/scripts/main-root-lib.sh'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "a source operand names a bare repo-relative path" <<<"$output"
}

@test "flags each position and spelling of a bare repo-relative load" {
  fixture_repo

  # The negated stand-down reads a moved working directory as a missing library
  # exactly as the unnegated form does; both bracket forms ride one case.
  refuse_case 'NEGATED spelling of the historical shape' '[ ! -f .claude/hooks/lib/worthiness-ledger.sh ] && exit 0
[[ ! -f ".gaia/scripts/main-root-lib.sh" ]] && exit 0' \
    ".claude/hooks/check.sh:3:" ".claude/hooks/check.sh:4:" \
    "a file-test operand names a bare repo-relative path"

  refuse_case 'INDENTED source operand' 'if true; then
  . .claude/hooks/lib/worthiness-ledger.sh
fi' \
    ".claude/hooks/check.sh:4:" "a source operand names a bare repo-relative path"

  refuse_case 'bare interpreter argument' 'bash .gaia/scripts/usage.sh pr 1' \
    ".claude/hooks/check.sh:3:" "an interpreter argument names a bare repo-relative path"

  refuse_case 'assignment naming a code file' 'classifier=".gaia/scripts/classifier/classify-determinism.mjs"' \
    ".claude/hooks/check.sh:3:" "this assignment names a bare repo-relative path to a code file"

  # Literal-versus-variable-rooted is the distinction, never quoted-versus-unquoted.
  refuse_case 'QUOTED spelling of each position' '[ -f ".claude/hooks/lib/worthiness-ledger.sh" ] && . ".claude/hooks/lib/worthiness-ledger.sh"
bash ".gaia/scripts/usage.sh" pr 1' \
    ".claude/hooks/check.sh:3:" ".claude/hooks/check.sh:4:" \
    "a file-test operand names a bare repo-relative path" \
    "an interpreter argument names a bare repo-relative path"

  refuse_case 'single-quoted literal' ". '.gaia/scripts/main-root-lib.sh'" \
    "a source operand names a bare repo-relative path"
}

@test "scans from its own root, not the working directory" {
  # The gate flags cwd-resolved paths, so it must not resolve its own surface
  # that way. Run from a subdirectory of the fixture it must still find the
  # planted hook rather than reporting an empty surface.
  fixture_repo
  fixture_hook '[ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh'
  mkdir -p "$TEMPORARY_DIRECTORY/app/components"
  run bash -c "cd '$TEMPORARY_DIRECTORY/app/components' && bash '$STAGED_LINTER' 2>&1"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output"
}

@test "reaches a hook under lib/, not only the top level" {
  fixture_repo
  mkdir -p "$TEMPORARY_DIRECTORY/.claude/hooks/lib"
  printf '%s\n' '#!/usr/bin/env bash
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh' \
    > "$TEMPORARY_DIRECTORY/.claude/hooks/lib/helper.sh"
  git -C "$TEMPORARY_DIRECTORY" add -A
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/helper.sh:2:" <<<"$output"
}

# --- quiet on every shape the header lists as deliberately not a hit --------

@test "quiet on every variable-rooted repair spelling" {
  fixture_repo

  echo "case: indented VARIABLE-rooted load"
  fixture_hook 'if true; then
  . "$_hook_dir/lib/worthiness-ledger.sh"
fi'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "lint-hook-cwd-relative-loads: clean" <<<"$output"

  quiet_case 'quoted VARIABLE-rooted path' '_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=""
[ -f "$_library_directory/worthiness-ledger.sh" ] && . "$_library_directory/worthiness-ledger.sh"
bash "$_library_directory/../../.gaia/scripts/usage.sh"'

  quiet_case 'BASH_SOURCE repair' '_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=""
[ -n "$_library_directory" ] && [ -f "$_library_directory/worthiness-ledger.sh" ] && . "$_library_directory/worthiness-ledger.sh"'

  # The arm admits a `!` in front of the primary, so the repair written in the
  # negated stand-down style has to stay the repair rather than become a finding.
  quiet_case 'NEGATED spelling of the repair' '_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=""
[ ! -f "$_library_directory/worthiness-ledger.sh" ] && exit 0'
}

@test "quiet on state paths, git revision paths and cd'd interpreter args" {
  fixture_repo

  quiet_case 'per-tree state path in ASSIGNMENT position' 'marker=".claude/example-session-marker"
config_path=".gaia/local/example-state.json"'

  # A state path carries no code extension, so the file-test arm gives up the
  # operand and the gate does not prescribe the BASH_SOURCE root its header rules
  # out for state, in either spelling.
  quiet_case 'per-tree state path in FILE TEST position' '[ -f .claude/example-session-marker ] || exit 0
[ -f ".gaia/local/example-state.json" ] || exit 0'

  quiet_case 'NEGATED per-tree state path in FILE TEST position' '[ ! -f .claude/example-session-marker ] && exit 0
[ ! -f ".gaia/local/example-state.json" ] && exit 0'

  quiet_case 'git revision path, which git resolves from the repo root' 'blob=$(git rev-parse "HEAD:.gaia/manifest.json")'

  quiet_case 'interpreter argument the same line cds for' 'members="$( cd "$tree_root" && bash .gaia/scripts/resolve-audit-members.sh )"'
}

@test "quiet on the class inside a heredoc, a multi-line string or a comment" {
  fixture_repo

  quiet_case 'heredoc body' 'cat <<EOF
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
EOF'

  quiet_case 'multi-line double-quoted string' 'reason="To unblock:
  1. Run the ledger writer per judged test:
       node .gaia/scripts/audit-ledger/append-worthiness.mjs <file>
  2. Retry gh pr merge."'

  quiet_case 'comment, whole-line and trailing' '# Usage: [ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh
true  # Usage: [ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh'
}

# --- where the quiet arms stop, and the class reports again -----------------

@test "reports a mention past a quoted span or an apostrophe comment" {
  fixture_repo

  # The mention sits BEHIND the `#`, so only the quote tracker keeps it in the
  # scanned prefix: a cut at that `#` would drop it and report clean.
  refuse_case 'mention inside a QUOTED span, which the # does not cut' 'msg="the shape is # [ -f .claude/hooks/lib/worthiness-ledger.sh ]"' \
    ".claude/hooks/check.sh:3:" "a file-test operand names a bare repo-relative path"

  refuse_case 'comment carrying an apostrophe does not blind the next line' "# The gate own tracker must not read this apostrophe as a quote: don't.
[ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh" \
    ".claude/hooks/check.sh:4:"
}

# --- the discovery itself --------------------------------------------------

@test "errors rather than passing when the scan surface is short" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ERROR:" <<<"$output" || return 1
  grep -qF -- "fewer than the floor" <<<"$output"
}
