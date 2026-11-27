#!/usr/bin/env bats
# shellcheck disable=SC2016 # the gh stub source is literal text, not an expansion
# Flow test: the session that hit an audit hand-off checkpoint skips that pull
# request in /gaia-next without parking it, and another session picks it up.
#
# One fixture repository serves both halves: the bound hook records the
# hand-off in session A's name, then the picker runs as session A and as
# session B against the same root. `gh` is a stub on PATH.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/gaia-next-handoff-skip.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq missing"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  mkdir -p "$ALF_ROOT/apps/web" "$ALF_ROOT/.notebook"
  cp "$REPO_ROOT/apps/web/gaia.package.json" "$ALF_ROOT/apps/web/gaia.package.json"
  printf '{"version":1,"items":[]}\n' >"$ALF_ROOT/.notebook/catalog.json"
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "pr list"*) printf "12\tfeat/loop\n"; exit 0 ;;' \
    '  "issue list"*) printf "[]"; exit 0 ;;' \
    '  *isCrossRepository*) printf "false\n"; exit 0 ;;' \
    'esac' \
    'echo "no pull requests found" >&2; exit 1' >"$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  SESSION_A=0a1b2c3d-1111-4222-8333-444455556666
  SESSION_B=0a1b2c3d-2222-4222-8333-444455556666
}

# pick_as <session>: the picker run as that session, with the stub gh first on PATH.
pick_as() {
  run --separate-stderr env PATH="$STUB_BIN:$PATH" CLAUDE_CODE_SESSION_ID="$1" \
    bash "$REPO_ROOT/.gaia/scripts/gaia-next.sh" pick --root "$ALF_ROOT"
}

@test "the session that hit a hand-off checkpoint skips the pull request without parking it, and another session picks it" {
  local reason='a hand-off checkpoint from this session; it continues in a fresh session'
  local payload

  # Session A, over the context line, is handed off at its next unit dispatch.
  alf_sequence 6 5
  gaia_context_write "$ALF_ROOT" "$SESSION_A" "$((GAIA_CONTEXT_ASK_TOKENS_DEFAULT * 100 / 1000000))" \
    "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" 1000000 "$(date +%s)"
  payload="$(jq -n -c --arg session_id "$SESSION_A" --arg root "$ALF_ROOT" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}}')"
  run env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$BATS_TEST_TMPDIR" \
    bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/.claude/hooks/audit-loop-bound.sh"
  [ "$status" -eq 0 ] || return 1
  [ "$(jq -r '.history.checkpoints | last | [.handoff, .session_id] | map(tostring) | join(" ")' "$ALF_STATE")" = "true $SESSION_A" ] || return 1

  # Still at the line, session A is handed off before any tier is read.
  pick_as "$SESSION_A"
  [ "$status" -eq 0 ] || return 1
  jq -e '.job == "handoff" and .band == "red"' <<<"$output" >/dev/null || return 1

  # After a compaction its reading is below the line; it skips the pull request and parks nothing.
  gaia_context_write "$ALF_ROOT" "$SESSION_A" 10 100000 1000000 "$(date +%s)"
  pick_as "$SESSION_A"
  [ "$status" -eq 0 ] || return 1
  jq -e --arg reason "$reason" '.job == "backlog" and .skipped == [{item: "pr #12", reason: $reason}]' <<<"$output" >/dev/null || return 1
  [[ "$stderr" == *"gaia-next: skipped pr #12: $reason"* ]] || return 1
  [ -z "$(find "$ALF_ROOT/.gaia/local/runs" -type f 2>/dev/null)" ] || return 1

  # Session B takes it.
  pick_as "$SESSION_B"
  [ "$status" -eq 0 ] || return 1
  jq -e '.job == "pr" and .pr == 12 and .branch == "feat/loop" and (.skipped | length) == 0' <<<"$output" >/dev/null
}
