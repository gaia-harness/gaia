#!/usr/bin/env bats

# .claude/hooks/context-checkpoint-inject.sh: after every tool call of a main
# session, injects the context checkpoint (three header lines, then
# .claude/doctrine/context-checkpoint.md verbatim) the first time the fresh
# reading is at or past red, and once more at each of fire and skull; silent for
# sub-agents, stale or missing readings, marked bands, an oversize or missing
# doctrine file, and a session its branch's audit-loop state file records.
#
# Every fixture repo carries its own copy of the hook, the libraries it loads
# and the real doctrine file. HOOK_SOURCE_PATH points the suite at another copy
# of the hook (a mutated scratch copy proves the cases can go red); it defaults
# to the real hook. Token values come from the lib at test time, never from a
# literal here, so the suite follows the lib's bands.
#
# Each negative case runs in the same fixture as a positive control that differs
# by one variable. The hook runs under /bin/bash, the shell whose cost budget it
# is held to.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-inject.bats < /dev/null

# The jq programs and the hook lines the mutants match are single-quoted so
# their `$` reaches jq or the match literally.
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
    audit-loop-state-lib.sh audit-key-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$root/.gaia/scripts/$library_file"
  done
  cp "$REAL_DOCTRINE" "$root/.claude/doctrine/context-checkpoint.md"
  HOOK="$root/.claude/hooks/context-checkpoint-inject.sh"
  # Beside the hook, so a mutant loads the same libraries and doctrine.
  MUTANT="$root/.claude/hooks/mutant.sh"
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

# The helpers below return 1 explicitly on every failed check, so a red twin
# can call them in an `&& return 1` probe.

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

@test "first crossing: a yellow reading is silent, then red emits header plus doctrine and marks red" {
  [ "$YELLOW" -lt "$RED" ]
  write_reading "$YELLOW"
  invoke "$(payload)"
  silent_unmarked_ok

  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
  cmp "$DOCTRINE" "$REAL_DOCTRINE"
  grep -qxF "Session id: $SID" "$TEMPORARY_DIRECTORY/context"
}

@test "a marked red band stays silent below fire; past fire in the same fixture emits" {
  mkdir -p "${MAIN_ROOT}/.gaia/local/cache/context-checkpoint"
  printf 'red\n' >"$(marker_path)"
  write_reading $((FIRE - 1))
  invoke "$(payload)"
  silent_ok
  [ "$(cat "$(marker_path)")" = red ]

  write_reading "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"
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

@test "a units entry carrying this session in the cwd branch's state file silences; another session id emits" {
  alf_branch feat/loop-units
  seed_loop_entry units "$SID"
  write_reading "$RED"
  invoke "$(payload)"
  silent_unmarked_ok

  alf_state_edit '.history.units[0].session_id = "other-session"'
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/loop-units/STATE.md"
}

@test "a checkpoints entry carrying this session in the cwd branch's state file silences; another session id emits" {
  alf_branch feat/loop-checkpoints
  seed_loop_entry checkpoints "$SID"
  write_reading "$RED"
  invoke "$(payload)"
  silent_unmarked_ok

  alf_state_edit '.history.checkpoints[0].session_id = "other-session"'
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/loop-checkpoints/STATE.md"
}

@test "a missing reading is silent; a fresh reading in the same fixture emits" {
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "a stale reading is silent; a fresh reading in the same fixture emits" {
  write_reading "$RED" "$WINDOW" $(($(date +%s) - GAIA_CONTEXT_FRESH_SECONDS - 60))
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "a future reading past the skew is silent; a fresh reading in the same fixture emits" {
  write_reading "$RED" "$WINDOW" $(($(date +%s) + 3600))
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "an unparseable reading is silent; a fresh reading in the same fixture emits" {
  local reading_file
  reading_file="$(gaia_context_file "$MAIN_ROOT" "$SID")"
  mkdir -p "${reading_file%/*}"
  printf '{"version":1,"used_tokens":' >"$reading_file"
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "a fresh reading with a zero window is silent; a positive window in the same fixture emits" {
  write_reading "$RED" 0
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "no jq on PATH is silent; the same PATH with jq emits" {
  local tool_directory="$TEMPORARY_DIRECTORY/tools" tool
  mkdir -p "$tool_directory"
  for tool in cat date mkdir mv rm; do ln -s "$(command -v "$tool")" "$tool_directory/$tool"; done
  write_reading "$RED"
  PATH="$tool_directory" invoke "$(payload)"
  silent_unmarked_ok

  ln -s "$(command -v jq)" "$tool_directory/jq"
  PATH="$tool_directory" invoke "$(payload)"
  fires_ok red "$RED"
}

@test "from a red marker: fire emits once and marks fire, then skull emits once; repeats are silent" {
  mkdir -p "${MAIN_ROOT}/.gaia/local/cache/context-checkpoint"
  printf 'red\n' >"$(marker_path)"
  write_reading "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"
  invoke "$(payload)"
  silent_ok
  [ "$(cat "$(marker_path)")" = fire ]

  write_reading "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
  invoke "$(payload)"
  silent_ok
  [ "$(cat "$(marker_path)")" = skull ]
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

@test "a state file on another branch carrying this session never silences" {
  alf_branch feat/other-branch
  seed_loop_entry units "$SID"
  alf_git checkout -q -b feat/this-branch
  [ -f "$ALF_STATE" ]
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/this-branch/STATE.md"
}

@test "the cwd branch's state file carrying only other session ids emits" {
  alf_branch feat/other-sessions
  seed_loop_entry units other-session
  alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: "other-session"}]'
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/other-sessions/STATE.md"
}

@test "an answered latest checkpoint carrying this session with no later unit silences; another session id emits" {
  alf_branch feat/answered
  seed_loop_entry units other-session
  alf_state_edit '.history.checkpoints = [{index: 1, at_round: 3, reason: "context", session_id: $session_id}]
    | .allowance.answers = [{checkpoint: 1, kind: "grant", n: 3, at: "2026-01-01T00:00:00Z", session_id: $session_id}]' \
    --arg session_id "$SID"
  write_reading "$RED"
  invoke "$(payload)"
  silent_unmarked_ok

  alf_state_edit '.history.checkpoints[0].session_id = "other-session"'
  invoke "$(payload)"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/answered/STATE.md"
}

@test "a jump from below red to fire emits fire once and marks red too" {
  write_reading $((RED - 1))
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$FIRE"
  invoke "$(payload)"
  fires_ok fire "$FIRE"
  write_reading "$RED"
  invoke "$(payload)"
  silent_ok
  [ "$(cat "$(marker_path)")" = fire ]
}

@test "a jump from below red to skull emits skull once and marks every band" {
  write_reading $((RED - 1))
  invoke "$(payload)"
  silent_unmarked_ok
  write_reading "$SKULL"
  invoke "$(payload)"
  fires_ok skull "$SKULL"
  invoke "$(payload)"
  silent_ok
  [ "$(cat "$(marker_path)")" = skull ]
}

@test "a missing doctrine file is silent and unmarked; the shipped file emits" {
  write_reading "$RED"
  mv "$DOCTRINE" "$DOCTRINE.saved"
  invoke "$(payload)"
  silent_unmarked_ok
  mv "$DOCTRINE.saved" "$DOCTRINE"
  invoke "$(payload)"
  fires_ok red "$RED"
}

@test "a doctrine file one byte over the cap is silent and unmarked; exactly at the cap emits" {
  local size
  write_reading "$RED"
  size="$(wc -c <"$REAL_DOCTRINE" | tr -d ' ')"
  [ "$size" -lt 3584 ]
  cp "$REAL_DOCTRINE" "$DOCTRINE"
  printf '%*s' $((3585 - size)) '' | tr ' ' x >>"$DOCTRINE"
  [ "$(wc -c <"$DOCTRINE" | tr -d ' ')" -eq 3585 ]
  invoke "$(payload)"
  silent_unmarked_ok

  cp "$REAL_DOCTRINE" "$DOCTRINE"
  printf '%*s' $((3584 - size)) '' | tr ' ' x >>"$DOCTRINE"
  [ "$(wc -c <"$DOCTRINE" | tr -d ' ')" -eq 3584 ]
  invoke "$(payload)"
  fires_ok red "$RED"
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
}

@test "fork budget red twin: a hook that calls gaia_loop_key on the firing path logs git" {
  make_shim
  alf_branch feat/budget-twin
  make_mutant '[ "$verdict" = emit ] || exit 0' '[ "$verdict" = emit ] || exit 0
gaia_loop_key "$cwd" >/dev/null || true' "$MUTANT"
  write_reading "$RED"
  invoke_shimmed "$(payload)" "$MUTANT"
  fires_ok red "$RED" "$MAIN_ROOT/.gaia/local/runs/feat/budget-twin/STATE.md"
  fork_budget_ok && return 1
  [ "$(logged_count git)" -ge 1 ]
}

@test "branch derivation: a feature branch matches gaia_loop_key and gaia_usage_default_branch" {
  alf_git checkout -q -b feat/derive-feature
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$MAIN_ROOT/.gaia/local/runs/feat/derive-feature/STATE.md" ]
}

@test "branch derivation: main as a loose ref, with no origin/HEAD and a master beside it, is the default" {
  alf_git remote set-head origin -d
  alf_git branch master
  [ -f "$MAIN_ROOT/.git/refs/heads/main" ]
  [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = main ]
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$(session_save_path)" ]
}

@test "branch derivation: main only in packed-refs is the default; a hook that skips packed-refs is not" {
  alf_git remote set-head origin -d
  alf_git pack-refs --all
  alf_git branch master
  [ ! -e "$MAIN_ROOT/.git/refs/heads/main" ]
  [ -f "$MAIN_ROOT/.git/refs/heads/master" ]
  grep -q ' refs/heads/main$' "$MAIN_ROOT/.git/packed-refs"
  [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = main ]
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$(session_save_path)" ]

  new_session
  make_mutant 'packed_references <"$common_directory/packed-refs"' '      :' "$MUTANT"
  write_reading "$RED"
  invoke "$(payload)" "$MUTANT"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")" && return 1
  grep -qxF "Save path: $MAIN_ROOT/.gaia/local/runs/main/STATE.md" "$TEMPORARY_DIRECTORY/context"
}

@test "branch derivation: origin/HEAD naming a non-main default wins" {
  alf_git push -q origin main:develop
  alf_git fetch -q origin
  alf_git remote set-head origin develop >/dev/null
  [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = develop ]
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$MAIN_ROOT/.gaia/local/runs/main/STATE.md" ]
}

@test "branch derivation: a master-only repository defaults to master" {
  alf_git remote remove origin
  alf_git branch -m main master
  [ "$(gaia_usage_default_branch "$MAIN_ROOT")" = master ]
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$(session_save_path)" ]
}

@test "branch derivation: a detached HEAD has no key" {
  alf_git checkout -q --detach
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$(session_save_path)" ]
}

@test "branch derivation: a name gaia_branch_normalize rewrites keys by its normalized form" {
  alf_git checkout -q -b 'worktree-feat+derive-normalized'
  write_reading "$RED"
  invoke "$(payload)"
  fires_ok red "$RED" "$(oracle_save_path "$MAIN_ROOT")"
  [ "$(oracle_save_path "$MAIN_ROOT")" = "$MAIN_ROOT/.gaia/local/runs/feat/derive-normalized/STATE.md" ]
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

@test "JSON encoding red twin: a hook that skips the backslash escape does not decode to the doctrine" {
  printf 'A line with a "quote", a back\\slash and a trailing \\\n' >>"$DOCTRINE"
  make_mutant 'text_line=${text_line//\\/\\\\}' '' "$MUTANT"
  write_reading "$RED"
  invoke "$(payload)" "$MUTANT"
  [ -s "$TEMPORARY_DIRECTORY/stdout" ]
  fires_ok red "$RED" && return 1
  rm -f "$(marker_path)"
  invoke "$(payload)"
  fires_ok red "$RED"
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

@test "band value red twin: a hook copy with one planted value fails the scan" {
  local pattern planted
  pattern="$(band_value_pattern)"
  planted="${pattern%%|*}"
  { cat "$HOOK_SOURCE_PATH"; printf '# %s\n' "$planted"; } >"$MUTANT"
  grep -qwE "$pattern" "$MUTANT"
}

@test "the hook is executable" {
  [ -x "$REPO_ROOT/.claude/hooks/context-checkpoint-inject.sh" ]
}
