# shellcheck shell=bash
#
# The read-only reports of audit-loop-eval.sh's CLI: the checkpoint brief with
# its spend line, and the light, quick and review additions to record-values.
# Sourced only by audit-loop-eval.sh. That script's header owns what each
# subcommand prints.

# _gaia_loop_spend <raw-branch>: usage.sh's text, or `unavailable`. A
# watchdog, not timeout(1), which macOS lacks; `set -m` gives the child its
# own process group so the kill also reaches anything it spawned, which would
# otherwise hold the capture pipe open past the deadline.
_gaia_loop_spend() {
  local usage_output exit_status=0
  usage_output="$(
    set -m
    bash "$_GAIA_LOOP_EVAL_DIRECTORY/usage.sh" pr --branch "$1" </dev/null 2>/dev/null &
    pid=$!
    (sleep "$_GAIA_LOOP_SPEND_TIMEOUT"; kill -TERM -- "-$pid") </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!
    wait "$pid"
    child_status=$?
    kill -TERM -- "-$watchdog_pid" 2>/dev/null
    exit "$child_status"
  )" 2>/dev/null || exit_status=$?
  if [ "$exit_status" -ne 0 ] || [ -z "$usage_output" ]; then
    printf 'unavailable'
  else
    printf '%s' "$usage_output"
  fi
}

# _gaia_loop_brief <audited-root> <main-root> <state-json>: the checkpoint
# brief.
_gaia_loop_brief() {
  local root="$1" main="$2" state="$3" used allowed pending snapshot findings raw spend per_round="[]" i round_snapshot head_tree blocked_snapshot
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  [ "$used" -ge 1 ] || { printf 'audit-loop-eval: no recorded round to brief for %s\n' "$(printf '%s' "$state" | jq -r '.branch')" >&2; return 2; }
  allowed="$(gaia_loop_allowed "$state")"
  pending="$(gaia_loop_pending_checkpoint "$state")"
  snapshot="$(printf '%s' "$state" | jq -c '.history.rounds | last | .snapshot')"
  [ "$snapshot" = null ] && { snapshot="$(gaia_loop_evaluate_round "$main" "$state" "$used" "$root")" || return $?; }
  i=1
  while [ "$i" -le "$used" ]; do
    if [ "$i" -eq "$used" ]; then round_snapshot="$snapshot"; else round_snapshot="$(printf '%s' "$state" | jq -c --argjson i "$i" '.history.rounds[$i - 1].snapshot')"; fi
    per_round="$(printf '%s' "$state" | jq -c --argjson accumulated_rounds "$per_round" --argjson round_snapshot "$round_snapshot" --argjson i "$i" \
      '$accumulated_rounds + [{round: $i, A: $round_snapshot.A?, verdict: $round_snapshot.verdict?, closing: (.history.rounds[$i - 1].closing // false)}]')"
    i=$((i + 1))
  done
  findings="$(gaia_loop_findings "$main" "$state" "$used")"
  head_tree="$(_gaia_loop_git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=""
  blocked_snapshot="$(gaia_loop_accept_blockers "$main" "$root" "$state" "$head_tree" "$snapshot")" || blocked_snapshot=null
  raw="$(_gaia_loop_git -C "$root" branch --show-current 2>/dev/null)" || raw=""
  spend="$(_gaia_loop_spend "$raw")"
  jq -n -c --argjson state "$state" --argjson used "$used" --argjson allowed "$allowed" \
    --argjson pending "$([ -n "$pending" ] && echo true || echo false)" --argjson per_round "$per_round" \
    --argjson pending_checkpoint "${pending:-null}" --argjson cap "$_GAIA_LOOP_HARD_CAP" \
    --argjson snapshot "$snapshot" --argjson findings "$findings" --arg spend "$spend" \
    --arg recommended "$(gaia_loop_recommended "$(printf '%s' "${pending:-null}" | jq -r '.trigger // empty')" "$blocked_snapshot")" \
    --argjson accept_blockers "$(printf '%s' "$blocked_snapshot" | jq -c '.accept_blockers? // null')" \
    --arg grant_line "$(gaia_loop_grant_line "$(_gaia_loop_grant_rounds "$state")")" --arg accept_line "$(gaia_loop_accept_line)" '
    {branch: $state.branch, pr: $state.pr, rounds_run: $used, allowed: $allowed, pending_checkpoint: $pending,
     per_round: $per_round, verdict: $snapshot.verdict, evidence: $snapshot.evidence,
     signals: ($snapshot.signals // null), accept_eligible: ($snapshot.accept_eligible == true),
     accept_reasons: ($snapshot.accept_reasons // []), rounds_cap: $cap,
     recommended: $recommended, accept_blockers: $accept_blockers,
     grant_line: $grant_line, accept_line: $accept_line,
     remaining_by_severity: ($findings.entries | {critical: map(select(.severity == "critical")) | length,
                                            major: map(select(.severity == "major")) | length,
                                            minor: map(select(.severity == "minor")) | length}),
     spend: $spend, spend_note: "information only"}'
}

# _gaia_loop_with_review_counts <root> <record-values-json>: adds the `light`
# (post-clearance reviews) and `quick` (merge-base clears) per-member counts
# from the branch's light-review ledger; `quick` drops members that have a full
# round. They never enter `total`, and each key
# is left out when the ledger is absent, unreadable or has no positive count.
_gaia_loop_with_review_counts() {
  local root="$1" values_json="$2" light_ledger review_counts=''
  light_ledger="$root/.gaia/local/audit/light/$(gaia_branch_slug "$root" 2>/dev/null).reviews.jsonl"
  if [ -f "$light_ledger" ] && [ -r "$light_ledger" ]; then
    review_counts="$(jq -cs 'map(select(type == "object" and (.member | type) == "string")) as $lines
      | def tally(selector): [$lines[] | select(selector) | .member] | reduce .[] as $member ({}; .[$member] += 1) | to_entries | sort_by(.key) | from_entries;
        {light: tally(.anchor_kind != "merge-base"), quick: tally(.anchor_kind == "merge-base" and .verdict == "clear")}
      | with_entries(select(.value != {}))' "$light_ledger" 2>/dev/null)" || review_counts=''
  fi
  if [ -n "$review_counts" ] && [ "$review_counts" != '{}' ]; then
    printf '%s' "$values_json" | jq -c --argjson counts "$review_counts" '. as $values
      | ($counts | if has("quick") then .quick |= with_entries(select(.key as $member | $values.members | has($member) | not)) else . end
         | with_entries(select(.value != {}))) as $kept
      | $values + $kept'
  else
    printf '%s\n' "$values_json"
  fi
}

# _gaia_loop_with_review_object <root> <run-folder> <rounds> <pr-or-empty> <values-json>:
# adds the additive `review` key from the review record's publish-values. The key
# is left out when that prints nothing or fails, so the line keeps its old shape.
_gaia_loop_with_review_object() {
  local root="$1" run_folder="$2" rounds="$3" pull_request="$4" values_json="$5" review_object
  local -a pull_request_arguments=()
  [ -z "$pull_request" ] || pull_request_arguments=(--pr "$pull_request")
  review_object="$(bash "$_GAIA_LOOP_EVAL_DIRECTORY/audit-code-review-record.sh" publish-values \
    --root "$root" --run-folder "$run_folder" --rounds "$rounds" ${pull_request_arguments[@]+"${pull_request_arguments[@]}"} 2>/dev/null)" || review_object=""
  if [ -n "$review_object" ]; then
    printf '%s' "$values_json" | jq -c --argjson review "$review_object" '. + {review: $review}'
  else
    printf '%s\n' "$values_json"
  fi
}
