#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the GAIA_PAYLOAD_AGENT_* globals are this library's output, read by the sourcing hook
#
# payload-agent.sh: the one reader of which agent made a hook call. Sourced,
# never executed; defines one function and does no work at source time. Bash 3.2
# compatible, bash only (no jq, no subprocess), so a hook every tool call pays can
# afford it.
#
#   gaia_payload_agent_read <raw-payload>
#
# The harness puts `agent_id` and `agent_type` at the top level of a sub-agent's
# payload (a fork's included, `agent_type` "fork") and neither on the main
# thread's (wiki/concepts/Claude Hooks.md). Always returns 0 and sets:
#
#   GAIA_PAYLOAD_AGENT_PRESENT  1 when an `agent_id` key is present, else 0
#   GAIA_PAYLOAD_AGENT_ID       its string value when that has the id shape
#                               (^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$), else ""
#   GAIA_PAYLOAD_AGENT_TYPE     the `agent_type` string value, else ""
#
# So a present key with a value of the wrong type or shape reads as a sub-agent
# with no usable id. A caller that denies on PRESENT fails closed on it; a
# caller that builds a path from the id stands down on "".
#
# Lookalike safety: a key counts only when no backslash precedes its opening
# quote, so `"agent_id"` written inside a string value (a Bash command, which
# JSON escapes as `\"agent_id\"`) never matches. A key nested inside an object
# of tool_input is unescaped and would match, so a caller whose tool input can
# carry object keys confirms with a real parse before acting on these values.

[ -n "${GAIA_PAYLOAD_AGENT_SH:-}" ] && return 0
GAIA_PAYLOAD_AGENT_SH=1

gaia_payload_agent_read() {
  local payload="$1"
  local key_pattern='(^|[^\\])"agent_id"[[:space:]]*:'
  local id_pattern='(^|[^\\])"agent_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
  local type_pattern='(^|[^\\])"agent_type"[[:space:]]*:[[:space:]]*"([^"]*)"'
  local id_shape='^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$'
  local candidate_id
  GAIA_PAYLOAD_AGENT_PRESENT=0
  GAIA_PAYLOAD_AGENT_ID=""
  GAIA_PAYLOAD_AGENT_TYPE=""
  [[ $payload =~ $key_pattern ]] || return 0
  GAIA_PAYLOAD_AGENT_PRESENT=1
  if [[ $payload =~ $id_pattern ]]; then
    candidate_id="${BASH_REMATCH[2]}"
    if [[ $candidate_id =~ $id_shape ]]; then GAIA_PAYLOAD_AGENT_ID="$candidate_id"; fi
  fi
  if [[ $payload =~ $type_pattern ]]; then
    GAIA_PAYLOAD_AGENT_TYPE="${BASH_REMATCH[2]}"
  fi
  return 0
}
