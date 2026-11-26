# shellcheck shell=bash
#
# The human-set round cap, the trigger set an answer-free admission may cover
# (shared by the bound hook's autonomy budget and its automatic continue), and
# the automatic continue and hand-off rule. Sourced by audit-loop-eval.sh after
# audit-loop-signals-lib.sh, which defines _GAIA_LOOP_HARD_CAP. The cap's range
# rule is context-checkpoint-lib.sh's `Override rule`; the decisions that read
# it are audit-loop-eval.sh's DECISION.
#
# AUTOMATIC CONTINUE AND HAND-OFF. This header owns the rule, and
# gaia_loop_automatic_answer is its one copy. The bound hook applies it at a
# unit dispatch its decision would deny with a checkpoint, before the autonomy
# budget. It never reads the autonomy switch, a file or the environment: every
# input is an argument the hook already holds. First match wins:
#   1. ask when the cap is invalid, the dispatch is at or past C, a fix is
#      disputed, or the latest answer is an accept: a human decision is at stake;
#   2. ask without a live line and a usable reading: ask_tokens 0, a line of 0
#      or none, or a reading that is not `fresh <tokens> <window>`;
#   3. hand off on the context trigger;
#   4. on a trigger gaia_loop_grant_window_trigger accepts, read the pinned
#      question's lead: the in-session grant leading under its plain label with
#      the reading below the line continues automatically; the new-session
#      grant leading with the reading at or above the line hands off;
#   5. ask otherwise.
# The lead is read rather than re-derived because gaia_loop_pinned_question is
# the one place a recommendation becomes a lead. The lead alone is not the
# predicate: it also puts the in-session grant first with the line off or on a
# repeated dispute, which rules 1 and 2 exclude.
# An automatic continue admits the unit as a grant of K would, ending at C and
# marked `automatic: true`, with no checkpoint, no question and no answer, so
# its window lifts what a human grant's does. A hand-off records the checkpoint
# with `handoff: true` and denies with the lines gaia_loop_handoff_instructions
# prints in place of the pinned question: nobody answers, the session saves its
# place, and a fresh session's unit dispatch continues on its own low reading
# (the decision admits `context`, or rule 4 continues automatically). The typed
# grant and accept lines stay printed as a present human's opt-out.
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

# gaia_loop_automatic_answer <trigger> <question-json> <reading> <ask_tokens>
# <context_line> <disputes-json> <latest_answer_kind> <cap_valid> <used> <cap>:
# prints `automatic`, `handoff` or `ask` (AUTOMATIC CONTINUE AND HAND-OFF above).
# rc 2 and nothing printed on a malformed argument, which the hook reads as ask.
gaia_loop_automatic_answer() {
  local trigger="${1-}" question="${2-}" reading="${3-}" ask_tokens="${4-}" line="${5-}" disputes="${6-}"
  local latest_answer_kind="${7-}" cap_valid="${8-}" used="${9-}" cap="${10-}" integer='^(0|[1-9][0-9]{0,11})$' facts disputed lead tokens
  [ $# -eq 10 ] || return 2
  [[ $trigger =~ ^(context|cap|fallback|rubric:[A-Za-z0-9_.-]+)$ ]] || return 2
  [[ $ask_tokens =~ $integer && $used =~ $integer && $cap =~ $integer ]] || return 2
  [ -z "$line" ] || [[ $line =~ $integer ]] || return 2
  facts=$(jq -nr --argjson question "$question" --argjson disputes "$disputes" '
    if ($disputes | type) != "array" or ($question.questions[0].options | type) != "array" then error("malformed")
    else "\($disputes | length > 0) \([$question.questions[0].options[].label | strings | select(endswith(" (Recommended)"))] | first // "")" end' 2>/dev/null) || return 2
  disputed="${facts%% *}"
  lead="${facts#* }"
  if [ "$cap_valid" != true ] || [ "$used" -ge "$cap" ] || [ "$disputed" != false ] || [ "$latest_answer_kind" = accept ]; then
    printf 'ask\n'
    return 0
  fi
  if [ "$ask_tokens" -eq 0 ] || [ -z "$line" ] || [ "$line" -eq 0 ] || ! [[ $reading =~ ^fresh\ (0|[1-9][0-9]{0,11})\ (0|[1-9][0-9]{0,11})$ ]]; then
    printf 'ask\n'
    return 0
  fi
  tokens="${BASH_REMATCH[1]}"
  if [ "$trigger" = context ]; then
    printf 'handoff\n'
  elif gaia_loop_grant_window_trigger "$trigger" && [ "$lead" = 'Continue audit in this session (Recommended)' ] && [ "$tokens" -lt "$line" ]; then
    printf 'automatic\n'
  elif gaia_loop_grant_window_trigger "$trigger" && [ "$lead" = 'Continue audit in a new session (Recommended)' ] && [ "$tokens" -ge "$line" ]; then
    printf 'handoff\n'
  else
    printf 'ask\n'
  fi
}

# gaia_loop_handoff_instructions: the hand-off deny's instruction lines, the
# one spelling the bound hook prints in place of the pinned question.
gaia_loop_handoff_instructions() {
  printf '%s\n' \
    'Hand-off checkpoint: do not ask a question. Save your place and hand off to a fresh session; its unit dispatch continues with no answer.' \
    'Inside an audit-loop-unit: stop with stop_reason checkpoint-deny and return; the main thread hands off.' \
    'Inside a /gaia-next pr job: leave the worktree with ExitWorktree (keep), then end the job with no park; the picker skips this pull request for this session.' \
    'Otherwise: print the continuation prompt and its instruction line, then stop.'
}
