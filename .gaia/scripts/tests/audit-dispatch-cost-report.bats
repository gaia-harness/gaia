#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-dispatch-cost-report.sh, the reader of the
# maintainer-only audit telemetry log: per-member, per-kind medians over a
# branch window, and the unrecorded count that joins result events to cost
# events.
#
# Every log is hand-written from JSON lines, so the expected output lines are
# computed by hand beside the fixture.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost-report.sh"
  [ -f "$SCRIPT" ]
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.claude/rules/maintainers"
  git -C "$ROOT" init --quiet --initial-branch=main
  printf '# maintainer rule\n' > "$ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  LOG="$ROOT/.gaia/local/telemetry/audit-light-routing.jsonl"
  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"

  FRONTEND="code-audit-frontend"
  SHELL_MEMBER="code-audit-maintainer-shell"
  WORKFLOWS="code-audit-github-workflows"
}

run_report() {
  run bash "$SCRIPT" --root "$ROOT" "$@"
}

# add_cost <branch> <member> <kind> <digest> <state> <incomplete> <dollars>
#   <calls> <wall> <children_state> <children_dollars> <child_calls> <child_wall>
# A dispatch_cost event with a measured dispatch and one specialist child.
add_cost() {
  jq -n -c --arg branch "$1" --arg member "$2" --arg kind "$3" --arg digest "$4" \
    --arg state "$5" --argjson incomplete "$6" --argjson dollars "$7" \
    --argjson calls "$8" --argjson wall "$9" --arg children_state "${10}" \
    --argjson children_dollars "${11}" --argjson child_calls "${12}" \
    --argjson child_wall "${13}" '
    {event: "dispatch_cost", schema: 1, branch: $branch, member: $member, kind: $kind,
     digest: $digest, state: $state, incomplete: $incomplete,
     own: {calls: $calls, wall_s: $wall, dollars: $dollars},
     children_state: $children_state,
     children: (if $children_state == "ok"
       then {specialist: {calls: $child_calls, longest_wall_s: $child_wall,
                          dollars: $children_dollars, dispatches: 1}}
       else null end),
     children_dollars: (if $children_state == "ok" then $children_dollars else null end)}' >> "$LOG"
}

# add_bare_cost <branch> <member> <kind> <digest> <state>: an event with no
# measured figures (transcript_missing, transcript_unparsed, not_dispatched).
add_bare_cost() {
  jq -n -c --arg branch "$1" --arg member "$2" --arg kind "$3" --arg digest "$4" \
    --arg state "$5" '
    {event: "dispatch_cost", schema: 1, branch: $branch, member: $member, kind: $kind,
     digest: $digest, state: $state, incomplete: null, own: null,
     children_state: null, children: null, children_dollars: null}' >> "$LOG"
}

# add_result <event> <branch> <member> <digest>: a member_result or light_outcome.
add_result() {
  jq -n -c --arg event "$1" --arg branch "$2" --arg member "$3" --arg digest "$4" \
    '{event: $event, branch: $branch, member: $member, digest: $digest}' >> "$LOG"
}

# The window fixture. Branches b1 to b5 hold frontend events (oldest first), b6
# and b7 hold only shell-member events, so a global window would differ from a
# per-member one.
build_window_log() {
  add_cost b1 "$FRONTEND" member d1 ok false 1.0 10 100 ok 0.5 2 50
  add_cost b1 "$FRONTEND" light_reviewer d1 ok false 9.0 90 900 ok 1.0 1 1
  add_cost b2 "$FRONTEND" member d2 ok false 2.0 20 200 ok 0.5 4 300
  add_cost b3 "$FRONTEND" light_reviewer d3 ok false 0.2 4 40 ok 0.1 1 10
  add_cost b4 "$FRONTEND" member d4 ok false 4.0 40 400 unparsed 0 0 0
  add_cost b5 "$FRONTEND" member d5 ok false 6.5 61 601.5 ok 1.0 6 100
  add_cost b5 "$FRONTEND" member d5 ok true 100.0 999 9999 ok 1.0 6 100
  add_bare_cost b5 "$FRONTEND" member d5 transcript_missing
  add_bare_cost b5 "$FRONTEND" member d5 transcript_unparsed
  add_bare_cost b5 "$FRONTEND" member d6 not_dispatched
  add_bare_cost b5 "$FRONTEND" member d6 not_dispatched
  add_cost b5 "$FRONTEND" light_reviewer d5 ok false 0.4 8 60 ok 0.3 2 20
  add_cost b6 "$SHELL_MEMBER" member d7 ok false 3.0 30 300 ok 1.0 3 100
  add_cost b7 "$SHELL_MEMBER" member d8 ok false 5.0 50 500 unparsed 0 0 0
  add_cost b7 "$SHELL_MEMBER" member d9 ok false null 70 700 ok 2.0 5 20
}

WINDOW_THREE_EXPECTED="code-audit-frontend member branches=3 dispatches=5 dollars=5.250000 calls=50.5 wall_s=500.750 dollars_with_children=7.500000 calls_with_children=67.0 wall_s_with_children=601.500 not_dispatched=1 transcript_missing=1 transcript_unparsed=1 incomplete=1 unrecorded=0
code-audit-frontend light_reviewer branches=3 dispatches=2 dollars=0.300000 calls=6.0 wall_s=50.000 dollars_with_children=0.500000 calls_with_children=7.5 wall_s_with_children=50.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0
code-audit-maintainer-shell member branches=2 dispatches=3 dollars=4.000000 calls=50.0 wall_s=500.000 dollars_with_children=4.000000 calls_with_children=54.0 wall_s_with_children=500.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0"

WINDOW_DEFAULT_EXPECTED="code-audit-frontend member branches=5 dispatches=7 dollars=3.000000 calls=30.0 wall_s=300.000 dollars_with_children=2.500000 calls_with_children=24.0 wall_s_with_children=300.000 not_dispatched=1 transcript_missing=1 transcript_unparsed=1 incomplete=1 unrecorded=0
code-audit-frontend light_reviewer branches=5 dispatches=3 dollars=0.400000 calls=8.0 wall_s=60.000 dollars_with_children=0.700000 calls_with_children=10.0 wall_s_with_children=60.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0
code-audit-maintainer-shell member branches=2 dispatches=3 dollars=4.000000 calls=50.0 wall_s=500.000 dollars_with_children=4.000000 calls_with_children=54.0 wall_s_with_children=500.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0"

@test "window keeps the last branches per member and medians use only complete events" {
  build_window_log
  run_report --window 3
  [ "$status" -eq 0 ]
  [ "$output" = "$WINDOW_THREE_EXPECTED" ]
}

@test "without --window older branches are counted, and the default is 30" {
  build_window_log
  run_report
  [ "$status" -eq 0 ]
  [ "$output" = "$WINDOW_DEFAULT_EXPECTED" ]
  [ "$output" != "$WINDOW_THREE_EXPECTED" ]
  local default_output="$output"
  run_report --window 30
  [ "$status" -eq 0 ]
  [ "$output" = "$default_output" ]
}

@test "a result event joins to a cost event of its own kind and branch cutoff" {
  local branch=jb
  add_cost "$branch" "$WORKFLOWS" member d1 ok false 1.0 10 100 ok 0.5 2 50
  add_result member_result "$branch" "$FRONTEND" d1
  add_result member_result "$branch" "$FRONTEND" d1
  add_cost "$branch" "$FRONTEND" member d1 ok false 1.0 10 100 ok 0.5 2 50
  add_cost "$branch" "$FRONTEND" light_reviewer d1 ok false 0.2 4 40 ok 0.1 1 10
  add_result light_outcome "$branch" "$FRONTEND" d2
  add_bare_cost "$branch" "$FRONTEND" member d3 not_dispatched
  add_bare_cost "$branch" "$FRONTEND" member d4 transcript_missing
  add_result member_result "$branch" "$FRONTEND" d4
  run_report
  [ "$status" -eq 0 ]
  local expected="code-audit-frontend member branches=1 dispatches=2 dollars=1.000000 calls=10.0 wall_s=100.000 dollars_with_children=1.500000 calls_with_children=12.0 wall_s_with_children=100.000 not_dispatched=1 transcript_missing=1 transcript_unparsed=0 incomplete=0 unrecorded=1
code-audit-frontend light_reviewer branches=1 dispatches=1 dollars=0.200000 calls=4.0 wall_s=40.000 dollars_with_children=0.300000 calls_with_children=5.0 wall_s_with_children=40.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=1
code-audit-github-workflows member branches=1 dispatches=1 dollars=1.000000 calls=10.0 wall_s=100.000 dollars_with_children=1.500000 calls_with_children=12.0 wall_s_with_children=100.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0"
  [ "$output" = "$expected" ]
}

# A light reviewer that escalates, then a full member result with no member
# cost event: the light cost event must not stand in for the missing one.
build_escalate_then_skip_log() {
  add_cost eb "$FRONTEND" light_reviewer d1 ok false 0.2 4 40 ok 0.1 1 10
  add_result light_outcome eb "$FRONTEND" d1
  add_result member_result eb "$FRONTEND" d1
  add_bare_cost eb "$FRONTEND" member d9 not_dispatched
}

ESCALATE_MEMBER_LINE="code-audit-frontend member branches=1 dispatches=0 dollars=n/a calls=n/a wall_s=n/a dollars_with_children=n/a calls_with_children=n/a wall_s_with_children=n/a not_dispatched=1 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=1"
ESCALATE_LIGHT_LINE="code-audit-frontend light_reviewer branches=1 dispatches=1 dollars=0.200000 calls=4.0 wall_s=40.000 dollars_with_children=0.300000 calls_with_children=5.0 wall_s_with_children=40.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0"

@test "an escalated light reviewer does not mask a full member result with no cost event" {
  build_escalate_then_skip_log
  run_report
  [ "$status" -eq 0 ]
  [ "$output" = "$ESCALATE_MEMBER_LINE
$ESCALATE_LIGHT_LINE" ]
}

@test "kind isolation can fail: a join without the kind condition masks the skip" {
  build_escalate_then_skip_log
  local mutant="$BATS_TEST_TMPDIR/mutant-report.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$BATS_TEST_TMPDIR/main-root-lib.sh"
  # shellcheck disable=SC2016
  sed 's/ and \.kind == \$kind and \.state != "not_dispatched"/ and .state != "not_dispatched"/' \
    "$SCRIPT" > "$mutant"
  # The scratch copy must really differ, or this test proves nothing.
  cmp -s "$SCRIPT" "$mutant" && return 1
  run bash "$mutant" --root "$ROOT"
  [ "$status" -eq 0 ]
  local expected_member_line="${ESCALATE_MEMBER_LINE%unrecorded=1}unrecorded=0"
  [ "$output" = "$expected_member_line
$ESCALATE_LIGHT_LINE" ]
}

@test "results on a branch with no cost event count as unrecorded nowhere" {
  add_result member_result lb1 "$FRONTEND" d1
  add_result member_result lb1 "$FRONTEND" d1
  run_report
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a result written before the branch's first cost event is not unrecorded" {
  add_result member_result lb2 "$FRONTEND" d1
  add_cost lb2 "$FRONTEND" member d1 ok false 1.0 10 100 ok 0.5 2 50
  run_report
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend member branches=1 dispatches=1 dollars=1.000000 calls=10.0 wall_s=100.000 dollars_with_children=1.500000 calls_with_children=12.0 wall_s_with_children=100.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=0" ]
}

@test "a result after the first cost event with no cost event of its own counts once" {
  add_result member_result lb1 "$FRONTEND" d1
  add_result member_result lb2 "$FRONTEND" d1
  add_cost lb2 "$FRONTEND" member d1 ok false 1.0 10 100 ok 0.5 2 50
  add_result member_result lb2 "$FRONTEND" d2
  run_report
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend member branches=2 dispatches=1 dollars=1.000000 calls=10.0 wall_s=100.000 dollars_with_children=1.500000 calls_with_children=12.0 wall_s_with_children=100.000 not_dispatched=0 transcript_missing=0 transcript_unparsed=0 incomplete=0 unrecorded=1" ]
}

@test "an absent log exits 0 with no output" {
  rm -f "$LOG"
  run_report
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--window rejects zero and non-numbers with exit 2" {
  build_window_log
  run_report --window 0
  [ "$status" -eq 2 ]
  run_report --window x
  [ "$status" -eq 2 ]
  run_report --window
  [ "$status" -eq 2 ]
}

@test "an unknown argument exits 2" {
  run_report --bogus
  [ "$status" -eq 2 ]
}

@test "jq absent from PATH exits 1 with one stderr line" {
  local bin="$BATS_TEST_TMPDIR/bin" tool
  mkdir -p "$bin"
  for tool in git awk sed dirname cat; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  [ ! -e "$bin/jq" ]
  run env PATH="$bin" /bin/bash "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "other event types and torn lines leave the output unchanged" {
  build_window_log
  run_report --window 3
  local baseline="$output" noisy="$BATS_TEST_TMPDIR/noisy.jsonl" line
  : > "$noisy"
  while IFS= read -r line; do
    {
      printf '%s\n' "$line"
      printf '%s\n' '{"event":"route","branch":"zz","member":"code-audit-frontend","digest":"x","route":"light"}'
      printf '%s\n' '{"event":"escalation_followup","branch":"zz","member":"code-audit-frontend"}'
      printf '%s\n' '{"event":"something_new","branch":"zz","member":"code-audit-frontend","state":"ok"}'
      printf '%s\n' '{"event":"dispatch_cost","branch":"zz",'
    } >> "$noisy"
  done < "$LOG"
  cp "$noisy" "$LOG"
  run_report --window 3
  [ "$status" -eq 0 ]
  [ "$output" = "$baseline" ]
}

# bats test_tags=whole-tree
@test "release-exclude lists both phase-one scripts" {
  grep -qxF '.gaia/scripts/audit-dispatch-cost-lib.sh' "$REPO_ROOT/.gaia/release-exclude"
  grep -qxF '.gaia/scripts/audit-dispatch-cost-report.sh' "$REPO_ROOT/.gaia/release-exclude"
}
