#!/usr/bin/env bats

# .claude/hooks/context-checkpoint-subagent.sh: after every tool call of a
# sub-agent whose dispatch prompt ends with a `Yield handoff: <path>` line,
# reads the sub-agent's reading from the last usage record of its own
# transcript and injects the yield instruction (two header lines, then
# .claude/doctrine/context-yield.md verbatim) the first time the reading is at
# or past red, and once more at each of fire and skull. Silent for main-session
# payloads (an agent_id lookalike in tool_input included), agents that did not
# opt in, marked bands, transcripts with no usage record in the widened read,
# an unreadable library, and a missing or oversize doctrine file.
#
# Every fixture repo carries its own copy of the hook, the libraries it loads
# and the real doctrine file. HOOK_SOURCE_PATH points the suite at another copy
# of the hook (a mutated scratch copy proves the cases can go red); it defaults
# to the real hook. Token values and read bounds come from the lib at test
# time; the exact figures appear only where a case names a window explicitly.
#
# Each negative case runs in the same fixture as a positive control that differs
# by one variable. The hook runs under /bin/bash, the shell whose cost budget it
# is held to.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-subagent.bats < /dev/null

# The jq programs and the hook lines the mutants match are single-quoted so
# their `$` reaches jq or the match literally.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/context-checkpoint-subagent.sh}"
  REAL_DOCTRINE="$REPO_ROOT/.claude/doctrine/context-yield.md"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  git init -q -b main "$TEMPORARY_DIRECTORY/repo"
  MAIN_ROOT="$(cd "$TEMPORARY_DIRECTORY/repo" && pwd -P)"
  install_hook "$MAIN_ROOT"
  MARKER_DIRECTORY="$MAIN_ROOT/.gaia/local/cache/context-checkpoint-agents"
  PROJECT_DIRECTORY="$TEMPORARY_DIRECTORY/project"
  mkdir -p "$PROJECT_DIRECTORY"
  session_counter=0
  agent_counter=0
  new_session
  new_agent
  HANDOFF="$MAIN_ROOT/.gaia/local/plans/demo/handoffs/phase-2-task-subagent-hook-yield-1.md"
  WINDOW=1000000
  write_reading "$WINDOW"
  load_bands "$WINDOW"
}

# install_hook <root>: the hook, its libraries and the real doctrine under <root>.
install_hook() {
  local root="$1" library_file
  mkdir -p "$root/.claude/hooks" "$root/.claude/doctrine" "$root/.gaia/scripts"
  cp "$HOOK_SOURCE_PATH" "$root/.claude/hooks/context-checkpoint-subagent.sh"
  chmod 755 "$root/.claude/hooks/context-checkpoint-subagent.sh"
  for library_file in context-checkpoint-lib.sh main-root-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$root/.gaia/scripts/$library_file"
  done
  cp "$REAL_DOCTRINE" "$root/.claude/doctrine/context-yield.md"
  HOOK="$root/.claude/hooks/context-checkpoint-subagent.sh"
  # Beside the hook, so a mutant loads the same libraries and doctrine.
  MUTANT="$root/.claude/hooks/mutant.sh"
  DOCTRINE="$root/.claude/doctrine/context-yield.md"
  FIXTURE_LIBRARY="$root/.gaia/scripts/context-checkpoint-lib.sh"
}

# new_session: a fresh UUID-shaped $SID and its main transcript path.
new_session() {
  session_counter=$((session_counter + 1))
  SID="$(printf '%08x-0000-4000-8000-%012x' "$session_counter" "$session_counter")"
  TRANSCRIPT="$PROJECT_DIRECTORY/$SID.jsonl"
}

# new_agent: a fresh agent id in $AGENT, shaped like the ones Claude Code writes.
new_agent() {
  agent_counter=$((agent_counter + 1))
  AGENT="$(printf 'a%016x' "$agent_counter")"
}

# load_bands <window>: YELLOW RED FIRE SKULL token values from the lib.
load_bands() {
  local line
  line="$(gaia_context_effective_line "$MAIN_ROOT" "$1")"
  read -r YELLOW RED FIRE SKULL <<<"$(gaia_context_bands "$1" "$line")"
  [ "$RED" -gt 0 ] && [ "$FIRE" -gt "$RED" ] && [ "$SKULL" -gt "$FIRE" ] && [ "$YELLOW" -lt "$RED" ]
}

# write_reading <window> [epoch]: the main session's statusline reading for $SID.
write_reading() {
  gaia_context_write "$MAIN_ROOT" "$SID" 1 1 "$1" "${2:-$(date +%s)}"
}

reading_file() { gaia_context_file "$MAIN_ROOT" "$SID"; }

subagent_transcript() { printf '%s/subagents/agent-%s.jsonl' "${TRANSCRIPT%.jsonl}" "${1:-$AGENT}"; }

opted_in_prompt() { printf 'Do the task in the task doc.\n\nYield handoff: %s' "${1:-$HANDOFF}"; }

# start_transcript <agent> <prompt>: the sub-agent transcript with its first
# record, the dispatch prompt, as Claude Code writes it.
start_transcript() {
  local file
  file="$(subagent_transcript "$1")"
  mkdir -p "${file%/*}"
  jq -nc --arg agent "$1" --arg prompt "$2" --arg session_id "$SID" --arg working_directory "$MAIN_ROOT" \
    '{parentUuid:null, isSidechain:true, agentId:$agent, type:"user",
      message:{role:"user", content:$prompt}, uuid:"record-1",
      cwd:$working_directory, sessionId:$session_id}' >"$file"
}

# append_usage <agent> <context tokens> [output tokens]: an assistant record
# whose input, cache creation and cache read tokens sum to <context tokens>.
append_usage() {
  local input=$(($2 / 100)) creation=$(($2 / 10))
  jq -nc --arg agent "$1" --argjson input "$input" --argjson creation "$creation" \
    --argjson read $(($2 - input - creation)) --argjson output "${3:-1}" \
    '{parentUuid:"record-1", isSidechain:true, agentId:$agent,
      message:{model:"model", id:"message", type:"message", role:"assistant",
        content:[{type:"text", text:"working"}],
        usage:{input_tokens:$input, cache_creation_input_tokens:$creation,
          cache_read_input_tokens:$read, cache_creation:{ephemeral_5m_input_tokens:0},
          output_tokens:$output}},
      type:"assistant", uuid:"record-n"}' >>"$(subagent_transcript "$1")"
}

# filler_line <agent> <bytes>: a user record carrying no usage object, at least
# <bytes> long.
filler_line() {
  {
    printf '{"type":"user","message":{"role":"user","content":"'
    head -c "$2" /dev/zero | tr '\0' x
    printf '"}}\n'
  } >>"$(subagent_transcript "$1")"
}

# opted_in_agent <agent> <tokens> [handoff]: an opted-in transcript at <tokens>.
opted_in_agent() {
  start_transcript "$1" "$(opted_in_prompt "${3:-$HANDOFF}")"
  append_usage "$1" "$2"
}

# payload [agent] [extra-json]: a sub-agent PostToolUse payload for $SID.
payload() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg session_id "$SID" --arg transcript_path "$TRANSCRIPT" --arg working_directory "$MAIN_ROOT" \
    --arg agent "${1:-$AGENT}" --argjson extra "$extra" \
    '{session_id:$session_id, transcript_path:$transcript_path, cwd:$working_directory,
      permission_mode:"default", hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:"ls", description:"List files"},
      tool_response:{stdout:"a\nb", stderr:"", interrupted:false},
      agent_id:$agent, agent_type:"general-purpose"} + $extra'
}

# main_payload [extra-json]: the same payload with no agent_id, as the main
# session sends it.
main_payload() {
  local extra="${1:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg session_id "$SID" --arg transcript_path "$TRANSCRIPT" --arg working_directory "$MAIN_ROOT" \
    --argjson extra "$extra" \
    '{session_id:$session_id, transcript_path:$transcript_path, cwd:$working_directory,
      permission_mode:"default", hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:"ls", description:"List files"},
      tool_response:{stdout:"a\nb", stderr:"", interrupted:false}} + $extra'
}

# invoke <payload> [hook]: run the hook; sets HOOK_STATUS, leaves stdout and
# stderr in files.
invoke() {
  HOOK_STATUS=0
  /bin/bash "${2:-$HOOK}" <<<"$1" >"$TEMPORARY_DIRECTORY/stdout" 2>"$TEMPORARY_DIRECTORY/stderr" || HOOK_STATUS=$?
}

marker_path() { printf '%s/%s.%s' "$MARKER_DIRECTORY" "$SID" "${1:-$AGENT}"; }

# The helpers below return 1 explicitly on every failed check, so a red twin
# can call them in an `&& return 1` probe.

silent_ok() {
  [ "$HOOK_STATUS" -eq 0 ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stdout" ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stderr" ] || return 1
}

# marker_is <agent> <opt-in> <band>: the agent's marker is exactly those two lines.
marker_is() {
  [ -f "$(marker_path "$1")" ] || return 1
  printf 'opt-in: %s\nband: %s\n' "$2" "$3" >"$TEMPORARY_DIRECTORY/expected-marker"
  cmp -s "$(marker_path "$1")" "$TEMPORARY_DIRECTORY/expected-marker" || return 1
}

# silent_unbanded_ok <agent>: silent, and the agent has no band marked (no
# marker at all, or one whose band line is `none`).
silent_unbanded_ok() {
  silent_ok || return 1
  [ ! -e "$(marker_path "$1")" ] && return 0
  [ "$(sed -n 2p "$(marker_path "$1")")" = "band: none" ] || return 1
}

# fires_ok <band> <tokens> [agent] [handoff] [doctrine-file] [window]: one JSON
# value whose decoded additionalContext is the two header lines plus the
# doctrine, byte for byte, and the agent's marker records <band>.
fires_ok() {
  local band="$1" tokens="$2" agent="${3:-$AGENT}" handoff="${4:-$HANDOFF}"
  local doctrine_file="${5:-$DOCTRINE}" window="${6:-$WINDOW}" summary
  [ "$HOOK_STATUS" -eq 0 ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stderr" ] || return 1
  [ "$(jq -s length <"$TEMPORARY_DIRECTORY/stdout" 2>/dev/null)" = 1 ] || return 1
  [ "$(jq -r .hookSpecificOutput.hookEventName <"$TEMPORARY_DIRECTORY/stdout")" = PostToolUse ] || return 1
  jq -j .hookSpecificOutput.additionalContext <"$TEMPORARY_DIRECTORY/stdout" >"$TEMPORARY_DIRECTORY/context" || return 1
  summary="$(gaia_context_summary "$tokens" "$window")" || return 1
  {
    printf 'Sub-agent context checkpoint: %s band reached (%s).\n' "$band" "$summary"
    printf 'Handoff path: %s\n' "$handoff"
    cat "$doctrine_file"
  } >"$TEMPORARY_DIRECTORY/expected"
  cmp -s "$TEMPORARY_DIRECTORY/context" "$TEMPORARY_DIRECTORY/expected" || return 1
  marker_is "$agent" "$handoff" "$band" || return 1
}

# make_mutant <needle> <replacement> <output>: a copy of the hook with every
# line containing <needle> replaced by <replacement> (empty deletes it). Fails
# when nothing matched, so a mutant can never be the unmutated hook.
make_mutant() {
  NEEDLE="$1" REPLACEMENT="$2" awk '
    index($0, ENVIRON["NEEDLE"]) { if (ENVIRON["REPLACEMENT"] != "") print ENVIRON["REPLACEMENT"]; next }
    { print }' "$HOOK_SOURCE_PATH" >"$3"
  cmp -s "$HOOK_SOURCE_PATH" "$3" && return 1
  return 0
}

# folder_snapshot: the marker folder's names and bytes, or `absent`.
folder_snapshot() {
  local file
  if [ ! -e "$MARKER_DIRECTORY" ]; then
    printf 'absent\n'
    return 0
  fi
  for file in "$MARKER_DIRECTORY"/* "$MARKER_DIRECTORY"/.[!.]*; do
    [ -e "$file" ] || continue
    printf '%s %s\n' "${file##*/}" "$(cksum <"$file")"
  done
}

@test "UAT-001: below red is silent; once the last usage record reaches red the next payload emits the header and doctrine and marks red" {
  [ "$WINDOW" -eq 1000000 ]
  opted_in_agent "$AGENT" $((RED - 1))
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" none

  append_usage "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
  cmp "$DOCTRINE" "$REAL_DOCTRINE"
  grep -qxF "Handoff path: $HANDOFF" "$TEMPORARY_DIRECTORY/context"
  grep -qF "red band reached ($(gaia_context_summary "$RED" "$WINDOW"))" "$TEMPORARY_DIRECTORY/context"
}

@test "UAT-001 red twin: a hook copy with the doctrine append removed fails the doctrine equality" {
  make_mutant 'text="Sub-agent context checkpoint:' \
    'text="Sub-agent context checkpoint: $band band reached ($summary)."$'"'"'\n'"'"'"Handoff path: $handoff_path"$'"'"'\n'"'"'"no doctrine"' \
    "$MUTANT"
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)" "$MUTANT"
  [ -s "$TEMPORARY_DIRECTORY/stdout" ]
  fires_ok red "$RED" && return 1

  new_agent
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-002: a not-opted-in agent past skull is silent and its cached marker governs a later opted-in head; the opted-in twin emits skull" {
  local plain_agent="$AGENT"
  start_transcript "$plain_agent" 'Do the task in the task doc.'
  append_usage "$plain_agent" "$SKULL"
  invoke "$(payload "$plain_agent")"
  silent_ok
  marker_is "$plain_agent" none none

  rm "$(subagent_transcript "$plain_agent")"
  opted_in_agent "$plain_agent" "$SKULL"
  invoke "$(payload "$plain_agent")"
  silent_ok
  marker_is "$plain_agent" none none

  new_agent
  opted_in_agent "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
}

@test "UAT-002 red twin: a hook copy that ignores the not-opted-in marker emits on the second run" {
  local plain_agent="$AGENT"
  make_mutant '[ "$marked_opt_in" != none ] || exit 0' '[ "$marked_opt_in" != none ] || marked_opt_in=""' "$MUTANT"
  start_transcript "$plain_agent" 'Do the task in the task doc.'
  append_usage "$plain_agent" "$SKULL"
  invoke "$(payload "$plain_agent")" "$MUTANT"
  silent_ok
  marker_is "$plain_agent" none none

  rm "$(subagent_transcript "$plain_agent")"
  opted_in_agent "$plain_agent" "$SKULL"
  invoke "$(payload "$plain_agent")" "$MUTANT"
  fires_ok skull "$SKULL" "$plain_agent"
}

@test "UAT-003: main payloads with the session transcript present, unreadable, deleted, or an agent_id lookalike in tool_input leave the marker folder untouched; a sub-agent payload emits" {
  printf '{"type":"user","message":{"role":"user","content":"main prompt"}}\n' >"$TRANSCRIPT"
  local before
  before="$(folder_snapshot)"
  [ "$before" = absent ]

  invoke "$(main_payload)"
  silent_ok
  [ "$(folder_snapshot)" = "$before" ]

  chmod 000 "$TRANSCRIPT"
  invoke "$(main_payload)"
  silent_ok
  [ "$(folder_snapshot)" = "$before" ]

  rm -f "$TRANSCRIPT"
  invoke "$(main_payload)"
  silent_ok
  [ "$(folder_snapshot)" = "$before" ]

  invoke "$(main_payload '{"tool_input":{"command":"ls","agent_id":"a00000000000000ff"}}')"
  silent_ok
  [ "$(folder_snapshot)" = "$before" ]

  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-003: a main payload whose tool_input names a live opted-in agent of the session is silent and leaves its marker byte-identical; that agent's own payload emits" {
  opted_in_agent "$AGENT" $((RED - 1))
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" none
  append_usage "$AGENT" "$RED"
  touch -t 202001010000 "$(marker_path)"
  touch -t 202001010001 "$TEMPORARY_DIRECTORY/reference"
  local before
  before="$(folder_snapshot)"

  invoke "$(main_payload "$(jq -nc --arg agent "$AGENT" '{tool_input:{command:"ls", agent_id:$agent}}')")"
  silent_ok
  [ "$(folder_snapshot)" = "$before" ]
  [ -z "$(find "$MARKER_DIRECTORY" -mindepth 1 -newer "$TEMPORARY_DIRECTORY/reference")" ]
  marker_is "$AGENT" "$HANDOFF" none

  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-003 red twin: a hook copy without the opted-in payload confirmation emits on the lookalike" {
  make_mutant '[ "$confirmed" = 1 ] || confirm_payload || exit 0' '' "$MUTANT"
  opted_in_agent "$AGENT" $((RED - 1))
  invoke "$(payload)" "$MUTANT"
  silent_ok
  append_usage "$AGENT" "$RED"
  invoke "$(main_payload "$(jq -nc --arg agent "$AGENT" '{tool_input:{command:"ls", agent_id:$agent}}')")" "$MUTANT"
  [ -s "$TEMPORARY_DIRECTORY/stdout" ]
  fires_ok red "$RED"
}

@test "UAT-004: a missing sub-agent transcript is silent and writes no marker; the transcript created emits red" {
  [ ! -e "$(subagent_transcript)" ]
  invoke "$(payload)"
  silent_ok
  [ ! -e "$(marker_path)" ]

  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-004: a tail read that starts mid-line and ends with a usage record emits red" {
  start_transcript "$AGENT" "$(opted_in_prompt)"
  filler_line "$AGENT" $((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES * 2))
  append_usage "$AGENT" "$RED"
  [ "$(wc -c <"$(subagent_transcript)")" -gt $((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES * 2)) ]
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-004: no usage record anywhere is silent with no band marked; a usage record appended emits red" {
  start_transcript "$AGENT" "$(opted_in_prompt)"
  filler_line "$AGENT" 512
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"no usage"}]}}\n' \
    >>"$(subagent_transcript)"
  invoke "$(payload)"
  silent_unbanded_ok "$AGENT"

  append_usage "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-004: a final line past the tail bound with the usage record inside the widened bound emits red; past the widened bound is silent with no band marked" {
  local inside_agent="$AGENT"
  start_transcript "$inside_agent" "$(opted_in_prompt)"
  append_usage "$inside_agent" "$RED"
  filler_line "$inside_agent" $((GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES + 1024))
  [ "$(wc -c <"$(subagent_transcript "$inside_agent")")" -lt "$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES" ]
  invoke "$(payload "$inside_agent")"
  fires_ok red "$RED" "$inside_agent"

  new_agent
  start_transcript "$AGENT" "$(opted_in_prompt)"
  append_usage "$AGENT" "$RED"
  filler_line "$AGENT" $((GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES + 1024))
  invoke "$(payload)"
  silent_unbanded_ok "$AGENT"
  marker_is "$AGENT" "$HANDOFF" none
}

@test "UAT-004: an unreadable library is silent and writes no marker; the library restored emits red" {
  opted_in_agent "$AGENT" "$RED"
  rm "$FIXTURE_LIBRARY"
  invoke "$(payload)"
  silent_ok
  [ ! -e "$(marker_path)" ]

  cp "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" "$FIXTURE_LIBRARY"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-005: from a red marker, fire emits once, then skull emits once; repeats are silent" {
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" red

  append_usage "$AGENT" "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" fire

  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" skull
}

@test "UAT-005: a jump from below red to skull emits exactly one instruction, for skull, and marks skull" {
  opted_in_agent "$AGENT" $((RED - 1))
  invoke "$(payload)"
  silent_ok
  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" skull
}

@test "UAT-005: on a 1000000 window one token below each band is silent and exactly at it fires; after skull a reading below red is silent" {
  [ "$WINDOW" -eq 1000000 ]
  opted_in_agent "$AGENT" $((RED - 1))
  invoke "$(payload)"
  silent_ok
  append_usage "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"

  append_usage "$AGENT" $((FIRE - 1))
  invoke "$(payload)"
  silent_ok
  append_usage "$AGENT" "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"

  append_usage "$AGENT" $((SKULL - 1))
  invoke "$(payload)"
  silent_ok
  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"

  append_usage "$AGENT" $((RED - 1))
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" skull
}

@test "UAT-006: a 110000 reading emits red under a 200000 main window and is silent under 1000000, no file, an unparseable file and a zero window" {
  load_bands 200000
  [ "$RED" -le 110000 ] && [ "$FIRE" -gt 110000 ]
  write_reading 200000
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  fires_ok red 110000 "$AGENT" "$HANDOFF" "$DOCTRINE" 200000

  new_agent
  write_reading 1000000
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  silent_ok

  new_agent
  rm "$(reading_file)"
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  silent_ok

  new_agent
  printf '{"version":1,"context_window_size":' >"$(reading_file)"
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  silent_ok

  new_agent
  write_reading 0
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  silent_ok

  new_agent
  write_reading 200000
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  fires_ok red 110000 "$AGENT" "$HANDOFF" "$DOCTRINE" 200000
}

@test "UAT-006: under a 200000 main window a 250000 reading takes the default window and is silent; a 200000 reading keeps it and emits skull" {
  write_reading 200000
  opted_in_agent "$AGENT" 250000
  invoke "$(payload)"
  silent_ok

  new_agent
  opted_in_agent "$AGENT" 200000
  invoke "$(payload)"
  fires_ok skull 200000 "$AGENT" "$HANDOFF" "$DOCTRINE" 200000
}

@test "UAT-006: a scratch lib with its default window changed moves the no-file case's band, so the default is read from the lib" {
  rm "$(reading_file)"
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  silent_ok

  sed 's/^GAIA_CONTEXT_DEFAULT_WINDOW=.*/GAIA_CONTEXT_DEFAULT_WINDOW=200000/' \
    "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" >"$FIXTURE_LIBRARY"
  cmp -s "$FIXTURE_LIBRARY" "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" && return 1
  new_agent
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  fires_ok red 110000 "$AGENT" "$HANDOFF" "$DOCTRINE" 200000
}

@test "UAT-020: a 200000-window main reading older than the freshness window still sets the window, so a 110000 reading emits red" {
  write_reading 200000 $(($(date +%s) - GAIA_CONTEXT_FRESH_SECONDS - 60))
  run gaia_context_read "$MAIN_ROOT" "$SID" "$(date +%s)"
  [ "$output" = stale ]
  opted_in_agent "$AGENT" 110000
  invoke "$(payload)"
  fires_ok red 110000 "$AGENT" "$HANDOFF" "$DOCTRINE" 200000
}

@test "UAT-026: an override lowering the line makes a reading below the default red emit red; with the override removed it is silent" {
  local default_red="$RED" override_file="$MAIN_ROOT/.gaia/local/protected/checkpoint-override.json"
  mkdir -p "${override_file%/*}"
  jq -nc --argjson ask_tokens $((default_red / 2)) '{version:1, context_checkpoint:{ask_tokens:$ask_tokens}}' >"$override_file"
  local overridden_line overridden_red overridden_fire reading
  overridden_line="$(gaia_context_effective_line "$MAIN_ROOT" "$WINDOW")"
  read -r _ overridden_red overridden_fire _ <<<"$(gaia_context_bands "$WINDOW" "$overridden_line")"
  [ "$overridden_red" -lt "$default_red" ]
  reading="$overridden_red"
  [ "$reading" -lt "$overridden_fire" ]
  opted_in_agent "$AGENT" "$reading"
  invoke "$(payload)"
  fires_ok red "$reading"

  rm "$override_file"
  new_agent
  opted_in_agent "$AGENT" "$reading"
  invoke "$(payload)"
  silent_unbanded_ok "$AGENT"
}

@test "UAT-008: a missing doctrine and one past its byte budget are silent with no band marked; the real doctrine emits" {
  local budget
  budget="$(sed -n 's/^maximum_doctrine_bytes=\([0-9][0-9]*\)$/\1/p' "$HOOK_SOURCE_PATH")"
  [ -n "$budget" ]

  rm "$DOCTRINE"
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  silent_unbanded_ok "$AGENT"

  head -c $((budget + 1)) /dev/zero | tr '\0' d >"$DOCTRINE"
  [ "$(wc -c <"$DOCTRINE")" -gt "$budget" ]
  invoke "$(payload)"
  silent_unbanded_ok "$AGENT"

  cp "$REAL_DOCTRINE" "$DOCTRINE"
  [ "$(wc -c <"$DOCTRINE")" -le "$budget" ]
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "UAT-023: a doctrine holding a double quote and a backslash encodes to valid JSON whose decoded text equals the file" {
  printf 'Say "yield" and keep C:\\path\\to and a\ttab.\nSecond line.\n' >"$DOCTRINE"
  grep -qF '"' "$DOCTRINE"
  grep -qF "\\" "$DOCTRINE"
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  jq -e . <"$TEMPORARY_DIRECTORY/stdout" >/dev/null
  fires_ok red "$RED"
}

@test "UAT-023 red twins: a hook copy without the backslash or the quote escaping produces invalid JSON or unequal text" {
  printf 'Say "yield" and keep C:\\path\\to.\n' >"$DOCTRINE"
  local needle
  for needle in 'text_line=${text_line//\\/\\\\}' 'text_line=${text_line//\"/\\\"}'; do
    make_mutant "$needle" '' "$MUTANT"
    new_agent
    opted_in_agent "$AGENT" "$RED"
    invoke "$(payload)" "$MUTANT"
    [ -s "$TEMPORARY_DIRECTORY/stdout" ]
    fires_ok red "$RED" && return 1
  done

  new_agent
  opted_in_agent "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "opt-in negatives: placeholder, mid-line, earlier-but-not-final, relative, outside .gaia/local, traversal and escaped paths read as not opted in; valid controls emit" {
  local prompt
  local -a negative_prompts=(
    "Do the task.

Yield handoff: <PLAN_DIR>/handoffs/phase-2-task-subagent-hook-yield-1.md"
    "Do the task.

Yield handoff: {PLAN_DIR}/handoffs/phase-2-task-subagent-hook-yield-1.md"
    "Do the task. Yield handoff: $HANDOFF"
    "Quoted task doc:
Yield handoff: $HANDOFF
End of quote. Do the task."
    "Do the task.

Yield handoff: plans/demo/handoffs/phase-2-task-subagent-hook-yield-1.md"
    "Do the task.

Yield handoff: $TEMPORARY_DIRECTORY/elsewhere/handoffs/phase-2-task-subagent-hook-yield-1.md"
    "Do the task.

Yield handoff: $MAIN_ROOT/.gaia/local/plans/demo/../demo/handoffs/phase-2-task-subagent-hook-yield-1.md"
    "Do the task.

Yield handoff: $MAIN_ROOT/.gaia/local/plans/de\\mo/handoffs/phase-2-task-subagent-hook-yield-1.md"
  )
  for prompt in "${negative_prompts[@]}"; do
    new_agent
    start_transcript "$AGENT" "$prompt"
    append_usage "$AGENT" "$SKULL"
    invoke "$(payload)"
    silent_ok
    marker_is "$AGENT" none none
  done

  new_agent
  opted_in_agent "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"

  new_agent
  start_transcript "$AGENT" "$(opted_in_prompt)
"
  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"

  new_agent
  local planner_handoff="$MAIN_ROOT/.gaia/local/plans/demo/handoffs/planner-yield-2.md"
  opted_in_agent "$AGENT" "$SKULL" "$planner_handoff"
  invoke "$(payload)"
  fires_ok skull "$SKULL" "$AGENT" "$planner_handoff"
}

@test "opt-in negatives: a traversal-shaped agent_id exits with no marker and no output; a well-shaped id emits" {
  local traversal_transcript
  traversal_transcript="$(subagent_transcript '../x')"
  opted_in_agent '../x' "$SKULL"
  [ -f "$traversal_transcript" ]
  invoke "$(payload '../x')"
  silent_ok
  [ "$(folder_snapshot)" = absent ]

  opted_in_agent "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
}

@test "a plan dispatched before the opt-in existed (no Yield handoff line) stays silent at skull; the same prompt with the line emits" {
  local legacy_prompt
  legacy_prompt="You are a task sub-agent for the plan. Your task doc is $MAIN_ROOT/.gaia/local/plans/demo/task-a.md. Read it whole first, then do the task.

How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result."
  start_transcript "$AGENT" "$legacy_prompt"
  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" none none

  new_agent
  start_transcript "$AGENT" "$legacy_prompt

Yield handoff: $HANDOFF"
  append_usage "$AGENT" "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
}

@test "a first record longer than the head bound with the opt-in at its end reads as not opted in; a shorter one is opted in" {
  local filler
  filler="$(head -c "$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES" /dev/zero | tr '\0' x)"
  start_transcript "$AGENT" "$filler

Yield handoff: $HANDOFF"
  append_usage "$AGENT" "$SKULL"
  [ "$(head -n 1 "$(subagent_transcript)" | wc -c)" -gt "$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES" ]
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" none none

  new_agent
  filler="$(head -c $((GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES - 1024)) /dev/zero | tr '\0' x)"
  start_transcript "$AGENT" "$filler

Yield handoff: $HANDOFF"
  append_usage "$AGENT" "$SKULL"
  [ "$(head -n 1 "$(subagent_transcript)" | wc -c)" -lt "$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES" ]
  invoke "$(payload)"
  fires_ok skull "$SKULL"
}

@test "a first record not yet ended by a newline writes no marker; once it is flushed the next call reads it and emits" {
  local file
  file="$(subagent_transcript)"
  mkdir -p "${file%/*}"
  jq -nc --arg prompt "$(opted_in_prompt)" '{type:"user", message:{role:"user", content:$prompt}}' | tr -d '\n' >"$file"
  invoke "$(payload)"
  silent_ok
  [ ! -e "$(marker_path)" ]

  printf '\n' >>"$file"
  append_usage "$AGENT" "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "the band follows input plus cache creation plus cache read tokens: output tokens past a band do not fire; the pinned sum at red does" {
  opted_in_agent "$AGENT" $((RED - 1))
  append_usage "$AGENT" $((RED - 1)) "$SKULL"
  invoke "$(payload)"
  silent_ok
  marker_is "$AGENT" "$HANDOFF" none

  append_usage "$AGENT" "$RED" 1
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "two opted-in agents in one session keep separate markers and fire independently" {
  local first_agent="$AGENT" second_agent second_handoff
  second_handoff="$MAIN_ROOT/.gaia/local/plans/demo/handoffs/phase-2-task-other-yield-1.md"
  new_agent
  second_agent="$AGENT"
  opted_in_agent "$first_agent" "$RED"
  opted_in_agent "$second_agent" $((RED - 1)) "$second_handoff"

  invoke "$(payload "$first_agent")"
  fires_ok red "$RED" "$first_agent"
  invoke "$(payload "$second_agent")"
  silent_ok
  marker_is "$second_agent" "$second_handoff" none

  append_usage "$second_agent" "$FIRE"
  invoke "$(payload "$second_agent")"
  fires_ok fire "$FIRE" "$second_agent" "$second_handoff"
  marker_is "$first_agent" "$HANDOFF" red

  append_usage "$first_agent" "$FIRE"
  invoke "$(payload "$first_agent")"
  fires_ok fire "$FIRE" "$first_agent"
  marker_is "$second_agent" "$second_handoff" fire
}

# The hook array guard and the other hook lints scan the whole tree, so they
# run through .gaia/tests/shell-lint.sh rather than here.
@test "the hook is mode 755 and shellcheck-clean" {
  local hook_path="$REPO_ROOT/.claude/hooks/context-checkpoint-subagent.sh"
  [ -x "$hook_path" ]
  [ -n "$(find "$hook_path" -perm 755)" ]
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  shellcheck "$hook_path"
}
