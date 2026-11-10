#!/usr/bin/env bats
#
# Suite for .claude/hooks/audit-loop-ask-grant.sh, the PostToolUse hook that
# records a human's selection of the question the bound hook pinned at an audit
# checkpoint. Every case drives the hook by direct invocation with a payload
# built from the redacted real capture in
# .gaia/tests/fixtures/askuserquestion-posttooluse.json, its question and
# answer replaced by the pinned question the lib builds.
#
# AUDIT_LOOP_ASK_GRANT_HOOK points the suite at a scratch copy of the hook (its
# libraries reached through a `.gaia` symlink beside it), which is how a mutant
# is run against it without touching the working file. UNIT_ROUNDS and the grant labels
# come from GAIA_CONTEXT_UNIT_ROUNDS in the shared lib, never a literal.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-ask-grant.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs and `bash -c` bodies are single-quoted so their `$` reaches
# the inner interpreter.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${AUDIT_LOOP_ASK_GRANT_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh}"
  FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/askuserquestion-posttooluse.json"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  UNIT_ROUNDS="$GAIA_CONTEXT_UNIT_ROUNDS"
  NONCE=0123456789abcdef
  alf_init
  alf_branch feat/ask
  TX_CLI="$BATS_TEST_TMPDIR/tx-cli.jsonl"
  TX_SDK="$BATS_TEST_TMPDIR/tx-sdk.jsonl"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"cli","sessionId":"s1"}' >"$TX_CLI"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"sdk-cli","sessionId":"s1"}' >"$TX_SDK"
}

# seed_rounds <n>: n recorded rounds on the feature branch.
seed_rounds() {
  local round_number
  alf_fill f.txt 5 x
  for round_number in $(seq 1 "$1"); do
    alf_set_line other.txt "$round_number" "round $round_number"
    alf_commit "round $round_number"
    alf_add_round '["code-audit-frontend"]'
  done
}

# pin_latest <nonce> <rounds> <eligible> <cap> <trigger>: pin the question on
# the latest checkpoint, as the bound hook does.
pin_latest() {
  local pinned_question
  pinned_question="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" "$1" "$2" "$UNIT_ROUNDS" "$3" "$4" "$5")"
  alf_state_edit '.history.checkpoints[-1] += {nonce: $nonce, trigger: $trigger, accept_eligible: $accept_eligible, question: $question}' \
    --arg nonce "$1" --arg trigger "$5" --argjson accept_eligible "$3" --argjson question "$pinned_question"
}

# seed_pinned [eligible] [cap]: five rounds and a pending, pinned checkpoint.
seed_pinned() {
  seed_rounds 5
  alf_add_checkpoint 5 context
  pin_latest "$NONCE" 5 "${1:-false}" "${2:-false}" context
}

state_pin() { jq -c '.history.checkpoints[-1].question' "$ALF_STATE"; }

# stored_label <base>: the label of the pinned option named <base>, with the
# (Recommended) suffix when the pin carries it; <base> itself when no option has it.
stored_label() {
  local pin="${PIN_USE:-$(state_pin)}" matched_label
  matched_label="$(printf '%s' "$pin" | jq -r --arg base_label "$1" '[.questions[0].options[].label | select(. == $base_label or . == ($base_label + " (Recommended)"))][0] // empty')"
  printf '%s' "${matched_label:-$1}"
}
continue_label() { stored_label "Continue audit in this session"; }
session_label() { stored_label "Continue audit in a new session"; }

# mk_payload <fixture-index> <label> [jq-filter]: the PostToolUse payload with
# the pinned question (PIN_USE, else the state's) asked and <label> answered,
# then <jq-filter> applied.
mk_payload() {
  local pin="${PIN_USE:-$(state_pin)}"
  jq -c --argjson fixture_index "$1" --argjson pin "$pin" --arg label "$2" --arg session_id "${SID:-s1}" \
    --arg transcript_path "${TX:-$TX_CLI}" --arg cwd "$ALF_ROOT" '
    .[$fixture_index]
    | .session_id = $session_id | .transcript_path = $transcript_path | .cwd = $cwd
    | .scratchpad_dir = "/scratch" | .prompt_id = "p"
    | ($pin.questions[0].question) as $question
    | .tool_input = ($pin + {answers: {($question): $label}, annotations: {}})
    | .tool_response = ($pin + {answers: {($question): $label}, annotations: {}})
    | '"${3:-.}" "$FIXTURE"
}

# send_payload <payload>: deliver it to the hook.
send_payload() {
  run bash -c 'printf %s "$1" | "$2"' _ "$1" "$HOOK"
}

# send <label> [jq-filter]: answer the pinned question with <label>.
send() {
  send_payload "$(mk_payload 0 "$1" "${2:-.}")"
}

# An AskUserQuestion with no connection to the audit loop.
UNRELATED='.tool_input = {questions: [{question: "Which color?", header: "Color", multiSelect: false, options: [{label: "Red", description: "r"}, {label: "Blue", description: "b"}]}]}'

snapshot() { cp "$ALF_STATE" "$BATS_TEST_TMPDIR/before.json"; }
unchanged() { cmp -s "$BATS_TEST_TMPDIR/before.json" "$ALF_STATE"; }

# declined <why>: the hook exited 0, left the state byte-identical, said
# nothing was recorded and named the typed fallback.
declined() {
  [ "$status" -eq 0 ] || { printf 'status %s for %s\n' "$status" "$1" >&2; return 1; }
  unchanged || { printf 'state changed for %s\n' "$1" >&2; return 1; }
  printf '%s' "$output" | jq -e '.systemMessage | length > 0' >/dev/null || { printf 'no systemMessage for %s: %s\n' "$1" "$output" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'Nothing was recorded' || { printf 'no decline text for %s: %s\n' "$1" "$output" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'audit-grant' || { printf 'fallback unnamed for %s\n' "$1" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'audit-accept' || { printf 'accept fallback unnamed for %s\n' "$1" >&2; return 1; }
  claude_told_nothing_recorded "$1"
}

# claude_told_nothing_recorded <why>: the reason is in the one field Claude reads.
claude_told_nothing_recorded() {
  printf '%s' "$output" | jq -e '
    .hookSpecificOutput.hookEventName == "PostToolUse"
    and (.hookSpecificOutput.additionalContext | contains("no grant or accept was recorded"))
    and (.systemMessage as $message | .hookSpecificOutput.additionalContext | contains($message))' >/dev/null \
    || { printf 'Claude not told for %s: %s\n' "$1" "$output" >&2; return 1; }
}

# --- UAT-011: the record ------------------------------------------------------

@test "UAT-011: the pinned grant, selected by a main-thread cli session, records one answer" {
  seed_pinned
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  jq -e --argjson unit_rounds "$UNIT_ROUNDS" --arg nonce "$NONCE" --arg option_label "$(continue_label)" \
    '.allowance.answers[0] | .checkpoint == 1 and .kind == "grant" and .n == $unit_rounds and .source == "ask" and .option == $option_label and .nonce == $nonce' "$ALF_STATE"
  printf '%s' "$output" | jq -e '(.systemMessage | length) > 0 and .hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length) > 0'
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = "$((5 + UNIT_ROUNDS))" ]
}

@test "every recorded answer carries at and the payload's session id" {
  seed_pinned true
  SID=s1 send "Accept the remainder"
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers[0] | (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and .session_id == "s1" and .kind == "accept" and .source == "ask"' "$ALF_STATE"
}

@test "Continue audit in a new session records the same answer shape as Continue audit in this session and tells the main thread to print a prompt" {
  seed_pinned
  send "$(session_label)"
  [ "$status" -eq 0 ]
  jq -e --argjson unit_rounds "$UNIT_ROUNDS" --arg option_label "$(session_label)" \
    '.allowance.answers[0] | .kind == "grant" and .n == $unit_rounds and .source == "ask" and .option == $option_label and (keys | sort) == ["at","checkpoint","kind","n","nonce","option","session_id","source"]' "$ALF_STATE"
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Run `/clear`, then paste the prompt below.") and contains("Press Ctrl+C, run `claude`") and contains("fenced continuation prompt") and contains("and stop")'
}

@test "the recommended label records the grant, with and without the suffix the pin carries, and the option keeps what was selected" {
  seed_pinned
  [ "$(session_label)" = "Continue audit in a new session (Recommended)" ]
  send "$(session_label)"
  [ "$status" -eq 0 ]
  jq -e --argjson unit_rounds "$UNIT_ROUNDS" --arg option_label "Continue audit in a new session (Recommended)" \
    '.allowance.answers | length == 1 and .[0].kind == "grant" and .[0].n == $unit_rounds and .[0].option == $option_label' "$ALF_STATE"
  printf '%s' "$output" | jq -e --argjson unit_rounds "$UNIT_ROUNDS" '(.systemMessage | startswith("Recorded: Continue audit in a new session on branch")) and (.hookSpecificOutput.additionalContext | contains("fenced continuation prompt"))'
}

@test "an unsuffixed label the pin carries as recommended, and a suffix the pin does not carry, both decline" {
  seed_pinned
  snapshot
  send "Continue audit in a new session"
  declined "base label while the pin carries the suffixed one"
  send "Continue audit in this session (Recommended)"
  declined "suffix on an option the pin does not recommend"
  send "Accept the remainder (Recommended)"
  declined "suffix on an option the pin lacks"
}

@test "Accept the remainder records kind accept only when it is in the pin" {
  seed_pinned true
  send "Accept the remainder"
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers | length == 1 and .[0].kind == "accept" and (.[0] | has("n") | not) and .[0].option == "Accept the remainder"' "$ALF_STATE"
}

@test "an accept selected against a pin without it declines, and an accept option the pin lacks declines" {
  seed_pinned false
  snapshot
  send "Accept the remainder"
  declined "accept selected, not in the pin"
  local eligible_pin
  eligible_pin="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" "$NONCE" 5 "$UNIT_ROUNDS" true false context)"
  PIN_USE="$eligible_pin" send "Accept the remainder"
  declined "payload offers an accept option the pin lacks"
}

@test "Type audit-accept instead against a cap-ineligible pin records nothing and names typed audit-accept" {
  seed_rounds 10
  alf_add_checkpoint 10 cap
  pin_latest "$NONCE" 10 false true cap
  snapshot
  send "Type audit-accept instead"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'audit-accept'
  printf '%s' "$output" | grep -qF 'deliberate override'
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
}

@test "a grant label selected against a cap pin records one grant of K" {
  seed_rounds 10
  alf_add_checkpoint 10 cap
  pin_latest "$NONCE" 10 false true cap
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  jq -e --argjson unit_rounds "$UNIT_ROUNDS" '.allowance.answers[0] | .checkpoint == 1 and .kind == "grant" and .n == $unit_rounds and .source == "ask"' "$ALF_STATE"
}

@test "UAT-030: Stop and file the remainder records nothing and names the file-and-report step" {
  seed_pinned
  snapshot
  send "Stop and file the remainder"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'file the remainder'
  printf '%s' "$output" | grep -qF 'leave the PR open'
  printf '%s' "$output" | grep -qF 'report'
  printf '%s' "$output" | jq -e '(.hookSpecificOutput.additionalContext | contains("Do not dispatch another audit round"))'
}

# --- UAT-012: every red state --------------------------------------------------

@test "UAT-012: Other free text records nothing" {
  seed_pinned
  snapshot
  send_payload "$(mk_payload 1 "free text probe")"
  declined "Other free text"
  send "free text probe"
  declined "Other free text, built payload"
}

@test "UAT-012: a label that is not in the pin records nothing" {
  seed_pinned
  snapshot
  send "Continue audit for 99 rounds"
  declined "label not in the pin"
  send "grant"
  declined "partial label"
}

@test "UAT-012: a stale nonce (an older checkpoint's question) records nothing" {
  seed_pinned
  local old_pin
  old_pin="$(state_pin)"
  alf_add_checkpoint 5 context
  pin_latest fedcba9876543210 5 false false context
  snapshot
  PIN_USE="$old_pin" send "$(continue_label)"
  declined "stale nonce"
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
}

@test "UAT-012: a wrong nonce records nothing" {
  seed_pinned
  snapshot
  PIN_USE="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" fedcba9876543210 5 "$UNIT_ROUNDS" false false context)" send "$(continue_label)"
  declined "wrong nonce"
}

@test "UAT-012: any change to the question the payload carries records nothing" {
  seed_pinned
  snapshot
  local name filter
  while IFS='|' read -r name filter; do
    send "$(continue_label)" "$filter"
    declined "$name"
  done <<'CASES'
changed question text|.tool_input.questions[0].question += " (edited)"
changed header|.tool_input.questions[0].header = "Edited"
changed option description|.tool_input.questions[0].options[0].description += " edited"
multiSelect true|.tool_input.questions[0].multiSelect = true
a second question|.tool_input.questions += [.tool_input.questions[0]]
an extra top-level key|.tool_input.extra = 1
a dropped option|.tool_input.questions[0].options |= .[1:]
CASES
}

@test "UAT-012: an agent_id on the payload records nothing" {
  seed_pinned
  snapshot
  send "$(continue_label)" '.agent_id = "agent-1"'
  declined "agent_id present"
  printf '%s' "$output" | grep -qF 'sub-agent'
}

@test "UAT-012: CLAUDE_CODE_ENTRYPOINT other than cli, or unset, records nothing" {
  seed_pinned
  snapshot
  CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)"
  declined "sdk-cli entrypoint"
  printf '%s' "$output" | grep -qF 'not interactive'
  unset CLAUDE_CODE_ENTRYPOINT
  send "$(continue_label)"
  declined "entrypoint unset"
}

@test "UAT-012: a transcript with a non-cli entrypoint, or none, records nothing" {
  seed_pinned
  snapshot
  TX="$TX_SDK" send "$(continue_label)"
  declined "sdk-cli transcript"
  printf '%s' "$output" | grep -qF 'Start a new interactive Claude Code session on this branch'
  printf '%s' "$output" | grep -qF -- '--continue or --resume'
  TX="$BATS_TEST_TMPDIR/no-such.jsonl" send "$(continue_label)"
  declined "missing transcript"
  printf '%s' "$output" | grep -qF 'Send any other message first'
  TX="$BATS_TEST_TMPDIR/no-such.jsonl" CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)"
  declined "missing transcript under sdk-cli"
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "mutant: a hook ignoring the check's status records" {
  seed_pinned
  scratch_hook 's/|| interactive_exit_status=\$?/|| true/'
  TX="$TX_SDK" send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "UAT-012: a permission mode outside the allowlist, an unmeasured one, or none records nothing" {
  seed_pinned
  snapshot
  send "$(continue_label)" '.permission_mode = "dontAsk"'
  declined "dontAsk"
  send "$(continue_label)" '.permission_mode = "somethingNew"'
  declined "unmeasured mode"
  send "$(continue_label)" 'del(.permission_mode)'
  declined "permission_mode absent"
  send "$(continue_label)" '.permission_mode = ""'
  declined "empty permission_mode"
}

@test "every allowlisted permission mode records" {
  local mode count=0
  seed_pinned
  for mode in default acceptEdits plan auto bypassPermissions; do
    alf_state_edit '.allowance.answers = []'
    send "$(continue_label)" ".permission_mode = \"$mode\""
    [ "$status" -eq 0 ]
    [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ] || { printf 'mode %s did not record: %s\n' "$mode" "$output" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -eq 5 ]
}

@test "a checkpoint without a pinned question records nothing and says so" {
  seed_rounds 5
  alf_add_checkpoint 5 allowance
  snapshot
  PIN_USE="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" "$NONCE" 5 "$UNIT_ROUNDS" false false context)" send "$(continue_label)"
  declined "no pinned question"
  printf '%s' "$output" | grep -qF 'no pinned question'
}

# --- replay, scope, silence ----------------------------------------------------

@test "replay: the same valid payload sent twice records once and the second says nothing is pending" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  snapshot
  send_payload "$payload_json"
  declined "replay"
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending'
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "worktree-audited shape: a main-checkout session answers the checkpoint its own session hit" {
  seed_pinned
  alf_git checkout -q main
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "a different session id on the main checkout records nothing and declines the checkpoint-shaped question visibly" {
  seed_pinned
  alf_git checkout -q main
  snapshot
  SID=other-session send "$(continue_label)"
  declined "other session, shaped"
  SID=other-session send "$(continue_label)" "$UNRELATED"
  [ "$status" -eq 0 ]
  unchanged
  [ -z "$output" ]
}

@test "two pending checkpoints with the same session id record nothing" {
  seed_pinned
  jq '.key = "branch:feat/second" | .branch = "feat/second"' "$ALF_STATE" >"$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json"
  alf_git checkout -q main
  snapshot
  cp "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json" "$BATS_TEST_TMPDIR/second-before.json"
  send "$(continue_label)"
  declined "ambiguous"
  cmp -s "$BATS_TEST_TMPDIR/second-before.json" "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json"
}

@test "state only at the old directory records nothing; the same state at protected/audit-loop records" {
  local OLD_STATE_DIRECTORY="$ALF_ROOT/.gaia/local/audit-loop"
  seed_pinned
  mkdir -p "$OLD_STATE_DIRECTORY/feat"
  cp "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json" "$OLD_STATE_DIRECTORY/feat/ask.json"
  cp "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json" "$BATS_TEST_TMPDIR/before.json"
  local PIN_USE
  PIN_USE="$(state_pin)"
  rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'Nothing was recorded'
  send "$(continue_label)" "$UNRELATED"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp -s "$BATS_TEST_TMPDIR/before.json" "$OLD_STATE_DIRECTORY/feat/ask.json"
  mkdir -p "$ALF_ROOT/.gaia/local/protected/audit-loop/feat"
  cp "$BATS_TEST_TMPDIR/before.json" "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json"
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json")" -eq 1 ]
}

@test "a tool that is not AskUserQuestion, or no audit state at all, exits 0 silently" {
  seed_pinned
  local valid PIN_USE
  PIN_USE="$(state_pin)"
  valid="$(mk_payload 0 "$(continue_label)")"
  snapshot
  send_payload "$(mk_payload 0 "$(continue_label)" '.tool_name = "Bash"')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unchanged
  rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
  send_payload "$(mk_payload 0 "$(continue_label)" "$UNRELATED")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  send_payload "$valid"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'Nothing was recorded'
  printf '%s' "$output" | grep -qF 'audit-grant'
}

@test "invocation with argv, or with empty stdin, exits 1 and records nothing" {
  seed_pinned
  snapshot
  run bash -c 'printf %s "$1" | "$2" extra' _ "$(mk_payload 0 "$(continue_label)")" "$HOOK"
  [ "$status" -eq 1 ]
  run bash -c 'printf "" | "$1"' _ "$HOOK"
  [ "$status" -eq 1 ]
  unchanged
}

@test "jq absent: the hook records nothing, says jq is missing and names the typed fallback" {
  seed_pinned
  snapshot
  local empty="$BATS_TEST_TMPDIR/nopath"
  mkdir -p "$empty"
  run bash -c 'printf %s "$1" | PATH="$3" "$(command -v bash)" "$2"' _ "$(mk_payload 0 "$(continue_label)")" "$HOOK" "$empty"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'jq is missing'
  printf '%s' "$output" | grep -qF 'audit-grant'
  claude_told_nothing_recorded "jq absent"
}

@test "a shaped question with no audit state tells Claude nothing was recorded" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  claude_told_nothing_recorded "no audit state"
}

@test "a decline with the libraries missing tells Claude nothing was recorded" {
  seed_pinned
  snapshot
  local payload_json lone_hook="$BATS_TEST_TMPDIR/lone/.claude/hooks/audit-loop-ask-grant.sh"
  payload_json="$(mk_payload 0 "$(continue_label)")"
  mkdir -p "$(dirname "$lone_hook")"
  cp "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" "$lone_hook"
  HOOK="$lone_hook" send_payload "$payload_json"
  declined "libraries missing"
}

@test "a failed state read before or under the lock tells Claude nothing was recorded" {
  seed_pinned
  snapshot
  scratch_hook 's/^state="\$(gaia_loop_read_state "\$target" 2>\/dev\/null)" || _ag_decline/false || _ag_decline/'
  send "$(continue_label)"
  declined "read failed before the lock"
  printf '%s' "$output" | grep -qF 'could not be read'
  rm -rf "$BATS_TEST_TMPDIR/scratch"
  HOOK="$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh"
  scratch_hook 's/^state="\$(gaia_loop_read_state "\$target" 2>\/dev\/null)"$/false/'
  send "$(continue_label)"
  declined "read failed under the lock"
  printf '%s' "$output" | grep -qF 'could not be read'
}

@test "a failed state write tells Claude nothing was recorded" {
  seed_pinned
  snapshot
  scratch_hook 's/! gaia_loop_write_state "\$target" "\$new"/true/'
  send "$(continue_label)"
  declined "write failed"
}

@test "corrupt state: the message names the file and the file is untouched" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  printf '{ not json' >"$ALF_STATE"
  snapshot
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'corrupt'
}

# --- concurrency ---------------------------------------------------------------

@test "two recorders racing the same payload record at most once" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  bash -c 'printf %s "$1" | "$2" >"$3/out-a" 2>&1' _ "$payload_json" "$HOOK" "$BATS_TEST_TMPDIR" &
  local pid_a=$!
  bash -c 'printf %s "$1" | "$2" >"$3/out-b" 2>&1' _ "$payload_json" "$HOOK" "$BATS_TEST_TMPDIR" &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  grep -qF 'Recorded' "$BATS_TEST_TMPDIR/out-a" "$BATS_TEST_TMPDIR/out-b"
  grep -lF 'no audit checkpoint is pending' "$BATS_TEST_TMPDIR/out-a" "$BATS_TEST_TMPDIR/out-b"
}

@test "a held lock past the deadline records nothing and is a visible decline" {
  seed_pinned
  snapshot
  mkdir "$ALF_STATE.lock"
  send "$(continue_label)"
  rmdir "$ALF_STATE.lock"
  declined "held lock"
  printf '%s' "$output" | grep -qF 'locked'
}

# --- unrelated questions are silent, shaped ones decline -----------------------

# silent <why>: exit 0, no output, state byte-identical.
silent() {
  [ "$status" -eq 0 ] || { printf 'status %s for %s\n' "$status" "$1" >&2; return 1; }
  [ -z "$output" ] || { printf 'output for %s: %s\n' "$1" "$output" >&2; return 1; }
  unchanged || { printf 'state changed for %s\n' "$1" >&2; return 1; }
}

@test "an unrelated question is silent with and without a checkpoint pending, from a sub-agent, a non-interactive session and an unlisted mode" {
  seed_pinned
  local PIN_USE
  PIN_USE="$(state_pin)"
  snapshot
  send "$(continue_label)" "$UNRELATED"
  silent "pending, plain"
  send "$(continue_label)" "$UNRELATED | .agent_id = \"agent-1\""
  silent "sub-agent"
  CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)" "$UNRELATED"
  silent "non-interactive"
  send "$(continue_label)" "$UNRELATED | .permission_mode = \"dontAsk\""
  silent "unlisted mode"
  alf_state_edit '.history.checkpoints = [] | .allowance.answers = []'
  snapshot
  send "$(continue_label)" "$UNRELATED | .agent_id = \"agent-1\""
  silent "nothing pending, sub-agent"
  send "$(continue_label)" "$UNRELATED | .permission_mode = \"dontAsk\""
  silent "nothing pending, unlisted mode"
}

@test "a header that merely contains the pinned header, and a label that contains a pinned label, stay silent" {
  seed_pinned
  snapshot
  send "$(continue_label)" "$UNRELATED | .tool_input.questions[0].header = \"Audit loop status\""
  silent "header substring"
  send "$(continue_label)" "$UNRELATED | .tool_input.questions[0].options[0].label = \"Continue audit in this session now\""
  silent "label containing a pinned label"
}

@test "a changed header and question text still decline visibly when an option label is pinned" {
  seed_pinned
  snapshot
  send "$(continue_label)" '.tool_input.questions[0].header = "Edited" | .tool_input.questions[0].question += " (edited)"'
  declined "altered copy with a checkpoint pending"
}

@test "an exact replay with nothing pending declines visibly, from a checkout with state and from one with none" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  send_payload "$payload_json"
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  snapshot
  send_payload "$payload_json"
  declined "replay with state"
  rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'Nothing was recorded'
  printf '%s' "$output" | grep -qF 'audit-grant'
}

@test "corrupt state declines visibly whatever the shape" {
  seed_pinned
  local PIN_USE
  PIN_USE="$(state_pin)"
  printf '{ not json' >"$ALF_STATE"
  snapshot
  send "$(continue_label)" "$UNRELATED"
  declined "corrupt, unrelated"
  send "$(continue_label)"
  declined "corrupt, shaped"
}

# --- the hook itself -----------------------------------------------------------

@test "the hook parses under stock bash and never exits 2" {
  /bin/bash -n "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh"
  grep -nE '^[[:space:]]*exit 2' "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  true
}

# --- mutants: each guard can fail ----------------------------------------------

# The header and the wiki sentence state the interactive check, the order and
# the silence scope. HEADER_FILE and WIKI_FILE let a mutant point at scratch copies.
doc_pin_holds() {
  local header_file="${HEADER_FILE:-$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh}" wiki_file="${WIKI_FILE:-$REPO_ROOT/wiki/concepts/Claude Hooks.md}"
  grep -qF 'Headless runs have no AskUserQuestion tool' "$header_file" && return 1
  grep -qF 'The interactive session check declines' "$header_file" || return 1
  grep -qF 'before any numbered check' "$header_file" || return 1
  grep -qF 'Silence covers only unrelated questions' "$header_file" || return 1
  grep -qF 'which declines headless runs' "$wiki_file" || return 1
  grep -qF 'before any check below' "$wiki_file" || return 1
  grep -qF 'silence covers only unrelated questions' "$wiki_file" || return 1
  true
}

@test "doc pin: the hook header and the wiki sentence state the interactive check, the order and the silence scope" {
  doc_pin_holds
}

@test "mutant: restoring the old headless sentence turns the doc pin red" {
  local scratch_header="$BATS_TEST_TMPDIR/header.sh"
  sed 's/The interactive session check declines/Headless runs have no AskUserQuestion tool. The interactive session check declines/' "$HOOK" >"$scratch_header"
  cmp -s "$HOOK" "$scratch_header" && return 1
  HEADER_FILE="$scratch_header" doc_pin_holds && return 1
  true
}

@test "mutant: a wiki sentence without the order turns the doc pin red" {
  local scratch_wiki="$BATS_TEST_TMPDIR/hooks.md"
  sed 's/before any check below/later/' "$REPO_ROOT/wiki/concepts/Claude Hooks.md" >"$scratch_wiki"
  cmp -s "$scratch_wiki" "$REPO_ROOT/wiki/concepts/Claude Hooks.md" && return 1
  WIKI_FILE="$scratch_wiki" doc_pin_holds && return 1
  true
}

# scratch_hook <sed-expression>: a scratch copy of the hook with its libraries
# reached through a `.gaia` symlink beside it; sets HOOK and proves the edit
# changed the copy.
scratch_hook() {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch_directory/.claude/hooks"
  ln -s "$REPO_ROOT/.gaia" "$scratch_directory/.gaia"
  sed "$1" "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" >"$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
  chmod +x "$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
  cmp -s "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" "$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  HOOK="$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
}

@test "mutant: with the question-equality check disabled, a changed question records" {
  seed_pinned
  scratch_hook 's/== \$pin'"'"' >\/dev\/null/== $pin or true'"'"' >\/dev\/null/'
  send "$(continue_label)" '.tool_input.questions[0].header = "Edited"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "mutant: with the shape test removed, an unrelated question from a sub-agent is no longer silent" {
  seed_pinned
  scratch_hook 's/^\[ "\$(_ag_shaped "\$shape_pin")" = true \] || exit 0$/true/'
  snapshot
  send "$(continue_label)" "$UNRELATED | .agent_id = \"agent-1\""
  [ -n "$output" ]
}

@test "mutant: with substring matching, a near-miss header is no longer silent" {
  seed_pinned
  scratch_hook 's/\.header == "Audit loop"/(.header | tostring | contains("Audit loop"))/'
  snapshot
  send "$(continue_label)" "$UNRELATED | .tool_input.questions[0].header = \"Audit loop status\""
  [ -n "$output" ]
}

@test "mutant: with the agent_id check disabled, a sub-agent payload records" {
  seed_pinned
  scratch_hook 's/ != false \]; then/ = nope ]; then/'
  send "$(continue_label)" '.agent_id = "agent-1"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "mutant: with the permission-mode allowlist emptied of its check, an unmeasured mode records" {
  seed_pinned
  scratch_hook 's/\*" \$mode "\*) ;;/*) ;;/'
  send "$(continue_label)" '.permission_mode = "somethingNew"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}
