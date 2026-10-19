# shellcheck shell=bash
# GAIA usage ledger: carries a recorded run across a session change.
#
#   handoff
#   join --workflow <w> --session <origin session id> --start <origin start>
#
# A run's start row is keyed by the session that started it, so a run continued
# after /clear, or in a fresh session the audit loop or the context checkpoint
# hands off to, would close in a session with no start and cost only that
# session. `handoff`, run in the session handing off, prints the `join` line its
# continuation prompt carries; `join`, run first in the continuing session,
# writes that session a start bound to the run's origin. `usage.sh record` then
# closes every session bound to the origin under one ref and sums them.
#
# The origin is the run's first start, never the previous session's join, so a
# chain of handoffs binds every session to the one run.
#
# Exit codes. handoff: 0 once its flags parse and the ledger is readable (no
# open run prints nothing, since a handoff of work that is not a recorded run
# owes no line); 2 usage error, jq absent, or an unreadable usage ledger. join:
# 0 written or already joined; 1 refused (no session id, no ledger mutex or
# directory, ledger lock timed out: nothing written; or an append failure, after
# which check the last row); 2 usage error, jq absent, or an unreadable usage
# ledger.
#
# Sourced by usage.sh at top level, after usage-record-lib.sh, and relies on its
# helpers and usage.sh's globals.

# shellcheck disable=SC2154  # flag variables and helpers come from usage.sh

# _handoff_preamble <args...>: the common flags, the roots and the session id.
_handoff_preamble() {
  local usage_file
  [ -z "$(gaia_usage_inactive_reason)" ] || { _error "jq not found; nothing was done"; return 2; }
  _parse "$@" || return 2
  _resolve_context || return 2
  if [ -n "$SOURCE$MERGE$BRANCH$KEY$MERGED_AT$AT$PR_NUMBER$ISSUE_NUMBER" ] || [ "$PARTIAL$UNCONFIRMED$LINE$AUDITORS_GIVEN$JSON" != 00000 ] || [ "$SIDECHAIN" != false ]; then
    _error "unknown flag; see usage.sh --help"
    return 2
  fi
  [ "${#ARGS[@]}" -eq 0 ] || { _error "takes no positional argument"; return 2; }
  usage_file="$TELEMETRY_DIRECTORY/usage.jsonl"
  if [ -e "$usage_file" ] && { [ ! -f "$usage_file" ] || [ ! -r "$usage_file" ]; }; then
    _error "the usage ledger exists but cannot be read"
    return 2
  fi
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  return 0
}

# _handoff_main: prints the join line for the newest open run in this session.
# shellcheck disable=SC2016,SC2329  # jq source, no shell expansion; reached through usage.sh's dispatch
_handoff_main() {
  _handoff_preamble "$@" || return 2
  [ -z "$SESSION$WORKFLOW$START_ISO" ] || { _error "unknown flag; handoff takes only the common flags"; return 2; }
  gaia_usage_valid_reference "session:$SESSION_ID" || return 0
  mkdir -p "$TELEMETRY_DIRECTORY" 2>/dev/null || return 0
  # The flush puts this session's start row, and its spend so far, on the
  # ledger before the line naming them is printed.
  _box_flush_wait
  { LC_ALL=C grep -F -- "$SESSION_ID" "$TELEMETRY_DIRECTORY/usage.jsonl" 2>/dev/null || true; } | LC_ALL=C grep -F '"kind":"binding"' |
    jq -nRr --arg session_id "$SESSION_ID" --argjson start_set "$GAIA_USAGE_START_SET" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
      [inputs | (try fromjson catch null) | select(type == "object" and .schema_version == 1 and .kind == "binding"
          and .session_id == $session_id and (.type == "start" or .type == "close") and (.workflow as $w | $start_set | index($w)))] as $rows
      | usage_intervals($rows) as $intervals
      | [$rows[] | select(.type == "start") | . + {_t: (.ts | usage_epoch)}
          | select(._t != null) | . as $start
          | select(any($intervals[]; .t0 == $start._t and .session_id == $start.session_id) | not)]
      | sort_by(._t) | last
      | select(. != null)
      | (.run // {session_id: .session_id, ts: .ts}) as $origin
      | "bash .gaia/scripts/usage.sh join --workflow \(.workflow) --session \($origin.session_id) --start \($origin.ts)"' 2>/dev/null
  return 0
}

# _join_locked: runs under with_ledger_lock. 0 written; 4 already joined; 6 the
# ledger could not be read; 7 the append failed.
# shellcheck disable=SC2016  # jq source, no shell expansion
_join_locked() {
  local ledger="$TELEMETRY_DIRECTORY/usage.jsonl" row
  row="$({ LC_ALL=C grep -F -- "$SESSION_ID" "$ledger" 2>/dev/null || true; } |
    jq -nRc --arg session_id "$SESSION_ID" --arg workflow "$WORKFLOW" --arg origin_session "$SESSION" --arg origin_ts "$START_ISO" --arg now "$NOW" \
      "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
      [inputs | (try fromjson catch null) | select(type == "object" and .schema_version == 1 and .session_id == $session_id)] as $rows
      | ($origin_ts | usage_epoch) as $origin_t
      | if any($rows[]; .kind == "binding" and .type == "start" and .workflow == $workflow and (.run | type) == "object"
            and .run.session_id == $origin_session and (.run.ts | usage_epoch) == $origin_t)
        then "joined"
        else
          # A session with no spend before the run began holds none of
          # another task, so all of it counts; one that predates the run
          # counts from now.
          (if any($rows[]; .kind == "segment" and (.first_ts | usage_epoch) as $t | $t != null and $t < $origin_t) then $now else $origin_ts end) as $ts
          | {schema_version: 1, kind: "binding", type: "start", session_id: $session_id, ts: $ts, workflow: $workflow,
             source: "join-command", run: {session_id: $origin_session, ts: $origin_ts}}
        end')" || return 6
  case "$row" in
    '"joined"') return 4 ;;
    '{'*) printf '%s\n' "$row" >>"$ledger" || return 7 ;;
    *) return 6 ;;
  esac
}

# shellcheck disable=SC2329  # reached through usage.sh's dispatch
_join_main() {
  local status=0
  _handoff_preamble "$@" || return 2
  [[ "$WORKFLOW" =~ ^[a-z][a-z-]{0,31}$ ]] || { _error "--workflow takes a workflow name"; return 2; }
  case "$GAIA_USAGE_START_SET" in
    *\"$WORKFLOW\"*) ;;
    *) _error "--workflow $WORKFLOW is not a workflow that records a run"; return 2 ;;
  esac
  gaia_usage_valid_reference "session:$SESSION" || { _error "--session takes the session id the run started in"; return 2; }
  _is_iso "$START_ISO" || { _error "--start takes the run's start time as the handoff line prints it"; return 2; }
  [[ "$START_ISO" > "$(_now)" ]] && { _error "--start is in the future"; return 2; }
  gaia_usage_valid_reference "session:$SESSION_ID" || { _error "no session id (CLAUDE_CODE_SESSION_ID is empty or invalid); nothing was written"; return 1; }
  [ "$SESSION_ID" != "$SESSION" ] || { printf 'this session started the run; nothing to join\n'; return 0; }
  _gaia_usage_load with_ledger_lock spec/with-ledger-lock.sh || { _error "no ledger mutex available; nothing was written"; return 1; }
  mkdir -p "$TELEMETRY_DIRECTORY" || { _error "no ledger directory; nothing was written"; return 1; }
  _box_flush_wait
  NOW="$(_now)"
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS="${GAIA_LEDGER_LOCK_TIMEOUT_SECONDS:-10}" with_ledger_lock "$TELEMETRY_DIRECTORY" _join_locked 2>/dev/null || status=$?
  case "$status" in
    0) printf 'joined the %s run started %s\n' "$WORKFLOW" "$START_ISO" ;;
    4) printf 'already joined the %s run started %s\n' "$WORKFLOW" "$START_ISO" ;;
    75) _error "ledger lock timed out; nothing was written, rerun the same join line"; return 1 ;;
    6) _error "could not read the usage ledger; nothing was written"; return 2 ;;
    *) _error "could not append to the usage ledger; check the last row before rerunning"; return 1 ;;
  esac
}
