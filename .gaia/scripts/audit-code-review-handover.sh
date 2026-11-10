# shellcheck shell=bash
# The review record's hand-over: which member each saved finding goes to, what a
# member received and kept or dropped, and how the outcome of each fix round
# reaches the record. Sourced by audit-code-review-record.sh, never executed;
# does no work at source time. Bash 3.2 compatible. Never `cd`s.
#
# It runs in the record script's shell, on that script's helpers (field,
# install_record, record_state, die_usage), so every write still goes through
# the record's one writer.
#
# State the rules below depend on. `kept` and `dropped` are written once and
# never change, whatever a later sidecar says: the member's answer to the
# delivery is the evidence, and a re-run must not rewrite it. `fixed` only ever
# turns true. A finding is accounted for when its state is kept or dropped; null
# and `unaccounted` both read as not yet accounted for.

require_round() {
  [[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || die_usage "--round must be a positive integer"
}

require_single_member() {
  [[ "$MEMBERS" =~ ^[A-Za-z0-9_-]+$ ]] || die_usage "--member must name exactly one member"
}

# newest_sidecar <member> [newer-than-file]: the member's newest findings sidecar
# for this branch, only when it is newer than the file given. The full-round
# glob does not match a light review's sidecar, which carries `.light` after
# the member.
newest_sidecar() {
  local member="$1" newer_than="${2:-}" slug newest="" candidate
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/audit-key-lib.sh"
  slug="$(gaia_branch_slug "$ROOT")" || return 1
  for candidate in "$ROOT/.gaia/local/audit/"*."$slug.$member.findings.json"; do
    [ -f "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then newest="$candidate"; fi
  done
  [ -n "$newest" ] || return 1
  if [ -n "$newer_than" ]; then
    [ "$newest" -nt "$newer_than" ] || return 1
  fi
  jq -e 'type == "object"' "$newest" >/dev/null 2>&1 || return 1
  printf '%s\n' "$newest"
}

print_recipients() {
  jq -r '[.findings[] | {member, handed_only}] | unique[] | "\(.member)\t\(.handed_only)"' "$RECORD_FILE"
}

cmd_assign() {
  require_root
  [ "$(record_state)" = ok ] || exit 5
  local total assigned
  total="$(field '.findings | length')"
  [ "$total" -gt 0 ] || return 0
  assigned="$(field '[.findings[] | select(.member != null)] | length')"
  if [ "$assigned" -eq "$total" ]; then
    print_recipients
    return 0
  fi

  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/../../.claude/hooks/lib/audit-scope.sh"
  audit_scope_init "$ROOT" || exit 2
  local default_member="$_AUDIT_SCOPE_DEFAULT_MEMBER" dispatched base changed="" have_changed=no owners
  [ -n "$default_member" ] || die_usage "the roster names no default member"
  dispatched="$(bash "$SCRIPT_DIRECTORY/resolve-audit-members.sh" --root "$ROOT")" || die_usage "cannot resolve the dispatched members"
  base="$(field '.base // empty')"
  [ -n "$base" ] || base="$(gaia_review_fork_point "$ROOT")"
  if [ -n "$base" ] && changed="$(set -o pipefail; git -C "$ROOT" diff -z --name-only "$base" HEAD 2>/dev/null | tr '\0' '\n')"; then
    have_changed=yes
  fi
  owners="$(field '.findings[].file' | sort -u | audit_owners_for_paths)"

  jq --arg owners "$owners" --arg changed "$changed" --arg have_changed "$have_changed" \
    --arg default_member "$default_member" --arg dispatched "$dispatched" '
    ($owners | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $owner_of
    | ($changed | split("\n")) as $changed_paths
    | ($dispatched | split("\n")) as $dispatched_members
    | .findings |= map(
        .file as $file
        | (if $have_changed == "yes" and (any($changed_paths[]; . == $file) | not) then $default_member
           else (($owner_of[$file] // "-") | if . == "-" then $default_member else . end) end) as $recipient
        | .member = $recipient
        | .handed_only = (any($dispatched_members[]; . == $recipient) | not))' \
    "$RECORD_FILE" | install_record
  print_recipients
}

cmd_delivery() {
  require_single_member
  [ "$(record_state)" = ok ] || exit 5
  [ "$(field .handover)" = open ] || return 0
  local items handed_file temporary_file
  items="$(jq -c --arg member "$MEMBERS" '[.findings[]
    | select(.member == $member and .state != "kept" and .state != "dropped")
    | {id, file, line, summary, failure_scenario}]' "$RECORD_FILE")"
  [ "$(printf '%s' "$items" | jq 'length')" -gt 0 ] || return 0
  handed_file="$RUN_FOLDER/code-review-handed-$MEMBERS.json"
  temporary_file="$(mktemp "$RUN_FOLDER/.code-review-handed.XXXXXX")"
  if ! jq --argjson findings "$items" --arg member "$MEMBERS" \
    '{handed_only: ([.findings[] | select(.member == $member) | .handed_only == true] | first // false), findings: $findings}' \
    "$RECORD_FILE" >"$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi
  mv -f "$temporary_file" "$handed_file"
  printf '%s\n' "$handed_file"
}

# cmd_reconcile: the second pass is the last. What is still unaccounted for then
# stays `unaccounted`, which keeps the sum visibly short of added.
cmd_reconcile() {
  require_root
  [ -n "$MEMBERS" ] || die_usage "--member is required"
  [ "$(record_state)" = ok ] || exit 5
  [ "$(field .handover)" = open ] || return 0
  local member sidecar outcomes='{}' listed='[]' updated
  while IFS= read -r member; do
    [[ "$member" =~ ^[A-Za-z0-9_-]+$ ]] || die_usage "invalid member name: $member"
    listed="$(printf '%s' "$listed" | jq -c --arg member "$member" '. + [$member]')"
    sidecar="$(newest_sidecar "$member" "$RUN_FOLDER/code-review-handed-$member.json")" || continue
    outcomes="$(printf '%s' "$outcomes" | jq -c --arg member "$member" --slurpfile sidecar "$sidecar" '. + {($member): {
      kept: [($sidecar[0].findings // [])[] | select((.review_ids | type) == "array") | (.review_merged == true) as $merged
             | .review_ids[] | {id: ., merged: $merged}],
      drops: [($sidecar[0].review_drops // [])[] | select(type == "object" and (.id | type) == "string"
             and (.reason | type) == "string" and ((.reason | gsub("^\\s+|\\s+$"; "")) | length) > 0)]}}')"
  done <<EOF
$MEMBERS
EOF
  updated="$(jq --argjson outcomes "$outcomes" --argjson listed "$listed" '
    .findings |= map(
      . as $finding
      | if (any($listed[]; . == $finding.member) | not) or $finding.state == "kept" or $finding.state == "dropped" then .
        else
          ($outcomes[$finding.member] // {kept: [], drops: []}) as $answer
          | [$answer.kept[] | select(.id == $finding.id)] as $kept
          | [$answer.drops[] | select(.id == $finding.id)] as $dropped
          | if ($kept | length) > 0 then .state = "kept" | .merged = any($kept[]; .merged) | .final_disposition = "open"
            elif ($dropped | length) > 0 then .state = "dropped" | .drop_reason = $dropped[0].reason
            else .state = "unaccounted" end
        end)
    | .reconcile_passes += 1
    | (if ([.findings[] | select(.state != "kept" and .state != "dropped")] | length) == 0 or .reconcile_passes >= 2
       then .handover = "closed" else . end)' "$RECORD_FILE")" || return 1
  printf '%s' "$updated" | install_record
  printf '%s' "$updated" | jq -r 'if .handover == "closed" then empty else
    [.findings[] | select(.state == "unaccounted") | .member] | unique[] end'
}

cmd_round_end() {
  require_root
  require_round
  [[ "$COMMIT" =~ ^([0-9a-f]{7,40}|none)$ ]] || die_usage "--commit must be a commit sha or none"
  [ "$(record_state)" = ok ] || exit 5
  local dispositions="[]" results="[]" committed=false member sidecar sidecar_entries='[]' history has_history=false
  if [ -f "$RUN_FOLDER/dispositions-$ROUND.json" ]; then
    dispositions="$(jq -c '.entries // []' "$RUN_FOLDER/dispositions-$ROUND.json")" || die_usage "unreadable dispositions file"
  fi
  if [ -f "$RUN_FOLDER/fixer-$ROUND-audit.json" ]; then
    results="$(jq -c '.results // []' "$RUN_FOLDER/fixer-$ROUND-audit.json")" || die_usage "unreadable fixer file"
  fi
  [ "$COMMIT" = none ] || committed=true
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    sidecar="$(newest_sidecar "$member")" || continue
    sidecar_entries="$(printf '%s' "$sidecar_entries" | jq -c --arg member "$member" --slurpfile sidecar "$sidecar" \
      '. + [($sidecar[0].findings // [])[] | select((.review_ids | type) == "array")
        | {member: $member, finding_class, path, line, review_ids}]')"
  done <<EOF
$(field '[.findings[] | select(.state == "kept") | .member] | unique[]')
EOF
  if history="$(bash "$SCRIPT_DIRECTORY/audit-loop-eval.sh" round-history --root "$ROOT" 2>/dev/null)"; then
    has_history=true
  else
    history='[]'
  fi
  jq --argjson sidecar_entries "$sidecar_entries" --argjson dispositions "$dispositions" --argjson results "$results" \
    --argjson committed "$committed" --argjson history "$history" --argjson has_history "$has_history" '
    def identity_key: [.member, .finding_class, .path, .line];
    .findings |= map(
      if .state != "kept" then .
      else
        . as $finding
        | (first($sidecar_entries[] | select(any(.review_ids[]; . == $finding.id))) // null) as $entry
        | if $entry == null then .
          else
            ($entry | identity_key) as $key
            | (first($dispositions[] | select(identity_key == $key) | .disposition) // null) as $disposition
            | (first($results[] | select(identity_key == $key) | .disposition) // null) as $result
            | ($disposition == "fix" and $result == "fixed" and $committed) as $fixed_now
            | .fixed = (.fixed or $fixed_now)
            | .final_disposition = (
                if $disposition == null then .final_disposition
                elif $disposition == "fix" then (if .fixed then "fixed" else "open" end)
                elif $disposition == "waive-out-of-scope" then "waived"
                elif $disposition == "file" then "filed"
                elif $disposition == "accept-residual" then "accepted"
                elif $disposition == "divert" then "diverted"
                else .final_disposition end)
            | .recheck = (if $fixed_now and .handed_only == true and .recheck != "done" then "owed" else .recheck end)
          end
      end)
    | (if $has_history then .rounds = ($history | length)
         | .members_dispatched = ([$history[].members[]] | unique | length) else . end)' \
    "$RECORD_FILE" | install_record
}

cmd_rechecks() {
  [ "$(record_state)" = ok ] || exit 5
  jq -r '[.findings[] | select(.recheck == "owed")] | group_by(.member)[]
    | "\(.[0].member)\t\([.[].id] | join(","))"' "$RECORD_FILE"
}

# cmd_recheck_close: a sidecar counts only when it is newer than the round's
# dispositions file, since the re-check dispatch follows the fix that file
# disposed. A member that left none keeps its ids owed.
cmd_recheck_close() {
  require_root
  require_round
  require_single_member
  [ "$(record_state)" = ok ] || exit 5
  [ -f "$RUN_FOLDER/dispositions-$ROUND.json" ] || die_usage "no dispositions file for round $ROUND"
  local sidecar reported
  sidecar="$(newest_sidecar "$MEMBERS" "$RUN_FOLDER/dispositions-$ROUND.json")" || return 0
  reported="$(jq -c '[(.findings // [])[] | select((.review_ids | type) == "array") | .review_ids[]]' "$sidecar")"
  jq --arg member "$MEMBERS" --argjson reported "$reported" '
    .findings |= map(
      if .member == $member and .recheck == "owed" then
        .id as $id | .recheck = (if any($reported[]; . == $id) then null else "done" end)
      else . end)' "$RECORD_FILE" | install_record
}

# cmd_convergence: how the loop ended, in the order a reader must not miss them:
# a stop, then accepted residuals, then a grant. The last write holds, so a
# window end a later unit continues is overwritten.
cmd_convergence() {
  require_root
  [ -n "$STOP_REASON" ] || die_usage "--stop-reason is required"
  [ "$(record_state)" = ok ] || exit 5
  local convergence=stopped residual_total state_file
  if [ "$STOP_REASON" = clean ]; then
    residual_total="$(bash "$SCRIPT_DIRECTORY/audit-dispositions-check.sh" residual-count --root "$ROOT" --run-folder "$RUN_FOLDER" | jq -r '.total')" || residual_total=""
    [[ "$residual_total" =~ ^[0-9]+$ ]] || die_usage "cannot read the accepted residual count"
    state_file="$(bash "$SCRIPT_DIRECTORY/audit-loop-eval.sh" state-path --root "$ROOT")" || state_file=""
    if [ "$residual_total" -gt 0 ]; then
      convergence="accepted with residuals"
    elif [ -f "$state_file" ] && jq -e '(.allowance.answers // []) | any(.kind == "grant")' "$state_file" >/dev/null 2>&1; then
      convergence="clean after a grant"
    else
      convergence=clean
    fi
  fi
  jq --arg convergence "$convergence" '.convergence = $convergence' "$RECORD_FILE" | install_record
}

# cmd_publish_values: the `review` object the pull request body publishes,
# printed on stdout and computed from state so a missing, stale or crashed
# record can never read as a blank. It writes nothing. Without --pr the record's
# own pull request number stands in, so only the history check can disown it.
# Nothing prints when no round ran and no record exists.
cmd_publish_values() {
  require_root
  [[ "$ROUNDS" =~ ^[0-9]+$ ]] || die_usage "--rounds must be a non-negative integer"
  local state record_pull_request="$PR"
  state="$(record_state)"
  if [ "$state" = unreadable ]; then
    printf '{"outcome":"not run","reason":"unreadable record","cost":"unknown"}\n'
    return 0
  fi
  [ "$state" != ok ] || [ -n "$record_pull_request" ] || record_pull_request="$(field '.pr // empty')"
  if [ "$state" != ok ] || ! gaia_review_record_is_current "$ROOT" "$record_pull_request"; then
    [ "$ROUNDS" -gt 0 ] || return 0
    printf '{"outcome":"not run","reason":"no record","cost":"none"}\n'
    return 0
  fi
  # Only a name or version in the expected shape travels, so a value the record
  # picked up from the child can never fail the published section's validation.
  jq -c --argjson rounds "$ROUNDS" '
    def tally($key): [.[] | select(.state == $key)] | length;
    if .outcome == "pending" then {outcome: "not run", reason: "interrupted", cost: .cost}
    else
      {outcome, reason, cost, level, convergence, rounds: (.rounds // $rounds), members_dispatched,
       model: (if (.model | type == "string") and (.model | test("\\A[A-Za-z0-9._\\[\\]-]+\\z")) then .model else null end),
       claude_version: (if (.claude_version | type == "string") and (.claude_version | test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z")) then .claude_version else null end)}
      + (if (.outcome | startswith("ran")) then
          (.findings // []) as $findings
          | {added: ($findings | length),
             kept: ($findings | tally("kept")), dropped: ($findings | tally("dropped")),
             unaccounted: (($findings | length) - ($findings | tally("kept")) - ($findings | tally("dropped"))),
             merged: ([$findings[] | select(.merged == true)] | length),
             fixed: ([$findings[] | select(.fixed == true)] | length),
             kept_by_disposition: ([$findings[] | select(.state == "kept") | .final_disposition] as $dispositions
               | reduce ("fixed", "waived", "filed", "accepted", "diverted", "open") as $key
                   ({}; .[$key] = ([$dispositions[] | select(. == $key)] | length))),
             denials: (.denials.count // 0),
             denial_tools: [(.denials.tools // [])[] | select(type == "string" and test("\\A[A-Za-z]+\\z"))]}
         else {} end)
      | with_entries(select(.value != null))
    end' "$RECORD_FILE" 2>/dev/null \
    || printf '{"outcome":"not run","reason":"unreadable record","cost":"unknown"}\n'
}
