#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-audit-key-callers.sh -- the
# static caller check task 4.1 adds alongside `gaia_audit_key` itself
# (analysis/task-4.1-audit-key-design.md §5.2). The meter's fixtures
# (`C4-01`/`C4-02`) prove the FUNCTION partitions two worktrees; they cannot
# prove the Code Audit Team agent definitions actually CALL it instead
# of hand-building the old collision-prone path. This check closes that gap
# over `.claude/agents/`.
#
# Every test below except the one marked "real repo" drives the check
# against a FIXTURE tree it builds, never the real repo: the real
# `.claude/agents/` definitions are mid-conversion by a parallel task and are
# EXPECTED to fail this check until that conversion lands (see the one real-
# repo test at the bottom, which documents that expected-red state rather
# than hiding it).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-audit-key-callers.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIRECTORY/check-audit-key-callers.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-audit-key-callers.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local fixture_repository
  for fixture_repository in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$fixture_repository" ] && rm -rf "$fixture_repository"
  done
  return 0
}

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR with an
# empty .claude/agents/ directory. Returns the repo path on stdout; commits
# happen once the caller has written its fixture files (commit_fixture_repo).
make_fixture_repo() {
  local name="$1"
  local repository_directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$repository_directory/.claude/agents"
  git init -q --initial-branch=main "$repository_directory"
  git -C "$repository_directory" config user.email t@example.com
  git -C "$repository_directory" config user.name T
  git -C "$repository_directory" config commit.gpgsign false
  FIXTURE_REPOS+=("$repository_directory")
  printf '%s' "$repository_directory"
}

# write_agent_file <repo> <basename> <content>
write_agent_file() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" > "$repo/.claude/agents/$name"
}

commit_fixture_repo() {
  local repo="$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fixture
}

# ---------- fixture content ----------
# The "converted" shape below calls gaia_audit_key inline rather than binding
# its result to a named variable first -- functionally equivalent to the
# real agent prose's "AUDIT_KEY=$(gaia_audit_key ...)" contract for what this
# check actually inspects (does the file call gaia_audit_key at all, and does
# a bare ${BASE_SHA}./${base}. literal survive), so the fixture proves the
# same thing without duplicating the real contract's exact variable name.

CONVERTED_OK='Some agent prose.
```bash
. .gaia/scripts/audit-key-lib.sh
SIDECAR=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").code-audit-frontend.findings.json"
LEDGER=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").rerun.json"
```
'

BAD_LEDGER_LITERAL='```bash
BASE_SHA="$(git merge-base "$BASE_REF" HEAD)"
LEDGER=".gaia/local/audit/${BASE_SHA}.rerun.json"
```
'

BAD_SIDECAR_LITERAL_BASE='Path: `.gaia/local/audit/${base}.code-audit-maintainer-shell.findings.json`
'

NAMES_LEDGER_NO_CALL='The re-run ledger lives at .gaia/local/audit/whatever.rerun.json, built elsewhere.
'

NAMES_FINDINGS_NO_CALL='The findings sidecar lives at .gaia/local/audit/whatever.findings.json, built elsewhere.
'

UNRELATED_FILE='This agent never touches an audit sidecar or the re-run ledger at all.
'

BAD_LITERAL_PLUS_CALL_ELSEWHERE='```bash
. .gaia/scripts/audit-key-lib.sh
SIDECAR=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").code-audit-frontend.findings.json"
LEDGER=".gaia/local/audit/${BASE_SHA}.rerun.json"
```
'

BAD_LEDGER_LITERAL_KEY_BASE='```bash
LEDGER=".gaia/local/audit/${KEY_BASE}.rerun.json"
```
'

GOOD_LEDGER_VIA_KEY_LIB='```bash
. .gaia/scripts/audit-key-lib.sh
LEDGER=".gaia/local/audit/$(gaia_audit_key "$KEY_BASE").rerun.json"
```
'

# check_fixture <name> <agent file> <content>: builds a fixture repo
# holding one agent file and runs the check over it.
check_fixture() {
  local repo
  repo="$(make_fixture_repo "$1")"
  write_agent_file "$repo" "$2" "$3"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
}

# ---------- assertion 1: bad literal ----------

# bats test_tags=protected
@test "fixture: a bare \${BASE_SHA}.rerun.json ledger literal fails assertion 1" {
  local -a contents=(
    "$BAD_LEDGER_LITERAL"
    "$BAD_SIDECAR_LITERAL_BASE"
    "$BAD_LEDGER_LITERAL_KEY_BASE"
    "$BAD_LITERAL_PLUS_CALL_ELSEWHERE"
  )
  local index=0 row name agent needle
  for row in \
    'bad-ledger|code-audit-frontend.md|${BASE_SHA}.rerun.json' \
    'bad-sidecar|code-audit-maintainer-shell.md|${base}.code-audit-maintainer-shell.findings.json' \
    'bad-ledger-key-base|code-audit-frontend.md|${KEY_BASE}.rerun.json' \
    'half-converted|code-audit-frontend.md|${BASE_SHA}.rerun.json'; do
    IFS='|' read -r name agent needle <<<"$row"
    check_fixture "$name" "$agent" "${contents[$index]}"
    index=$((index + 1))
    [ "$status" -eq 1 ] || { echo "row $name: status $status"; return 1; }
    grep -qF "$agent" <<<"$output" || { echo "row $name: file not named"; return 1; }
    grep -qF "$needle" <<<"$output" || { echo "row $name: literal not named"; return 1; }
    grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 1" <<<"$output" || { echo "row $name: assertion 1 count not 1"; return 1; }
  done
  # A leftover literal fails even when the file also calls gaia_audit_key
  # elsewhere, so assertion 2 stays clean for it.
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
}

@test "a conforming file passes clean" {
  local -a contents=("$CONVERTED_OK" "$GOOD_LEDGER_VIA_KEY_LIB" "$UNRELATED_FILE")
  local index=0 row name agent
  for row in \
    'converted-ok|code-audit-frontend.md' \
    'good-ledger-key-base|code-audit-frontend.md' \
    'unrelated|unrelated.md'; do
    IFS='|' read -r name agent <<<"$row"
    check_fixture "$name" "$agent" "${contents[$index]}"
    index=$((index + 1))
    [ "$status" -eq 0 ] || { echo "row $name: status $status"; return 1; }
    grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 0" <<<"$output" || { echo "row $name: assertion 1 count not 0"; return 1; }
    grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || { echo "row $name: assertion 2 count not 0"; return 1; }
  done
}

# ---------- assertion 2: every namer calls gaia_audit_key ----------

@test "assertion 2: a file naming the artifact without calling gaia_audit_key fails" {
  local -a contents=("$NAMES_LEDGER_NO_CALL" "$NAMES_FINDINGS_NO_CALL")
  local index name
  for index in 0 1; do
    name="names-no-call-$index"
    check_fixture "$name" some-agent.md "${contents[$index]}"
    [ "$status" -eq 1 ] || { echo "row $name: status $status"; return 1; }
    grep -qF "names a sidecar/ledger but never calls gaia_audit_key: .claude/agents/some-agent.md" <<<"$output" || { echo "row $name: file not named"; return 1; }
    grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 1" <<<"$output" || { echo "row $name: assertion 2 count not 1"; return 1; }
  done
}

@test "fixture: multiple violations across files are all named, and the check still fails once" {
  local repo
  repo="$(make_fixture_repo multi)"
  write_agent_file "$repo" code-audit-frontend.md "$BAD_LEDGER_LITERAL"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$NAMES_FINDINGS_NO_CALL"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "unrelated.md" <<<"$output" && return 1
  return 0
}

# ---------- real repo: the standing guarantee ----------

# bats test_tags=whole-tree
@test "real repo: every Code Audit Team definition derives its path through gaia_audit_key" {
  run gaia_check_audit_key_callers "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 0" <<<"$output" || return 1
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "real repo: the guarantee above is not vacuous -- agent definitions do name these artifacts" {
  # Both of the check's verdicts are counts of violations, so a scan that saw
  # no candidate at all reports zero and passes. Pin the candidate set as
  # non-empty so a future move of the agent definitions out from under
  # `.claude/agents/` surfaces as a red here rather than as a silent green.
  run git -C "$REPO_ROOT" grep -lIE 'findings\.json|rerun\.json' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
}

# ---------- structural ----------

@test "a bad repo_root reports 2, never a clean 0" {
  # 2, not 1: "the check could not run" is a different answer from "the check
  # says no", and neither is the 0 an unscanned tree used to report. A repo
  # subdirectory separates "is in a repo" from "is a repo root".
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  local root
  for root in "$BATS_TEST_TMPDIR/not-a-repo" "$REPO_ROOT/.gaia/scripts"; do
    run gaia_check_audit_key_callers "$root"
    [ "$status" -eq 2 ] || { echo "root $root: status $status"; return 1; }
    grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || { echo "root $root: no refusal message"; return 1; }
    # Both verdict lines: each one alone reads as a clean bill of health for a
    # tree that was never read.
    grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 0" <<<"$output" && { echo "root $root: clean assertion-1 verdict for an unscanned tree"; return 1; }
    grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" && { echo "root $root: clean assertion-2 verdict for an unscanned tree"; return 1; }
  done
  return 0
}

@test "structural: sourcing the script defines gaia_check_audit_key_callers with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_audit_key_callers >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
