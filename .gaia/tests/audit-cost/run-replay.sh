#!/usr/bin/env bash
# run-replay.sh: one round-1 audit replay in a throwaway adopter checkout.
#
#   run-replay.sh --scaffold <throwaway> --replay language-file|tsx-variant
#                 --run <k> --out <dir> --max-usd <n>
#
# From <throwaway> (a scaffolded adopter checkout with a GitHub remote and the
# sentinel .gaia/local/measurement-scratch) it cuts replay-<replay>-<k>-<epoch>
# from `main`, applies replays/<replay>.patch, commits, pushes and opens a
# draft pull request. It then runs the audit gate in one headless
# `claude -p` session and stops that session once every frontend member
# dispatched before the unit's first fixer has returned (round 1 only).
#
# Output in <dir>: run.json (claude version, start and end UTC, the router's
# route and reason, the branch and pull request), measure.json (from
# measure-dispatch.mjs, priced from this checkout's token-rates.json), the
# stream and a copy of the session transcript.
#
# The router must send the frontend member down the full route. A light or
# quick route leaves no specialist wave to measure, so it is an input error
# (exit 2, no measure.json), never a measurement. Consecutive runs belong at
# least six minutes apart so the five-minute cache lifetime cannot carry a
# prefix from one run into the next; the start and end times in run.json let
# the caller record the actual spacing.
#
# On exit, success or not, a trap closes the draft pull request, deletes the
# remote branch and returns the throwaway to `main`, so it never accumulates
# open pull requests.
#
# Exit 0 done, 2 usage error, a scaffold without the sentinel (before any
# claude call) or an input error, 3 the session ended or timed out before the
# wave returned, or the cost could not be read.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RATES_FILE="$SCRIPT_DIRECTORY/../../scripts/token-rates.json"
SENTINEL_RELATIVE_PATH=".gaia/local/measurement-scratch"
POLL_SECONDS="${AUDIT_COST_POLL_SECONDS:-15}"
SESSION_TIMEOUT_SECONDS="${AUDIT_COST_SESSION_TIMEOUT_SECONDS:-2700}"

usage() {
  echo "usage: run-replay.sh --scaffold <throwaway> --replay language-file|tsx-variant --run <k> --out <dir> --max-usd <n>" >&2
}

refuse() {
  echo "ERROR: $*" >&2
  exit 2
}

scaffold=""
replay=""
run_number=""
output_directory=""
maximum_usd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scaffold | --replay | --run | --out | --max-usd)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
      case "$1" in
        --scaffold) scaffold="$2" ;;
        --replay) replay="$2" ;;
        --run) run_number="$2" ;;
        --out) output_directory="$2" ;;
        --max-usd) maximum_usd="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
{ [ -n "$scaffold" ] && [ -n "$replay" ] && [ -n "$run_number" ] && [ -n "$output_directory" ] && [ -n "$maximum_usd" ]; } || { usage; exit 2; }
case "$replay" in
  language-file | tsx-variant) ;;
  *) refuse "--replay must be language-file or tsx-variant: $replay" ;;
esac
grep -Eq '^[0-9]+$' <<<"$run_number" || refuse "--run must be a number: $run_number"
grep -Eq '^[0-9]+([.][0-9]+)?$' <<<"$maximum_usd" || refuse "--max-usd must be a number: $maximum_usd"
[ -f "$scaffold/$SENTINEL_RELATIVE_PATH" ] || refuse "--scaffold has no $SENTINEL_RELATIVE_PATH sentinel; a replay runs only in a throwaway: $scaffold"
patch_file="$SCRIPT_DIRECTORY/replays/$replay.patch"
[ -f "$patch_file" ] || refuse "no such replay patch: $patch_file"
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
  refuse "--out exists and is not empty: $output_directory"
fi
[ -z "$(git -C "$scaffold" status --porcelain --untracked-files=no)" ] || refuse "the scaffold has tracked changes; a replay starts from a clean main"
mkdir -p "$output_directory"
scaffold="$(cd "$scaffold" && pwd -P)"
output_directory="$(cd "$output_directory" && pwd -P)"

epoch="$(date +%s)"
branch="replay-$replay-$run_number-$epoch"
branch_pushed=0
pull_request_number=""
claude_pid=""

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null; then
    kill "$claude_pid" 2>/dev/null || true
    wait "$claude_pid" 2>/dev/null || true
  fi
  if [ -n "$pull_request_number" ]; then
    (cd "$scaffold" && gh pr close "$pull_request_number" --delete-branch >/dev/null 2>&1) || true
  fi
  if [ "$branch_pushed" -eq 1 ]; then
    git -C "$scaffold" push --no-verify origin --delete "$branch" >/dev/null 2>&1 || true
  fi
  # A session killed mid-fix leaves edits that block the checkout and would leak into the next
  # replay; the scaffold is a sentinel-guarded throwaway, so they are discarded.
  git -C "$scaffold" reset --quiet --hard >/dev/null 2>&1 || true
  git -C "$scaffold" clean --quiet -fd >/dev/null 2>&1 || true
  git -C "$scaffold" checkout --quiet main >/dev/null 2>&1 || true
  git -C "$scaffold" branch -D "$branch" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

git -C "$scaffold" checkout --quiet main
git -C "$scaffold" checkout --quiet -b "$branch"
git -C "$scaffold" apply "$patch_file"
git -C "$scaffold" add -A -- frontend
git -C "$scaffold" -c user.name=measurement -c user.email=measurement@example.com -c commit.gpgsign=false \
  commit --quiet --no-verify -m "feat: replay change for the $replay measurement"
git -C "$scaffold" push --quiet --no-verify -u origin "$branch"
branch_pushed=1
pull_request_url="$(cd "$scaffold" && gh pr create --draft --base main --head "$branch" --title "Replay $replay run $run_number" --body "Throwaway measurement replay. Closed automatically.")"
pull_request_number="${pull_request_url##*/}"

start_marker="$output_directory/.started"
: >"$start_marker"
start_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
claude_version="$(claude --version 2>/dev/null | head -n 1 || true)"
stream="$output_directory/stream.jsonl"
prompt="Run the pre-merge Code Audit Team audit for pull request $pull_request_number per wiki/concepts/PR Merge Workflow.md. Stop after the audit loop unit's report: do not merge, and do not fix anything yourself."
# bypassPermissions: a throwaway is an untrusted workspace, so headless claude
# ignores the project's allow list and the workflow's first gh call waits on a
# prompt nobody can answer. Hooks still run; the sentinel check keeps this to
# throwaways.
(
  cd "$scaffold"
  exec env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
    claude -p "$prompt" --output-format stream-json --verbose --permission-mode bypassPermissions --max-budget-usd "$maximum_usd"
) >"$stream" 2>"$output_directory/stderr.log" </dev/null &
claude_pid=$!

live_transcript() {
  local session_id candidate
  session_id="$(jq -rs '[.[] | select(.type == "system" and .subtype == "init") | .session_id][0] // empty' "$stream" 2>/dev/null || true)"
  [ -n "$session_id" ] || return 1
  for candidate in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$session_id".jsonl; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# The earliest route record for the frontend member written since the start.
first_route_record() {
  local directory record
  for directory in "$scaffold/.gaia/local/audit/light" "$scaffold"/.claude/worktrees/*/.gaia/local/audit/light; do
    [ -d "$directory" ] || continue
    for record in "$directory"/*.code-audit-frontend.route.json; do
      [ -f "$record" ] && [ "$record" -nt "$start_marker" ] && printf '%s\n' "$record"
    done
  done | while IFS= read -r record; do
    printf '%s\t%s\n' "$(jq -r '.routed_at // ""' "$record")" "$record"
  done | sort | head -n 1 | cut -f 2
}

route=""
reason=""
wave_done=0
elapsed=0
while kill -0 "$claude_pid" 2>/dev/null && [ "$elapsed" -lt "$SESSION_TIMEOUT_SECONDS" ]; do
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
  if [ -z "$route" ]; then
    record="$(first_route_record || true)"
    if [ -n "$record" ]; then
      route="$(jq -r '.route' "$record")"
      reason="$(jq -r '.reason' "$record")"
      if [ "$route" != full ]; then
        echo "ERROR: the router sent the frontend member $route ($reason); a light or quick route leaves no specialist wave to measure" >&2
        exit 2
      fi
    fi
  fi
  if transcript="$(live_transcript)" && node "$SCRIPT_DIRECTORY/lib/session-checks.mjs" wave-done "$transcript"; then
    wave_done=1
    break
  fi
done
if kill -0 "$claude_pid" 2>/dev/null; then
  kill "$claude_pid" 2>/dev/null || true
fi
wait "$claude_pid" 2>/dev/null || true
claude_pid=""
end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

transcript="$(live_transcript)" || { echo "ERROR: no session transcript found for the replay" >&2; exit 3; }
session_name="$(basename "$transcript" .jsonl)"
cp "$transcript" "$output_directory/$session_name.jsonl"
[ ! -d "${transcript%.jsonl}" ] || cp -R "${transcript%.jsonl}" "$output_directory/$session_name"
copied_transcript="$output_directory/$session_name.jsonl"

if [ -z "$route" ]; then
  record="$(first_route_record || true)"
  if [ -n "$record" ]; then
    route="$(jq -r '.route' "$record")"
    reason="$(jq -r '.reason' "$record")"
  else
    # The router's printed line, in the unit's tool results: <route><TAB><reason>.
    line="$(grep -rhoE '(full|light)\\t[a-z-]+' "$copied_transcript" "$output_directory/$session_name" 2>/dev/null | head -n 1 || true)"
    route="${line%%\\t*}"
    reason="${line#*\\t}"
  fi
  [ "$route" = full ] || refuse "the router's route for the frontend member is '${route:-unknown}' (${reason:-no reason recorded}); only a full route is a measurement"
fi
[ "$wave_done" -eq 1 ] || { echo "ERROR: the session ended before the round-1 frontend member wave returned" >&2; exit 3; }

cost_usd="$(jq -s '[.[] | select(.type == "result") | (.total_cost_usd // 0)] | add // null' "$stream" 2>/dev/null || echo null)"
jq -n --arg replay "$replay" --argjson run "$run_number" --arg branch "$branch" --arg pr "$pull_request_number" --arg version "$claude_version" \
  --arg start "$start_time" --arg end "$end_time" --arg route "$route" --arg reason "$reason" --arg session "$session_name" --argjson cost "${cost_usd:-null}" \
  '{replay: $replay, run: $run, branch: $branch, pull_request: $pr, claude_version: $version, start_utc: $start, end_utc: $end, route: $route, route_reason: $reason, session: $session, session_cost_usd: $cost}' \
  >"$output_directory/run.json"
node "$SCRIPT_DIRECTORY/measure-dispatch.mjs" --session "$copied_transcript" --rates "$RATES_FILE" --out "$output_directory/measure.json"
