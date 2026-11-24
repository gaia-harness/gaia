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
blocked() { [ "$status" -eq 2 ] && [[ "$output" == *"BLOCKED: autonomy-gate.sh cannot load autonomy-lib.sh"* ]]; }

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

@test "a recommended merge parks while may_merge is false and is taken once it is true" {
  switch_on
  echo "case: may_merge false"
  ask "$(question 'Merge it' 'Merge it (Recommended)' 'Hold the merge')"
  denied
  [[ "$(reason)" == *"may_merge false"*"autonomy-park.sh --reason question"* ]]
  [ ! -e "$LOG" ]
  echo "case: an uppercase MERGE label parks too"
  ask "$(question 'Merge it' 'MERGE NOW (Recommended)' 'Hold the merge')"
  denied
  [[ "$(reason)" == *"may_merge false"*"autonomy-park.sh --reason question"* ]]
  [ ! -e "$LOG" ]
  echo "case: may_merge true"
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: true}' >"$SWITCH"
  ask "$(question 'Merge it' 'Merge it (Recommended)' 'Hold the merge')"
  denied
  [[ "$(reason)" == *"Take 'Merge it (Recommended)'"* ]]
}

# bats test_tags=protected
@test "may_merge false or absent: a recommended merge is never taken and no decision is logged" {
  echo "case: may_merge false parks"
  switch_on
  ask "$(question 'Merge it' 'Merge it (Recommended)' 'Hold the merge')"
  denied
  [[ "$(reason)" == *"autonomy-park.sh --reason question"* ]] || return 1
  [[ "$(reason)" == *"Take 'Merge it"* ]] && return 1
  [ ! -e "$LOG" ] || return 1
  echo "case: may_merge absent is never a take"
  jq -n '{enabled: true, expires_at: (now + 3600 | todate)}' >"$SWITCH"
  ask "$(question 'Merge it' 'Merge it (Recommended)' 'Hold the merge')"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Take 'Merge it"* ]] && return 1
  [ ! -e "$LOG" ] || return 1
  true
}

@test "with jq missing, a bare AskUserQuestion is allowed and a guarded spelling is refused" {
  local bin payload tool
  bin="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$bin"
  for tool in bash cat dirname tr sed grep; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  payload='{"session_id":"s1","cwd":"/x","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q","header":"h","options":[]}]}}'
  run env PATH="$bin" bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  payload='{"session_id":"s1","cwd":"/x","tool_name":"Write","tool_input":{"file_path":"/x/.claude/settings.json"}}'
  run env PATH="$bin" bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK"
  [ "$status" -eq 2 ]
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
    apps/web/.claude/commands/c.md .gaia/local/protected/autonomy.json CLAUDE.md apps/web/CLAUDE.md \
    .gaia/autonomy-protected-paths.json .gaia/autonomy-human-only-headers.json .gaia/scripts/autonomy-lib.sh \
    .gaia/scripts/autonomy-park.sh .gaia/scripts/main-root-lib.sh .gaia/scripts/audit-loop-state-lib.sh \
    CLAUDE.local.md apps/web/CLAUDE.local.md apps/web/.claude/settings.local.json; do
    autonomy_protected_match "$path" "$globs" || { echo "unmatched: $path"; return 1; }
  done
  for path in src/CLAUDE.md .claude/settings.jsonx .claude/doctrine/x.md .gaia/local/runs/x apps/web/src/a.ts README.md .gaia/scripts/other.sh; do
    ! autonomy_protected_match "$path" "$globs" || { echo "matched: $path"; return 1; }
  done
}

# conflicted_lane: a copy of the hook's tree in which a lane worktree merges a
# branch that rewrote the same autonomy-lib.sh header line the lane did, so the
# library holds conflict markers ahead of every function. Sets TREE, LANE and
# HOOK (the lane's own copy).
conflicted_lane() {
  local conflicted="${1:-.gaia/scripts/autonomy-lib.sh}"
  local other="$BATS_TEST_TMPDIR/other"
  TREE="$BATS_TEST_TMPDIR/conflicted"
  LANE="$TREE/.claude/worktrees/lane"
  mkdir -p "$TREE/.claude/hooks" "$TREE/.gaia"
  cp "$REPO_ROOT/.claude/hooks/autonomy-gate.sh" "$TREE/.claude/hooks/"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$TREE/.claude/hooks/lib"
  cp -R "$REPO_ROOT/.gaia/scripts" "$TREE/.gaia/scripts"
  git -C "$TREE" init -q -b main
  git -C "$TREE" config user.email t@example.com
  git -C "$TREE" config user.name t
  printf '.claude/worktrees/\n' >"$TREE/.gitignore"
  git -C "$TREE" add -A
  git -C "$TREE" commit -q -m base
  git -C "$TREE" worktree add -q "$LANE" -b lane
  git -C "$TREE" worktree add -q "$other" -b other main
  sed -i.bak '2s/.*/# lane header/' "$LANE/$conflicted"
  sed -i.bak '2s/.*/# other header/' "$other/$conflicted"
  rm -f "$LANE/$conflicted.bak" "$other/$conflicted.bak"
  git -C "$LANE" commit -q -am lane
  git -C "$other" commit -q -am other
  git -C "$LANE" merge -q other >/dev/null 2>&1 || true
  [ -f "$(git -C "$LANE" rev-parse --git-path MERGE_HEAD)" ]
  [ "$(git -C "$LANE" ls-files -u | wc -l)" -gt 0 ]
  HOOK="$LANE/.claude/hooks/autonomy-gate.sh"
}

# library_conflicted_lane <path>: conflicted_lane for another library the hook
# sources, with the autonomy switch live so the gate does not stand down.
library_conflicted_lane() {
  conflicted_lane "$1"
  mkdir -p "$TREE/.gaia/local/protected"
  jq -n '{enabled: true, expires_at: (now + 3600 | todate), may_merge: false}' >"$TREE/.gaia/local/protected/autonomy.json"
}

# repair_allowed <library>: the abort and the side pick of one conflicted
# library pass silently in the git -C <lane> form and from inside the lane.
repair_allowed() {
  local library="$1" command
  for command in \
    "git -C $LANE merge --abort" \
    "git -C $LANE checkout --ours -- $library" \
    "git -C $LANE checkout --theirs -- $library" \
    "git -C $LANE restore --theirs -- $library" \
    "git -C $LANE restore -- $library"; do
    echo "case allowed (git -C): $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    silent
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$BATS_TEST_TMPDIR" "$HOOK"
    silent
  done
  for command in "git merge --abort" "git checkout --theirs -- $library" "git restore -- $library"; do
    echo "case allowed (cwd-relative): $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    silent
  done
}

# library_blocked <file name>: the hook refused because that library cannot load.
library_blocked() {
  [ "$status" -eq 2 ] && [[ "$output" == *"BLOCKED: autonomy-gate.sh cannot load $1"* ]]
}

# not_repair_commands <library>: calls that look like a repair and are not one.
not_repair_commands() {
  printf '%s\n' \
    "git -C $LANE checkout --theirs -- .gaia/scripts/other.sh" \
    "git -C $LANE checkout --theirs -- $1 .claude/hooks/x.sh" \
    "git -C $LANE merge --abort; rm -rf $LANE/.claude/hooks" \
    "git -C $LANE merge --abort && printf x > $LANE/.claude/hooks/x.sh" \
    "git -C $LANE rebase --abort" \
    "git -C $LANE merge --continue" \
    "git -C $LANE reset --hard" \
    "ls $LANE/.claude"
}

@test "an unloadable autonomy library mid-merge allows only the narrow repair commands and names them" {
  local library='.gaia/scripts/autonomy-lib.sh' command tool
  conflicted_lane
  for command in \
    "git -C $LANE merge --abort" \
    "git -C $LANE checkout --ours -- $library" \
    "git -C $LANE checkout --theirs -- $library" \
    "git -C $LANE restore --theirs -- $library" \
    "git -C $LANE restore -- $library"; do
    echo "case allowed: $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    silent
  done
  for command in \
    "git -C $LANE checkout --theirs -- .gaia/scripts/other.sh" \
    "git -C $LANE checkout --theirs -- $library .claude/hooks/x.sh" \
    "git -C $LANE merge --abort; rm -rf $LANE/.claude/hooks" \
    "git -C $LANE merge --abort && printf x > $LANE/.claude/hooks/x.sh" \
    "git -C $LANE merge --continue" \
    "git -C $LANE reset --hard" \
    "ls $LANE/.claude"; do
    echo "case denied: $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    blocked
    [[ "$output" == *"git merge --abort"*"git checkout --ours|--theirs -- .gaia/scripts/autonomy-lib.sh"* ]]
  done
  for tool in Write Edit; do
    echo "case denied: $tool"
    call "$tool" "{\"file_path\":\"$LANE/README.md\"}" "$LANE" "$HOOK"
    blocked
    call "$tool" "{\"file_path\":\"$LANE/$library\"}" "$LANE" "$HOOK"
    blocked
  done
}

@test "an unloadable autonomy library with no merge in progress allows no repair and names none" {
  conflicted_lane
  git -C "$LANE" merge --abort
  printf '<<<<<<< x\n' | cat - "$LANE/.gaia/scripts/autonomy-lib.sh" >"$BATS_TEST_TMPDIR/broken"
  cp "$BATS_TEST_TMPDIR/broken" "$LANE/.gaia/scripts/autonomy-lib.sh"
  call Bash "$(jq -nc --arg command "git -C $LANE merge --abort" '{command: $command}')" "$LANE" "$HOOK"
  blocked
  [[ "$output" != *"A merge is in progress"* ]]
}

@test "a conflict hunk late in the autonomy library blocks the call instead of half-loading it" {
  conflicted_lane
  git -C "$LANE" merge --abort
  local library="$LANE/.gaia/scripts/autonomy-lib.sh"
  awk '/^autonomy_protected_match\(\) \{/ { print "<<<<<<< x" } { print }' "$library" >"$BATS_TEST_TMPDIR/late"
  cp "$BATS_TEST_TMPDIR/late" "$library"
  bash -c '. "$1" 2>/dev/null; type autonomy_active' _ "$library" >/dev/null 2>&1
  call Write "{\"file_path\":\"$LANE/.claude/settings.json\"}" "$LANE" "$HOOK"
  blocked
}

@test "a rebase conflict in the autonomy library allows only its abort and the side pick, and warns about the dropped side" {
  local library='.gaia/scripts/autonomy-lib.sh'
  conflicted_lane
  git -C "$LANE" merge --abort
  git -C "$LANE" rebase other >/dev/null 2>&1 || true
  [ -f "$(git -C "$LANE" rev-parse --git-path REBASE_HEAD)" ]
  call Bash "$(jq -nc --arg command "git -C $LANE rebase --abort" '{command: $command}')" "$LANE" "$HOOK"
  silent
  call Bash "$(jq -nc --arg command "git -C $LANE merge --abort" '{command: $command}')" "$LANE" "$HOOK"
  blocked
  [[ "$output" == *"A rebase is in progress"*"git rebase --abort"*"drops the other side's changes"* ]]
  call Bash "$(jq -nc --arg command "git -C $LANE checkout --ours -- $library" '{command: $command}')" "$LANE" "$HOOK"
  silent
}

@test "a merge conflict in a hooks/lib library allows only its repair, in both spellings, and refuses everything else" {
  local library='.claude/hooks/lib/hook-payload.sh' command tool
  library_conflicted_lane "$library"
  repair_allowed "$library"
  while IFS= read -r command; do
    echo "case denied: $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    library_blocked hook-payload.sh
  done < <(
    not_repair_commands "$library"
    printf '%s\n' "git -C $LANE checkout --theirs -- .claude/hooks/lib/jq-availability.sh"
  )
  for tool in Write Edit; do
    echo "case denied: $tool"
    call "$tool" "{\"file_path\":\"$LANE/README.md\"}" "$LANE" "$HOOK"
    library_blocked hook-payload.sh
  done
}

@test "a rebase conflict in a hooks/lib library allows its abort and refuses a merge abort" {
  local library='.claude/hooks/lib/hook-payload.sh'
  library_conflicted_lane "$library"
  git -C "$LANE" merge --abort
  git -C "$LANE" rebase other >/dev/null 2>&1 || true
  [ -f "$(git -C "$LANE" rev-parse --git-path REBASE_HEAD)" ]
  call Bash "$(jq -nc --arg command "git -C $LANE rebase --abort" '{command: $command}')" "$LANE" "$HOOK"
  silent
  call Bash "$(jq -nc --arg command "git -C $LANE merge --abort" '{command: $command}')" "$LANE" "$HOOK"
  library_blocked hook-payload.sh
}

@test "a hooks/lib conflict with no operation in progress allows no repair" {
  library_conflicted_lane .claude/hooks/lib/hook-payload.sh
  git -C "$LANE" merge --abort
  printf '<<<<<<< x\n' | cat - "$LANE/.claude/hooks/lib/hook-payload.sh" >"$BATS_TEST_TMPDIR/broken"
  cp "$BATS_TEST_TMPDIR/broken" "$LANE/.claude/hooks/lib/hook-payload.sh"
  call Bash "$(jq -nc --arg command "git -C $LANE merge --abort" '{command: $command}')" "$LANE" "$HOOK"
  library_blocked hook-payload.sh
}

@test "a merge conflict in the audit-loop state library allows its repair and keeps the protected-write denials" {
  local library='.gaia/scripts/audit-loop-state-lib.sh' command
  library_conflicted_lane "$library"
  mkdir -p "$TREE/.gaia/local/protected/audit-loop"
  repair_allowed "$library"
  echo "case: a question reaches the unloadable state library"
  ask "$(question 'Pick' 'Take (Recommended)' 'Leave')" "$LANE"
  library_blocked audit-loop-state-lib.sh
  for command in \
    "git -C $LANE merge --abort; rm -rf $LANE/.claude/hooks" \
    "git -C $LANE merge --abort && printf x > $LANE/.claude/hooks/x.sh"; do
    echo "case denied: $command"
    call Bash "$(jq -nc --arg command "$command" '{command: $command}')" "$LANE" "$HOOK"
    denied
  done
  call Write "{\"file_path\":\"$LANE/.claude/settings.json\"}" "$LANE" "$HOOK"
  denied
}

# bats test_tags=whole-tree
@test "every library the gate sources before it reads the payload is in the repair set, or has its own arm" {
  local hook="$REPO_ROOT/.claude/hooks/autonomy-gate.sh" listed sourced name path
  listed=$(awk "/^_gate_conflict_libraries='/{on=1; next} on && /^'/{exit} on{print}" "$hook")
  [ -n "$listed" ]
  sourced=$(sed -n -E 's/^[[:space:]]*load "\$_gate_(directory|scripts)\/([^"]+)" .*/\1 \2/p' "$hook")
  [ -n "$sourced" ]
  while read -r name path; do
    case "$name" in directory) path=".claude/hooks/$path" ;; *) path=".gaia/scripts/$path" ;; esac
    echo "sourced: $path"
    [ "$path" = .gaia/scripts/autonomy-lib.sh ] && continue
    printf '%s\n' "$listed" | grep -qxF -- "$path" || return 1
  done <<<"$sourced"
}
