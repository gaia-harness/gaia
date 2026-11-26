# shellcheck shell=bash
#
# The human-set round cap and the trigger set an answer-free admission may
# cover, shared by the bound hook's autonomy budget and its automatic continue.
# Sourced by audit-loop-eval.sh after audit-loop-signals-lib.sh, which defines
# _GAIA_LOOP_HARD_CAP. The cap's range rule is context-checkpoint-lib.sh's
# `Override rule`; the decisions that read it are audit-loop-eval.sh's
# DECISION.
#
# Defines functions only and runs nothing at source time. Bash 3.2
# compatible. Never `cd`s.

# gaia_loop_round_cap_state <main-root>: prints `<status> <cap> <value>`.
# status is absent, ok, capped or invalid; cap is the integer in use (the
# value for ok, the hard cap otherwise); value is `-` when nothing was read,
# else the key as compact JSON and the rest of the line. A missing jq reads as
# invalid: the file is there and cannot be honoured.
gaia_loop_round_cap_state() {
  local file="${1:-}/.gaia/local/protected/checkpoint-override.json" fields
  [ -f "$file" ] || { printf 'absent %s -\n' "$_GAIA_LOOP_HARD_CAP"; return 0; }
  if command -v jq >/dev/null 2>&1; then
    fields=$(jq -rs --argjson hard "$_GAIA_LOOP_HARD_CAP" '
      if length != 1 or (.[0] | type) != "object" or .[0].version != 1 then "invalid \($hard) -"
      elif .[0].audit_loop == null then "absent \($hard) -"
      elif (.[0].audit_loop | type) != "object" then "invalid \($hard) -"
      elif (.[0].audit_loop | has("round_cap") | not) then "absent \($hard) -"
      else .[0].audit_loop.round_cap as $value
        | if ($value | type) != "number" or $value != ($value | floor) or $value < 1 then "invalid \($hard) \($value | tojson)"
          elif $value > $hard then "capped \($hard) \($value | tojson)"
          else "ok \($value) \($value | tojson)" end
      end' "$file" 2>/dev/null) || fields=""
    if [[ $fields =~ ^(absent|ok|capped|invalid)\ [0-9]{1,12}\ [^[:space:]].*$ ]]; then
      printf '%s\n' "$fields"
      return 0
    fi
  fi
  printf 'invalid %s -\n' "$_GAIA_LOOP_HARD_CAP"
}

# gaia_loop_grant_window_trigger <trigger>: rc 0 for a trigger a grant window
# lifts, the set the autonomy budget and the automatic continue both answer.
gaia_loop_grant_window_trigger() {
  case "${1:-}" in
    fallback | rubric:enriching | rubric:stalled | rubric:nitpicky | rubric:small-tail) return 0 ;;
    *) return 1 ;;
  esac
}
