# shellcheck shell=bash
# Writes transcript JSONL lines in the shapes the usage flusher reads, so a bats
# suite builds a session transcript one line at a time instead of keeping a
# fixture file per scenario. Sourced by the usage flush suites that need
# timestamps, openers, tool uses and turn lengths under test control.
#
# Each function appends one line to <file>. The session id, cwd, branch and
# entrypoint come from UT_SESSION, UT_CWD (required), UT_BRANCH and
# UT_ENTRYPOINT (defaults s-act, main, cli). A queue-operation line carries no
# cwd, as in a real transcript.

# shellcheck disable=SC2016  # jq filters; no shell expansion
_ut_common() {
  jq -nc --arg session "${UT_SESSION:-s-act}" --arg cwd "${UT_CWD:?UT_CWD must name the tree root}" \
    --arg branch "${UT_BRANCH:-main}" --arg entrypoint "${UT_ENTRYPOINT:-cli}" \
    '{sessionId: $session, cwd: $cwd, gitBranch: $branch, entrypoint: $entrypoint}'
}

# ut_append <file> <jq-filter> [jq args...]: merges the common keys into the object the filter builds.
_ut_append() {
  local file="$1" filter="$2"
  shift 2
  jq -nc --argjson common "$(_ut_common)" "$@" "$filter" >>"$file"
}

ut_prompt() {
  _ut_append "$1" '{type: "user", uuid: ("u-p-" + $at), timestamp: $at, message: {role: "user", content: $text}} + $common' \
    --arg at "$2" --arg text "${3:-go}"
}

ut_notification() {
  jq -nc --arg session "${UT_SESSION:-s-act}" --arg at "$2" \
    '{type: "queue-operation", operation: "dequeue", timestamp: $at, sessionId: $session}' >>"$1"
}

ut_queued_attachment() {
  _ut_append "$1" '{type: "attachment", uuid: ("u-q-" + $at), timestamp: $at, attachment: {type: "queued_command", prompt: "queued"}} + $common' \
    --arg at "$2"
}

# ut_assistant <file> <iso> <message_id> [--tool <name> <tool_use_id>] [--tokens <input> <output>] [--model <model>]
ut_assistant() {
  local file="$1" at="$2" message_id="$3" tool_name="" tool_use_id="" input_tokens=1 output_tokens=1 model="claude-opus-5-5"
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tool) tool_name="$2"; tool_use_id="$3"; shift 3 ;;
      --tokens) input_tokens="$2"; output_tokens="$3"; shift 3 ;;
      --model) model="$2"; shift 2 ;;
      *) echo "ut_assistant: unknown option $1" >&2; return 1 ;;
    esac
  done
  _ut_append "$file" '{type: "assistant", uuid: ("u-" + $message_id), timestamp: $at,
      message: {id: $message_id, model: $model, role: "assistant",
        usage: {input_tokens: $input_tokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: $output_tokens},
        content: (if $tool_name == "" then [{type: "text", text: "ok"}] else [{type: "tool_use", id: $tool_use_id, name: $tool_name, input: {}}] end)}} + $common' \
    --arg at "$at" --arg message_id "$message_id" --arg model "$model" --arg tool_name "$tool_name" --arg tool_use_id "$tool_use_id" \
    --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens"
}

ut_tool_result() {
  _ut_append "$1" '{type: "user", uuid: ("u-r-" + $at), timestamp: $at,
      message: {role: "user", content: [{type: "tool_result", tool_use_id: $tool_use_id, content: "ok"}]}} + $common' \
    --arg at "$2" --arg tool_use_id "$3"
}

ut_turn_duration() {
  _ut_append "$1" '{type: "system", subtype: "turn_duration", uuid: ("u-d-" + $at), timestamp: $at, durationMs: $duration} + $common' \
    --arg at "$2" --argjson duration "$3"
}

ut_system() {
  _ut_append "$1" '{type: "system", subtype: $subtype, uuid: ("u-s-" + $at), timestamp: $at, content: "note"} + $common' \
    --arg at "$2" --arg subtype "$3"
}

ut_interrupt() {
  _ut_append "$1" '{type: "user", uuid: ("u-i-" + $at), timestamp: $at,
      message: {role: "user", content: [{type: "text", text: "[Request interrupted by user]"}]}} + $common' \
    --arg at "$2"
}

ut_meta_prompt() {
  _ut_append "$1" '{type: "user", isMeta: true, uuid: ("u-m-" + $at), timestamp: $at, message: {role: "user", content: "meta"}} + $common' \
    --arg at "$2"
}
