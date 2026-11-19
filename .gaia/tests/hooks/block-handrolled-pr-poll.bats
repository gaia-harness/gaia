#!/usr/bin/env bats

# Tests for .claude/hooks/block-handrolled-pr-poll.sh.
#
# The hook denies a shell loop polling `gh pr view` for PR state, or
# `gh pr checks`, when the command never reads `mergeable`. Such a loop cannot
# end once the base branch has landed a conflicting change: the queued `--auto`
# merge never lands and nothing left in the loop can fire. Exit 2 = block
# (stderr shown to Claude); exit 0 = allow.
#
# The hook is a pure stdin->pattern->exit filter beyond the shared
# jq-availability arm, so each test pipes a synthetic PreToolUse payload and
# asserts on the exit code, and on the denial's own text where the message
# carries the claim.
#
# THE ALLOW CASES ARE THE LOAD-BEARING HALF HERE. This is a text heuristic over
# an unbounded surface, so its real risk is denying a legitimate command, and a
# deny-only suite would say nothing about that. The false positives pinned
# below are the specific ones the matcher was narrowed to avoid: prose
# mentioning a poll inside a `--body`, a loop enumerating pull requests by a
# field other than state, an ordinary one-shot state read, and any loop that
# already satisfies the rule by reading `mergeable`.
#
# The multi-line fixtures are not decoration. A matcher built from `^` and the
# separator punctuation alone reads a loop keyword after a newline as prose, and
# a multi-line command is the ordinary shape for a poll, so that gap would leave
# the guard inert on most real instances of exactly what it denies.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK="$HOOKS_SOURCE_DIRECTORY/block-handrolled-pr-poll.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
}

# Pipe a Bash PreToolUse payload for $1 to the hook and capture status/output.
run_hook() {
  local command_line="$1" payload
  payload=$(jq -nc --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$payload" "$HOOK"
}

# The same, for a Monitor payload. Monitor carries its shell command in the
# same `tool_input.command` field, so the two differ only in `tool_name`.
run_hook_monitor() {
  local command_line="$1" payload
  payload=$(jq -nc --arg command "$command_line" '{tool_name: "Monitor", tool_input: {command: $command}}')
  invoke_hook "$payload" "$HOOK"
}

# --- blocked: the shape that spins forever ------------------------------------

# bats test_tags=protected
@test "the observed recurrence is blocked" {
  # Verbatim from a live recurrence: the loop substituted after the
  # worktree-isolation guard refused the documented compound form. It waits
  # only for the state to leave OPEN, so a CONFLICTING base never ends it.
  run_hook 'until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  assert_blocked_by_exit
}

@test "the denial names the shipped script, so there is an alternative to take" {
  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  grep -qF -- '.gaia/scripts/pr-wait-merge.sh' <<<"$output"
}

# The arithmetic spellings close the keyword on `(` rather than on whitespace.
# A multi-line poll is the ordinary shape, so the keyword after a newline has
# to read as a loop, not prose. `then` opens a command position no punctuation
# precedes; `done` closes on a substitution's `)` in one row. Monitor takes a
# raw shell command in the same field Bash does, so binding only Bash would
# leave the guard inert in the tool beside the one it watches.
@test "a hand-rolled poll loop is blocked in every shape" {
  local row
  local bash_rows=(
    'while ! gh pr checks 42 --required; do sleep 20; done'
    'for i in 1 2 3; do s=$(gh pr view 9 --json state -q .state); [ "$s" = MERGED ] && break; sleep 10; done'
    'for((i=0;i<20;i++)); do gh pr view 42 --json state --jq .state; sleep 30; done'
    'while((n<20)); do gh pr view 42 --json state --jq .state; sleep 30; done'
    'for((i=0;i<20;i++)); do gh pr checks 42 --required; sleep 30; done'
    $'gh pr merge 42 --auto\nfor i in 1 2 3; do\n  gh pr view 42 --json state\n  sleep 30\ndone'
    'gh pr merge 9 --auto && until gh pr view 9 --json state | grep -q MERGED; do sleep 5; done'
    'if true; then until gh pr view 5 --json state; do sleep 1; done; fi'
    '{ while gh pr view 5 --json state; do sleep 1; done; }'
    'x=$(for i in 1 2; do gh pr view 5 --json state; done)'
    'for n in 1 2; do until gh pr view $n --json state; do sleep 1; done; done'
  )
  local monitor_rows=(
    'until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
    'while true; do gh pr checks 42; sleep 30; done'
  )
  for row in "${bash_rows[@]}"; do
    echo "case: bash: $row"
    run_hook "$row"
    assert_blocked_by_exit
  done
  for row in "${monitor_rows[@]}"; do
    echo "case: monitor: $row"
    run_hook_monitor "$row"
    assert_blocked_by_exit
  done
}

@test "the denial's verdict list carries every verdict the script can print" {
  # Derived from the script's own header rather than restated here, so adding a
  # verdict without amending the denial goes red. The denial is the only
  # contract an agent reads before taking the blessed path, so a caller
  # branching on a stale list falls through silently on the missing state.
  local wait_script verdicts verdict
  wait_script="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/scripts/pr-wait-merge.sh"
  [ -f "$wait_script" ] || return 1
  # The header's exit table lines, e.g. "#   6   CLOSED        the pull ...".
  verdicts=$(sed -n 's/^#   [0-9]\{1,3\}   \([A-Z_]\{3,\}\).*/\1/p' "$wait_script")
  [ -n "$verdicts" ] || return 1

  # Guard the derivation against a header line that stops matching. A floor
  # would not: reformatting one verdict's line drops it from the set while a
  # `-ge <n>` still passes, and the test then greens over a denial that no
  # longer names it. Count the script's own verdict arms instead and require
  # equality, so losing one line from either side reds.
  local arms verdict_count arm_count
  arms=$(sed -n 's/^  \([A-Z_]\{3,\}\))$/\1/p' "$wait_script")
  verdict_count=$(printf '%s\n' "$verdicts" | grep -c .)
  arm_count=$(printf '%s\n' "$arms" | grep -c .)
  [ "$arm_count" -ge 2 ] || return 1
  # +1 for TIMEOUT, which is the `*)` default arm and so carries no uppercase
  # case label for the derivation above to count. Giving it an explicit arm
  # keeps both sides honest and reds this line, which is the moment to drop
  # the offset rather than to widen it.
  [ "$verdict_count" -eq "$((arm_count + 1))" ] || return 1

  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  while IFS= read -r verdict; do
    [ -n "$verdict" ] || continue
    grep -qF -- "$verdict" <<<"$output" || return 1
  done <<<"$verdicts"
}

# --- allowed ------------------------------------------------------------------
#
# Beyond the header's list: the shipped script (the blessed path) and a state
# read that is not the loop's own. The three conjuncts (a loop
# keyword, a `done`, a state read) would otherwise be independent tests over the
# whole command, so a one-shot `gh pr` read beside an unrelated loop satisfies
# all three; denying those is the over-deny direction this guard cannot afford.
# The arithmetic `mergeable` row names `state` alongside `mergeable` so the
# stand-down is the only thing allowing it. The mergeStateStatus row pins the second
# alternative of the stand-down pattern: it never names the field `mergeable`.
# The `--body` rows pin the narrowing and the `done` conjunct: the second one
# reaches the loop keyword but carries no `done`.
@test "a non-polling or mergeable-reading command is allowed" {
  local row payload
  local bash_rows=(
    'for((i=0;i<20;i++)); do gh pr view 42 --json state,mergeable --jq .mergeable; sleep 30; done'
    'bash .gaia/scripts/pr-wait-merge.sh --pr 42'
    'for f in 1 2; do gh pr view $f --json state; done # see pr-wait-merge.sh'
    'until gh pr view 9 --json state,mergeable | grep -q CONFLICTING; do sleep 5; done'
    'until gh pr view 9 --json state,mergeStateStatus --jq .mergeStateStatus | grep -q CONFLICTING; do sleep 5; done'
    $'for i in 1 2; do\n  gh pr view 42 --json state,mergeable\ndone'
    'gh pr view 42 --json state --jq .state'
    'for n in 1 2; do gh pr view $n --json title; done'
    'gh pr create --body "we used to do a for loop on gh pr checks here"'
    'gh pr comment 5 --body "we do while gh pr view 5 --json state says OPEN, then stop"'
    'gh pr checks 2209 --watch; for f in .gaia/local/audit/*; do echo "$f"; done'
    'if gh pr checks 2209; then for f in *.log; do cat "$f"; done; fi'
    'gh pr view 42 --json state -q .state; { for f in *.sh; do shellcheck "$f"; done; }'
    'if gh pr view 5 --json state --jq .state | grep -q MERGED; then echo merged; else for f in a b; do echo "$f"; done; fi'
    'for f in *.sh; do shellcheck "$f"; done'
    ''
  )
  for row in "${bash_rows[@]}"; do
    echo "case: bash: $row"
    run_hook "$row"
    assert_allowed_by_exit
  done

  echo "case: monitor: loop that reads mergeable"
  run_hook_monitor 'while true; do gh pr view 9 --json state,mergeable; sleep 30; done'
  assert_allowed_by_exit

  # A WebSocket subscription is not a poll, and it carries no `command` field.
  echo "case: monitor: ws rather than a command"
  payload=$(jq -nc '{tool_name: "Monitor", tool_input: {ws: {url: "wss://example.test/stream"}}}')
  invoke_hook "$payload" "$HOOK"
  assert_allowed_by_exit

  # The denied shape rides in `command`, so the tool check alone allows it.
  echo "case: Read tool carrying the denied shape"
  payload=$(jq -nc '{tool_name: "Read", tool_input: {command: "until [ \"$(gh pr view 1 --json state --jq .state)\" != \"OPEN\" ]; do sleep 30; done"}}')
  invoke_hook "$payload" "$HOOK"
  assert_allowed_by_exit
}

# --- registration: the hook is reached at all ---------------------------------
#
# Every test above invokes the hook by path, so all of them stay green on a
# dropped registration, with the guard inert in every real session. This is the
# only assertion that reads the file deciding whether the hook runs.

@test "the hook is registered in settings.json for both tools it binds" {
  # The tool check inside the hook reaches nothing the matcher does not
  # deliver, so the Monitor deny tests above stay green on a matcher narrowed
  # back to one tool, with the guard inert for the other in every real session.
  # One matcher names both rather than a row per tool: two rows registering one
  # hook run it twice wherever both matchers select the same tool.
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-handrolled-pr-poll.sh
}

# --- the one-jq payload reader ---

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'until [ "$(gh pr view 1 --json state --jq .state)" != "OPEN" ]; do sleep 30; done' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/block-handrolled-pr-poll.sh"
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-handrolled-pr-poll.sh cannot load lib/hook-payload.sh' <<<"$output"
}

@test "a non-arming Bash payload spawns exactly one jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-handrolled-pr-poll.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}
