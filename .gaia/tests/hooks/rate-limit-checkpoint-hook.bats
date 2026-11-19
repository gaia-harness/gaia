#!/usr/bin/env bats

# .claude/hooks/rate-limit-checkpoint-inject.sh: on a main session's Agent,
# Task or Workflow dispatch, injects the shared rate-limit reading (one header
# line per window newly at or above the warning band, every reader line, and
# the doctrine pointer) once per band per window per session, and never blocks.
#
# Every fixture checkout carries its own copy of the hook and the libraries it
# loads. HOOK_SOURCE_PATH points the suite at another copy of the hook (a
# mutated scratch copy proves a case can go red); it defaults to the real hook.
# Windows, bands and reader lines come from the library at test time. The clock
# and TZ are pinned for every run.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/rate-limit-checkpoint-hook.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# Monday 2026-11-23 13:20 UTC.
NOW=1795440000
# The five_hour window resets at 14:00 UTC the same day.
RESETS_AT=1795442400
# The seven_day window resets Saturday 09:00 UTC.
SATURDAY_RESETS_AT=1795856400
SESSION_ONE=0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e
SESSION_TWO=7a6b5c4d-3e2f-4a1b-9c8d-0e1f2a3b4c5d

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/rate-limit-checkpoint-inject.sh}"
  # shellcheck source=.gaia/tests/helpers/rate-limits-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/rate-limits-fixture.sh"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  MAIN="$TEMPORARY_DIRECTORY/main"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" commit -q --allow-empty -m init
  # The shared reading's file name is assembled so no command line here names it whole.
  READING_NAME=rate-limits
  SHARED_DIRECTORY="$MAIN/.gaia/local/cache/shared"
  READING="$SHARED_DIRECTORY/$READING_NAME.json"
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
  for library_file in context-checkpoint-lib.sh rate-limits-lib.sh main-root-lib.sh rate-limit-main-root-probe-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$root/.gaia/scripts/$library_file"
  done
  HOOK="$root/.claude/hooks/rate-limit-checkpoint-inject.sh"
}

# seed <name> <percentage> <resets_at> [<name> <percentage> <resets_at> ...]:
# a valid stored file, every window observed at NOW.
seed() {
  rate_limits_seed_file "$READING" "$NOW" "$@"
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
  local label

  # Control: the same fixture and a plain payload speak.
  seed five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1

  # A window below the warning band.
  seed five_hour 74 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # An expired window.
  seed five_hour 92 $((NOW - 60))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # No shared reading at all.
  rm -f "$READING"
  dispatch "$SESSION_ONE" Workflow
  silent || return 1

  # A string percentage skips that window; nothing else qualifies.
  mkdir -p "$SHARED_DIRECTORY"
  printf '{"version":1,"windows":{"five_hour":{"used_percentage":"92","resets_at":%s,"observed_at":%s,"producer":"statusline","history":[]}}}' "$RESETS_AT" "$NOW" >"$READING"
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # A window whose name fails the writer's name rule is skipped.
  printf '{"version":1,"windows":{"Five-Hour":{"used_percentage":92,"resets_at":%s,"observed_at":%s,"producer":"statusline","history":[]}}}' "$RESETS_AT" "$NOW" >"$READING"
  dispatch "$SESSION_ONE" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Payload variations on a qualifying file: a sub-agent (agent_id), another
  # event, another tool.
  seed five_hour 92 "$RESETS_AT"
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

  # Nine valid windows: only the first eight by name are read.
  seed a_window 80 "$RESETS_AT" b_window 80 "$RESETS_AT" c_window 80 "$RESETS_AT" d_window 80 "$RESETS_AT" \
    e_window 80 "$RESETS_AT" f_window 80 "$RESETS_AT" g_window 80 "$RESETS_AT" h_window 80 "$RESETS_AT" i_window 80 "$RESETS_AT"
  dispatch 3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f Agent
  speaks || return 1
  [ "$(context_text | grep -c '^Rate-limit checkpoint: ')" = 8 ] || { echo "$(context_text)"; return 1; }
  [ "$(context_text | grep -c 'i_window')" = 0 ] || return 1
  label=$(context_text | grep -c '^h_window ')
  [ "$label" = 1 ] || return 1
}

@test "the hook speaks once per band per window per session" {
  # The first dispatch of a session tells the warning band.
  seed five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || { echo "$(first_line)"; return 1; }

  # The same session's next dispatch, nothing changed, is silent.
  dispatch "$SESSION_ONE" Task
  silent || return 1

  # A higher band of the same window speaks again.
  seed five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Workflow
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # A new window (a reset more than 600 seconds later) speaks again at warning.
  seed five_hour 76 $((RESETS_AT + 601))
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (76%), resets 14:10." ] || { echo "$(first_line)"; return 1; }

  # The same window with its reset 600 seconds later stays silent.
  seed five_hour 79 $((RESETS_AT + 601 + 600))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # Another session that has not dispatched yet is told.
  seed five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
}

@test "the hook never blocks a dispatch and fails open" {
  local scratch_bin tool

  seed five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  grep -q permissionDecision <<<"$output" && return 1

  # An unparseable file, a wrong version and a string percentage.
  printf 'not json {' >"$READING"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  printf '{"version":2,"windows":{"five_hour":{"used_percentage":91,"resets_at":%s,"observed_at":%s}}}' "$RESETS_AT" "$NOW" >"$READING"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1

  # A payload that is not JSON, and an empty one.
  seed five_hour 91 "$RESETS_AT"
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

  # An unwritable marker folder: the injection still goes out, nothing is
  # recorded, and the next dispatch injects again.
  if [ "$(id -u)" != 0 ]; then
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
  fi
}

@test "the marker matches a window by the 600-second rule and a malformed session id writes none" {
  local bad_session

  # The marker holds, per window name, the reset time and the highest band told.
  seed five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(marker_of "$SESSION_ONE")" = "{\"five_hour\":{\"resets_at\":$RESETS_AT,\"band\":\"warning\"}}" ] || { marker_of "$SESSION_ONE"; return 1; }
  [ -z "$(find "$MARKER_DIRECTORY" -name '*.tmp.*')" ] || return 1

  # A reset 601 seconds later is a new window and speaks.
  seed five_hour 78 $((RESETS_AT + 601))
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(marker_of "$SESSION_ONE")" = "{\"five_hour\":{\"resets_at\":$((RESETS_AT + 601)),\"band\":\"warning\"}}" ] || { marker_of "$SESSION_ONE"; return 1; }

  # A reset 600 seconds later is the same window and stays silent.
  seed five_hour 79 $((RESETS_AT + 601 + 600))
  dispatch "$SESSION_ONE" Agent
  silent || return 1

  # Other windows' entries are kept when one window is told.
  seed five_hour 78 $((RESETS_AT + 601 + 600)) seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }
  [ "$(marker_of "$SESSION_ONE" | jq -c 'keys')" = '["five_hour","seven_day"]' ] || { marker_of "$SESSION_ONE"; return 1; }

  # A session id that is not UUID-shaped prints nothing and writes no marker.
  seed five_hour 91 "$RESETS_AT"
  for bad_session in '../x' '../../escape' '0b9c2d4e' '0b9c2d4e-1f3a-4b5c-8d7e-9f0a1b2c3d4e/x' ''; do
    dispatch "$bad_session" Agent
    silent || { echo "session '$bad_session'"; return 1; }
  done
  [ ! -e "$MAIN/.gaia/local/cache/x.json" ] || return 1
  [ ! -e "$MAIN/.gaia/local/cache/escape.json" ] || return 1
  [ "$(find "$MAIN/.gaia/local" -name '*.json' -newer "$READING" | wc -l | tr -d ' ')" = 0 ] || return 1
  [ "$(ls "$MARKER_DIRECTORY" | wc -l | tr -d ' ')" = 1 ] || { ls "$MARKER_DIRECTORY"; return 1; }
  # Control: a UUID-shaped id speaks over the same file.
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
}

@test "the injection holds one header per due window, the reader lines and the policy pointer" {
  local expected_reader_lines expected

  seed five_hour 78 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  expected_reader_lines=$(TZ=UTC gaia_rate_limits_report "$MAIN" "$NOW" | sed -n 's/^line	//p')
  [ -n "$expected_reader_lines" ] || return 1
  expected="Rate-limit checkpoint: five_hour warning band (78%), resets 14:00.
$expected_reader_lines
Policy: .claude/doctrine/rate-limit-checkpoint.md"
  [ "$(context_text)" = "$expected" ] || { echo "got: $(context_text)"; echo "want: $expected"; return 1; }

  # A critical band in an already-told window names the critical band.
  seed five_hour 91 "$RESETS_AT"
  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }

  # A lone seven_day window names its reset day.
  seed seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch "$SESSION_TWO" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || { echo "$(first_line)"; return 1; }

  # Two qualifying windows make one injection, two header lines, both marked.
  seed five_hour 78 "$RESETS_AT" seven_day 91 "$SATURDAY_RESETS_AT"
  dispatch 3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f Agent
  speaks || return 1
  [ "$(context_text | grep -c '^Rate-limit checkpoint: ')" = 2 ] || { context_text; return 1; }
  [ "$(context_text | sed -n 1p)" = "Rate-limit checkpoint: five_hour warning band (78%), resets 14:00." ] || return 1
  [ "$(context_text | sed -n 2p)" = "Rate-limit checkpoint: seven_day critical band (91%), resets Sat 09:00." ] || return 1
  [ "$(context_text | tail -n 1)" = "Policy: .claude/doctrine/rate-limit-checkpoint.md" ] || return 1
  [ "$(marker_of 3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f | jq -c '[.five_hour.band, .seven_day.band]')" = '["warning","critical"]' ] || return 1

  # A later dispatch with neither window changed is silent.
  dispatch 3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f Task
  silent || return 1
}

@test "the fast pre-check only concludes absent: a root where the reading exists still reaches the full ladder" {
  local decoy="$TEMPORARY_DIRECTORY/decoy" library="$MAIN/.gaia/scripts/rate-limit-main-root-probe-lib.sh"

  # The fast layout read is overridden to answer a decoy root that holds a
  # reading with nothing to say (a 40% window). The true main root holds a 91%
  # window. A pre-check that trusted the fast answer for anything but "absent"
  # would go on with the decoy and stay silent; the full ladder resolves the
  # true root and speaks.
  mkdir -p "$decoy"
  rate_limits_seed_file "$decoy/.gaia/local/cache/shared/$READING_NAME.json" "$NOW" five_hour 40 "$RESETS_AT"
  printf 'gaia_resolve_main_root_fast() { printf "%%s\n" "%s"; }\n' "$decoy" >>"$library"
  seed five_hour 91 "$RESETS_AT"

  dispatch "$SESSION_ONE" Agent
  speaks || return 1
  [ "$(first_line)" = "Rate-limit checkpoint: five_hour critical band (91%), resets 14:00." ] || { echo "$(first_line)"; return 1; }
  [ -f "$MARKER_DIRECTORY/$SESSION_ONE.json" ] || return 1

  # Control: when the fast answer is a root with no reading, the hook exits early.
  rm -f "$decoy/.gaia/local/cache/shared/$READING_NAME.json"
  dispatch "$SESSION_TWO" Agent
  silent || return 1
  [ ! -e "$MARKER_DIRECTORY/$SESSION_TWO.json" ] || return 1
}
