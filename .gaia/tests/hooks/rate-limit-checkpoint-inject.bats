#!/usr/bin/env bats

# Flow test: a statusline render whose payload holds the five-hour window at the
# warning band writes the shared rate-limit reading, and a main session's Agent
# dispatch, sent through the command registered in .claude/settings.json,
# receives that reading as additional context. Only the journey is asserted; the
# injection's text, once-per-band silence, the critical band, new windows,
# sub-agents and the fail-open cases belong to the library, hook and statusline
# suites.
#
# The fixture checkout carries copies of the statusline, the libraries and the
# hook. The shared file's name is assembled from parts so no command line here
# names it whole.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-inject.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 13:20 UTC; the five-hour window resets an hour later.
NOW=1795440000
RESETS_AT=1795443600
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
  READING_NAME=rate-limits
  READING="$MAIN/.gaia/local/cache/shared/$READING_NAME.json"
  TEMPORARY_HOME="$TEMPORARY_DIRECTORY/home"
  mkdir -p "$TEMPORARY_HOME"
}

# registered_command: the command string of the settings entry whose matcher is
# Agent|Task|Workflow and which runs the rate-limit hook.
registered_command() {
  jq -er '[.hooks.PreToolUse[]
      | select(.matcher == "Agent|Task|Workflow")
      | .hooks[].command
      | select(contains("rate-limit-checkpoint-inject.sh"))] | first' "$REPO_ROOT/.claude/settings.json"
}

@test "a warning-band render reaches a main-session dispatch through the registered command" {
  local command_string render_payload dispatch_payload
  command_string="$(registered_command)"
  [ -n "$command_string" ] || return 1
  [ ! -e "$READING" ] || return 1

  render_payload="$(jq -nc --arg current_directory "$MAIN" --arg session_id "$SESSION" --argjson resets_at "$RESETS_AT" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, cwd: $current_directory,
      model: {display_name: "Claude Opus"}, effort: {level: "high"},
      rate_limits: {five_hour: {used_percentage: 80, resets_at: $resets_at}}}')"
  run env HOME="$TEMPORARY_HOME" COLUMNS=200 TZ=UTC GAIA_RATE_LIMITS_NOW="$NOW" \
    bash "$MAIN/.gaia/statusline/gaia-statusline.sh" <<<"$render_payload"
  [ "$status" -eq 0 ] || return 1
  [ -f "$READING" ] || { echo "the render wrote no shared reading"; return 1; }

  dispatch_payload="$(jq -nc --arg session_id "$SESSION" --arg cwd "$MAIN" \
    '{hook_event_name: "PreToolUse", session_id: $session_id, cwd: $cwd, tool_name: "Agent", tool_input: {}}')"
  # The registered command carries its own quoting and substitutions, so the inner shell evaluates it.
  # shellcheck disable=SC2016
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC \
    bash -c 'cd "$1" && shift && eval "$1"' _ "$MAIN" "$command_string" <<<"$dispatch_payload"
  [ "$status" -eq 0 ] || { echo "status $status"; return 1; }
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' <<<"$output" >/dev/null || {
    echo "no additional context: $output"
    return 1
  }
}
