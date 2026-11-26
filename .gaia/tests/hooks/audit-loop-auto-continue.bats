#!/usr/bin/env bats
#
# The journey of an audit loop that continues on its own: below a live context
# line, a unit dispatch at an enriching checkpoint is admitted with no
# question, a member dispatched inside that unit's window is admitted while the
# next round still reads enriching, and the published `## Audit rounds` line
# counts the one automatic grant. It drives the real
# .claude/hooks/audit-loop-bound.sh, audit-loop-eval.sh record-values and
# audit-loop-record.sh. The refusals (accept, stop, disputes, a stale reading,
# the cap) belong to the hook's own suite.
#
# Every fixture lives under $BATS_TEST_TMPDIR. gh is stubbed on PATH.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-auto-continue.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  HOOK="$REPO_ROOT/.claude/hooks/audit-loop-bound.sh"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  FRONTEND_MEMBER=code-audit-frontend
  SID=0a1b2c3d-1111-4222-8333-444455556666
  IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  GH_STUB_STATE_DIRECTORY="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$STUB_BIN" "$GH_STUB_STATE_DIRECTORY"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${GH_STUB_DIRECTORY:?}/calls.log"
case "$*" in
  *isCrossRepository*) [ -f "$GH_STUB_DIRECTORY/branch.json" ] || { echo "no pull requests found" >&2; exit 1; }; printf 'false\n'; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$STUB_BIN/gh"
}

run_payload() {
  # shellcheck disable=SC2016
  run env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" \
    bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$HOOK"
}

# unit_dispatch: an audit-loop-unit dispatch from the main thread.
unit_dispatch() {
  run_payload "$(jq -n -c --arg session_id "$SID" --arg root "$ALF_ROOT" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 5")}}')"
}

# nested: a member dispatch made from inside a unit.
nested() {
  run_payload "$(jq -n -c --arg member "$FRONTEND_MEMBER" --arg session_id "$SID" --arg root "$ALF_ROOT" --argjson extra "$IN_UNIT" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: $member, prompt: ("Audit the change. Working root: " + $root + ", base main")}} + $extra')"
}

assert_allowed() {
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'unexpected output: %s\n' "$output" >&2; return 1; }
}

new_tree() {
  CTR=$((${CTR:-0} + 1))
  alf_set_line other.txt "$CTR" "tree $CTR"
  alf_commit "tree $CTR"
}

# enriching_snapshot: a stored snapshot holding the enriching signal alone,
# not accept-eligible.
enriching_snapshot() {
  jq -n -c '{verdict: "enriching", A: 1, counted_keys: [], raw_count: 1, waived_count: 0,
    signals: {enriching: true}, accept_eligible: false, accept_reasons: ["enriching"]}'
}

# seed_rounds <n>: n recorded rounds on stand-in trees, the last enriching.
seed_rounds() {
  local object_id_prefix
  object_id_prefix="$(printf 'a%.0s' $(seq 1 37))"
  alf_seed_state "$(jq -n -c --arg object_id_prefix "$object_id_prefix" --argjson round_count "$1" --argjson last "$(enriching_snapshot)" \
    '{knobs: {checkpoint_round: 6, grant_rounds: 3},
      rounds: [range(1; $round_count + 1) | {round: ., tree: ($object_id_prefix + ((100 + .) | tostring)), commit: ($object_id_prefix + ((100 + .) | tostring)),
        raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false,
        snapshot: (if . == $round_count then $last else {verdict: "continue", A: 1} end)}]}')"
}

# below: a fresh reading one token under the default context line.
below() {
  gaia_context_write "$ALF_ROOT" "$SID" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT - 1))" 1000000 "$(date +%s)"
}

@test "an enriching checkpoint below the context line continues on its own and the record counts one automatic grant" {
  local values_file="$BATS_TEST_TMPDIR/values.json" body_file="$BATS_TEST_TMPDIR/body.md"
  seed_rounds 4
  below
  unit_dispatch
  assert_allowed || return 1
  [ "$(jq -r '.history.checkpoints // [] | length' "$ALF_STATE")" -eq 0 ] || return 1
  # A member dispatched inside the unit's window records round 5.
  new_tree
  nested
  assert_allowed || return 1
  # Round 5 still reads enriching, and the next member is admitted as well.
  # shellcheck disable=SC2016
  alf_state_edit '.history.rounds[4].snapshot = $snapshot' --argjson snapshot "$(enriching_snapshot)"
  new_tree
  nested
  assert_allowed || return 1
  [ "$(jq -r '.history.rounds | length' "$ALF_STATE")" -eq 6 ] || return 1
  # The record counts the one automatic unit.
  bash "$SCRIPTS/audit-loop-eval.sh" record-values --root "$ALF_ROOT" >"$values_file" || return 1
  : >"$body_file"
  run bash "$SCRIPTS/audit-loop-record.sh" --pr 12 --values-json "$values_file" --body-in "$body_file" --body-out "$body_file.out"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF -- 'automatic grants: 1' "$body_file.out"
}

# at_or_above: a fresh reading on the context line for session $SID.
at_or_above() {
  gaia_context_write "$ALF_ROOT" "$SID" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" 1000000 "$(date +%s)"
}

@test "a session at the context line hands off without asking and a fresh session below the line is admitted with no answer" {
  local answers_before
  seed_rounds 4
  at_or_above
  unit_dispatch
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ] || { printf 'not a deny: %s\n' "$output" >&2; return 1; }
  case "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" in "BLOCKED: audit checkpoint"*) ;; *) printf 'not a checkpoint deny: %s\n' "$output" >&2; return 1 ;; esac
  [ "$(jq -r '.history.checkpoints | last | [.handoff, .session_id] | map(tostring) | join(" ")' "$ALF_STATE")" = "true $SID" ] || return 1
  answers_before="$(jq -c '.allowance.answers // []' "$ALF_STATE")"
  # A fresh session reads low and its unit dispatch continues on its own.
  SID=9f8e7d6c-1111-4222-8333-444455556666
  below
  unit_dispatch
  assert_allowed || return 1
  [ "$(jq -c '.allowance.answers // []' "$ALF_STATE")" = "$answers_before" ]
}

# record_rounds <through> <last-snapshot-json>: set the recorded rounds to
# <through> on stand-in trees, leaving the units and checkpoints as they are;
# the last round carries the given snapshot, the earlier ones read continue.
record_rounds() {
  local object_id_prefix
  object_id_prefix="$(printf 'a%.0s' $(seq 1 37))"
  # shellcheck disable=SC2016
  alf_state_edit '.history.rounds = [range(1; $through + 1) | {round: ., tree: ($prefix + ((100 + .) | tostring)), commit: ($prefix + ((100 + .) | tostring)),
      raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false,
      snapshot: (if . == $through then $last else {verdict: "continue", A: 1} end)}]' \
    --argjson through "$1" --arg prefix "$object_id_prefix" --argjson last "$2"
}

@test "a human-set cap bounds the chain: a unit dispatch that would open the round past it is denied" {
  local override_dir="$ALF_ROOT/.gaia/local/protected"
  mkdir -p "$override_dir"
  jq -n -c '{version: 1, audit_loop: {round_cap: 4}}' >"$override_dir/checkpoint-override.json"
  # The first unit is admitted on the context line and runs rounds 1 to 3.
  below
  unit_dispatch
  assert_allowed || return 1
  [ "$(jq -r '.history.units[-1] | [.admitted_on, .start_round, .through_round] | map(tostring) | join(" ")' "$ALF_STATE")" = "context 1 3" ] || return 1
  # Round 3 reads enriching; the next unit continues on its own and ends at the cap.
  record_rounds 3 "$(enriching_snapshot)"
  unit_dispatch
  assert_allowed || return 1
  [ "$(jq -r '.history.units[-1] | [.admitted_on, .start_round, .through_round, .automatic] | map(tostring) | join(" ")' "$ALF_STATE")" = "grant 4 4 true" ] || return 1
  # Round 4 is recorded; a unit that would open round 5 needs a human answer.
  record_rounds 4 "$(enriching_snapshot)"
  unit_dispatch
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ] || { printf 'not a deny: %s\n' "$output" >&2; return 1; }
  case "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" in "BLOCKED: audit checkpoint"*) ;; *) printf 'not a checkpoint deny: %s\n' "$output" >&2; return 1 ;; esac
  [ "$(jq -r '.history.checkpoints | last | .reason' "$ALF_STATE")" = cap ]
}
