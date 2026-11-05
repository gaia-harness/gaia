# shellcheck shell=bash
#
# Sourced by plan-verify.sh, never executed (nothing runs at source time).
# plan_phases_check <readme> <orchestrator> <routing-rows-text> prints one
# failure message per line on stdout (no "plan-verify: " prefix) and returns 0;
# plan-verify.sh passes each line to its `fail`. It runs only for a
# spec-derived plan. <routing-rows-text> is uat_lib_parse_routing's output
# (tab-separated uat_id, surface, phase, feature_folder, file_name).
#
# Why: a phase that owns no acceptance test can only carry per-function unit
# tests, so a phase either owns a routing-table row (any surface) or is marked
# infrastructure with a reason.
#
# README phase list: a line that starts, after optional whitespace, with
# "| Phase <N>" (a task-graph row), "**Phase <N>" or a ##, ### or ####
# heading "Phase <N>", where <N> is a positive integer followed by a non-digit
# or the end of the line. Phases are enumerated from this list, never from the
# routing table.
#
# ORCHESTRATOR phase list: lines outside every fenced block (a line starting
# with three backticks toggles a fence) of the form "**Phase <N>, <title>".
# Fenced text is never read, so the progress-ledger examples a planner copies
# (headings such as "## Phase 2, Helper implementation") never count, and no
# heading form counts in ORCHESTRATOR.md.
#
# Infrastructure marker: a README line "- Phase <N>: Infrastructure: <reason>".
# Only its syntax is judged: a reason empty after trimming is refused, and the
# check does not judge whether the reason holds.
#
# Failures, each naming the phase (and the UAT where one applies): no phase
# listed; a gap in the list (it must run 1..N); a README phase with no
# ORCHESTRATOR entry and the reverse; a routing row or a marker naming a phase
# the README lacks; a marker with an empty reason; a phase with no routing row
# and no marker with a reason.
#
# Bash 3.2 compatible; BSD and GNU tools.

plan_phases_check() {
  local readme="$1" orchestrator="$2" routing_rows="$3"
  local tab=$'\t' readme_phases orchestrator_phases markers highest phase number
  local uat_id row_phase reason owned

  readme_phases=$(sed -nE 's/^[[:space:]]*([|][[:space:]]*|\*\*|#{2,4}[[:space:]]+)Phase[[:space:]]+([1-9][0-9]*)([^0-9].*)?$/\2/p' "$readme" | sort -un)
  if [ -z "$readme_phases" ]; then
    printf "README.md names no phase: list each phase as a '| Phase <N>' task-graph row or a '### Phase <N>' heading\n"
    return 0
  fi

  highest=$(printf '%s\n' "$readme_phases" | tail -n 1)
  number=1
  while [ "$number" -le "$highest" ]; do
    grep -qxF -- "$number" <<<"$readme_phases" || printf "README.md's phase list skips Phase %s\n" "$number"
    number=$((number + 1))
  done

  orchestrator_phases=$(awk '
    /^[[:space:]]*```/ { fenced = !fenced; next }
    !fenced && $0 ~ /^[[:space:]]*\*\*Phase[[:space:]]+[1-9][0-9]*,/ {
      text = $0
      sub(/^[[:space:]]*\*\*Phase[[:space:]]+/, "", text)
      sub(/,.*$/, "", text)
      print text
    }' "$orchestrator" | sort -un)
  for phase in $readme_phases; do
    grep -qxF -- "$phase" <<<"$orchestrator_phases" || printf 'ORCHESTRATOR.md has no phase entry for Phase %s\n' "$phase"
  done
  for phase in $orchestrator_phases; do
    grep -qxF -- "$phase" <<<"$readme_phases" || printf "ORCHESTRATOR.md names Phase %s, which README.md's phase list lacks\n" "$phase"
  done

  while IFS="$tab" read -r uat_id _ row_phase _; do
    [ -n "$uat_id" ] || continue
    grep -qxF -- "$row_phase" <<<"$readme_phases" || printf "%s is routed to Phase %s, which README.md's phase list lacks\n" "$uat_id" "$row_phase"
  done <<<"$routing_rows"

  markers=$(sed -nE "s/^[[:space:]]*[-*][[:space:]]+Phase[[:space:]]+([1-9][0-9]*):[[:space:]]+Infrastructure:(.*)\$/\\1${tab}\\2/p" "$readme")
  while IFS="$tab" read -r phase reason; do
    [ -n "$phase" ] || continue
    grep -qxF -- "$phase" <<<"$readme_phases" || printf "the Infrastructure marker names Phase %s, which README.md's phase list lacks\n" "$phase"
    [ -n "${reason//[[:space:]]/}" ] || printf "Phase %s's Infrastructure marker has an empty reason\n" "$phase"
  done <<<"$markers"

  for phase in $readme_phases; do
    owned=0
    while IFS="$tab" read -r uat_id _ row_phase _; do
      [ -n "$uat_id" ] || continue
      [ "$row_phase" = "$phase" ] && owned=1
    done <<<"$routing_rows"
    # A marker with an empty reason was reported above; it is not reported twice.
    while IFS="$tab" read -r number _; do
      [ "$number" = "$phase" ] && owned=1
    done <<<"$markers"
    [ "$owned" -eq 1 ] || printf "Phase %s owns no acceptance test: no routing-table row names it and README.md carries no '- Phase %s: Infrastructure: <reason>' line\n" "$phase" "$phase"
  done
  return 0
}
