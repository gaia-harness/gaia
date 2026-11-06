#!/usr/bin/env bats
#
# The pre-audit fidelity judge's verdict cache (uat-fidelity-cache.sh): a resume
# re-judges only the tests whose key (test, SPEC, guard, surface, judge rubric)
# changed, and carries every other verdict forward.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CACHE_SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/uat-fidelity-cache.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/.claude/agents" "$WORK/tests" "$WORK/plan" "$WORK/scratch"
  printf 'judge rubric v1\n' >"$WORK/.claude/agents/uat-fidelity-judge.md"
  SPEC="$WORK/SPEC.md"
  printf 'spec v1\n' >"$SPEC"
  CACHE="$WORK/plan/uat-fidelity-cache.json"
  BRIEF="$WORK/scratch/brief.txt"
  PENDING="$WORK/scratch/pending.txt"
  CARRIED="$WORK/scratch/carried.json"
  VERDICTS="$WORK/scratch/verdicts.json"
  MERGED="$WORK/scratch/merged.json"
  printf 'test one\n' >"$WORK/tests/one.test.ts"
  printf 'test two\n' >"$WORK/tests/two.test.ts"
  printf 'guard\n' >"$WORK/tests/guard.ts"
  cat >"$BRIEF" <<BRIEF_EOF
Spec: UAT-001 $WORK/tests/one.test.ts
Surface: UAT-001 route
Guard: UAT-001 $WORK/tests/guard.ts
Spec: UAT-002 $WORK/tests/two.test.ts
Surface: UAT-002 browser
BRIEF_EOF
}

run_select() {
  run bash -c 'cd "$1" && bash "$2" select "$3" --spec "$4" --brief "$5" --pending "$6" --carried "$7"' _ \
    "$WORK" "$CACHE_SCRIPT" "$CACHE" "$SPEC" "$BRIEF" "$PENDING" "$CARRIED"
}

run_record() {
  run bash -c 'cd "$1" && bash "$2" record "$3" --spec "$4" --brief "$5" --carried "$6" --verdicts "$7" --out "$8"' _ \
    "$WORK" "$CACHE_SCRIPT" "$CACHE" "$SPEC" "$BRIEF" "$CARRIED" "$VERDICTS" "$MERGED"
}

# judge_all <verdict-one> <verdict-two>: a first pre-audit that judges both
# tests and records the verdicts.
judge_all() {
  run_select
  [ "$status" -eq 0 ] || return 1
  cat >"$VERDICTS" <<VERDICTS_EOF
[
  {"uat_id": "UAT-001", "file": "$WORK/tests/one.test.ts", "verdict": "$1", "reason": "one"},
  {"uat_id": "UAT-002", "file": "$WORK/tests/two.test.ts", "verdict": "$2", "reason": "two"}
]
VERDICTS_EOF
  run_record
  [ "$status" -eq 0 ] || return 1
}

pending_ids() {
  awk '$1 == "Spec:" { print $2 }' "$PENDING" | tr '\n' ' '
}

@test "with no cache every test is pending and nothing is carried" {
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "2" ] || return 1
  [ "$(pending_ids)" = "UAT-001 UAT-002 " ] || return 1
  grep -qxF "Surface: UAT-001 route" "$PENDING" || return 1
  grep -qxF "Guard: UAT-001 $WORK/tests/guard.ts" "$PENDING" || return 1
  [ "$(jq 'length' "$CARRIED")" -eq 0 ]
}

@test "a resume with nothing changed carries every verdict and judges none" {
  judge_all asserts asserts
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "0" ] || return 1
  [ -s "$PENDING" ] && return 1
  [ "$(jq -r 'map(.uat_id) | join(" ")' "$CARRIED")" = "UAT-001 UAT-002" ]
}

@test "a changed test file is re-judged and the other verdict carried" {
  judge_all asserts asserts
  printf 'test two edited\n' >"$WORK/tests/two.test.ts"
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "1" ] || return 1
  [ "$(pending_ids)" = "UAT-002 " ] || return 1
  grep -qxF "Surface: UAT-002 browser" "$PENDING" || return 1
  [ "$(jq -r 'map(.uat_id) | join(" ")' "$CARRIED")" = "UAT-001" ]
}

@test "a SPEC change re-judges every test" {
  judge_all asserts asserts
  printf 'spec v2, reopened\n' >"$SPEC"
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "2" ] || return 1
  [ "$(jq 'length' "$CARRIED")" -eq 0 ]
}

@test "a changed guard file re-judges only the test that names it" {
  judge_all asserts asserts
  printf 'guard edited\n' >"$WORK/tests/guard.ts"
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$(pending_ids)" = "UAT-001 " ]
}

@test "a changed judge rubric re-judges every test" {
  judge_all asserts asserts
  printf 'judge rubric v2\n' >"$WORK/.claude/agents/uat-fidelity-judge.md"
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "2" ]
}

@test "a corrupt cache is ignored and every test is pending" {
  printf 'not json\n' >"$CACHE"
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "2" ]
}

@test "a diverges verdict is carried, not re-judged" {
  judge_all asserts diverges
  run_select
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "0" ] || return 1
  [ "$(jq -r '.[] | select(.uat_id == "UAT-002") | .verdict' "$CARRIED")" = "diverges" ]
}

@test "record merges carried and new verdicts in brief order" {
  judge_all asserts asserts
  printf 'test one edited\n' >"$WORK/tests/one.test.ts"
  run_select
  [ "$status" -eq 0 ] || return 1
  cat >"$VERDICTS" <<VERDICTS_EOF
[{"uat_id": "UAT-001", "file": "$WORK/tests/one.test.ts", "verdict": "diverges", "reason": "rejudged"}]
VERDICTS_EOF
  run_record
  [ "$status" -eq 0 ] || return 1
  [ "$(jq -r 'map("\(.uat_id)=\(.verdict)") | join(" ")' "$MERGED")" = "UAT-001=diverges UAT-002=asserts" ] || return 1
  jq -e 'all(.[]; has("key") | not)' "$MERGED" >/dev/null || return 1
  run_select
  [ "$output" = "0" ]
}

@test "lifecycle.md selects before the judge dispatch, records after it, and halts on the merged verdicts" {
  lifecycle="$REPO_ROOT_REAL/.claude/skills/gaia/references/spec/lifecycle.md"
  select_line=$(grep -n 'uat-fidelity-cache.sh select ' "$lifecycle" | cut -d: -f1)
  dispatch_line=$(grep -n 'dispatch `Agent(subagent_type: "uat-fidelity-judge")`' "$lifecycle" | cut -d: -f1)
  record_line=$(grep -n 'uat-fidelity-cache.sh record ' "$lifecycle" | cut -d: -f1)
  halt_line=$(grep -nF "jq -e 'all(.[]; .verdict == \"asserts\")' <MERGED_FILE>" "$lifecycle" | cut -d: -f1)
  [ -n "$select_line" ] && [ -n "$dispatch_line" ] && [ -n "$record_line" ] && [ -n "$halt_line" ] || return 1
  [ "$select_line" -lt "$dispatch_line" ] || return 1
  [ "$dispatch_line" -lt "$record_line" ] || return 1
  [ "$record_line" -lt "$halt_line" ]
}

@test "record refuses a brief test that has no verdict" {
  run_select
  [ "$status" -eq 0 ] || return 1
  cat >"$VERDICTS" <<VERDICTS_EOF
[{"uat_id": "UAT-001", "file": "$WORK/tests/one.test.ts", "verdict": "asserts", "reason": "one"}]
VERDICTS_EOF
  run_record
  [ "$status" -eq 2 ] || return 1
  [ -f "$CACHE" ] && return 1
  true
}
