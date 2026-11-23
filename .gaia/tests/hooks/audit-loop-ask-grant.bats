#!/usr/bin/env bats
#
# Suite for .claude/hooks/audit-loop-ask-grant.sh, the PostToolUse hook that
# records a human's selection of the question the bound hook pinned at an audit
# checkpoint. Every case drives the hook by direct invocation with a payload
# built from the redacted real capture in
# .gaia/tests/fixtures/askuserquestion-posttooluse.json, its question and
# answer replaced by the pinned question the lib builds.
#
# AUDIT_LOOP_ASK_GRANT_HOOK points the suite at another copy of the hook (its
# libraries reached through a `.gaia` symlink beside it); the decline table
# uses scratch copies the same way to inject a failed state read or write.
# UNIT_ROUNDS and the grant labels come from GAIA_CONTEXT_UNIT_ROUNDS in the
# shared lib, never a literal.
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

# seed_cap: ten rounds and a pending checkpoint pinned on the round cap.
seed_cap() {
  seed_rounds 10
  alf_add_checkpoint 10 cap
  pin_latest "$NONCE" 10 false true cap
}

# keep_state / restore_state: save the seeded state once, and put it back
# before each table row so no row's record, edit or removal leaks into the next.
keep_state() { cp "$ALF_STATE" "$BATS_TEST_TMPDIR/kept.json"; }
restore_state() {
  mkdir -p "${ALF_STATE%/*}"
  cp "$BATS_TEST_TMPDIR/kept.json" "$ALF_STATE"
}

# fresh_fixture: discard the fixture and build a new one, as setup does per test.
fresh_fixture() {
  rm -rf "${BATS_TEST_TMPDIR:?}"/*
  setup
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

# silent <why>: exit 0, no output, state byte-identical.
silent() {
  [ "$status" -eq 0 ] || { printf 'status %s for %s\n' "$status" "$1" >&2; return 1; }
  [ -z "$output" ] || { printf 'output for %s: %s\n' "$1" "$output" >&2; return 1; }
  unchanged || { printf 'state changed for %s\n' "$1" >&2; return 1; }
}

# scratch_hook <sed-expression>: points HOOK at a scratch copy carrying the edit,
# and fails when the edit changed nothing.
scratch_hook() {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch_directory/.claude/hooks"
  ln -s "$REPO_ROOT/.gaia" "$scratch_directory/.gaia"
  sed "$1" "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" >"$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
  chmod +x "$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
  cmp -s "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" "$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  HOOK="$scratch_directory/.claude/hooks/audit-loop-ask-grant.sh"
}

# --- the record ------------------------------------------------------------------

@test "a fallback checkpoint with the context line 0 (checkpoint off) leads with continuing here and omits the short-on-room text" {
  local question labels
  question="$(gaia_loop_pinned_question feat/ask "$NONCE" 5 "$UNIT_ROUNDS" false false fallback "fresh 50000 1000000" grant 0)"
  labels="$(jq -r '.questions[0].options[].label' <<<"$question")"
  [ "$(head -n 1 <<<"$labels")" = "Continue audit in this session (Recommended)" ] || return 1
  jq -r '.questions[0].options[].description' <<<"$question" | grep -qF "short on room" && return 1
  true
}

@test "a high reading with the checkpoint off keeps the continue-here lead and claims neither room nor a line" {
  local question descriptions
  question="$(gaia_loop_pinned_question feat/ask "$NONCE" 5 "$UNIT_ROUNDS" false false fallback "fresh 950000 1000000" grant 0)"
  [ "$(jq -r '.questions[0].options[0].label' <<<"$question")" = "Continue audit in this session (Recommended)" ] || return 1
  descriptions="$(jq -r '.questions[0].options[].description' <<<"$question")"
  grep -qF "the checkpoint is off" <<<"$descriptions" || return 1
  grep -qF "has room" <<<"$descriptions" && return 1
  grep -qF "below the checkpoint line" <<<"$descriptions" && return 1
  true
}

@test "each pinned answer label records its answer shape and tells the main thread what to do next" {
  local row disputed_pin
  # sanctioned copy of .claude/hooks/audit-loop-ask-grant.sh#grant_labels
  local grant_rows=(
    'Continue audit in this session'
    'Continue audit in a new session'
    'State the rule, then continue'
  )
  local rows=("${grant_rows[@]}" 'Accept the remainder' 'a grant label against a cap pin')
  seed_pinned
  keep_state
  for row in "${rows[@]}"; do
    echo "case: $row"
    restore_state
    case "$row" in
      'Continue audit in this session')
        send "$(continue_label)"
        [ "$status" -eq 0 ]
        [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
        jq -e --argjson unit_rounds "$UNIT_ROUNDS" --arg nonce "$NONCE" --arg option_label "$(continue_label)" \
          '.allowance.answers[0] | .checkpoint == 1 and .kind == "grant" and .n == $unit_rounds and .source == "ask" and .option == $option_label and .nonce == $nonce' "$ALF_STATE"
        printf '%s' "$output" | jq -e '(.systemMessage | length) > 0 and .hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length) > 0'
        [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = "$((5 + UNIT_ROUNDS))" ]
        ;;
      'Continue audit in a new session')
        # The pin recommends this option, so its stored label carries the suffix.
        [ "$(session_label)" = "Continue audit in a new session (Recommended)" ]
        send "$(session_label)"
        [ "$status" -eq 0 ]
        jq -e --argjson unit_rounds "$UNIT_ROUNDS" --arg option_label "Continue audit in a new session (Recommended)" \
          '.allowance.answers | length == 1 and .[0].kind == "grant" and .[0].n == $unit_rounds and .[0].source == "ask" and .[0].option == $option_label
           and (.[0] | keys | sort) == ["at","checkpoint","kind","n","nonce","option","session_id","source"]' "$ALF_STATE"
        printf '%s' "$output" | jq -e '(.systemMessage | startswith("Recorded: Continue audit in a new session on branch"))
          and (.hookSpecificOutput.additionalContext | contains("Run `/clear`, then paste the prompt below.") and contains("Press Ctrl+C, run `claude`") and contains("fenced continuation prompt") and contains("and stop"))'
        ;;
      'State the rule, then continue')
        disputed_pin="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" "$NONCE" 5 "$UNIT_ROUNDS" false false fallback "" grant "" \
          '[{"path":"a.ts","line":1,"severity":"major","reason":"needs a requirement: r","repeated":true}]')"
        alf_state_edit '.history.checkpoints[-1] += {trigger: "fallback", question: $question}' --argjson question "$disputed_pin"
        send "$(stored_label "State the rule, then continue")"
        [ "$status" -eq 0 ]
        jq -e --argjson unit_rounds "$UNIT_ROUNDS" '.allowance.answers[0] | .kind == "grant" and .n == $unit_rounds and .option == "State the rule, then continue (Recommended)"' "$ALF_STATE"
        printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("wait for the human to state the rule") and contains("never word the rule yourself") and contains("as for Stop and file the remainder")'
        ;;
      'Accept the remainder')
        pin_latest "$NONCE" 5 true false context
        send "Accept the remainder"
        [ "$status" -eq 0 ]
        jq -e '.allowance.answers | length == 1 and .[0].kind == "accept" and (.[0] | has("n") | not) and .[0].option == "Accept the remainder"' "$ALF_STATE"
        ;;
      *)
        fresh_fixture
        seed_cap
        send "$(continue_label)"
        [ "$status" -eq 0 ]
        [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
        jq -e --argjson unit_rounds "$UNIT_ROUNDS" '.allowance.answers[0] | .checkpoint == 1 and .kind == "grant" and .n == $unit_rounds and .source == "ask"' "$ALF_STATE"
        ;;
    esac
  done
}

@test "every recorded answer carries at and the payload's session id" {
  seed_pinned true
  SID=s1 send "Accept the remainder"
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers[0] | (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and .session_id == "s1" and .kind == "accept" and .source == "ask"' "$ALF_STATE"
}

@test "a selection the pin does not offer as a grant records nothing: a suffix mismatch, an accept the pin lacks, free text, an unpinned label, Stop and file the remainder, and Type audit-accept instead" {
  local row
  local rows=(
    'base label while the pin carries the suffixed one'
    'suffix on an option the pin does not recommend'
    'suffix on an option the pin lacks'
    'accept selected, not in the pin'
    'payload offers an accept option the pin lacks'
    'Other free text'
    'Other free text, built payload'
    'label not in the pin'
    'partial label'
    'Stop and file the remainder'
    'Type audit-accept instead against a cap-ineligible pin'
  )
  seed_pinned false
  snapshot
  for row in "${rows[@]}"; do
    echo "case: $row"
    case "$row" in
      'base label'*) send "Continue audit in a new session" ;;
      'suffix on an option the pin does not'*) send "Continue audit in this session (Recommended)" ;;
      'suffix on an option the pin lacks') send "Accept the remainder (Recommended)" ;;
      'accept selected'*) send "Accept the remainder" ;;
      'payload offers'*) PIN_USE="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" "$NONCE" 5 "$UNIT_ROUNDS" true false context)" send "Accept the remainder" ;;
      'Other free text') send_payload "$(mk_payload 1 "free text probe")" ;;
      'Other free text, built payload') send "free text probe" ;;
      'label not in the pin') send "Continue audit for 99 rounds" ;;
      'partial label') send "grant" ;;
      'Stop and file the remainder')
        send "Stop and file the remainder"
        [ "$status" -eq 0 ]
        unchanged
        printf '%s' "$output" | grep -qF 'file the remainder'
        printf '%s' "$output" | grep -qF 'leave the PR open'
        printf '%s' "$output" | grep -qF 'report'
        printf '%s' "$output" | jq -e '(.hookSpecificOutput.additionalContext | contains("Do not dispatch another audit round"))'
        continue
        ;;
      *)
        fresh_fixture
        seed_cap
        snapshot
        send "Type audit-accept instead"
        [ "$status" -eq 0 ]
        unchanged
        printf '%s' "$output" | grep -qF 'audit-accept'
        printf '%s' "$output" | grep -qF 'deliberate override'
        [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
        continue
        ;;
    esac
    declined "$row"
  done
}

# --- every red state ---------------------------------------------------------------

# bats test_tags=protected
@test "a payload failing one check records nothing: a stale or wrong nonce, any change to the question, a non-cli entrypoint or transcript, and a permission mode outside the allowlist" {
  local row old_pin
  local rows=(
    'wrong nonce'
    'changed question text'
    'changed header'
    'changed option description'
    'multiSelect true'
    'a second question'
    'an extra top-level key'
    'a dropped option'
    'sdk-cli entrypoint'
    'entrypoint unset'
    'sdk-cli transcript'
    'missing transcript'
    'missing transcript under sdk-cli'
    'dontAsk'
    'unmeasured mode'
    'permission_mode absent'
    'empty permission_mode'
    'stale nonce'
  )
  seed_pinned
  keep_state
  for row in "${rows[@]}"; do
    echo "case: $row"
    restore_state
    export CLAUDE_CODE_ENTRYPOINT=cli
    snapshot
    case "$row" in
      'wrong nonce') PIN_USE="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" fedcba9876543210 5 "$UNIT_ROUNDS" false false context)" send "$(continue_label)" ;;
      'changed question text') send "$(continue_label)" '.tool_input.questions[0].question += " (edited)"' ;;
      'changed header') send "$(continue_label)" '.tool_input.questions[0].header = "Edited"' ;;
      'changed option description') send "$(continue_label)" '.tool_input.questions[0].options[0].description += " edited"' ;;
      'multiSelect true') send "$(continue_label)" '.tool_input.questions[0].multiSelect = true' ;;
      'a second question') send "$(continue_label)" '.tool_input.questions += [.tool_input.questions[0]]' ;;
      'an extra top-level key') send "$(continue_label)" '.tool_input.extra = 1' ;;
      'a dropped option') send "$(continue_label)" '.tool_input.questions[0].options |= .[1:]' ;;
      'sdk-cli entrypoint') CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)" ;;
      'entrypoint unset')
        unset CLAUDE_CODE_ENTRYPOINT
        send "$(continue_label)"
        ;;
      'sdk-cli transcript') TX="$TX_SDK" send "$(continue_label)" ;;
      'missing transcript') TX="$BATS_TEST_TMPDIR/no-such.jsonl" send "$(continue_label)" ;;
      'missing transcript under sdk-cli') TX="$BATS_TEST_TMPDIR/no-such.jsonl" CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)" ;;
      'dontAsk') send "$(continue_label)" '.permission_mode = "dontAsk"' ;;
      'unmeasured mode') send "$(continue_label)" '.permission_mode = "somethingNew"' ;;
      'permission_mode absent') send "$(continue_label)" 'del(.permission_mode)' ;;
      'empty permission_mode') send "$(continue_label)" '.permission_mode = ""' ;;
      'stale nonce')
        old_pin="$(state_pin)"
        alf_add_checkpoint 5 context
        pin_latest fedcba9876543210 5 false false context
        snapshot
        PIN_USE="$old_pin" send "$(continue_label)"
        ;;
    esac
    declined "$row"
    case "$row" in
      'sdk-cli entrypoint' | 'missing transcript under sdk-cli') printf '%s' "$output" | grep -qF 'not interactive' ;;
      'sdk-cli transcript')
        printf '%s' "$output" | grep -qF "In a new Claude Code terminal session in the audited branch's checkout, send any message"
        printf '%s' "$output" | grep -qF -- '--continue or --resume'
        printf '%s' "$output" | grep -qF 'as the whole prompt instead' && return 1
        ;;
      'missing transcript') printf '%s' "$output" | grep -qF 'Send any other message first' ;;
      'stale nonce') [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ] ;;
    esac
  done
}

# bats test_tags=protected
@test "UAT-012: an agent_id on the payload records nothing" {
  seed_pinned
  snapshot
  send "$(continue_label)" '.agent_id = "agent-1"'
  declined "agent_id present"
  printf '%s' "$output" | grep -qF 'sub-agent'
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

# --- replay, scope, silence ----------------------------------------------------

@test "a replay records once and then declines visibly that nothing is pending, from a checkout with state and from one with none" {
  seed_pinned
  local payload_json
  payload_json="$(mk_payload 0 "$(continue_label)")"
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  snapshot
  send_payload "$payload_json"
  declined "replay with state"
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending'
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
  send_payload "$payload_json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'Nothing was recorded'
  printf '%s' "$output" | grep -qF 'audit-grant'
}

@test "a checkpoint is answered only by the session that hit it, from the state under protected/audit-loop: another session or two pending checkpoints decline, state only at the old directory records nothing" {
  local row PIN_USE old_state_directory="$ALF_ROOT/.gaia/local/audit-loop" second_state="$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json"
  local rows=(
    'state only at the old directory'
    'a main-checkout session answers the checkpoint its own session hit'
    'a different session id on the main checkout'
    'two pending checkpoints with the same session id'
  )
  seed_pinned
  keep_state
  for row in "${rows[@]}"; do
    echo "case: $row"
    restore_state
    PIN_USE=""
    case "$row" in
      'state only at the old directory')
        mkdir -p "$old_state_directory/feat"
        cp "$ALF_STATE" "$old_state_directory/feat/ask.json"
        cp "$ALF_STATE" "$BATS_TEST_TMPDIR/before.json"
        PIN_USE="$(state_pin)"
        rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop"
        send "$(continue_label)"
        [ "$status" -eq 0 ]
        printf '%s' "$output" | grep -qF 'Nothing was recorded'
        send "$(continue_label)" "$UNRELATED"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        cmp -s "$BATS_TEST_TMPDIR/before.json" "$old_state_directory/feat/ask.json"
        mkdir -p "$ALF_ROOT/.gaia/local/protected/audit-loop/feat"
        cp "$BATS_TEST_TMPDIR/before.json" "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json"
        send "$(continue_label)"
        [ "$status" -eq 0 ]
        [ "$(jq '.allowance.answers | length' "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/ask.json")" -eq 1 ]
        rm -rf "$old_state_directory"
        alf_git checkout -q main
        ;;
      'a main-checkout session'*)
        send "$(continue_label)"
        [ "$status" -eq 0 ]
        [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
        ;;
      'a different session id'*)
        snapshot
        SID=other-session send "$(continue_label)"
        declined "other session, shaped"
        SID=other-session send "$(continue_label)" "$UNRELATED"
        [ "$status" -eq 0 ]
        unchanged
        [ -z "$output" ]
        ;;
      *)
        jq '.key = "branch:feat/second" | .branch = "feat/second"' "$ALF_STATE" >"$second_state"
        snapshot
        cp "$second_state" "$BATS_TEST_TMPDIR/second-before.json"
        send "$(continue_label)"
        declined "ambiguous"
        cmp -s "$BATS_TEST_TMPDIR/second-before.json" "$second_state"
        rm -f "$second_state"
        ;;
    esac
  done
}

@test "an unrelated or lookalike question is silent whatever the session, mode or pending state, and a shaped one with no audit state declines visibly" {
  local row PIN_USE
  local rows=(
    'a tool that is not AskUserQuestion'
    'unrelated, pending'
    'unrelated, sub-agent'
    'unrelated, non-interactive'
    'unrelated, unlisted mode'
    'a header that merely contains the pinned header'
    'a label that contains a pinned label'
    'unrelated, nothing pending, sub-agent'
    'unrelated, nothing pending, unlisted mode'
    'unrelated, no audit state'
    'shaped, no audit state'
  )
  seed_pinned
  keep_state
  PIN_USE="$(state_pin)"
  for row in "${rows[@]}"; do
    echo "case: $row"
    restore_state
    case "$row" in
      *'nothing pending'*) alf_state_edit '.history.checkpoints = [] | .allowance.answers = []' ;;
      *'no audit state') rm -rf "$ALF_ROOT/.gaia/local/protected/audit-loop" ;;
    esac
    [ -f "$ALF_STATE" ] && snapshot
    case "$row" in
      'a tool that is not AskUserQuestion') send "$(continue_label)" '.tool_name = "Bash"' ;;
      'unrelated, pending' | 'unrelated, no audit state') send "$(continue_label)" "$UNRELATED" ;;
      *'sub-agent') send "$(continue_label)" "$UNRELATED | .agent_id = \"agent-1\"" ;;
      'unrelated, non-interactive') CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)" "$UNRELATED" ;;
      *'unlisted mode') send "$(continue_label)" "$UNRELATED | .permission_mode = \"dontAsk\"" ;;
      'a header'*) send "$(continue_label)" "$UNRELATED | .tool_input.questions[0].header = \"Audit loop status\"" ;;
      'a label'*) send "$(continue_label)" "$UNRELATED | .tool_input.questions[0].options[0].label = \"Continue audit in this session now\"" ;;
      'shaped, no audit state') send "$(continue_label)" ;;
    esac
    case "$row" in
      'unrelated, no audit state')
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        ;;
      'shaped, no audit state')
        [ "$status" -eq 0 ]
        printf '%s' "$output" | grep -qF 'Nothing was recorded'
        printf '%s' "$output" | grep -qF 'audit-grant'
        claude_told_nothing_recorded "$row"
        ;;
      *) silent "$row" ;;
    esac
  done
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

@test "every decline tells Claude nothing was recorded, and a missing pin, a failed read, a held lock and corrupt state each say why" {
  local row original_hook="$HOOK" lone_hook="$BATS_TEST_TMPDIR/lone/.claude/hooks/audit-loop-ask-grant.sh" PIN_USE
  local rows=(
    'no pinned question'
    'libraries missing'
    'read failed before the lock'
    'read failed under the lock'
    'write failed'
    'held lock'
    'corrupt, shaped'
    'corrupt, unrelated'
  )
  seed_rounds 5
  alf_add_checkpoint 5 allowance
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/unpinned.json"
  alf_state_edit '.history.checkpoints = []'
  alf_add_checkpoint 5 context
  pin_latest "$NONCE" 5 false false context
  keep_state
  PIN_USE="$(state_pin)"
  mkdir -p "$(dirname "$lone_hook")"
  cp "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" "$lone_hook"
  for row in "${rows[@]}"; do
    echo "case: $row"
    HOOK="$original_hook"
    rm -rf "$BATS_TEST_TMPDIR/scratch"
    restore_state
    case "$row" in
      'no pinned question') cp "$BATS_TEST_TMPDIR/unpinned.json" "$ALF_STATE" ;;
      corrupt*) printf '{ not json' >"$ALF_STATE" ;;
      'read failed before the lock') scratch_hook 's/^state="\$(gaia_loop_read_state "\$target" 2>\/dev\/null)" || _ag_decline/false || _ag_decline/' ;;
      'read failed under the lock') scratch_hook 's/^state="\$(gaia_loop_read_state "\$target" 2>\/dev\/null)"$/false/' ;;
      'write failed') scratch_hook 's/! gaia_loop_write_state "\$target" "\$new"/true/' ;;
      'libraries missing') HOOK="$lone_hook" ;;
    esac
    snapshot
    case "$row" in
      'held lock')
        mkdir "$ALF_STATE.lock"
        send "$(continue_label)"
        rmdir "$ALF_STATE.lock"
        ;;
      'corrupt, unrelated') send "$(continue_label)" "$UNRELATED" ;;
      *) send "$(continue_label)" ;;
    esac
    declined "$row"
    case "$row" in
      'no pinned question') printf '%s' "$output" | grep -qF 'no pinned question' ;;
      'read failed'*) printf '%s' "$output" | grep -qF 'could not be read' ;;
      'held lock') printf '%s' "$output" | grep -qF 'locked' ;;
      'corrupt, shaped') printf '%s' "$output" | grep -qF 'corrupt' ;;
    esac
  done
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

@test "a changed header and question text still decline visibly when an option label is pinned" {
  seed_pinned
  snapshot
  send "$(continue_label)" '.tool_input.questions[0].header = "Edited" | .tool_input.questions[0].question += " (edited)"'
  declined "altered copy with a checkpoint pending"
}

# --- the hook itself -----------------------------------------------------------

@test "the hook parses under stock bash and never exits 2" {
  /bin/bash -n "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh"
  grep -nE '^[[:space:]]*exit 2' "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  true
}
