#!/usr/bin/env bats

# .claude/hooks/rate-limit-checkpoint-inject.sh: on a main session's Agent,
# Task or Workflow dispatch, injects the dispatching session's own rate-limit
# reading (one header line per window newly at or above its warning band, the
# reader lines, and the doctrine pointer) once per band per window per session,
# and never blocks. Another session's reading is never acted on.
#
# Every fixture checkout carries its own copy of the hook and the libraries it
# loads. HOOK_SOURCE_PATH points the suite at another copy of the hook (a
# mutated scratch copy proves a case can go red); it defaults to the real hook.
# Windows, bands and reader lines come from the library at test time. The clock
# and TZ are pinned for every run, and HOME and CLAUDE_CONFIG_DIR point at
# scratch folders so no run opens a real account profile.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-hook.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 13:20 UTC.
NOW=1795440000
# The five_hour window resets at 14:00 UTC the same day.
RESETS_AT=1795442400
# The five_hour window resets at 14:30 UTC the same day.
LATE_RESETS_AT=1795444200
# The seven_day window resets Saturday 09:00 UTC.
SATURDAY_RESETS_AT=1795856400
SESSION_ONE=0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e
SESSION_TWO=7a6b5c4d-3e2f-4a1b-9c8d-0e1f2a3b4c5d
SESSION_THREE=3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/rate-limit-checkpoint-inject.sh}"
  # shellcheck source=.gaia/tests/helpers/rate-limits-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/rate-limits-fixture.sh"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR CLAUDE_CODE_SESSION_ID
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  export HOME="$TEMPORARY_DIRECTORY/home" CLAUDE_CONFIG_DIR="$TEMPORARY_DIRECTORY/config"
  mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
  MAIN="$TEMPORARY_DIRECTORY/main"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" commit -q --allow-empty -m init
  MARKER_DIRECTORY="$MAIN/.gaia/local/cache/rate-limit-checkpoint"
  install_hook "$MAIN"
  . "$REPO_ROOT/.gaia/scripts/rate-limits-lib.sh"
}

teardown() {
  chmod -R u+rwx "$MAIN/.gaia" 2>/dev/null || true
  return 0
}

# install_hook <root>: the hook and its libraries under <root>. Sets HOOK.
install_hook() {
  local root="$1" library_file
  mkdir -p "$root/.claude/hooks" "$root/.gaia/scripts"
  cp "$HOOK_SOURCE_PATH" "$root/.claude/hooks/rate-limit-checkpoint-inject.sh"
  chmod 755 "$root/.claude/hooks/rate-limit-checkpoint-inject.sh"
  for library_file in context-checkpoint-lib.sh rate-limits-lib.sh rate-limits-programs-lib.sh main-root-lib.sh rate-limit-main-root-probe-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$root/.gaia/scripts/$library_file"
  done
  HOOK="$root/.claude/hooks/rate-limit-checkpoint-inject.sh"
}

# seed <session> <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# a valid stored file for that session, every window changed and confirmed at NOW.
seed() {
  local session="$1"
  shift
  rate_limits_seed_session "$MAIN" "$session" "$NOW" true "$@"
}

# own_file <session>: that session's reading file in MAIN.
own_file() {
  gaia_rate_limits_file "$MAIN" "$1"
}

# set_tier <tier string>: the account profile the 7-day banding reads.
set_tier() {
  jq -n --arg tier "$1" '{oauthAccount: {organizationRateLimitTier: $tier}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
}

# payload <session> <tool> [<extra-jq-filter>]: a PreToolUse payload for MAIN.
payload() {
  jq -nc --arg session_id "$1" --arg tool_name "$2" --arg cwd "$MAIN" \
    '{hook_event_name: "PreToolUse", session_id: $session_id, cwd: $cwd, tool_name: $tool_name, tool_input: {}} | '"${3:-.}"
}

# dispatch <session> <tool> [<now>]: one run of HOOK; sets status, output, stderr.
dispatch() {
  local session="$1" tool="$2" now="${3:-$NOW}"
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$now" TZ=UTC /bin/bash "$HOOK" < <(payload "$session" "$tool")
}

# silent: the last run exited 0 with nothing on stdout or stderr.
silent() {
  [ "$status" -eq 0 ] || { echo "status $status"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
}

# context_text: the injected text of the last run, newline separated.
context_text() {
  jq -er '.hookSpecificOutput.additionalContext' <<<"$output"
}

# first_line: the first line of the injected text.
first_line() {
  context_text | head -n 1
}

# speaks: the last run printed one valid hook object and exited 0.
speaks() {
  [ "$status" -eq 0 ] || { echo "status $status"; return 1; }
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$output" >/dev/null || { echo "not a PreToolUse object: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ] || { echo "not one line: $output"; return 1; }
}

marker_of() {
  jq -c . "$MARKER_DIRECTORY/$1.json"
}

@test "the hook is silent when there is nothing to say" {
  # Control: the same fixture and a plain payload speak.
  seed "$SESSION_TWO" five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1

  # A window below the warning band.
  seed "$SESSION_ONE" five_hour 74 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # An expired window.
  seed "$SESSION_ONE" five_hour 92 $((NOW - 60))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # No reading file at all.
  rm -f "$(own_file "$SESSION_ONE")"
  dispatch "$SESSION_ONE" Workflow
  silent || return 1

  # A string percentage skips that window; nothing else qualifies.
  printf '{"version":2,"windows":{"five_hour":{"used_percentage":"92","resets_at":%s,"changed_at":%s,"confirmed":true,"history":[]}}}' "$RESETS_AT" "$NOW" >"$(own_file "$SESSION_ONE")"
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # A window whose name fails the writer's name rule is skipped.
  printf '{"version":2,"windows":{"Five-Hour":{"used_percentage":92,"resets_at":%s,"changed_at":%s,"confirmed":true,"history":[]}}}' "$RESETS_AT" "$NOW" >"$(own_file "$SESSION_ONE")"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Payload variations on a qualifying file: a sub-agent (agent_id), another
  # event, another tool.
  seed "$SESSION_ONE" five_hour 92 "$RESETS_AT"
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" < <(payload "$SESSION_ONE" Agent '. + {agent_id: "agent-1"}')
  silent || return 1
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" < <(payload "$SESSION_ONE" Agent '.hook_event_name = "PostToolUse"')
  silent || return 1
  dispatch "$SESSION_ONE" Bash
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1
  # Control: the same session and file, a plain dispatch, speaks.
  dispatch "$SESSION_ONE" Agent
  speaks || return 1

  # The injected text over the byte cap prints nothing and records nothing.
  local capped_hook="$TEMPORARY_DIRECTORY/capped/.claude/hooks/rate-limit-checkpoint-inject.sh"
  local real_hook="$HOOK"
  install_hook "$TEMPORARY_DIRECTORY/capped"
  HOOK="$real_hook"
  sed -i.bak 's/^maximum_text_bytes=.*/maximum_text_bytes=100/' "$capped_hook"
  grep -q '^maximum_text_bytes=100$' "$capped_hook" || return 1
  rm -f "$MARKER_DIRECTORY/$SESSION_TWO.json"
  HOOK="$capped_hook" dispatch "$SESSION_TWO" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
}

@test "the checkpoint acts only on the dispatching session's own reading" {
  # Another session's confirmed, newer 99% never fires this session's 3%.
  rate_limits_seed_session "$MAIN" "$SESSION_ONE" $((NOW - 100)) true five_hour 3 "$RESETS_AT"
  rate_limits_seed_session "$MAIN" "$SESSION_TWO" "$NOW" true five_hour 99 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # A session with no file stays silent while another holds 91%.
  rm -f "$(own_file "$SESSION_ONE")"
  seed "$SESSION_TWO" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Its own 91% resetting at 14:30 fires with the exact header and last line.
  seed "$SESSION_ONE" five_hour 91 "$LATE_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:30." ] || { echo "$(first_line)"; return 1; }
  [ "$(context_text | tail -n 1)" = "Policy: .claude/doctrine/rate-limit-checkpoint.md" ] || return 1

  # An own 7-day 91% on the standard set fires its header, with no other file.
  seed "$SESSION_THREE" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_THREE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  # A session whose file lacks five_hour gets no five_hour header while another
  # session's file holds 91%.
  rm -f "$MARKER_DIRECTORY/$SESSION_THREE.json"
  seed "$SESSION_THREE" seven_day 10 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_THREE" Agent
  silent || return 1
}

@test "the 7-day header follows the tier's bands and the 5-hour header the standard bands" {
  # An ultra tier warns the 7-day window at 85 and criticals at 95.
  set_tier default_claude_max_20x
  seed "$SESSION_ONE" seven_day 84 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  seed "$SESSION_ONE" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day warning band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }
  seed "$SESSION_ONE" seven_day 96 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (96%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  # A max tier warns at 80 and criticals at 92.
  set_tier default_claude_max_5x
  seed "$SESSION_TWO" seven_day 79 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  seed "$SESSION_TWO" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day warning band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }
  seed "$SESSION_TWO" seven_day 92 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (92%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  # The 5-hour window bands on the standard set on every tier.
  set_tier default_claude_max_20x
  seed "$SESSION_THREE" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_THREE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
}

@test "a missing, unreadable, non-JSON or unmapped tier bands on the standard set" {
  local case_name

  # Control: a mapped tier does not give the standard critical at 91.
  set_tier default_claude_max_20x
  seed "$SESSION_ONE" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day warning band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  for case_name in missing unreadable non_json non_string unmapped standard; do
    rm -f "$MARKER_DIRECTORY/$SESSION_ONE.json" "$CLAUDE_CONFIG_DIR/.claude.json"
    case "$case_name" in
      missing) ;;
      unreadable)
        set_tier default_claude_max_20x
        chmod 000 "$CLAUDE_CONFIG_DIR/.claude.json"
        ;;
      non_json) printf 'not json {' >"$CLAUDE_CONFIG_DIR/.claude.json" ;;
      non_string) printf '{"oauthAccount":{"organizationRateLimitTier":20}}' >"$CLAUDE_CONFIG_DIR/.claude.json" ;;
      unmapped) set_tier some_future_tier ;;
      standard) set_tier default_raven ;;
    esac
    dispatch "$SESSION_ONE" Agent
    speaks || { echo "case $case_name"; return 1; }
    [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "case $case_name: $(first_line)"; return 1; }
    chmod 600 "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null || true
  done
}

@test "the hook speaks once per band per window per session" {
  # The first dispatch of a session tells the warning band.
  seed "$SESSION_ONE" five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || { echo "$(first_line)"; return 1; }

  # The same session's next dispatch, nothing changed, is silent.
  dispatch "$SESSION_ONE" Task
  silent || return 1

  # A higher band of the same window speaks again.
  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Workflow
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # A new window (a reset more than 600 seconds later) speaks again at warning.
  seed "$SESSION_ONE" five_hour 76 $((RESETS_AT + 601))
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (76%), resets 14:10." ] || { echo "$(first_line)"; return 1; }

  # The same window with its reset 600 seconds later stays silent.
  seed "$SESSION_ONE" five_hour 79 $((RESETS_AT + 601 + 600))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # Another session that has not dispatched yet is told.
  seed "$SESSION_TWO" five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
}

@test "the hook never blocks a dispatch and fails open" {
  local scratch_bin tool

  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  grep -q permissionDecision <<<"$output" && return 1

  # An unparseable file and a wrong version.
  printf 'not json {' >"$(own_file "$SESSION_TWO")"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  printf '{"version":1,"windows":{"five_hour":{"used_percentage":91,"resets_at":%s}}}' "$RESETS_AT" >"$(own_file "$SESSION_TWO")"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1

  # A payload that is not JSON, and an empty one.
  seed "$SESSION_TWO" five_hour 91 "$RESETS_AT"
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" < <(printf 'garbage')
  silent || return 1
  run --separate-stderr env GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" </dev/null
  silent || return 1

  # jq off PATH: silent. The same PATH with jq linked in speaks.
  scratch_bin="$TEMPORARY_DIRECTORY/bin"
  mkdir -p "$scratch_bin"
  for tool in cat git mkdir mv rm date dirname sed grep tr head wc env uname; do
    ln -sf "$(command -v "$tool")" "$scratch_bin/$tool"
  done
  run --separate-stderr env PATH="$scratch_bin" GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" < <(payload "$SESSION_TWO" Agent)
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1
  ln -sf "$(command -v jq)" "$scratch_bin/jq"
  run --separate-stderr env PATH="$scratch_bin" GAIA_RATE_LIMITS_NOW="$NOW" TZ=UTC /bin/bash "$HOOK" < <(payload "$SESSION_TWO" Agent)
  speaks || return 1

  # The library absent: silent. Restored, it speaks.
  rm -f "$MARKER_DIRECTORY/$SESSION_TWO.json"
  mv "$MAIN/.gaia/scripts/rate-limits-lib.sh" "$TEMPORARY_DIRECTORY/rate-limits-lib.sh.away"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  mv "$TEMPORARY_DIRECTORY/rate-limits-lib.sh.away" "$MAIN/.gaia/scripts/rate-limits-lib.sh"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
}

@test "the checkpoint fails open on a bad own file and an unwritable marker folder" {
  # An unparseable own file is silent even when another session's file is due.
  seed "$SESSION_TWO" five_hour 91 "$RESETS_AT"
  printf 'not json {' >"$(own_file "$SESSION_ONE")"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Control: a readable own file at the same figure speaks.
  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
  rm -f "$MARKER_DIRECTORY/$SESSION_ONE.json"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  grep -q permissionDecision <<<"$output" && return 1

  if [ "$(id -u)" != 0 ]; then
    # An unwritable marker folder: the injection still goes out, nothing is
    # recorded, and the next dispatch injects again.
    rm -rf "$MARKER_DIRECTORY"
    mkdir -p "$MARKER_DIRECTORY"
    chmod 555 "$MARKER_DIRECTORY"
    dispatch "$SESSION_ONE" Agent
    speaks || return 1
    grep -q permissionDecision <<<"$output" && return 1
    [ -z "$(ls -A "$MARKER_DIRECTORY")" ] || { ls -A "$MARKER_DIRECTORY"; return 1; }
    dispatch "$SESSION_ONE" Agent
    speaks || return 1
    chmod 755 "$MARKER_DIRECTORY"
    dispatch "$SESSION_ONE" Agent
    speaks || return 1
    dispatch "$SESSION_ONE" Agent
    silent || return 1

    # A failed lowering keeps the old marker, so the next climb at the same
    # reset stays silent.
    seed "$SESSION_ONE" five_hour 3 "$RESETS_AT"
    chmod 555 "$MARKER_DIRECTORY"
    dispatch "$SESSION_ONE" Agent
    silent || return 1
    [ "$(marker_of "$SESSION_ONE" | jq -r '.five_hour.band')" = critical ] || { marker_of "$SESSION_ONE"; return 1; }
    seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
    dispatch "$SESSION_ONE" Agent
    silent || return 1
    chmod 755 "$MARKER_DIRECTORY"
  fi
}

@test "the marker matches a window by the 600-second rule and a malformed session id writes none" {
  local bad_session

  # The marker holds, per window name, the reset time and the highest band told.
  seed "$SESSION_ONE" five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(marker_of "$SESSION_ONE")" = "{\"five_hour\":{\"resets_at\":$RESETS_AT,\"band\":\"warning\"}}" ] || { marker_of "$SESSION_ONE"; return 1; }
  [ -z "$(find "$MARKER_DIRECTORY" -name '*.tmp.*')" ] || return 1

  # A reset 601 seconds later is a new window and speaks.
  seed "$SESSION_ONE" five_hour 78 $((RESETS_AT + 601))
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(marker_of "$SESSION_ONE")" = "{\"five_hour\":{\"resets_at\":$((RESETS_AT + 601)),\"band\":\"warning\"}}" ] || { marker_of "$SESSION_ONE"; return 1; }

  # A reset 600 seconds later is the same window and stays silent.
  seed "$SESSION_ONE" five_hour 79 $((RESETS_AT + 601 + 600))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # Other windows' entries are kept when one window is told.
  seed "$SESSION_ONE" five_hour 78 $((RESETS_AT + 601 + 600)) seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }
  [ "$(marker_of "$SESSION_ONE" | jq -c 'keys')" = '["five_hour","seven_day"]' ] || { marker_of "$SESSION_ONE"; return 1; }

  # A session id that is not UUID-shaped prints nothing and writes no marker,
  # even while a UUID-shaped session's file is due.
  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
  for bad_session in '../x' '../../escape' '0b9c2d4e' '0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e/x' ''; do
    dispatch "$bad_session" Agent
    silent || { echo "session '$bad_session'"; return 1; }
  done
  [ ! -e "$MAIN/.gaia/local/cache/x.json" ] || return 1
  [ ! -e "$MAIN/.gaia/local/cache/escape.json" ] || return 1
  [ "$(find "$MAIN/.gaia/local" -name '*.json' -newer "$(own_file "$SESSION_ONE")" | wc -l | tr -d ' ')" = 0 ] || return 1
  [ "$(ls "$MARKER_DIRECTORY" | wc -l | tr -d ' ')" = 1 ] || { ls "$MARKER_DIRECTORY"; return 1; }
  # Control: a UUID-shaped id with its own file speaks.
  seed "$SESSION_TWO" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
}

@test "the injection holds one header per due window, the reader lines and the policy pointer" {
  local expected_reader_lines expected

  seed "$SESSION_ONE" five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  expected_reader_lines=$(TZ=UTC gaia_rate_limits_report "$MAIN" "$NOW" own "$SESSION_ONE" | sed -n 's/^line	//p')
  [ -n "$expected_reader_lines" ] || return 1
  expected="Rate-limit checkpoint: five_hour warning band (78%), resets 14:00.
$expected_reader_lines
Policy: .claude/doctrine/rate-limit-checkpoint.md"
  [ "$(context_text)" = "$expected" ] || { echo "got: $(context_text)"; echo "want: $expected"; return 1; }

  # A critical band in an already-told window names the critical band.
  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }

  # A lone seven_day window names its reset day.
  seed "$SESSION_TWO" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  # Two qualifying windows make one injection, two header lines, both marked.
  seed "$SESSION_THREE" five_hour 78 "$RESETS_AT" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_THREE" Agent
  speaks || return 1
  [ "$(context_text | grep -c '^Rate-limit checkpoint: ')" = 2 ] || { context_text; return 1; }
  [ "$(context_text | sed -n 1p)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || return 1
  [ "$(context_text | sed -n 2p)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || return 1
  [ "$(context_text | tail -n 1)" = "Policy: .claude/doctrine/rate-limit-checkpoint.md" ] || return 1
  [ "$(marker_of "$SESSION_THREE" | jq -c '[.five_hour.band, .seven_day.band]')" = '["warning","critical"]' ] || return 1

  # A later dispatch with neither window changed is silent.
  dispatch "$SESSION_THREE" Task
  silent || return 1
}

@test "the fast pre-check only concludes absent: a root where the own reading exists still reaches the full ladder" {
  local decoy="$TEMPORARY_DIRECTORY/decoy" library="$MAIN/.gaia/scripts/rate-limit-main-root-probe-lib.sh"

  # The fast layout read is overridden to answer a decoy root that holds an own
  # reading with nothing to say (a 40% window). The true main root holds a 91%
  # window. A pre-check that trusted the fast answer for anything but "absent"
  # would go on with the decoy and stay silent; the full ladder resolves the
  # true root and speaks.
  mkdir -p "$decoy"
  rate_limits_seed_session "$decoy" "$SESSION_ONE" "$NOW" true five_hour 40 "$RESETS_AT"
  printf 'gaia_resolve_main_root_fast() { printf "%%s\n" "%s"; }\n' "$decoy" >>"$library"
  seed "$SESSION_ONE" five_hour 91 "$RESETS_AT"

  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
  [ -f "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Control: when the fast answer is a root with no own reading, the hook exits early.
  rm -f "$(gaia_rate_limits_file "$decoy" "$SESSION_ONE")"
  seed "$SESSION_TWO" five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1
}
