#!/usr/bin/env bats
#
# Suite for .claude/hooks/autonomy-gate.sh: under a live autonomy switch every
# AskUserQuestion is denied with the option to take or the park command, each
# taken option lands in the main checkout's decision log, and a write into the
# protected set is denied; with the switch off the hook stays silent.
#
# AUTONOMY_GATE_HOOK points the suite at another copy of the hook (its
# libraries reached through `.gaia` and `.claude/hooks/lib` beside it).
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/autonomy-gate.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs and `bash -c` bodies are single-quoted so their `$` reaches
# the inner interpreter.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${AUTONOMY_GATE_HOOK:-$REPO_ROOT/.claude/hooks/autonomy-gate.sh}"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/autonomy-lib.sh"
  alf_init
  alf_branch feat/gate
  MAIN="$ALF_ROOT"
  WORKTREE="$MAIN/.claude/worktrees/wt"
  git -C "$MAIN" worktree add -q "$WORKTREE" -b wt
  mkdir -p "$MAIN/.gaia/local/protected" "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  SWITCH="$MAIN/.gaia/local/protected/autonomy.json"
  LOG="$MAIN/.gaia/local/protected/autonomy-log.jsonl"
}

switch_on() { jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: false}' >"$SWITCH"; }

# ask <questions-json> [cwd]: run the hook on an AskUserQuestion call.
ask() {
  local payload
  payload=$(jq -nc --argjson questions "$1" --arg cwd "${2:-$MAIN}" \
    '{session_id: "s1", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", tool_input: {questions: $questions}}')
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK"
}

# call <tool> <tool_input-json> [cwd] [hook]: run a hook on any PreToolUse call.
call() {
  local payload
  payload=$(jq -nc --arg tool "$1" --argjson input "$2" --arg cwd "${3:-$MAIN}" \
    '{session_id: "s1", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: $tool, tool_input: $input}')
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "${4:-$HOOK}"
}

# question <header> <label>...: one single-select question with these options.
question() {
  local header="$1"
  shift
  jq -nc --arg header "$header" '[{question: "Which way?", header: $header, multiSelect: false,
    options: [$ARGS.positional[] | {label: ., description: "d"}]}]' --args "$@"
}

reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"; }
denied() {
  [ "$status" -eq 0 ] || return 1
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ]
}
silent() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

ORDINARY_TOOLS='Edit Write MultiEdit'

@test "switch off or expired: no question and no protected write is denied" {
  local tool
  for state in absent expired; do
    echo "case: switch $state"
    [ "$state" = absent ] || jq -n '{enabled: true, expires_at: (now - 1 | todate), may_merge: false}' >"$SWITCH"
    ask "$(question Pick 'A (Recommended)' B)"
    silent
    ask "$(question Pick A B)"
    silent
    for tool in $ORDINARY_TOOLS; do
      call "$tool" "{\"file_path\":\"$MAIN/.claude/hooks/x.sh\"}"
      silent
    done
    call NotebookEdit "{\"notebook_path\":\"$MAIN/CLAUDE.md\"}"
    silent
    call Bash "{\"command\":\"printf x > $MAIN/.claude/hooks/x.sh\"}"
    silent
  done
  [ ! -e "$LOG" ]
}

@test "ordinary question: the denial names the label to take and one log entry lands in the main checkout" {
  switch_on
  ask "$(question Pick 'Keep it (Recommended)' Drop)"
  denied
  [[ "$(reason)" == *"Take 'Keep it (Recommended)' for 'Pick'"* ]]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  jq -e '(keys == ["branch","header","option","session_id","time"]) and .session_id == "s1" and .branch == "feat/gate"
    and .header == "Pick" and .option == "Keep it (Recommended)" and (.time | test("^[0-9-]{10}T[0-9:]{8}Z$"))' "$LOG"

  echo "case: from the linked worktree, the entry lands in the main checkout's log"
  ask "$(question Other 'Yes (Recommended)' No)" "$WORKTREE"
  denied
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.branch + " " + .option')" = "wt Yes (Recommended)" ]
  [ ! -e "$WORKTREE/.gaia/local/protected/autonomy-log.jsonl" ] || [ "$WORKTREE/.gaia/local/protected/autonomy-log.jsonl" -ef "$LOG" ]
}

@test "listed header, zero and two Recommended options park with the question reason and log nothing" {
  local listed
  switch_on
  listed=$(jq -r '.headers[0]' "$REPO_ROOT/.gaia/autonomy-human-only-headers.json")
  [ -n "$listed" ]
  echo "case: listed header"
  ask "$(question "$listed" 'A (Recommended)' B)"
  denied
  [[ "$(reason)" == *"human-only list"*"autonomy-park.sh --reason question"* ]]
  echo "case: no Recommended"
  ask "$(question Pick A B)"
  denied
  [[ "$(reason)" == *"exactly one option (Recommended)"*"autonomy-park.sh --reason question"* ]]
  echo "case: two Recommended"
  ask "$(question Pick 'A (Recommended)' 'B (Recommended)')"
  denied
  [[ "$(reason)" == *"exactly one option (Recommended)"*"autonomy-park.sh --reason question"* ]]
  [ ! -e "$LOG" ]
}

# bats test_tags=protected
@test "the pinned checkpoint question parks with audit-checkpoint, records no grant and logs nothing" {
  local pinned_question round_number before
  switch_on
  alf_fill f.txt 5 x
  for round_number in 1 2 3 4 5; do
    alf_set_line other.txt "$round_number" "round $round_number"
    alf_commit "round $round_number"
    alf_add_round '["code-audit-frontend"]'
  done
  alf_add_checkpoint 5 context
  pinned_question="$(gaia_loop_pinned_question "$ALF_NORMALIZED_BRANCH" 0123456789abcdef 5 "$GAIA_CONTEXT_UNIT_ROUNDS" false false context)"
  alf_state_edit '.history.checkpoints[-1] += {nonce: "0123456789abcdef", trigger: "context", accept_eligible: false, question: $question} | .pr = 41' \
    --argjson question "$pinned_question"
  # The pinned question's own options carry one (Recommended), so only the
  # pin comparison parks it.
  [ "$(jq '[.questions[0].options[].label | select(endswith(" (Recommended)"))] | length' <<<"$pinned_question")" -eq 1 ]
  before=$(cat "$ALF_STATE")
  call AskUserQuestion "$pinned_question"
  denied
  [[ "$(reason)" == *"pinned audit checkpoint question"*"autonomy-park.sh --reason audit-checkpoint --pr 41"* ]]
  [ "$(cat "$ALF_STATE")" = "$before" ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
  [ ! -e "$LOG" ]
}

# bats test_tags=protected
@test "under autonomy every write tool and a Bash write into the protected set is denied, naming the park command and the path" {
  local tool
  switch_on
  for tool in $ORDINARY_TOOLS; do
    echo "case: $tool"
    call "$tool" "{\"file_path\":\"$MAIN/.claude/hooks/x.sh\"}"
    denied
    [[ "$(reason)" == *".claude/hooks/x.sh governs the harness"*"autonomy-park.sh --reason question"* ]]
  done
  echo "case: NotebookEdit"
  call NotebookEdit "{\"notebook_path\":\"$MAIN/apps/web/CLAUDE.md\"}"
  denied
  [[ "$(reason)" == *"apps/web/CLAUDE.md governs the harness"*"autonomy-park.sh --reason question"* ]]
  for command in "printf x > .claude/rules/r.md" "printf x >| .claude/hooks/h.sh" "rm -f .claude/agents/a.md" "sed -i '' s/a/b/ CLAUDE.md" "echo x | sponge apps/web/.claude/settings.overlay.json"; do
    echo "case: Bash $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')"
    denied
    [[ "$(reason)" == *"autonomy-park.sh --reason question"* ]]
  done
  echo "case: Monitor"
  call Monitor '{"command":"tee .claude/settings.local.json"}'
  denied
}

@test "a linked-worktree spelling of a protected path is denied, from either checkout" {
  switch_on
  call Edit "{\"file_path\":\"$WORKTREE/.claude/skills/s/SKILL.md\"}"
  denied
  [[ "$(reason)" == *".claude/skills/s/SKILL.md governs the harness"* ]]
  call Write "{\"file_path\":\"$WORKTREE/.claude/commands/c.md\"}" "$WORKTREE"
  denied
  call Bash '{"command":"printf x > .claude/hooks/h.sh"}' "$WORKTREE"
  denied
  echo "case: a linked worktree outside the main checkout"
  local outside="$BATS_TEST_TMPDIR/outside"
  git -C "$MAIN" worktree add -q "$outside" -b outside
  outside=$(cd "$outside" && pwd -P)
  mkdir -p "$outside/.gaia"
  ln -s "$MAIN/.gaia/local" "$outside/.gaia/local"
  call Edit "{\"file_path\":\"$outside/.claude/rules/r.md\"}" "$outside"
  denied
  [[ "$(reason)" == *" .claude/rules/r.md governs the harness"* ]]
  echo "case: that outside worktree's copy, from a session in the main checkout"
  call Write "{\"file_path\":\"$outside/.claude/agents/a.md\"}" "$MAIN"
  denied
  [[ "$(reason)" == *" .claude/agents/a.md governs the harness"* ]]
}

@test "under autonomy, reads and writes outside the protected set pass" {
  switch_on
  call Edit "{\"file_path\":\"$MAIN/src/CLAUDE.md\"}"
  silent
  call Write "{\"file_path\":\"$MAIN/.claude/doctrine-notes.md\"}"
  silent
  call Bash '{"command":"cat .claude/hooks/x.sh > /dev/null; git add .claude/hooks/x.sh; bash -n .claude/hooks/x.sh"}'
  silent
  call Bash '{"command":"printf x > notes.txt"}'
  silent
}

@test "Claude's Edit, Write and Bash writes to the decision log are denied by the protected-folder guard" {
  local guard="$REPO_ROOT/.claude/hooks/block-audit-loop-write.sh"
  for tool in Edit Write; do
    call "$tool" "{\"file_path\":\"$LOG\"}" "$MAIN" "$guard"
    denied
    call "$tool" "{\"file_path\":\"$WORKTREE/.gaia/local/protected/autonomy-log.jsonl\"}" "$WORKTREE" "$guard"
    denied
  done
  call Bash "{\"command\":\"printf x >> $LOG\"}" "$MAIN" "$guard"
  denied
}

# bats test_tags=protected,whole-tree
@test "the protected set matches the self-governing paths and none of the ordinary paths beside them" {
  local globs path
  globs=$(autonomy_protected_globs "$REPO_ROOT")
  [ -n "$globs" ]
  for path in .claude/settings.json apps/web/.claude/settings.json .claude/settings.local.json \
    apps/web/.claude/settings.overlay.json .claude/hooks/x.sh .claude/hooks/lib/y.sh \
    .claude/rules/r.md apps/web/.claude/rules/r.md .claude/agents/a.md .claude/skills/s/SKILL.md \
    .claude/commands/c.md apps/web/.claude/agents/a.md apps/web/.claude/skills/s/SKILL.md \
    apps/web/.claude/commands/c.md .gaia/local/protected/autonomy.json CLAUDE.md apps/web/CLAUDE.md; do
    autonomy_protected_match "$path" "$globs" || { echo "unmatched: $path"; return 1; }
  done
  for path in src/CLAUDE.md .claude/settings.jsonx .claude/doctrine/x.md .gaia/local/runs/x apps/web/src/a.ts README.md; do
    ! autonomy_protected_match "$path" "$globs" || { echo "matched: $path"; return 1; }
  done
}
