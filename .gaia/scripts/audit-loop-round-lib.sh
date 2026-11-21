# shellcheck shell=bash
#
# Round evaluation for audit-loop-eval.sh: the finding set F(r) and its
# authorship, the vetoed and waived keys, and the round snapshot with its
# verdict. Sourced only by audit-loop-eval.sh, after the state library (which
# loads the branch-authorship library) and the signals library, whose jq
# programs these definitions splice in. That script's header owns the formulas.

# jq defs shared by the finding set and the snapshot. $names and $hunks are
# round r's changed paths and new-side hunks against its merge base, null when
# the merge base cannot be computed.
# shellcheck disable=SC2016
_GAIA_LOOP_AUTHORED_JQ="$GAIA_AUTHORSHIP_JQ"'
def key: [.member, .finding_class, .path, .line];
def authored($names; $hunks): authorship($names; $hunks) != "not-authored";
'

# _gaia_loop_authorship <main-root> <state-json> <r>: round r's
# {"mb","names","hunks"}; mb is "" and the rest null without a merge base.
_gaia_loop_authorship() {
  local main="$1" round="$3" tree commit merge_base names=null hunks=null
  tree="$(printf '%s' "$2" | jq -r --argjson round "$round" '.history.rounds[$round - 1].tree // ""' 2>/dev/null)" || tree=""
  commit="$(printf '%s' "$2" | jq -r --argjson round "$round" '.history.rounds[$round - 1].commit // ""' 2>/dev/null)" || commit=""
  if gaia_loop_is_oid "$tree" && merge_base="$(gaia_authorship_merge_base "$main" "$commit")"; then
    names="$(gaia_authorship_names "$main" "$merge_base" "$tree" | jq -R -s -c 'split("\n") | map(select(length > 0))')" || names="null"
    hunks="$(gaia_authorship_hunks_json "$main" "$merge_base" "$tree")"
  else
    merge_base=""
  fi
  jq -n -c --arg merge_base "$merge_base" --argjson names "${names:-null}" --argjson hunks "${hunks:-null}" \
    '{mb: $merge_base, names: $names, hunks: $hunks}'
}

# _gaia_loop_annotate <F-json> <authorship-json>: F with `authored` on every entry.
_gaia_loop_annotate() {
  jq -n -c --argjson findings "$1" --argjson authorship "$2" "$_GAIA_LOOP_AUTHORED_JQ"'
    $findings | .entries |= map(. + {authored: authored($authorship.names; $authorship.hunks)})'
}

# _gaia_loop_vetoed <main-root> <B> <r>: identity keys vetoed for round r
# (effective_from_round <= r). rc 1 on an unreadable or malformed file.
_gaia_loop_vetoed() {
  local vetoes_file vetoed_keys
  vetoes_file="$(gaia_loop_run_directory "$1" "$2")/vetoes.json"
  [ -e "$vetoes_file" ] || { printf '[]\n'; return 0; }
  vetoed_keys="$(jq -c -s --argjson round "$3" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then [.[0].keys[] | select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line]]
    else error("malformed vetoes.json") end' <"$vetoes_file" 2>/dev/null)" || return 1
  [ -n "$vetoed_keys" ] || return 1
  printf '%s\n' "$vetoed_keys"
}

# _gaia_loop_waived_keys <main-root> <B> <r>: identity keys round r's own
# dispositions file waives on the triage threshold. Unreadable reads as none.
_gaia_loop_waived_keys() {
  local dispositions_file waived_keys
  dispositions_file="$(gaia_loop_run_directory "$1" "$2")/dispositions-$3.json"
  [ -f "$dispositions_file" ] || { printf '[]\n'; return 0; }
  waived_keys="$(jq -c '[.entries[] | select(.disposition == "waive-out-of-scope" and .basis == "triage-threshold")
    | [.member, .finding_class, .path, .line]]' <"$dispositions_file" 2>/dev/null)" || waived_keys=""
  [ -n "$waived_keys" ] && printf '%s\n' "$waived_keys" || printf '[]\n'
}

# _gaia_loop_raw_findings <main-root> <state-json> <r>: F(r) before authorship.
_gaia_loop_raw_findings() {
  local main="$1" state="$2" round="$3" branch_key slug stamp baseline audit_directory member candidate_file sorted_candidates newest member_entries reason
  local entries="[]" missing="[]" review_bases="{}"
  local -a candidates members
  branch_key="$(printf '%s' "$state" | jq -r '.branch')"
  slug="$(printf '%s' "$state" | jq -r --argjson round "$round" '.history.rounds[$round - 1].raw_branch_slug // ""')"
  members=()
  while IFS= read -r member; do members+=("$member"); done < <(printf '%s' "$state" | jq -r --argjson round "$round" '.history.rounds[$round - 1].members[]? | strings')
  stamp="$(gaia_loop_stamp_file "$main" "$branch_key" "$round")"
  baseline="$(gaia_loop_run_directory "$main" "$branch_key")/baseline-$round.json"
  audit_directory="$main/.gaia/local/audit"
  for member in ${members[@]+"${members[@]}"}; do
    newest=""
    # The slug and member are glob text: only the classes gaia_key_slug and
    # the member names emit are let through, anything else is missing evidence.
    if [[ "$slug" =~ ^[A-Za-z0-9_%-]+$ && "$member" =~ ^[A-Za-z0-9_-]+$ ]] && _gaia_loop_keyable "$branch_key" && [ -f "$stamp" ]; then
      candidates=()
      if [ -f "$baseline" ]; then
        while IFS= read -r candidate_file; do candidates+=("$candidate_file"); done < <(find "$audit_directory" -maxdepth 1 -type f -name "*.$slug.$member.findings.json" -newer "$stamp" ! -newer "$baseline" 2>/dev/null)
      else
        while IFS= read -r candidate_file; do candidates+=("$candidate_file"); done < <(find "$audit_directory" -maxdepth 1 -type f -name "*.$slug.$member.findings.json" -newer "$stamp" 2>/dev/null)
      fi
      sorted_candidates=""
      [ "${#candidates[@]}" -eq 0 ] || sorted_candidates="$(ls -t -- "${candidates[@]}" 2>/dev/null)" || sorted_candidates=""
      newest="${sorted_candidates%%$'\n'*}"
    fi
    member_entries=""
    if [ -n "$newest" ]; then
      # Never `.security // true`: `//` treats false as absent, so every
      # security:false finding would read true.
      member_entries="$(jq -c --arg member "$member" '.findings | if type == "array" then map({member: $member, finding_class, path, line, severity,
        security: (if (.security | type) == "boolean" then .security else true end),
        cross_remit: (.cross_remit == true), failure_mode: (if (.failure_mode | type) == "string" then .failure_mode else "" end)}
        + (if .triage == true then {triage: true, triage_reason: (if (.triage_reason | type) == "string" then .triage_reason else "" end)} else {} end))
        else error("no findings") end' <"$newest" 2>/dev/null)" || member_entries=""
    fi
    reason=null
    [ -n "$newest" ] && reason="$(jq -c '.review_base.reason? | if type == "string" then . else null end' <"$newest" 2>/dev/null)"
    review_bases="$(jq -n -c --argjson review_bases "$review_bases" --arg member "$member" --argjson reason "${reason:-null}" '$review_bases + {($member): $reason}')"
    if [ -n "$member_entries" ]; then
      entries="$(jq -n -c --argjson existing "$entries" --argjson additional "$member_entries" '$existing + $additional')"
    else
      missing="$(jq -n -c --argjson existing "$missing" --arg member "$member" '$existing + [$member]')"
    fi
  done
  jq -n -c --argjson round "$round" --argjson entries "$entries" --argjson missing_members "$missing" --argjson review_bases "$review_bases" \
    '{round: $round, entries: $entries, missing_members: $missing_members, review_bases: $review_bases}'
}

# gaia_loop_findings <main-root> <state-json> <r>: F(r) as
# {"round","entries":[...],"missing_members":[...],"review_bases":{member: reason|null}}, each entry
# {member, finding_class, path, line, severity, security, cross_remit, failure_mode, authored},
# plus triage and triage_reason on an entry whose sidecar marks it triage:true
# (the dispositions check decides whether the mark is honored).
gaia_loop_findings() {
  local findings authorship
  findings="$(_gaia_loop_raw_findings "$1" "$2" "$3")" || return 2
  authorship="$(_gaia_loop_authorship "$1" "$2" "$3")" || return 2
  _gaia_loop_annotate "$findings" "$authorship"
}

# shellcheck disable=SC2016
_GAIA_LOOP_VERDICT_JQ='
def disposed: key as $entry_key | any($disposed[]; . == $entry_key);
def isnew: key as $entry_key | any(($previous_keys // [])[]; . == $entry_key) | not;
($findings.entries | map(select(.authored and (disposed | not)))) as $counted
| (if ($findings.missing_members | length) > 0 then null else ($counted | length) end) as $authored_count
| ($series + [$authored_count]) as $authored_series
# Negative indices wrap in jq; the r >= 3 guards below keep them unread.
| $authored_series[$round - 2] as $previous_authored_count | $authored_series[$round - 3] as $second_previous_authored_count
| ($counted | map(select(.line != null and .line > 0 and isnew and in_hunks($enriching_hunks // [])) | key)) as $new_keys_on_repaired_lines
| (if $authored_count == null then "unknown"
   elif $authored_count == 0 then "quiet"
   elif $round >= 3 and $round >= $granted_round + 1 and $previous_authored_count != null and ($new_keys_on_repaired_lines | length) > 0 then "enriching"
   elif $round >= 3 and $round >= $granted_round + 2 and $second_previous_authored_count != null and $second_previous_authored_count >= 1 and $previous_authored_count != null and $previous_authored_count >= $second_previous_authored_count and $authored_count >= $previous_authored_count then "stalled"
   else "continue" end) as $verdict
'"$_GAIA_LOOP_SIGNALS_JQ"'
| {round: $round, merge_base: (if $merge_base == "" then null else $merge_base end), keys: ($findings.entries | map(key) | unique),
   A: $authored_count, verdict: $verdict,
   counted_keys: $counted_summaries, raw_count: $raw, waived_count: $waived,
   signals: $signals, accept_eligible: $eligible, accept_reasons: $reasons,
   default_stop: $default_stop, default_stop_keys: (if $default_stop then $stop_keys else [] end), review_bases: $review_bases,
   evidence: {members: $members, missing_members: $findings.missing_members, new_keys_on_repaired_lines: $new_keys_on_repaired_lines, A_series: $authored_series},
   evaluated_at: $now}
'

# gaia_loop_evaluate_round <main-root> <state-json> <r> [<audited-root>]: round
# r's snapshot; without the audited root no marker is provable, so
# default_stop is false. rc 2 no such round, 5 a bad round record or an
# unreadable vetoes.json. Every failure writes one `audit-loop-eval: <reason>`
# line to stderr, which the bound hook relays in its deny.
gaia_loop_evaluate_round() {
  local main="$1" state="$2" round="$3" audited_root="${4-}" branch_key round_context tree commit previous_tree authorship enriching_hunks="null" findings disposed vetoed waived is_maintainer_repo=false snapshot_status stop_inputs
  gaia_loop_is_uint "$round" && [ "$round" -ge 1 ] ||
    { printf 'audit-loop-eval: round %s is not a positive integer\n' "$round" >&2; return 2; }
  round_context="$(printf '%s' "$state" | jq -c --argjson round "$round" '
    .history.rounds as $rounds
    | if $round > ($rounds | length) then error("no round") else
      ([.allowance.answers[] | select(.kind == "grant")] | last) as $latest_grant
      | {tree: $rounds[$round - 1].tree, commit: $rounds[$round - 1].commit, members: ($rounds[$round - 1].members // []),
         previous_tree: (if $round >= 2 then $rounds[$round - 2].tree else "" end),
         previous_keys: (if $round >= 2 then $rounds[$round - 2].snapshot.keys? else null end),
         previous_snapshot: (if $round >= 2 then $rounds[$round - 2].snapshot else null end),
         second_previous_snapshot: (if $round >= 3 then $rounds[$round - 3].snapshot else null end),
         series: [$rounds[0:$round - 1][] | .snapshot.A?],
         history_snapshots: [range(0; $round - 1) as $index | $rounds[$index] | {round: ($index + 1), members: (.members // []),
           counted_keys: (if (.snapshot.counted_keys? | type) == "array" then .snapshot.counted_keys | map([.member, .finding_class, .path, .line]) else null end)}],
         granted_round: (if $latest_grant == null then 0 else ([.history.checkpoints[] | select(.index == $latest_grant.checkpoint)] | .[0].at_round // 0) end)}
      end' 2>/dev/null)" ||
    { printf 'audit-loop-eval: round %s is not in the recorded history, or the state cannot be read for it\n' "$round" >&2; return 2; }
  tree="$(printf '%s' "$round_context" | jq -r '.tree')"
  commit="$(printf '%s' "$round_context" | jq -r '.commit')"
  previous_tree="$(printf '%s' "$round_context" | jq -r '.previous_tree')"
  if ! gaia_loop_is_oid "$tree" || ! gaia_loop_is_oid "$commit"; then
    printf 'audit-loop-eval: round %s records no valid tree or commit oid\n' "$round" >&2
    return 5
  fi
  branch_key="$(printf '%s' "$state" | jq -r '.branch')"
  vetoed="$(_gaia_loop_vetoed "$main" "$branch_key" "$round")" ||
    { printf 'audit-loop-eval: %s/vetoes.json is unreadable or malformed\n' "$(gaia_loop_run_directory "$main" "$branch_key")" >&2; return 5; }
  findings="$(_gaia_loop_raw_findings "$main" "$state" "$round")" ||
    { printf 'audit-loop-eval: could not read the findings for round %s\n' "$round" >&2; return 2; }
  authorship="$(_gaia_loop_authorship "$main" "$state" "$round")" ||
    { printf 'audit-loop-eval: could not read the authorship (changed paths and hunks) for round %s\n' "$round" >&2; return 2; }
  findings="$(_gaia_loop_annotate "$findings" "$authorship")" ||
    { printf 'audit-loop-eval: could not annotate authorship on the findings for round %s\n' "$round" >&2; return 2; }
  if gaia_loop_is_oid "$previous_tree"; then
    enriching_hunks="$(gaia_authorship_hunks_json "$main" "$previous_tree" "$tree")"
  fi
  disposed="$(_gaia_loop_disposed "$main" "$branch_key" "$round" | jq -c --argjson vetoed_keys "$vetoed" 'map(select(. as $entry_key | any($vetoed_keys[]; . == $entry_key) | not))')" ||
    { printf 'audit-loop-eval: could not read the dispositions before round %s\n' "$round" >&2; return 5; }
  waived="$(_gaia_loop_waived_keys "$main" "$branch_key" "$round")"
  # gaia:maintainer-only:start
  [ -f "$main/.claude/rules/maintainers/harness-triage-threshold.md" ] && is_maintainer_repo=true
  # gaia:maintainer-only:end
  stop_inputs="$(_gaia_loop_stop_inputs "$main" "$audited_root" "$state" "$round" "$tree" "$(printf '%s' "$round_context" | jq -c '.members')" "$findings")" || stop_inputs=null
  jq -n -c --argjson findings "$findings" --argjson enriching_hunks "$enriching_hunks" --argjson disposed "$disposed" \
    --argjson history_snapshots "$(printf '%s' "$round_context" | jq -c '.history_snapshots')" \
    --argjson fixed_triples "$(_gaia_loop_fixed_triples "$main" "$branch_key" "$round")" --argjson stop_inputs "${stop_inputs:-null}" \
    --argjson previous_keys "$(printf '%s' "$round_context" | jq -c '.previous_keys')" \
    --argjson series "$(printf '%s' "$round_context" | jq -c '.series')" \
    --argjson members "$(printf '%s' "$round_context" | jq -c '.members')" \
    --argjson previous_snapshot "$(printf '%s' "$round_context" | jq -c '.previous_snapshot')" --argjson second_previous_snapshot "$(printf '%s' "$round_context" | jq -c '.second_previous_snapshot')" \
    --argjson waivedkeys "$waived" --argjson is_maintainer_repo "$is_maintainer_repo" \
    --argjson granted_round "$(printf '%s' "$round_context" | jq -r '.granted_round')" --argjson round "$round" \
    --arg merge_base "$(printf '%s' "$authorship" | jq -r '.mb')" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$_GAIA_LOOP_AUTHORED_JQ $_GAIA_LOOP_STOP_DEFS_JQ $_GAIA_LOOP_VERDICT_JQ" ||
    { snapshot_status=$?; printf 'audit-loop-eval: could not compute the snapshot for round %s\n' "$round" >&2; return "$snapshot_status"; }
}
