#!/usr/bin/env bash
# probe-first-call.sh: measure what an agent type costs on its first call.
#
#   probe-first-call.sh --root <scratch tree> --types <comma list> --out <dir>
#                       --max-usd <n> [--callability] [--model <model>]
#
# One fresh `claude -p` session per listed agent type, each dispatching that
# type once with a trivial prompt (stdout only, no edits), then
# measure-dispatch.mjs over the session. <out>/<type>/measure.json carries the
# first-call context and the attachments that precede the first call.
#
# --callability adds a probe per deferred-class tool an allowlist lists: for
# audit-loop-unit one trivial child dispatch continued once with SendMessage
# and one Monitor on `echo ok`; for code-audit-maintainer-shell one Monitor
# and one WebFetch of https://example.com. <out>/callability.json holds
# [{type, tool, called, toolsearch_used, error}]; a tool is callable when it was
# called, ToolSearch was not used, and no result for it was an error.
#
# Needs Claude auth and spends tokens. It runs only in a root carrying
# .gaia/local/measurement-scratch (prepare-scratch-clone.sh, or a scaffolded
# throwaway the caller marked), so no probe ever touches the live checkout. The
# accumulated cost is read from each session's result event; the run stops and
# records a partial summary when it reaches --max-usd.
#
# Exit 0 done, 2 usage error or a root without the sentinel (before any claude
# call), 3 stopped on the cost cap or on a cost that could not be read.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RATES_FILE="$SCRIPT_DIRECTORY/../../scripts/token-rates.json"
SENTINEL_RELATIVE_PATH=".gaia/local/measurement-scratch"
TRIVIAL_PROMPT="This is a measurement probe. Do not follow your usual procedure, run no tools, edit nothing, and reply with the single word OK."

usage() {
  echo "usage: probe-first-call.sh --root <scratch tree> --types <comma list> --out <dir> --max-usd <n> [--callability] [--model <model>]" >&2
}

refuse() {
  echo "ERROR: $*" >&2
  exit 2
}

root=""
types=""
output_directory=""
maximum_usd=""
with_callability=0
model="sonnet"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --callability)
      with_callability=1
      shift
      ;;
    --root | --types | --out | --max-usd | --model)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
      case "$1" in
        --root) root="$2" ;;
        --types) types="$2" ;;
        --out) output_directory="$2" ;;
        --max-usd) maximum_usd="$2" ;;
        --model) model="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
{ [ -n "$root" ] && [ -n "$types" ] && [ -n "$output_directory" ] && [ -n "$maximum_usd" ]; } || { usage; exit 2; }
grep -Eq '^[0-9]+([.][0-9]+)?$' <<<"$maximum_usd" || refuse "--max-usd must be a number: $maximum_usd"
[ -f "$root/$SENTINEL_RELATIVE_PATH" ] || refuse "--root has no $SENTINEL_RELATIVE_PATH sentinel; a probe runs only in a scratch tree: $root"
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
  refuse "--out exists and is not empty: $output_directory"
fi
mkdir -p "$output_directory"
root="$(cd "$root" && pwd -P)"

# owner/name of the GitHub repository behind a checkout, following a local
# clone's origin (a scratch clone's origin is the checkout it was cloned from).
# The audit-loop hook's fork check asks gh about the probe's branch; without a
# GitHub remote gh exits non-zero and the hook refuses every member dispatch.
github_repository_of() {
  local checkout="$1" url depth=0
  while [ "$depth" -lt 4 ]; do
    url="$(git -C "$checkout" remote get-url origin 2>/dev/null)" || return 1
    case "$url" in
      *github.com[:/]*)
        url="${url#*github.com[:/]}"
        printf '%s\n' "${url%.git}"
        return 0
        ;;
      /* | file://*)
        checkout="${url#file://}"
        depth=$((depth + 1))
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}
if [ -z "${GH_REPO:-}" ] && GH_REPO="$(github_repository_of "$root")"; then
  export GH_REPO
fi

spent_usd=0
completed_labels=""

write_summary() {
  local complete="$1" stopped_before="${2:-}"
  jq -n --argjson complete "$complete" --arg spent "$spent_usd" --arg cap "$maximum_usd" --arg done_labels "$completed_labels" --arg stopped_before "$stopped_before" \
    '{complete: $complete, spent_usd: ($spent | tonumber), max_usd: ($cap | tonumber), completed: ($done_labels | split(" ") | map(select(length > 0))), stopped_before: (if $stopped_before == "" then null else $stopped_before end)}' \
    >"$output_directory/summary.json"
}

# Copies the session transcript and its sub-agent directory to <dest>/ and
# prints the copied main transcript path.
copy_session() {
  local session_id="$1" destination="$2" candidate
  mkdir -p "$destination"
  for candidate in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$session_id".jsonl; do
    [ -f "$candidate" ] || continue
    cp "$candidate" "$destination/$session_id.jsonl"
    [ ! -d "${candidate%.jsonl}" ] || cp -R "${candidate%.jsonl}" "$destination/$session_id"
    printf '%s\n' "$destination/$session_id.jsonl"
    return 0
  done
  return 1
}

# One claude session; sets session_transcript to the copied transcript path
# (empty when none could be found). Refuses to start once the cap is reached;
# the session that crosses it still gets its measure or callability row.
run_session() {
  local label="$1" prompt="$2" remaining stream cost session_id
  remaining="$(awk -v cap="$maximum_usd" -v spent="$spent_usd" 'BEGIN { printf "%.4f", cap - spent }')"
  if ! awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; then
    write_summary false "$label"
    echo "ERROR: cost cap reached: spent \$$spent_usd of --max-usd \$$maximum_usd; stopped before $label" >&2
    exit 3
  fi
  mkdir -p "$output_directory/$label"
  stream="$output_directory/$label/stream.jsonl"
  # bypassPermissions: a scratch tree is an untrusted workspace, so headless
  # claude ignores the project's allow list, and a background sub-agent's
  # WebFetch is denied with no one to answer the prompt.
  (
    cd "$root"
    exec env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
      claude -p "$prompt" --output-format stream-json --verbose --model "$model" \
      --permission-mode bypassPermissions --max-budget-usd "$remaining"
  ) >"$stream" 2>"$output_directory/$label/stderr.log" </dev/null || true
  session_transcript=""
  session_id="$(jq -rs '[.[] | select(.type == "system" and .subtype == "init") | .session_id][0] // empty' "$stream" 2>/dev/null || true)"
  if [ -n "$session_id" ]; then
    session_transcript="$(copy_session "$session_id" "$output_directory/$label" || true)"
  fi
  cost="$(jq -s '[.[] | select(.type == "result") | (.total_cost_usd // 0)] | add // empty' "$stream" 2>/dev/null || true)"
  if [ -z "$cost" ] || [ "$cost" = null ]; then
    write_summary false "$label"
    echo "ERROR: cannot read total_cost_usd from $stream; stopping (cost cannot be capped blind)" >&2
    exit 3
  fi
  spent_usd="$(awk -v spent="$spent_usd" -v cost="$cost" 'BEGIN { printf "%.6f", spent + cost }')"
  completed_labels="$completed_labels $label"
}

measure_session() {
  local label="$1" agent_type="$2"
  if [ -z "$session_transcript" ]; then
    echo "WARN: no transcript found for $label; no measure written" >&2
    return 0
  fi
  node "$SCRIPT_DIRECTORY/measure-dispatch.mjs" --session "$session_transcript" --rates "$RATES_FILE" \
    --measure-types "$agent_type" --out "$output_directory/$label/measure.json" 2>"$output_directory/$label/measure.err" \
    || echo "WARN: measure-dispatch failed for $label (see $output_directory/$label/measure.err)" >&2
}

dispatch_prompt() {
  local agent_type="$1" inner="$2"
  printf 'Use the Agent tool exactly once, with subagent_type "%s", description "first-call probe" and this prompt: %s\nMake no other tool call. When it returns, reply with the single word DONE.' "$agent_type" "$inner"
}

session_transcript=""
old_ifs="$IFS"
IFS=,
read -r -a type_list <<<"$types"
IFS="$old_ifs"

for agent_type in ${type_list[@]+"${type_list[@]}"}; do
  run_session "$agent_type" "$(dispatch_prompt "$agent_type" "$TRIVIAL_PROMPT")"
  measure_session "$agent_type" "$agent_type"
done

if [ "$with_callability" -eq 1 ]; then
  entries_file="$output_directory/callability-entries.jsonl"
  : >"$entries_file"
  unit_prompt="This is a callability probe in a scratch tree. Make exactly these tool calls in order and nothing else: 1. Dispatch one trivial child with the Agent tool (subagent_type general-purpose, prompt \"Reply with the single word OK.\"). 2. Continue that same child once with SendMessage. 3. Run one Monitor on the command: echo ok. Then reply DONE."
  run_session "callability-audit-loop-unit" "$(dispatch_prompt audit-loop-unit "$unit_prompt")"
  if [ -n "$session_transcript" ]; then
    node "$SCRIPT_DIRECTORY/lib/session-checks.mjs" callability "$session_transcript" audit-loop-unit SendMessage,Monitor >>"$entries_file" || true
  fi
  shell_prompt="This is a callability probe in a scratch tree. Make exactly these tool calls in order and nothing else: 1. Run one Monitor on the command: echo ok. 2. Run one WebFetch of https://example.com. Then reply DONE."
  run_session "callability-code-audit-maintainer-shell" "$(dispatch_prompt code-audit-maintainer-shell "$shell_prompt")"
  if [ -n "$session_transcript" ]; then
    node "$SCRIPT_DIRECTORY/lib/session-checks.mjs" callability "$session_transcript" code-audit-maintainer-shell Monitor,WebFetch >>"$entries_file" || true
  fi
  jq -s 'add // []' "$entries_file" >"$output_directory/callability.json"
fi

if awk -v spent="$spent_usd" -v cap="$maximum_usd" 'BEGIN { exit !(spent >= cap) }'; then
  write_summary false ""
  echo "ERROR: cost cap reached: spent \$$spent_usd of --max-usd \$$maximum_usd" >&2
  exit 3
fi
write_summary true ""
