#!/usr/bin/env bats

# Flow test: a max-tier account's statusline renders carrying only a seven-day
# figure write the session's own rate-limit reading, and a main session's Agent
# dispatch, sent through the command registered in .claude/settings.json, stays
# silent at 78 percent and receives the seven-day warning band as additional
# context at 91 percent, because the tier raises that band. Only the journey is
# asserted; the injection's text, once-per-band silence, the critical band, new
# windows, sub-agents and the fail-open cases belong to the library, hook and
# statusline suites.
#
# The fixture checkout carries copies of the statusline, the libraries and the
# hook. HOME and CLAUDE_CONFIG_DIR point at scratch folders.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-inject.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 13:20 UTC.
NOW=1795440000
SESSION=0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  MAIN="$TEMPORARY_DIRECTORY/main"
  mkdir -p "$MAIN/.claude/hooks" "$MAIN/.gaia/scripts" "$MAIN/.gaia/statusline" "$MAIN/.gaia/local"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" commit -q --allow-empty -m init
  cp "$REPO_ROOT"/.gaia/statusline/*.sh "$MAIN/.gaia/statusline/"
  cp "$REPO_ROOT"/.gaia/scripts/*-lib.sh "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/rate-limit-checkpoint-inject.sh" "$MAIN/.claude/hooks/"
  chmod 755 "$MAIN/.claude/hooks/rate-limit-checkpoint-inject.sh"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' >"$MAIN/.gaia/local/setup-state.json"
  . "$REPO_ROOT/.gaia/scripts/rate-limits-lib.sh"
  READING="$(gaia_rate_limits_file "$MAIN" "$SESSION")"
  TEMPORARY_HOME="$TEMPORARY_DIRECTORY/home"
  mkdir -p "$TEMPORARY_HOME" "$TEMPORARY_DIRECTORY/config"
  unset CLAUDE_CODE_SESSION_ID
  export HOME="$TEMPORARY_HOME" CLAUDE_CONFIG_DIR="$TEMPORARY_DIRECTORY/config"
}

# registered_command: the command string of the settings entry whose matcher is
# Agent|Task|Workflow and which runs the rate-limit hook.
registered_command() {
  jq -er '[.hooks.PreToolUse[]
      | select(.matcher == "Agent|Task|Workflow")
      | .hooks[].command
      | select(contains("rate-limit-checkpoint-inject.sh"))] | first' "$REPO_ROOT/.claude/settings.json"
}

# render_seven_day: one statusline render of the session carrying only a seven-day figure.
render_seven_day() {
  local percentage="$1" render_payload
  render_payload="$(jq -nc --arg current_directory "$MAIN" --arg session_id "$SESSION" \
    --argjson percentage "$percentage" --argjson resets_at "$((NOW + 259200))" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, cwd: $current_directory,
      model: {display_name: "Claude Opus"}, effort: {level: "high"},
      rate_limits: {seven_day: {used_percentage: $percentage, resets_at: $resets_at}}}')"
  run env HOME="$TEMPORARY_HOME" COLUMNS=200 TZ=UTC GAIA_RATE_LIMITS_NOW="$NOW" \
    bash "$MAIN/.gaia/statusline/gaia-statusline.sh" <<<"$render_payload"
  # shellcheck disable=SC2031
  [ "$status" -eq 0 ]
}

# dispatch_agent: an Agent dispatch through the registered command; the hook output lands in $output.
dispatch_agent() {
  local command_string dispatch_payload
  command_string="$(registered_command)"
  dispatch_payload="$(jq -nc --arg session_id "$SESSION" --arg cwd "$MAIN" \
    '{hook_event_name: "PreToolUse", session_id: $session_id, cwd: $cwd, tool_name: "Agent", tool_input: {}}')"
  # shellcheck disable=SC2016
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC \
    bash -c 'cd "$1" && shift && eval "$1"' _ "$MAIN" "$command_string" <<<"$dispatch_payload"
  # shellcheck disable=SC2031
  [ "$status" -eq 0 ]
}

@test "a max-tier account's seven-day figure stays silent at 78 percent and warns at 91 percent" {
  jq -nc '{oauthAccount: {organizationRateLimitTier: "default_claude_max_5x"}}' >"$CLAUDE_CONFIG_DIR/.claude.json"

  render_seven_day 78 || return 1
  [ -f "$READING" ] || { echo "the render wrote no reading for the session"; return 1; }
  dispatch_agent || { echo "status $status"; return 1; }
  [ -z "$output" ] || { echo "the checkpoint spoke below the tier's warning band: $output"; return 1; }

  render_seven_day 91 || return 1
  dispatch_agent || { echo "status $status"; return 1; }
  jq -e '.hookSpecificOutput.additionalContext | type == "string" and contains("seven_day warning band")' \
    <<<"$output" >/dev/null || {
    echo "no seven_day warning band: $output"
    return 1
  }
  jq -e '.hookSpecificOutput.additionalContext | contains("critical band")' <<<"$output" >/dev/null && return 1
  true
}
