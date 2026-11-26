#!/usr/bin/env bash
# run-dry-run.sh: run one unattended /gaia-next iteration in a fresh adopter
# fixture as a headless Claude session, then assert what it left behind.
#
#   run-dry-run.sh --out <empty directory outside this checkout> --max-usd <n>
#                  [--model <model>] [--permission-mode <mode>]
#                  [--max-minutes <n>] [--mutate none|gate|park]
#
# Spends model usage. README.md beside this script has the cost and when to
# run it. --mutate passes to build-fixture.sh for the negative proofs.
#
# Assertions, each printed as PASS or FAIL:
#   ended        the session ended on its own with a result event (no stall,
#                no wall-clock kill)
#   answered     the session called AskUserQuestion, and every call got a
#                tool result
#   decision-log the gate's entry for the fixture question, from this
#                session, is in the decision log
#   parked       the parked marker names audit-checkpoint, the pull request
#                and the branch head origin holds
#   comment      the gh stub recorded the park comment carrying the grant line
#
# Evidence in --out: stream.jsonl, stderr.log, summary.json (cost, wall
# seconds, each assertion), and the fixture itself.
#
# Exit 0 every assertion passed, 1 one failed, 2 usage or a refused --out,
# 3 the fixture or the session could not start.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
QUESTION_HEADER="Dry run"
QUESTION_OPTION="Continue (Recommended)"
# The question the session asks before its first step. The iteration itself
# asks none before it parks, so without it the gate's take-the-recommendation
# arm would go unexercised.
FIXTURE_PROMPT="This session runs in a GAIA test fixture. Before any step of /gaia-next, call AskUserQuestion once with exactly this input and act on the answer: {\"questions\":[{\"question\":\"Start this unattended iteration?\",\"header\":\"$QUESTION_HEADER\",\"multiSelect\":false,\"options\":[{\"label\":\"$QUESTION_OPTION\",\"description\":\"Run the next job.\"},{\"label\":\"Stop\",\"description\":\"End now.\"}]}]} Then carry out /gaia-next as written. This session's spend cap is not a reason to skip or shorten a step."

usage() {
  echo "usage: run-dry-run.sh --out <empty directory outside this checkout> --max-usd <n> [--model <model>] [--permission-mode <mode>] [--max-minutes <n>] [--mutate none|gate|park]" >&2
  exit 2
}

output_directory="" max_usd="" model=sonnet permission_mode=bypassPermissions max_minutes=30 mutation=none
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --out) output_directory="$2" ;;
    --max-usd) max_usd="$2" ;;
    --model) model="$2" ;;
    --permission-mode) permission_mode="$2" ;;
    --max-minutes) max_minutes="$2" ;;
    --mutate) mutation="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$output_directory" ] && [ -n "$max_usd" ] || usage
[[ "$max_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage
[[ "$max_minutes" =~ ^[1-9][0-9]*$ ]] || usage
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "run-dry-run: $CLAUDE_BIN not found" >&2; exit 3; }

fixture_status=0
bash "$HERE/build-fixture.sh" --out "$output_directory" --mutate "$mutation" >/dev/null || fixture_status=$?
case "$fixture_status" in 0) ;; 2) exit 2 ;; *) echo "run-dry-run: build-fixture.sh failed" >&2; exit 3 ;; esac
output_directory="$(cd "$output_directory" && pwd -P)"
# shellcheck source=/dev/null
. "$output_directory/fixture.env"
repo="$output_directory/repo"
stream="$output_directory/stream.jsonl"
mkdir -p "$output_directory/gh-config"

# The session sees the fixture's gh stub, an empty gh config (so a gh reached
# by absolute path is unauthenticated) and none of this session's Claude Code
# variables. Only project and local settings load, so the user's own hooks
# stay out of the fixture.
#
# A plain `claude -p` session has no AskUserQuestion tool at all, so the gate's
# question arm could never fire. The tool is present only when a host answers
# prompts: `--permission-prompt-tool stdio` with stream-json input, the
# protocol the Agent SDK speaks. stdin carries the one prompt and then closes,
# so a question that reaches the host (the gate removed) is never answered.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"/gaia-next"}}' >"$output_directory/prompt.jsonl"
start_seconds="$(date +%s)"
(
  cd "$repo" || exit 3
  exec env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
    -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
    PATH="$output_directory/bin:$PATH" GH_STUB_DIRECTORY="$output_directory/gh" \
    GH_CONFIG_DIR="$output_directory/gh-config" GAIA_TELEMETRY_PING_DISABLE=1 \
    "$CLAUDE_BIN" -p --input-format stream-json --permission-prompt-tool stdio \
    --output-format stream-json --verbose --include-hook-events \
    --model "$model" --permission-mode "$permission_mode" --max-budget-usd "$max_usd" \
    --setting-sources project,local --append-system-prompt "$FIXTURE_PROMPT"
) >"$stream" 2>"$output_directory/stderr.log" <"$output_directory/prompt.jsonl" &
session_pid=$!
# macOS ships no timeout(1): a sleeper kills the session at the wall-clock cap.
( sleep $((max_minutes * 60)) && kill "$session_pid" 2>/dev/null && : >"$output_directory/killed" ) &
watchdog_pid=$!
wait "$session_pid"
session_status=$?
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null
wall_seconds=$(($(date +%s) - start_seconds))

results="[]"
failed=0
record() {
  local name="$1" verdict="$2" detail="$3"
  printf '%s %s: %s\n' "$verdict" "$name" "$detail"
  [ "$verdict" = PASS ] || failed=1
  results="$(jq -c --arg name "$name" --arg verdict "$verdict" --arg detail "$detail" '. + [{name: $name, verdict: $verdict, detail: $detail}]' <<<"$results")"
}

session_id="$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$stream" 2>/dev/null | head -n 1)"
cost="$(jq -s '[.[] | select(.type == "result") | (.total_cost_usd // 0)] | add // 0' "$stream" 2>/dev/null)" || cost=null

if [ -e "$output_directory/killed" ]; then
  record ended FAIL "killed at the ${max_minutes}-minute cap"
elif jq -e 'select(.type == "result")' "$stream" >/dev/null 2>&1; then
  record ended PASS "result $(jq -r 'select(.type == "result") | .subtype' "$stream" | head -n 1), exit $session_status"
else
  record ended FAIL "no result event, exit $session_status (stderr.log)"
fi

asked="$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "AskUserQuestion") | .id' "$stream" 2>/dev/null)"
if [ -z "$asked" ]; then
  record answered FAIL "the session called AskUserQuestion zero times"
else
  unanswered=""
  while IFS= read -r tool_use_id; do
    jq -e --arg id "$tool_use_id" 'select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .tool_use_id == $id)' "$stream" >/dev/null 2>&1 ||
      unanswered="$unanswered $tool_use_id"
  done <<<"$asked"
  if [ -z "$unanswered" ]; then
    record answered PASS "$(wc -l <<<"$asked" | tr -d ' ') call(s), each with a tool result"
  else
    record answered FAIL "no tool result for:$unanswered"
  fi
fi

decision_log="$repo/.gaia/local/protected/autonomy-log.jsonl"
if [ -n "$session_id" ] && [ -f "$decision_log" ] &&
  jq -e -s --arg session "$session_id" --arg header "$QUESTION_HEADER" --arg option "$QUESTION_OPTION" \
    'any(.[]; .session_id == $session and .header == $header and .option == $option)' "$decision_log" >/dev/null 2>&1; then
  record decision-log PASS "'$QUESTION_HEADER: $QUESTION_OPTION' logged for session $session_id"
else
  record decision-log FAIL "no '$QUESTION_HEADER: $QUESTION_OPTION' entry for session ${session_id:-<none>} in $decision_log"
fi

marker="$repo/.gaia/local/runs/$FIXTURE_BRANCH_KEY/PARKED.json"
origin_head="$(git --git-dir="$output_directory/origin.git" rev-parse --verify --quiet "refs/heads/$FIXTURE_BRANCH")"
if [ -f "$marker" ] &&
  jq -e --arg branch "$FIXTURE_BRANCH" --argjson pr "$FIXTURE_PR" --arg head "$origin_head" \
    '.reason == "audit-checkpoint" and .branch == $branch and .pr == $pr and .head == $head' "$marker" >/dev/null 2>&1; then
  record parked PASS "audit-checkpoint on $FIXTURE_BRANCH (PR #$FIXTURE_PR) at pushed head $origin_head"
else
  record parked FAIL "no parked marker for audit-checkpoint, PR #$FIXTURE_PR and pushed head ${origin_head:-<none>} at $marker"
fi

if grep -l -F '<!-- gaia:autonomy-park -->' "$output_directory/gh/comments/"*.md 2>/dev/null | xargs grep -l -E '^audit-grant [0-9]+$' >/dev/null 2>&1; then
  record comment PASS "the stub recorded the park comment with its grant line"
else
  record comment FAIL "no park comment with a grant line under $output_directory/gh/comments"
fi

jq -n --arg model "$model" --arg permission_mode "$permission_mode" --arg mutation "$mutation" \
  --arg session_id "$session_id" --argjson cost "${cost:-null}" --argjson wall_seconds "$wall_seconds" \
  --argjson results "$results" --arg claude_version "$("$CLAUDE_BIN" --version 2>/dev/null)" \
  '{model: $model, permission_mode: $permission_mode, mutation: $mutation, claude_version: $claude_version,
    session_id: $session_id, total_cost_usd: $cost, wall_seconds: $wall_seconds, results: $results}' \
  >"$output_directory/summary.json"
printf 'cost $%s, %ss wall, evidence in %s\n' "$cost" "$wall_seconds" "$output_directory"
exit "$failed"
