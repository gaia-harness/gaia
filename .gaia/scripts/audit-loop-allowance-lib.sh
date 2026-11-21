# shellcheck shell=bash
#
# The allowance and the gate decision for audit-loop-eval.sh: the knobs frozen
# at round 1, the allowance fold, gaia_loop_decide, and the context-line config
# frozen at round 1 and in effect. Sourced only by audit-loop-eval.sh, which
# sets the defaults these read. That script's header owns the formulas.

# _gaia_loop_live <knob-name>: the live value when set and valid, else rc 1.
_gaia_loop_live() {
  local name="$1" value="" isset=0
  case "$name" in
    GAIA_AUDIT_CHECKPOINT_ROUND) [ "${GAIA_AUDIT_CHECKPOINT_ROUND+x}" = x ] && isset=1 && value="$GAIA_AUDIT_CHECKPOINT_ROUND" ;;
    GAIA_AUDIT_GRANT_ROUNDS) [ "${GAIA_AUDIT_GRANT_ROUNDS+x}" = x ] && isset=1 && value="$GAIA_AUDIT_GRANT_ROUNDS" ;;
  esac
  [ "$isset" -eq 1 ] || return 1
  if gaia_loop_is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 99 ]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'audit-loop: ignoring malformed %s=%s (want an integer 1..99)\n' "$name" "$value" >&2
  return 1
}

# gaia_loop_knobs_initial: the knobs a branch freezes at round 1.
gaia_loop_knobs_initial() {
  local checkpoint_round="$_GAIA_LOOP_CHECKPOINT_DEFAULT" grant_rounds="$_GAIA_LOOP_GRANT_DEFAULT" value
  if value="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" && [ "$value" -lt "$checkpoint_round" ]; then checkpoint_round="$value"; fi
  if value="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS)" && [ "$value" -lt "$grant_rounds" ]; then grant_rounds="$value"; fi
  printf '{"checkpoint_round":%s,"grant_rounds":%s}\n' "$checkpoint_round" "$grant_rounds"
}

# gaia_loop_allowed <state-json>: the allowance after folding every answer.
gaia_loop_allowed() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.checkpoint_round // $init.checkpoint_round) as $base
    | .history.checkpoints as $checkpoints
    | if (.allowance.answers | length) == 0 then
        (if $live != null and $live < $base then $live else $base end)
      else
        reduce .allowance.answers[] as $answer ($base;
          ([$checkpoints[] | select(.index == $answer.checkpoint)] | .[0].at_round) as $answered_round
          | if $answered_round == null then .
            elif $answer.kind == "grant" then $answered_round + $answer.n
            elif $answer.kind == "accept" then $answered_round + 1
            else . end)
      end'
}

# _gaia_loop_grant_rounds <state-json>: the default n the brief prints.
_gaia_loop_grant_rounds() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS 2>/dev/null)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.grant_rounds // $init.grant_rounds) as $base
    | if $live != null and $live < $base then $live else $base end'
}

# gaia_loop_decide <state-json> <r-snapshot-json>: `allow` or `deny <reason>`.
gaia_loop_decide() {
  local state="$1" snapshot="${2:-null}" used allowed verdict answered
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')" || return 5
  allowed="$(gaia_loop_allowed "$state")" || return 5
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap\n'
    return 0
  fi
  if [ "$(_gaia_loop_stop_override_set "$snapshot")" = true ]; then
    printf 'allow\n'
    return 0
  fi
  if [ "$used" -ge "$allowed" ]; then
    printf 'deny allowance\n'
    return 0
  fi
  verdict="$(printf '%s' "$snapshot" | jq -r '.verdict? // empty' 2>/dev/null)" || verdict=""
  case "$verdict" in
    stalled | enriching)
      answered="$(printf '%s' "$state" | jq -r --argjson round "$used" '
        [.history.checkpoints[] | select(.at_round >= $round) | .index] as $indexes
        | any(.allowance.answers[]; .checkpoint as $checkpoint | any($indexes[]; . == $checkpoint))')"
      if [ "$answered" != true ]; then
        printf 'deny %s\n' "$verdict"
        return 0
      fi
      ;;
  esac
  printf 'allow\n'
}

# gaia_loop_context_config_initial <main-root>: the line config a branch
# freezes, as {"ask_tokens","ask_window_pct"}.
gaia_loop_context_config_initial() {
  local tokens percent
  read -r tokens percent <<<"$(gaia_context_override "$1")"
  tokens="$(_gaia_loop_minimum "$tokens" "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT")"
  percent="$(_gaia_loop_minimum "$percent" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT")"
  printf '{"ask_tokens":%s,"ask_window_pct":%s}\n' "$tokens" "$percent"
}

# gaia_loop_context_config_effective <main-root> <state-json>: prints
# `<ask_tokens> <ask_window_pct>`; rc 5 when the state cannot be read.
gaia_loop_context_config_effective() {
  local init frozen live_tokens live_percent tokens percent integer_pattern='^[1-9][0-9]{0,11} [1-9][0-9]{0,11}$'
  init="$(gaia_loop_context_config_initial "$1")"
  frozen="$(printf '%s' "$2" | jq -r --argjson initial "$init" '
    def positive_integer: type == "number" and . == floor and . >= 1;
    (.history.context_config | if type == "object" then . else {} end) as $config
    | "\(if ($config.ask_tokens | positive_integer) then $config.ask_tokens else $initial.ask_tokens end) \(if ($config.ask_window_pct | positive_integer) then $config.ask_window_pct else $initial.ask_window_pct end)"' 2>/dev/null)" || return 5
  [[ $frozen =~ $integer_pattern ]] || return 5
  read -r tokens percent <<<"$frozen"
  read -r live_tokens live_percent <<<"$(gaia_context_override "$1")"
  printf '%s %s\n' "$(_gaia_loop_minimum "$tokens" "$live_tokens")" "$(_gaia_loop_minimum "$percent" "$live_percent")"
}
