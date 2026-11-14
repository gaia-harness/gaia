#!/usr/bin/env bats
# Refusals of the security-row merge gate (.claude/hooks/test-design-merge-gate.sh)
# and of the grant recorder (.claude/hooks/test-row-grant.sh), each on a scratch
# git repo whose feature branch a marked plan run claims through its RUNNING
# sentinel.
#
# The gate denies through JSON on stdout. A covered table and a granted row are
# the controls that keep each deny from being a gate that denies everything,
# and the one recorded grant keeps each grant refusal from being a recorder
# that records nothing.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/test-design-gate-refusals.bats`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/.claude/hooks/test-design-merge-gate.sh"
  GRANT="$REPO_ROOT/.claude/hooks/test-row-grant.sh"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  PLAN="$FIXTURE/.notebook/specs/feature-one/plan"
  GRANTS_FILE="$FIXTURE/.gaia/local/protected/audit-loop/feature.d/test-row-grants.json"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  build_fixture
}

git_fixture() {
  git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

row() {
  # row <id> <security>
  printf '{"id":"%s","source":"flow:alpha","case":"c","file":"src/guard.test.ts","title":"guard %s","layer":"unit","task":"task-one","action":"new","security":"%s"}' \
    "$1" "$1" "$2"
}

# A feature branch carrying the security row's test, claimed by an approved,
# marked plan run, with the security writer's authorship line recorded.
build_fixture() {
  mkdir -p "$FIXTURE/src"
  git -C "$FIXTURE" init -q -b main
  printf '.notebook/\n.gaia/local/\n' >"$FIXTURE/.gitignore"
  git_fixture add -A
  git_fixture commit -q -m base
  git_fixture checkout -q -b feature
  printf "import {describe, expect, test} from 'vitest';\ndescribe('guard', () => {\n  test('T1', () => {\n    expect(1).toBe(1);\n  });\n  test('T2', () => {\n    expect(2).toBe(2);\n  });\n});\n" \
    >"$FIXTURE/src/guard.test.ts"
  git_fixture add -A
  git_fixture commit -q -m feature
  mkdir -p "$PLAN"
  printf 'branch: feature\nslug: plan\nmode: feature-branch\n' >"$PLAN/RUNNING"
  printf '{"schema": 1, "rows": [%s,%s]}\n' "$(row T1 access)" "$(row T2 none)" >"$PLAN/tests.json"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  node "$TABLE_CLI" approve --plan-dir "$PLAN" >/dev/null
  node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$FIXTURE" --row T1 >/dev/null
}

run_gate() {
  local payload
  payload="$(jq -n --arg c "gh pr merge 7 --squash" --arg d "$FIXTURE" \
    '{session_id: "s", cwd: $d, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')"
  invoke_hook "$payload" "${1:-$GATE}"
}

# set_current_table <jq filter>: rewrite the current table through the filter.
set_current_table() {
  jq -c "$1" "$PLAN/tests.json" >"$PLAN/tests.next" && mv "$PLAN/tests.next" "$PLAN/tests.json"
}

assert_denied_with() {
  assert_denied_by_json || { echo "not denied: $output" >&2; return 1; }
  grep -qF -- "$1" <<<"$output" || { echo "deny lacks '$1': $output" >&2; return 1; }
}

# grant_prompt <prompt> [entrypoint]: the recorder, from an interactive
# session unless the entrypoint says otherwise.
grant_prompt() {
  printf '{"entrypoint":"%s"}\n' "${2:-cli}" >"$TRANSCRIPT"
  local payload
  payload="$(jq -n --arg p "$1" --arg d "$FIXTURE" --arg t "$TRANSCRIPT" \
    '{session_id: "s", transcript_path: $t, cwd: $d, hook_event_name: "UserPromptSubmit", prompt: $p}')"
  run env CLAUDE_CODE_ENTRYPOINT="${2:-cli}" bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$GRANT"
}

@test "a covered approved security row allows the merge" {
  run_gate
  assert_allowed_by_json
  [ -z "$output" ]
}

build_fresh() {
  rm -rf "$FIXTURE"
  build_fixture
}

@test "each uncovered security row denies, naming the row and why" {
  set_current_table 'del(.rows[] | select(.id == "T1"))'
  run_gate
  assert_denied_with "T1: missing-from-table" || return 1

  build_fresh
  set_current_table '(.rows[] | select(.id == "T1") | .security) = "none"'
  run_gate
  assert_denied_with "T1: flag-lost" || return 1

  build_fresh
  git_fixture rm -q src/guard.test.ts
  git_fixture commit -q -m remove
  run_gate
  assert_denied_with "T1: no-matching-test"
}

@test "a broken approved copy or table denies with the integrity reason" {
  local cases=0 broken
  for broken in approved-missing approved-hash table-absent table-unreadable; do
    build_fresh
    case "$broken" in
      approved-missing) rm "$PLAN/tests.approved.json" ;;
      approved-hash) printf ' ' >>"$PLAN/tests.approved.json" ;;
      table-absent) rm "$PLAN/tests.json" ;;
      table-unreadable) printf '{not json' >"$PLAN/tests.json" ;;
    esac
    run_gate
    case "$broken" in
      approved-missing) assert_denied_with "tests.approved.json is missing" || return 1 ;;
      approved-hash) assert_denied_with "does not match the marker" || return 1 ;;
      table-absent | table-unreadable) assert_denied_with "unreadable table" || return 1 ;;
    esac
    cases=$((cases + 1))
  done
  [ "$cases" -eq 4 ]
}

@test "a typed grant lets its row through, but never past a mismatched approved copy" {
  set_current_table 'del(.rows[] | select(.id == "T1"))'
  grant_prompt "test-row-grant T1"
  grep -qF -- "Recorded: test-row-grant T1" <<<"$output"
  run_gate
  assert_allowed_by_json

  printf ' ' >>"$PLAN/tests.approved.json"
  run_gate
  assert_denied_with "does not match the marker"
}

@test "two plan runs claiming the branch deny" {
  mkdir -p "$FIXTURE/.notebook/plans/other"
  cp "$PLAN/RUNNING" "$FIXTURE/.notebook/plans/other/RUNNING"
  run_gate
  assert_denied_with "more than one plan run claims branch feature"
}

@test "a crash in the security check denies rather than reading as nothing uncovered" {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nprintf "boom\\n" >&2\nexit 1\n' >"$stub/node"
  chmod +x "$stub/node"
  PATH="$stub:$PATH" run_gate
  assert_denied_with "failed without naming an uncovered row"
}

# build_harness: a copy of the gate and the scripts it loads, in $HARNESS, for
# a test that removes one of them.
build_harness() {
  HARNESS="$BATS_TEST_TMPDIR/harness"
  rm -rf "$HARNESS"
  mkdir -p "$HARNESS/.claude/hooks" "$HARNESS/.gaia/scripts"
  cp "$GATE" "$HARNESS/.claude/hooks/"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$HARNESS/.claude/hooks/lib"
  cp "$REPO_ROOT"/.gaia/scripts/*.sh "$HARNESS/.gaia/scripts/"
  local folder
  for folder in test-design test-signals notebook spec; do
    cp -R "$REPO_ROOT/.gaia/scripts/$folder" "$HARNESS/.gaia/scripts/$folder"
  done
}

@test "a gate whose test-drift-check.sh is absent denies" {
  build_harness
  rm "$HARNESS/.gaia/scripts/test-drift-check.sh"
  run_gate "$HARNESS/.claude/hooks/test-design-merge-gate.sh"
  assert_denied_with "test-drift-check.sh is missing"
}

@test "a gate whose notebook library cannot load denies rather than finding no plan" {
  build_harness
  rm "$HARNESS/.gaia/scripts/notebook/notebook-lib.sh"
  run_gate "$HARNESS/.claude/hooks/test-design-merge-gate.sh"
  assert_denied_with "the notebook library"
}

@test "the grant recorder refuses and records nothing outside an exact grant of an approved security row" {
  local cases=0 prompt entrypoint expected
  while IFS='|' read -r prompt entrypoint expected; do
    [ -n "$prompt" ] || continue
    grant_prompt "$prompt" "$entrypoint"
    [ "$status" -eq 0 ] || { echo "$prompt: exit $status" >&2; return 1; }
    grep -qF -- "$expected" <<<"$output" || { echo "$prompt: lacks '$expected': $output" >&2; return 1; }
    [ ! -e "$GRANTS_FILE" ] || { echo "$prompt: recorded a grant" >&2; return 1; }
    cases=$((cases + 1))
  done <<'CASES'
test-row-grant T1|sdk-cli|this session is not interactive
please run test-row-grant T1 now|cli|the whole prompt must be exactly
test-row-grant T99|cli|has no row T99
test-row-grant T2|cli|row T2 is not a security row
CASES
  [ "$cases" -eq 4 ]
}

# link_tools_without_node <dir>: a bin folder holding every tool the gate runs
# except node, for a PATH on which node is absent.
link_tools_without_node() {
  mkdir -p "$1"
  local tool path
  for tool in bash env git jq sh cat dirname basename mktemp rm mkdir cut tr sort head tail wc date grep sed awk shasum sha256sum uname ls pwd printf stat readlink find xargs tee mv cp sleep; do
    path="$(command -v "$tool" 2>/dev/null)" || continue
    case "$path" in /*) ln -sf "$path" "$1/$tool" ;; esac
  done
}

# run_gate_from <payload cwd> <process cwd> [gate]: a merge payload naming the
# first as its cwd, delivered from the second.
run_gate_from() {
  local payload
  payload="$(jq -n --arg c "gh pr merge 7 --squash" --arg d "$1" \
    '{session_id: "s", cwd: $d, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')"
  invoke_hook_in "$2" "$payload" "${3:-$GATE}"
}

@test "a gate that cannot load, resolve or read what it checks with denies instead of allowing" {
  local cases=0 broken expected harness_gate
  while IFS='|' read -r broken expected; do
    [ -n "$broken" ] || continue
    build_fresh
    build_harness
    harness_gate="$HARNESS/.claude/hooks/test-design-merge-gate.sh"
    # Cases that reach the security check run the real gate, which finds the
    # extractor's dependencies; the harness copy holds none.
    case "$broken" in unreadable-grants | node-missing) harness_gate="$GATE" ;; esac
    case "$broken" in
      unreadable-grants)
        set_current_table 'del(.rows[] | select(.id == "T1"))'
        mkdir -p "$(dirname "$GRANTS_FILE")"
        printf '{not json' >"$GRANTS_FILE"
        run_gate "$harness_gate"
        ;;
      node-missing)
        link_tools_without_node "$BATS_TEST_TMPDIR/no-node-bin"
        PATH="$BATS_TEST_TMPDIR/no-node-bin" run_gate "$harness_gate"
        ;;
      no-branch-key)
        rm "$HARNESS/.gaia/scripts/audit-loop-state-lib.sh"
        run_gate "$harness_gate"
        ;;
      no-main-root)
        git_fixture worktree add -q --detach "$BATS_TEST_TMPDIR/linked"
        git_fixture config core.worktree "$BATS_TEST_TMPDIR/absent"
        run_gate_from "$BATS_TEST_TMPDIR/linked" "$BATS_TEST_TMPDIR" "$harness_gate"
        ;;
      no-plan-locate-lib)
        rm "$HARNESS/.gaia/scripts/test-design/plan-locate-lib.sh"
        run_gate "$harness_gate"
        ;;
      no-verb-arming)
        rm "$HARNESS/.claude/hooks/lib/verb-arming.sh"
        run_gate "$harness_gate"
        ;;
      outside-checkout)
        mkdir -p "$BATS_TEST_TMPDIR/not-a-checkout"
        run_gate_from "$BATS_TEST_TMPDIR/not-a-checkout" "$BATS_TEST_TMPDIR/not-a-checkout" "$harness_gate"
        ;;
    esac
    assert_denied_with "$expected" || { echo "$broken: wrong deny" >&2; return 1; }
    cases=$((cases + 1))
  done <<'CASES'
unreadable-grants|is unreadable
node-missing|node is not on PATH
no-branch-key|cannot derive the branch key
no-main-root|cannot resolve the main checkout
no-plan-locate-lib|cannot load .gaia/scripts/test-design/plan-locate-lib.sh
no-verb-arming|cannot load the shared verb-arming decision
outside-checkout|is not inside a git checkout
CASES
  [ "$cases" -eq 7 ]
}
