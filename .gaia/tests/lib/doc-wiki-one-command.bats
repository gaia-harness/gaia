#!/usr/bin/env bats
#
# Doc conformance for the one-command wiki maintenance chain. The router and
# the playbooks are prose instructions Claude executes, so the only
# deterministic check on them is on their text.
#
#   UAT-003: sync ends with a completion line the router branches on, and the
#            router gates nothing on consolidate.
#   UAT-014: the router stops the chain when the begin step fails.
#
# Each assertion is a helper that takes its file paths as arguments, so the
# same helper runs on the real file and on a scratch copy that holds the bad
# form and must fail. Banned stage invocations and the removed subcommand are
# owned by wiki-stage-args-retired.bats; this suite names none of them.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/gaia-wiki/SKILL.md"
  ROUTER="$REPO_ROOT/.claude/skills/gaia/references/wiki.md"
  SYNC="$REPO_ROOT/.claude/skills/gaia/references/wiki/sync.md"
  CONSOLIDATE="$REPO_ROOT/.claude/skills/gaia/references/wiki/consolidate.md"
  LINT="$REPO_ROOT/.claude/skills/gaia/references/wiki/lint.md"
  LINT_FIX="$REPO_ROOT/.claude/skills/gaia/references/wiki/lint-fix.md"
}

# --- shared helpers -------------------------------------------------------

# Fail unless file $1 exists and is non-empty, so a moved file is not a pass.
need_file() {
  [ -s "$1" ] || { echo "missing or empty file: $1"; return 1; }
}

# Print the body of the "## <name>" section of file $1: from its heading to the
# next "## " heading or end of file.
section_text() {
  awk -v heading="## $2" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# Fail unless file $1 holds fixed string $2.
has_fixed() {
  need_file "$1" || return 1
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; return 1; }
  return 0
}

# Fail when file $1 has a line matching extended regex $2 (case-sensitive).
lacks_regex() {
  need_file "$1" || return 1
  if grep -qE -- "$2" "$1"; then
    echo "unwanted in $1:"
    grep -nE -- "$2" "$1"
    return 1
  fi
  return 0
}

# Fail unless section $2 of file $1 holds fixed string $3.
section_has_fixed() {
  local text
  need_file "$1" || return 1
  text="$(section_text "$1" "$2")"
  [ -n "$text" ] || { echo "section is empty or absent in $1: $2"; return 1; }
  grep -qF -- "$3" <<<"$text" || { echo "missing in section '$2' of $1: $3"; return 1; }
  return 0
}

# Fail when section $2 of file $1 has a line matching extended regex $3,
# case-insensitive.
section_lacks_regex() {
  local text
  need_file "$1" || return 1
  text="$(section_text "$1" "$2")"
  [ -n "$text" ] || { echo "section is empty or absent in $1: $2"; return 1; }
  if grep -qiE -- "$3" <<<"$text"; then
    echo "unwanted in section '$2' of $1:"
    grep -niE -- "$3" <<<"$text"
    return 1
  fi
  return 0
}

# A scratch copy of file $1 named $2 under the test's temp dir; prints its path.
scratch_copy() {
  local destination="$BATS_TEST_TMPDIR/$2"
  cp "$1" "$destination"
  printf '%s\n' "$destination"
}

# --- UAT-003: completion signal -------------------------------------------

assert_completion_signal() {
  local sync="$1" router="$2"
  has_fixed "$sync" 'SYNC_COMPLETE: true' || return 1
  section_has_fixed "$router" 'Sync' 'SYNC_COMPLETE: true' || return 1
  section_has_fixed "$router" 'Full chain' 'SYNC_COMPLETE: true' || return 1
  return 0
}

@test "UAT-003: sync ends with the completion line the router branches on" {
  run assert_completion_signal "$SYNC" "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-003 can fail: a sync playbook without the completion line is flagged" {
  local scratch="$BATS_TEST_TMPDIR/sync-no-signal.md"
  grep -v 'SYNC_COMPLETE: true' "$SYNC" >"$scratch" || true
  run assert_completion_signal "$scratch" "$ROUTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing in $scratch"* ]]
}

# --- Conformance beyond the UAT clauses ------------------------------------

assert_sync_commits_only_through_chain() {
  has_fixed "$1" 'gaia wiki chain commit' || return 1
  lacks_regex "$1" 'git commit|git -C [^ ]+ commit|commit -m' || return 1
  return 0
}

@test "sync commits only through the chain commit command" {
  run assert_sync_commits_only_through_chain "$SYNC"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "can fail: a sync playbook with a bare git commit line is flagged" {
  local scratch
  scratch="$(scratch_copy "$SYNC" sync-bare-commit.md)"
  printf 'git commit -m "wiki: sync"\n' >>"$scratch"
  run assert_sync_commits_only_through_chain "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git commit"* ]]
}

# --- UAT-014: the chain stops when begin fails -------------------------------

assert_router_stops_on_failed_begin() {
  section_has_fixed "$1" 'Full chain' 'If `chain begin` exits non-zero, stop the chain:' || return 1
  section_lacks_regex "$1" 'Full chain' 'proceed regardless' || return 1
  return 0
}

@test "UAT-014: the router stops the chain when the begin step fails" {
  run assert_router_stops_on_failed_begin "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-014 can fail: a router that proceeds regardless is flagged" {
  local scratch="$BATS_TEST_TMPDIR/router-proceeds.md"
  sed 's/If `chain begin` exits non-zero, stop the chain:/Proceed regardless of which./' "$ROUTER" >"$scratch"
  run assert_router_stops_on_failed_begin "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stop the chain"* ]]
}
