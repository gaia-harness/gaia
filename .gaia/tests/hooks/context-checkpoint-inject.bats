#!/usr/bin/env bats

# .claude/hooks/context-checkpoint-inject.sh: after every tool call of a main
# session, injects the context checkpoint (three header lines, then
# .claude/doctrine/context-checkpoint.md verbatim) the first time the fresh
# reading is at or past red, and once more at each of fire and skull; silent for
# sub-agents, stale or missing readings, marked bands, an oversize or missing
# doctrine file, and a session its branch's audit-loop state file shows
# mid-loop (a live unit, or an answered checkpoint with no later unit).
#
# Every fixture repo carries its own copy of the hook, the libraries it loads
# and the real doctrine file. HOOK_SOURCE_PATH points the suite at another copy
# of the hook; it defaults to the real hook. Token values come from the lib at
# test time, never from a literal here, so the suite follows the lib's bands.
#
# Each negative case runs in the same fixture as a positive control that differs
# by one variable. The hook runs under /bin/bash, the shell whose cost budget it
# is held to.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-inject.bats < /dev/null

# The jq programs are single-quoted so their `$` reaches jq.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/context-checkpoint-inject.sh}"
  REAL_DOCTRINE="$REPO_ROOT/.claude/doctrine/context-checkpoint.md"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/usage-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  mkdir -p "$TEMPORARY_DIRECTORY/norepo"
  cd "$TEMPORARY_DIRECTORY/norepo" || return 1
  alf_init
  MAIN_ROOT="$ALF_ROOT"
  install_hook "$MAIN_ROOT"
  session_counter=0
  new_session
  WINDOW=1000000
  load_bands "$WINDOW"
}

# install_hook <root>: the hook, its libraries and the real doctrine under <root>.
install_hook() {
  local root="$1" library_file
  mkdir -p "$root/.claude/hooks" "$root/.claude/doctrine" "$root/.gaia/scripts"
  cp "$HOOK_SOURCE_PATH" "$root/.claude/hooks/context-checkpoint-inject.sh"
  chmod 755 "$root/.claude/hooks/context-checkpoint-inject.sh"
  for library_file in context-checkpoint-lib.sh main-root-lib.sh branch-name-lib.sh usage-lib.sh \
    audit-loop-state-lib.sh audit-key-lib.sh exclusive-lock-lib.sh branch-authorship-lib.sh filing-outcomes-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$root/.gaia/scripts/$library_file"
  done
  cp "$REAL_DOCTRINE" "$root/.claude/doctrine/context-checkpoint.md"
  HOOK="$root/.claude/hooks/context-checkpoint-inject.sh"
  DOCTRINE="$root/.claude/doctrine/context-checkpoint.md"
}

# new_session: a fresh UUID-shaped $SID, so no earlier marker applies.
new_session() {
  session_counter=$((session_counter + 1))
  SID="$(printf '%08x-0000-4000-8000-%012x' "$session_counter" "$session_counter")"
}

# load_bands <window>: YELLOW RED FIRE SKULL token values from the lib.
load_bands() {
  local line
  line="$(gaia_context_effective_line "$MAIN_ROOT" "$1")"
  read -r YELLOW RED FIRE SKULL <<<"$(gaia_context_bands "$1" "$line")"
  [ "$RED" -gt 0 ] && [ "$FIRE" -gt "$RED" ] && [ "$SKULL" -gt "$FIRE" ] && [ "$YELLOW" -lt "$RED" ]
}

# write_reading <tokens> [window] [epoch]: the statusline's reading for $SID.
write_reading() {
  gaia_context_write "$MAIN_ROOT" "$SID" 1 "$1" "${2:-$WINDOW}" "${3:-$(date +%s)}"
}

# payload [cwd] [extra-json]: a PostToolUse payload for $SID.
payload() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg session_id "$SID" --arg working_directory "${1:-$MAIN_ROOT}" --argjson extra "$extra" \
    '{session_id:$session_id, transcript_path:"/tmp/transcript.jsonl", cwd:$working_directory,
      permission_mode:"default", hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:"ls", description:"List files"},
      tool_response:{stdout:"a\nb", stderr:"", interrupted:false}} + $extra'
}

session_start_payload() {
  jq -nc --arg session_id "$SID" --arg working_directory "${1:-$MAIN_ROOT}" \
    '{session_id:$session_id, transcript_path:"/tmp/transcript.jsonl", cwd:$working_directory,
      hook_event_name:"SessionStart", source:"compact"}'
}

# invoke <payload> [hook]: run the hook; sets HOOK_STATUS, leaves stdout and
# stderr in files.
invoke() {
  HOOK_STATUS=0
  /bin/bash "${2:-$HOOK}" <<<"$1" >"$TEMPORARY_DIRECTORY/stdout" 2>"$TEMPORARY_DIRECTORY/stderr" || HOOK_STATUS=$?
}

marker_path() { printf '%s/.gaia/local/cache/context-checkpoint/%s' "$MAIN_ROOT" "$SID"; }
session_save_path() { printf '%s/.gaia/local/runs/session-%s/STATE.md' "$MAIN_ROOT" "$SID"; }

# The helpers below return 1 explicitly on every failed check, so a case-table
# row can report its own label through `|| { ...; return 1; }`, where set -e
# would not stop at a bare failed `[ ]` inside the helper.

silent_ok() {
  [ "$HOOK_STATUS" -eq 0 ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stdout" ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stderr" ] || return 1
}

silent_unmarked_ok() {
  silent_ok || return 1
  [ ! -e "$(marker_path)" ] || return 1
}

# fires_ok <band> <tokens> [save-path] [doctrine-file] [window]: one JSON value
# whose decoded additionalContext is the three header lines plus the doctrine,
# byte for byte, and the marker holds <band>.
fires_ok() {
  local band="$1" tokens="$2" save_path="${3:-}" doctrine_file="${4:-$DOCTRINE}" window="${5:-$WINDOW}" summary
  [ -n "$save_path" ] || save_path="$(session_save_path)"
  [ "$HOOK_STATUS" -eq 0 ] || return 1
  [ ! -s "$TEMPORARY_DIRECTORY/stderr" ] || return 1
  [ "$(jq -s length <"$TEMPORARY_DIRECTORY/stdout" 2>/dev/null)" = 1 ] || return 1
  [ "$(jq -r .hookSpecificOutput.hookEventName <"$TEMPORARY_DIRECTORY/stdout")" = PostToolUse ] || return 1
  jq -j .hookSpecificOutput.additionalContext <"$TEMPORARY_DIRECTORY/stdout" >"$TEMPORARY_DIRECTORY/context" || return 1
  summary="$(gaia_context_summary "$tokens" "$window")" || return 1
  {
    printf 'Context checkpoint: %s band reached (%s).\n' "$band" "$summary"
    printf 'Session id: %s\n' "$SID"
    printf 'Save path: %s\n' "$save_path"
    cat "$doctrine_file"
  } >"$TEMPORARY_DIRECTORY/expected"
  cmp "$TEMPORARY_DIRECTORY/context" "$TEMPORARY_DIRECTORY/expected" || return 1
  [ "$(cat "$(marker_path)")" = "$band" ] || return 1
}

# oracle_save_path <cwd>: the save path built from gaia_loop_key and
# gaia_usage_default_branch, the functions the hook reproduces with file reads.
oracle_save_path() {
  local key default_branch root
  root="$(gaia_resolve_main_root "$1" 2>/dev/null)" || return 1
  key="$(gaia_loop_key "$1" 2>/dev/null)" || key=""
  default_branch="$(gaia_usage_default_branch "$1" 2>/dev/null)" || default_branch=""
  if [ -n "$key" ] && [ "$key" != "$default_branch" ]; then
    printf '%s/STATE.md\n' "$(gaia_loop_run_directory "$root" "$key")"
  else
    printf '%s/.gaia/local/runs/session-%s/STATE.md\n' "$root" "$SID"
  fi
}

# A PATH shim whose git and jq append their name to a call log, then run the
# real binary.
make_shim() {
  SHIM="$TEMPORARY_DIRECTORY/shim"
  CALL_LOG="$TEMPORARY_DIRECTORY/calls.log"
  mkdir -p "$SHIM"
  : >"$CALL_LOG"
  local tool real_path
  for tool in git jq; do
    real_path="$(command -v "$tool")"
    printf '#!/bin/sh\nprintf "%%s\\n" %s >>"%s"\nexec "%s" "$@"\n' "$tool" "$CALL_LOG" "$real_path" >"$SHIM/$tool"
    chmod 755 "$SHIM/$tool"
  done
}

invoke_shimmed() {
  : >"$CALL_LOG"
  PATH="$SHIM:$PATH" invoke "$@"
}

logged_count() {
  local count
  count="$(grep -c -x "$1" "$CALL_LOG")" || true
  printf '%s\n' "${count:-0}"
}

# fork_budget_ok: no git, and at most the two jq calls of a firing path with no
# override file (the reading, then the confirm and audit-loop read).
fork_budget_ok() {
  [ "$(logged_count git)" -eq 0 ] || return 1
  [ "$(logged_count jq)" -le 2 ] || return 1
}

seed_loop_entry() {
  # <units|checkpoints> <session id>
  alf_seed_state '{}'
  if [ "$1" = units ]; then
    alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, after_checkpoint: 0,
      admitted_on: "context", session_id: $session_id}]' --arg session_id "$2"
  else
    alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: $session_id}]' \
      --arg session_id "$2"
  fi
}

# mark_band <band>: plant $SID's marker as already holding <band>.
mark_band() {
  mkdir -p "${MAIN_ROOT}/.gaia/local/cache/context-checkpoint"
  printf '%s\n' "$1" >"$(marker_path)"
}

# Each row takes a fresh session id, so no earlier row's reading or marker applies.
@test "band transitions emit once per band and mark it: first crossing, marked red below fire, red to fire to skull, jump to fire, jump to skull" {
  local label
  for label in first-crossing marked-red-below-fire red-fire-skull jump-to-fire jump-to-skull; do
    new_session
    case "$label" in
      first-crossing)
        [ "$YELLOW" -lt "$RED" ] || { echo "case $label: yellow $YELLOW not below red $RED"; return 1; }
        write_reading "$YELLOW"
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: yellow not silent and unmarked"; return 1; }
        write_reading "$RED"
        invoke "$(payload)"
        fires_ok red "$RED" || { echo "case $label: red did not fire"; return 1; }
        cmp "$DOCTRINE" "$REAL_DOCTRINE" || { echo "case $label: doctrine differs from the shipped file"; return 1; }
        grep -qxF "Session id: $SID" "$TEMPORARY_DIRECTORY/context" || { echo "case $label: no session id line"; return 1; }
        ;;
      marked-red-below-fire)
        mark_band red
        write_reading $((FIRE - 1))
        invoke "$(payload)"
        silent_ok || { echo "case $label: below fire not silent"; return 1; }
        [ "$(cat "$(marker_path)")" = red ] || { echo "case $label: marker changed below fire"; return 1; }
        write_reading "$FIRE"
        invoke "$(payload)"
        fires_ok fire "$FIRE" || { echo "case $label: fire did not fire"; return 1; }
        ;;
      red-fire-skull)
        mark_band red
        write_reading "$FIRE"
        invoke "$(payload)"
        fires_ok fire "$FIRE" || { echo "case $label: fire did not fire"; return 1; }
        invoke "$(payload)"
        silent_ok || { echo "case $label: repeated fire not silent"; return 1; }
        [ "$(cat "$(marker_path)")" = fire ] || { echo "case $label: marker not fire"; return 1; }
        write_reading "$SKULL"
        invoke "$(payload)"
        fires_ok skull "$SKULL" || { echo "case $label: skull did not fire"; return 1; }
        invoke "$(payload)"
        silent_ok || { echo "case $label: repeated skull not silent"; return 1; }
        [ "$(cat "$(marker_path)")" = skull ] || { echo "case $label: marker not skull"; return 1; }
        ;;
      jump-to-fire)
        write_reading $((RED - 1))
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: below red not silent and unmarked"; return 1; }
        write_reading "$FIRE"
        invoke "$(payload)"
        fires_ok fire "$FIRE" || { echo "case $label: fire did not fire"; return 1; }
        write_reading "$RED"
        invoke "$(payload)"
        silent_ok || { echo "case $label: red after fire not silent"; return 1; }
        [ "$(cat "$(marker_path)")" = fire ] || { echo "case $label: marker not fire"; return 1; }
        ;;
      jump-to-skull)
        write_reading $((RED - 1))
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: below red not silent and unmarked"; return 1; }
        write_reading "$SKULL"
        invoke "$(payload)"
        fires_ok skull "$SKULL" || { echo "case $label: skull did not fire"; return 1; }
        invoke "$(payload)"
        silent_ok || { echo "case $label: repeated skull not silent"; return 1; }
        [ "$(cat "$(marker_path)")" = skull ] || { echo "case $label: marker not skull"; return 1; }
        ;;
    esac
  done
}

@test "a sub-agent payload past red is silent, unmarked and parse-free; the same payload without agent_id emits" {
  make_shim
  write_reading "$RED"
  invoke_shimmed "$(payload "$MAIN_ROOT" '{"agent_id":"agent-1","agent_type":"Explore"}')"
  silent_unmarked_ok
  [ ! -s "$CALL_LOG" ]

  invoke_shimmed "$(payload)"
  fires_ok red "$RED"
}

# Each row cuts its own branch off main, so its state file is its own, and takes
# a fresh session id. A row whose first call is silent then emits after one
# change shares that silent call's fixture with its positive control.
@test "audit-loop state: a live unit silences until it returns, an unanswered checkpoint emits, another branch's state or other session ids never silence, an answered checkpoint silences without a later unit and emits with a returned one" {
  local label run_directory
  for label in live-unit unanswered-checkpoint other-branch other-sessions answered-no-later-unit answered-then-returned-unit; do
    new_session
    alf_git checkout -q main || { echo "case $label: checkout main failed"; return 1; }
    case "$label" in
      live-unit)
        alf_branch feat/loop-units
        run_directory="$(gaia_loop_run_directory "$MAIN_ROOT" feat/loop-units)"
        seed_loop_entry units "$SID"
        write_reading "$RED"
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: live unit did not silence"; return 1; }
        mkdir -p "$run_directory"
        printf '{}\n' >"$run_directory/unit-1.json"
        invoke "$(payload)"
        fires_ok red "$RED" "$run_directory/STATE.md" || { echo "case $label: returned unit did not emit"; return 1; }
        ;;
      unanswered-checkpoint)
        alf_branch feat/loop-checkpoints
        seed_loop_entry checkpoints "$SID"
        write_reading "$RED"
        invoke "$(payload)"
        fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/loop-checkpoints/STATE.md" || { echo "case $label: did not emit"; return 1; }
        ;;
      other-branch)
        alf_branch feat/other-branch
        seed_loop_entry units "$SID"
        alf_git checkout -q -b feat/this-branch
        [ -f "$ALF_STATE" ] || { echo "case $label: other branch state file missing"; return 1; }
        write_reading "$RED"
        invoke "$(payload)"
        fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/this-branch/STATE.md" || { echo "case $label: did not emit"; return 1; }
        ;;
      other-sessions)
        alf_branch feat/other-sessions
        seed_loop_entry units other-session
        alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: "other-session"}]'
        write_reading "$RED"
        invoke "$(payload)"
        fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/other-sessions/STATE.md" || { echo "case $label: did not emit"; return 1; }
        ;;
      answered-no-later-unit)
        alf_branch feat/answered
        seed_loop_entry units other-session
        alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: $session_id}]
          | .allowance.answers = [{checkpoint: 1, kind: "grant", n: 3, at: "2026-01-01T00:00:00Z", session_id: $session_id}]' \
          --arg session_id "$SID"
        write_reading "$RED"
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: answered checkpoint did not silence"; return 1; }
        alf_state_edit '.history.checkpoints[0].session_id = "other-session"'
        invoke "$(payload)"
        fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/answered/STATE.md" || { echo "case $label: another session id did not emit"; return 1; }
        ;;
      answered-then-returned-unit)
        alf_branch feat/answered-then-unit
        run_directory="$(gaia_loop_run_directory "$MAIN_ROOT" feat/answered-then-unit)"
        alf_seed_state '{}'
        alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: $session_id}]
          | .allowance.answers = [{checkpoint: 1, kind: "grant", n: 3, at: "2026-01-01T00:00:00Z", session_id: $session_id}]
          | .history.units = [{unit: 2, start_round: 4, k: 3, through_round: 6, after_checkpoint: 1,
              admitted_on: "grant", session_id: $session_id}]' --arg session_id "$SID"
        mkdir -p "$run_directory"
        printf '{}\n' >"$run_directory/unit-2.json"
        write_reading "$RED"
        invoke "$(payload)"
        fires_ok red "$RED" "$run_directory/STATE.md" || { echo "case $label: did not emit"; return 1; }
        ;;
    esac
  done
}

# Each row takes a fresh session id, so its reading file and marker are its own.
@test "a missing, stale, future, unparseable or zero-window reading, or no jq on PATH, is silent; a fresh reading, or jq added, in the same fixture emits" {
  local label reading_file tool_directory tool
  for label in missing stale future unparseable zero-window no-jq; do
    new_session
    case "$label" in
      missing) ;;
      stale) write_reading "$RED" "$WINDOW" $(($(date +%s) - GAIA_CONTEXT_FRESH_SECONDS - 60)) ;;
      future) write_reading "$RED" "$WINDOW" $(($(date +%s) + 3600)) ;;
      unparseable)
        reading_file="$(gaia_context_file "$MAIN_ROOT" "$SID")"
        mkdir -p "${reading_file%/*}"
        printf '{"version":1,"used_tokens":' >"$reading_file"
        ;;
      zero-window) write_reading "$RED" 0 ;;
    esac
    if [ "$label" = no-jq ]; then
      tool_directory="$TEMPORARY_DIRECTORY/tools"
      mkdir -p "$tool_directory"
      for tool in cat date mkdir mv rm; do ln -s "$(command -v "$tool")" "$tool_directory/$tool"; done
      write_reading "$RED"
      PATH="$tool_directory" invoke "$(payload)"
      silent_unmarked_ok || { echo "case $label: not silent and unmarked"; return 1; }
      ln -s "$(command -v jq)" "$tool_directory/jq"
      PATH="$tool_directory" invoke "$(payload)"
      fires_ok red "$RED" || { echo "case $label: jq added did not emit"; return 1; }
      continue
    fi
    invoke "$(payload)"
    silent_unmarked_ok || { echo "case $label: not silent and unmarked"; return 1; }
    write_reading "$RED"
    invoke "$(payload)"
    fires_ok red "$RED" || { echo "case $label: fresh reading did not emit"; return 1; }
  done
}

@test "the checkpoint off: an override ask_tokens of 0 is silent and unmarked past red; removing it emits" {
  local override_file="$MAIN_ROOT/.gaia/local/protected/checkpoint-override.json"
  new_session
  mkdir -p "${override_file%/*}"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":0}}\n' >"$override_file"
  write_reading "$RED"
  invoke "$(payload)"
  silent_unmarked_ok || { echo "off: not silent and unmarked"; return 1; }
  rm "$override_file"
  invoke "$(payload)"
  fires_ok red "$RED" || { echo "override removed: did not emit"; return 1; }
}

@test "save path: the default branch and a detached HEAD take the session form; a feature branch takes its run folder" {
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/session-$SID/STATE.md"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$(session_save_path)" ]
  [ ! -e "$MAIN_ROOT/.gaia/local/runs" ]

  new_session
  alf_git checkout -q --detach
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/session-$SID/STATE.md"

  new_session
  alf_git checkout -q -b feat/save-path-control
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/save-path-control/STATE.md"
}

# Both rows share the fixture's doctrine file, each with a fresh session id; the
# over-cap row restores the shipped file when done.
@test "a missing doctrine or one a byte over the cap is silent and unmarked; the shipped file, or one exactly at the cap, emits" {
  local label size
  for label in missing over-cap; do
    new_session
    write_reading "$RED"
    case "$label" in
      missing)
        mv "$DOCTRINE" "$DOCTRINE.saved"
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: not silent and unmarked"; return 1; }
        mv "$DOCTRINE.saved" "$DOCTRINE"
        invoke "$(payload)"
        fires_ok red "$RED" || { echo "case $label: shipped file did not emit"; return 1; }
        ;;
      over-cap)
        size="$(wc -c <"$REAL_DOCTRINE" | tr -d ' ')"
        [ "$size" -lt 3584 ] || { echo "case $label: shipped doctrine is $size bytes, not under the cap"; return 1; }
        cp "$REAL_DOCTRINE" "$DOCTRINE"
        printf '%*s' $((3585 - size)) '' | tr ' ' x >>"$DOCTRINE"
        [ "$(wc -c <"$DOCTRINE" | tr -d ' ')" -eq 3585 ] || { echo "case $label: padding missed 3585"; return 1; }
        invoke "$(payload)"
        silent_unmarked_ok || { echo "case $label: over the cap not silent and unmarked"; return 1; }
        cp "$REAL_DOCTRINE" "$DOCTRINE"
        printf '%*s' $((3584 - size)) '' | tr ' ' x >>"$DOCTRINE"
        [ "$(wc -c <"$DOCTRINE" | tr -d ' ')" -eq 3584 ] || { echo "case $label: padding missed 3584"; return 1; }
        invoke "$(payload)"
        fires_ok red "$RED" || { echo "case $label: exactly at the cap did not emit"; return 1; }
        cp "$REAL_DOCTRINE" "$DOCTRINE"
        ;;
    esac
  done
}

@test "compaction keeps the marker: SessionStart compact is silent and leaves it byte-identical; fire emits later" {
  mkdir -p "${MAIN_ROOT}/.gaia/local/cache/context-checkpoint"
  printf 'red\n' >"$(marker_path)"
  cp "$(marker_path)" "$TEMPORARY_DIRECTORY/marker-before"
  write_reading "$FIRE"
  invoke "$(session_start_payload)"
  silent_ok
  cmp "$(marker_path)" "$TEMPORARY_DIRECTORY/marker-before"

  write_reading $((FIRE - 1))
  invoke "$(payload)"
  silent_ok
  cmp "$(marker_path)" "$TEMPORARY_DIRECTORY/marker-before"

  write_reading "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"
}

@test "a linked worktree reads and marks under the main root; the main checkout then sees the band as marked" {
  local linked="$TEMPORARY_DIRECTORY/linked"
  alf_git worktree add -q -b feat/linked "$linked"
  [ "$(gaia_resolve_main_root "$linked")" = "$MAIN_ROOT" ]
  write_reading "$RED"
  invoke "$(payload "$linked")"
  fires_ok red "$RED" "$(oracle_save_path "$linked")"
  [ "$(oracle_save_path "$linked")" = "$MAIN_ROOT/.gaia/local/runs/feat/linked/STATE.md" ]
  [ -f "$(gaia_resolve_main_root "$linked")/.gaia/local/cache/context-checkpoint/$SID" ]
  [ ! -e "$linked/.gaia" ]

  invoke "$(payload "$MAIN_ROOT")"
  silent_ok
}

@test "the sub-agent and skull-marked paths start no git and no jq; a firing payload does" {
  make_shim
  write_reading "$SKULL"
  invoke_shimmed "$(payload "$MAIN_ROOT" '{"agent_id":"agent-1"}')"
  silent_unmarked_ok
  [ ! -s "$CALL_LOG" ]

  mkdir -p "${MAIN_ROOT}/.gaia/local/cache/context-checkpoint"
  printf 'skull\n' >"$(marker_path)"
  invoke_shimmed "$(payload)"
  silent_ok
  [ ! -s "$CALL_LOG" ]

  new_session
  write_reading "$RED"
  invoke_shimmed "$(payload)"
  fires_ok red "$RED"
  [ -s "$CALL_LOG" ]
}

@test "fork budget: the firing and in-audit-loop paths start no git and at most two jq" {
  make_shim
  alf_branch feat/budget
  write_reading "$RED"
  invoke_shimmed "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/budget/STATE.md"
  fork_budget_ok
  [ "$(logged_count jq)" -ge 1 ]

  new_session
  seed_loop_entry units "$SID"
  write_reading "$RED"
  invoke_shimmed "$(payload)"
  silent_unmarked_ok
  fork_budget_ok

  mkdir -p "$(gaia_loop_run_directory "$MAIN_ROOT" feat/budget)"
  printf '{}\n' >"$(gaia_loop_run_directory "$MAIN_ROOT" feat/budget)/unit-1.json"
  invoke_shimmed "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/budget/STATE.md"
  fork_budget_ok
}

# The rows rewrite refs, the remote and the origin, so the fixture's repo and
# origin are copied once before the loop and restored before every row: one
# fixture build instead of one per row, at the same absolute paths the repo's
# config and the hook's reads expect.
@test "branch derivation matches gaia_loop_key and the default-branch rules: a feature branch, main loose beside master, main only in packed-refs, origin/HEAD naming develop, master-only, a detached HEAD, a normalized name" {
  local label expected pristine="$TEMPORARY_DIRECTORY/pristine"
  mkdir -p "$pristine"
  cp -Rp "$MAIN_ROOT" "$pristine/repo"
  cp -Rp "$ALF_ORIGIN" "$pristine/origin.git"
  for label in feature loose-main packed-main origin-head-develop master-only detached normalized; do
    rm -rf "$MAIN_ROOT" "$ALF_ORIGIN"
    cp -Rp "$pristine/repo" "$MAIN_ROOT"
    cp -Rp "$pristine/origin.git" "$ALF_ORIGIN"
    new_session
    expected="$(session_save_path)"
    case "$label" in
      feature)
        alf_git checkout -q -b feat/derive-feature
        expected="$MAIN_ROOT/.gaia/local/runs/feat/derive-feature/STATE.md"
        ;;
      loose-main)
        alf_git remote set-head origin -d
        alf_git branch master
        [ -f "$MAIN_ROOT/.git/refs/heads/main" ] || { echo "case $label: main is not a loose ref"; return 1; }
        [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = main ] || { echo "case $label: default is not main"; return 1; }
        ;;
      packed-main)
        alf_git remote set-head origin -d
        alf_git pack-refs --all
        alf_git branch master
        [ ! -e "$MAIN_ROOT/.git/refs/heads/main" ] || { echo "case $label: main is still a loose ref"; return 1; }
        [ -f "$MAIN_ROOT/.git/refs/heads/master" ] || { echo "case $label: master is not a loose ref"; return 1; }
        grep -q ' refs/heads/main$' "$MAIN_ROOT/.git/packed-refs" || { echo "case $label: main not in packed-refs"; return 1; }
        [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = main ] || { echo "case $label: default is not main"; return 1; }
        ;;
      origin-head-develop)
        alf_git push -q origin main:develop
        alf_git fetch -q origin
        alf_git remote set-head origin develop >/dev/null
        [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = develop ] || { echo "case $label: default is not develop"; return 1; }
        expected="$MAIN_ROOT/.gaia/local/runs/main/STATE.md"
        ;;
      master-only)
        alf_git remote remove origin
        alf_git branch -m main master
        [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = master ] || { echo "case $label: default is not master"; return 1; }
        ;;
      detached)
        alf_git checkout -q --detach
        ;;
      normalized)
        alf_git checkout -q -b 'worktree-feat+derive-normalized'
        expected="$MAIN_ROOT/.gaia/local/runs/feat/derive-normalized/STATE.md"
        ;;
    esac
    write_reading "$RED"
    invoke "$(payload)"
    fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")" || { echo "case $label: save path differs from the oracle's $(oracle_save_path "$MAIN_ROOT")"; return 1; }
    [ "$(oracle_save_path "$MAIN_ROOT")" = "$expected" ] || { echo "case $label: oracle gave $(oracle_save_path "$MAIN_ROOT"), expected $expected"; return 1; }
  done
}

@test "JSON encoding: a main root with a space and a doctrine with quote and backslash decode byte for byte" {
  local spaced_root="$TEMPORARY_DIRECTORY/main root/repo"
  mkdir -p "$spaced_root"
  git init -q -b main "$spaced_root"
  git -C "$spaced_root" commit -q --allow-empty -m init
  MAIN_ROOT="$(cd "$spaced_root" && pwd -P)"
  install_hook "$MAIN_ROOT"
  printf 'A line with a "quote", a back\\slash and a trailing \\\n' >>"$DOCTRINE"
  grep -qF '"quote"' "$DOCTRINE"
  grep -qF 'back\slash' "$DOCTRINE"
  [ "$(wc -c <"$DOCTRINE" | tr -d ' ')" -le 3584 ]
  write_reading "$RED"
  invoke "$(payload "$MAIN_ROOT")"
  fires_ok red "$RED"
  grep -qF "Save path: $TEMPORARY_DIRECTORY/main root/repo/.gaia/local/runs/session-$SID/STATE.md" "$TEMPORARY_DIRECTORY/context"
}

# The band values for a 1M and a 200k window at the shipped line, plus the
# lib's token constants, as a grep -wE alternation.
band_value_pattern() {
  local window line values=() pattern
  for window in 1000000 200000; do
    line="$(gaia_context_line "$window" "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT")"
    # shellcheck disable=SC2207 # four space-separated integers
    values+=($(gaia_context_bands "$window" "$line"))
  done
  values+=("$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" "$GAIA_CONTEXT_YELLOW_TOKENS")
  [ "${#values[@]}" -eq 10 ] || return 1
  pattern="$(IFS='|'; printf '%s' "${values[*]}")"
  printf '%s\n' "$pattern"
}

@test "the hook spells no band value" {
  local pattern
  pattern="$(band_value_pattern)"
  [ -n "$pattern" ]
  grep -nwE "$pattern" "$HOOK_SOURCE_PATH" && return 1
  true
}

@test "the hook is executable" {
  [ -x "$REPO_ROOT/.claude/hooks/context-checkpoint-inject.sh" ]
}
