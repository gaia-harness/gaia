#!/usr/bin/env bash
# The sole writer and reader of a branch's review record, <run>/code-review.json.
# Every write goes through install_record (a temp file plus mv), so a reader never
# sees half a record. The name stays outside the *.findings.json glob, so no
# findings reader takes it for a member's sidecar.
#
#   open         --root --run-folder --pr --base --head [--claude-version] [--wait-seconds]
#   attempt-open --run-folder --n
#   attempt-close --run-folder --n --exit --cost [--reason] [--model] [--denials <file>]
#   outcome      --run-folder --pr --outcome [--reason] [--findings <file>] [--claude-version]
#   read         --run-folder
#   decide       --root --run-folder --pr --routes <all-light|mixed>
#   assign       --root --run-folder
#   delivery     --run-folder --member
#   reconcile    --root --run-folder --member <m> [--member <m>...]
#   round-end    --root --run-folder --round --commit <sha|none>
#   rechecks     --run-folder
#   recheck-close --root --run-folder --member --round
#   convergence  --root --run-folder --stop-reason
#   publish-values --root --run-folder --rounds [--pr]
#
# Exit: 0 done, 1 no record (read), 2 usage or an unknown reason, 4 an open
# attempt's process group or script is still alive, 5 the record is unreadable.
# `open` prints `ended` and writes nothing on a current record that already ended
# the branch's one review. `decide` prints exactly one of none, quick-first, run,
# deliver. The hand-over subcommands live in audit-code-review-handover.sh.
#
# HONEST LIMIT. This is a local file under the git-ignored run folder, the same
# trust position as a findings sidecar: it sits under the audit's documented limit
# that a tree-writing actor can rewrite local state. It reports what happened and
# guards no merge on its own.
#
# LIFECYCLE INVARIANT. No write happens while a child is alive: `open` and
# `attempt-open` run before a spawn, everything else after the supervisor has
# returned and its group is gone. `outcome` and `open` enforce it from the
# attempt's pgid and script.pid files, which are not record writes.
#
# Bash 3.2 compatible. jq programs are single-quoted so their `$` reach jq.
# SC2034: ROUND, COMMIT and STOP_REASON are read by the sourced hand-over library.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolved from this script, so the working directory never picks the library.
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/audit-code-review-decide.sh"
# A failed source under bash 3.2 ends the shell before any `||` runs, so the
# file test comes first.
[ -f "$SCRIPT_DIRECTORY/audit-code-review-handover.sh" ] || {
  printf 'audit-code-review-record: missing library: %s\n' "$SCRIPT_DIRECTORY/audit-code-review-handover.sh" >&2
  exit 1
}
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/audit-code-review-handover.sh"

die_usage() {
  printf 'audit-code-review-record: %s\n' "$1" >&2
  exit 2
}

SUBCOMMAND="${1-}"
[ $# -gt 0 ] && shift
ROOT="" RUN_FOLDER="" PR="" BASE="" HEAD="" CLAUDE_VERSION="" WAIT_SECONDS=0 ATTEMPT=""
EXIT_STATUS="" COST="" REASON="" MODEL="" DENIALS_FILE="" OUTCOME="" FINDINGS_FILE="" ROUTES=""
MEMBERS="" ROUND="" COMMIT="" STOP_REASON="" ROUNDS=0
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die_usage "$1 needs a value"
  case "$1" in
    --root) ROOT="$2" ;;
    --run-folder) RUN_FOLDER="$2" ;;
    --pr) PR="$2" ;;
    --base) BASE="$2" ;;
    --head) HEAD="$2" ;;
    --claude-version) CLAUDE_VERSION="$2" ;;
    --wait-seconds) WAIT_SECONDS="$2" ;;
    --n) ATTEMPT="$2" ;;
    --exit) EXIT_STATUS="$2" ;;
    --cost) COST="$2" ;;
    --reason) REASON="$2" ;;
    --model) MODEL="$2" ;;
    --denials) DENIALS_FILE="$2" ;;
    --outcome) OUTCOME="$2" ;;
    --findings) FINDINGS_FILE="$2" ;;
    --routes) ROUTES="$2" ;;
    --member) MEMBERS="${MEMBERS:+$MEMBERS$'\n'}$2" ;;
    --round) ROUND="$2" ;;
    --commit) COMMIT="$2" ;;
    --stop-reason) STOP_REASON="$2" ;;
    --rounds) ROUNDS="$2" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift 2
done

case "$RUN_FOLDER" in /*) ;; *) die_usage "--run-folder must be an absolute path" ;; esac
RECORD_FILE="$RUN_FOLDER/code-review.json"

require_pr() {
  [[ "$PR" =~ ^[1-9][0-9]{0,9}$ ]] || die_usage "--pr must be a positive integer"
}
require_root() {
  case "$ROOT" in /*) ;; *) die_usage "--root must be an absolute path" ;; esac
}
require_attempt() {
  [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] || die_usage "--n must be a positive integer"
}
# The list lives in audit-loop-record.sh, which owns it; the copy beside this
# script answers, so a reason this checkout does not know is refused. An
# unreadable list refuses too: the closed list is what keeps a published reason
# from carrying free text.
require_known_reason() {
  [ -n "$1" ] || return 0
  local known_reasons
  known_reasons="$(bash "$SCRIPT_DIRECTORY/audit-loop-record.sh" --list-review-reasons 2>/dev/null)" || known_reasons=""
  grep -Fxq -- "$1" <<<"$known_reasons" || die_usage "unknown reason: $1"
}

JQ_DEFINITIONS='
def recompute_cost:
  .cost = (if (.attempts | length) == 0 then "none"
           elif any(.attempts[]; .cost == "unknown") then "unknown"
           else ([.attempts[].cost] | add) end);
def close_open_attempts($now):
  .attempts |= map(if .closed_at == null
    then .closed_at = $now | .cost = "unknown" | .reason = "interrupted" else . end);
'

now_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# install_record: stdin becomes the record, or nothing changes. The check catches
# a jq failure upstream, which pipefail alone would report only after the temp
# file already held a truncated value.
install_record() {
  local temporary_file
  mkdir -p "$RUN_FOLDER"
  temporary_file="$(mktemp "$RUN_FOLDER/.code-review.json.XXXXXX")"
  cat >"$temporary_file"
  if jq -e 'type == "object" and .version == 1' "$temporary_file" >/dev/null 2>&1; then
    mv -f "$temporary_file" "$RECORD_FILE"
  else
    rm -f "$temporary_file"
    printf 'audit-code-review-record: refused to write a malformed record\n' >&2
    return 1
  fi
}

fresh_record() {
  jq -n --argjson pr "$PR" '{version: 1, pr: $pr, base: null, head: null, outcome: "pending", reason: null,
    level: "high", model: null, claude_version: null, attempts: [], cost: "none",
    denials: {count: 0, tools: [], detail: []}, findings: [], handover: "none", reconcile_passes: 0,
    rounds: null, members_dispatched: null, convergence: null}'
}

# record_state: absent, unreadable or ok. -s so a file holding two JSON values
# is unreadable rather than reading as its last.
record_state() {
  [ -e "$RECORD_FILE" ] || { printf 'absent\n'; return 0; }
  if jq -e -s 'length == 1 and (.[0] | type == "object" and .version == 1
      and (.outcome | type == "string") and (.attempts | type == "array"))' "$RECORD_FILE" >/dev/null 2>&1; then
    printf 'ok\n'
  else
    printf 'unreadable\n'
  fi
}

field() { jq -r "$1" "$RECORD_FILE"; }

attempt_is_alive() {
  local attempt_directory="$RUN_FOLDER/code-review-attempt-$1" recorded_id
  if [ -f "$attempt_directory/pgid" ]; then
    recorded_id="$(cat "$attempt_directory/pgid")"
    case "$recorded_id" in
      '' | *[!0-9]*) ;;
      *) kill -0 -- "-$recorded_id" 2>/dev/null && return 0 ;;
    esac
  fi
  if [ -f "$attempt_directory/script.pid" ]; then
    recorded_id="$(cat "$attempt_directory/script.pid")"
    case "$recorded_id" in
      '' | *[!0-9]*) ;;
      *) kill -0 "$recorded_id" 2>/dev/null && return 0 ;;
    esac
  fi
  return 1
}

any_open_attempt_alive() {
  local attempt_number
  while IFS= read -r attempt_number; do
    [ -z "$attempt_number" ] || ! attempt_is_alive "$attempt_number" || return 0
  done <<EOF
$(field '.attempts[] | select(.closed_at == null) | .n')
EOF
  return 1
}

# write_outcome <fresh|existing> <outcome> <reason> <findings-file-or-empty>: the
# single place an outcome lands. Open attempts close as failed with cost unknown
# here, so every path to a final outcome keeps the cost honest. The saved finding
# carries only what the judge validated, plus the empty fields later writers fill.
write_outcome() {
  local source_kind="$1" new_outcome="$2" new_reason="$3" findings_source="${4:-}"
  [ -n "$findings_source" ] || findings_source=/dev/null
  {
    if [ "$source_kind" = fresh ]; then fresh_record; else cat "$RECORD_FILE"; fi
  } | jq --arg now "$(now_stamp)" --arg outcome "$new_outcome" --arg reason "$new_reason" \
    --arg claude_version "$CLAUDE_VERSION" --slurpfile saved "$findings_source" "$JQ_DEFINITIONS"'
    close_open_attempts($now)
    | recompute_cost
    | .outcome = $outcome
    | .reason = (if $reason == "" then null else $reason end)
    | (if $claude_version != "" then .claude_version = $claude_version else . end)
    | .findings = (if $outcome == "ran" then ($saved[0] // []) else [] end | to_entries | map(.value + {
        id: "cr-\(.key + 1)", member: null, handed_only: null, state: null, drop_reason: null,
        merged: false, fixed: false, final_disposition: null, recheck: null}))
    | .handover = (if (.findings | length) > 0 then "open" else "none" end)' \
    | install_record
}

cmd_open() {
  require_pr
  require_root
  local state waited=0
  state="$(record_state)"
  [ "$state" != unreadable ] || exit 5
  if [ "$state" = ok ]; then
    while any_open_attempt_alive; do
      [ "$waited" -lt "$WAIT_SECONDS" ] || exit 4
      sleep 1
      waited=$((waited + 1))
    done
    if gaia_review_record_is_current "$ROOT" "$PR"; then
      case "$(field .outcome)" in
        ran | ran,* | 'not run')
          printf 'ended\n'
          return 0
          ;;
        pending)
          jq --arg now "$(now_stamp)" --arg base "$BASE" --arg head "$HEAD" --arg claude_version "$CLAUDE_VERSION" \
            "$JQ_DEFINITIONS"'close_open_attempts($now) | recompute_cost
              | .base = $base | .head = $head | .claude_version = $claude_version' "$RECORD_FILE" | install_record
          return 0
          ;;
      esac
    fi
  fi
  fresh_record | jq --arg base "$BASE" --arg head "$HEAD" --arg claude_version "$CLAUDE_VERSION" \
    '.base = $base | .head = $head | .claude_version = $claude_version' | install_record
}

cmd_attempt_open() {
  require_attempt
  [ "$(record_state)" = ok ] || exit 5
  jq --argjson n "$ATTEMPT" --arg now "$(now_stamp)" "$JQ_DEFINITIONS"'
    .attempts += [{n: $n, opened_at: $now, closed_at: null, exit: null, cost: "unknown", reason: null}]
    | recompute_cost' "$RECORD_FILE" | install_record
}

cmd_attempt_close() {
  require_attempt
  [ "$(record_state)" = ok ] || exit 5
  [[ "$EXIT_STATUS" =~ ^[0-9]+$ ]] || die_usage "--exit must be an integer"
  [[ "$COST" =~ ^(unknown|[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?)$ ]] || die_usage "--cost must be a number or unknown"
  require_known_reason "$REASON"
  [ -n "$DENIALS_FILE" ] || DENIALS_FILE=/dev/null
  jq --argjson n "$ATTEMPT" --arg now "$(now_stamp)" --argjson exit_status "$EXIT_STATUS" --arg cost "$COST" \
    --arg reason "$REASON" --arg model "$MODEL" --slurpfile denials "$DENIALS_FILE" "$JQ_DEFINITIONS"'
    .attempts |= map(if .n == $n
      then .closed_at = $now | .exit = $exit_status
        | .cost = (if $cost == "unknown" then "unknown" else ($cost | tonumber) end)
        | .reason = (if $reason == "" then null else $reason end)
      else . end)
    | (if $model != "" then .model = $model else . end)
    | (if ($denials | length) > 0 then .denials = $denials[0] else . end)
    | recompute_cost' "$RECORD_FILE" | install_record
}

cmd_outcome() {
  require_pr
  case "$OUTCOME" in
    ran | 'ran, clean' | 'ran, no findings')
      [ -z "$REASON" ] || die_usage "$OUTCOME takes no reason"
      ;;
    'not run' | 'not needed')
      [ -n "$REASON" ] || die_usage "$OUTCOME needs a reason"
      ;;
    *) die_usage "unknown outcome: $OUTCOME" ;;
  esac
  require_known_reason "$REASON"
  if [ -n "$FINDINGS_FILE" ]; then
    jq -e 'type == "array"' "$FINDINGS_FILE" >/dev/null 2>&1 || die_usage "--findings must hold a JSON array"
  fi
  local state source_kind=fresh
  state="$(record_state)"
  [ "$state" != unreadable ] || exit 5
  if [ "$state" = ok ]; then
    ! any_open_attempt_alive || exit 4
    [ "$(field '.pr // empty')" != "$PR" ] || source_kind=existing
  fi
  write_outcome "$source_kind" "$OUTCOME" "$REASON" "$FINDINGS_FILE"
}

cmd_read() {
  case "$(record_state)" in
    absent) exit 1 ;;
    unreadable) exit 5 ;;
  esac
  cat "$RECORD_FILE"
}

case "$SUBCOMMAND" in
  open) cmd_open ;;
  attempt-open) cmd_attempt_open ;;
  attempt-close) cmd_attempt_close ;;
  outcome) cmd_outcome ;;
  read) cmd_read ;;
  decide)
    require_pr
    require_root
    cmd_decide "$ROOT" "$PR" "$ROUTES"
    ;;
  assign) cmd_assign ;;
  delivery) cmd_delivery ;;
  reconcile) cmd_reconcile ;;
  round-end) cmd_round_end ;;
  rechecks) cmd_rechecks ;;
  recheck-close) cmd_recheck_close ;;
  convergence) cmd_convergence ;;
  publish-values) cmd_publish_values ;;
  *) die_usage "usage: audit-code-review-record.sh open|attempt-open|attempt-close|outcome|read|decide|assign|delivery|reconcile|round-end|rechecks|recheck-close|convergence|publish-values ..." ;;
esac
