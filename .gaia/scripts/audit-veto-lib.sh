# shellcheck shell=bash
#
# Veto satisfaction, the shell inputs of the default stop, the stop override
# and the reopened-round test, sourced by audit-loop-eval.sh only. The
# formulas they serve are stated once, in audit-loop-eval.sh's header
# (DEFAULT STOP, DECISION) and the bound hook's (THE REOPENED ROUND); this
# file implements them and restates none. Needs audit-loop-state-lib.sh and
# audit-triage-lib.sh already sourced. Defines functions only and runs nothing
# at source time. Bash 3.2 compatible.
#
# Nothing here writes a file: the override in particular is derived in
# memory on every dispatch and never stored, so the frozen default_stop the
# dispositions grader reads stays exactly as evaluated.

# _gaia_veto_fix_records <run-directory> <r>: every exact key disposed `fix`
# in a dispositions-<k>.json and every exact key a fixer-<k>-audit.json
# reports `fixed`, k < r, as {"fixes":[{round,key}],"fixed":[{round,key}]}.
# An unreadable file contributes nothing, which can only leave a veto
# unsatisfied.
_gaia_veto_fix_records() {
  local run="$1" k=1 fixes="[]" fixed="[]" round_records
  while [ "$k" -lt "$2" ]; do
    if [ -f "$run/dispositions-$k.json" ]; then
      round_records="$(jq -c --argjson k "$k" '[.entries[]? | select(.disposition == "fix") | {round: $k, key: [.member, .finding_class, .path, .line]}]' <"$run/dispositions-$k.json" 2>/dev/null)" || round_records=""
      [ -n "$round_records" ] && fixes="$(jq -n -c --argjson accumulated "$fixes" --argjson more "$round_records" '$accumulated + $more')"
    fi
    if [ -f "$run/fixer-$k-audit.json" ]; then
      round_records="$(jq -c --argjson k "$k" '[.results[]? | select(.disposition == "fixed") | {round: $k, key: [.member, .finding_class, .path, .line]}]' <"$run/fixer-$k-audit.json" 2>/dev/null)" || round_records=""
      [ -n "$round_records" ] && fixed="$(jq -n -c --argjson accumulated "$fixed" --argjson more "$round_records" '$accumulated + $more')"
    fi
    k=$((k + 1))
  done
  jq -n -c --argjson fixes "$fixes" --argjson fixed "$fixed" '{fixes: $fixes, fixed: $fixed}'
}

# gaia_veto_keys_state <main-root> <B> <state-json> <r> <round-r-keys-json>:
# prints {"satisfied":[keys],"unsatisfied":[keys]} over the vetoes effective
# by round r. A key is satisfied when one round k, effective_from_round <= k
# < r, holds all of: a `fix` entry on the exact key; a fixer result `fixed`
# on it; a later recorded round on a different tree than round k (the fix was
# committed); and at least one round j, k < j <= r, that dispatched the key's
# member, with the exact key absent from every such round's keys (round r's
# from the argument, earlier ones from the stored snapshot, where null keys
# prove nothing). rc 1 on an unreadable or malformed vetoes.json.
gaia_veto_keys_state() {
  local run vetoes_file records answer
  run="$(gaia_loop_run_directory "$1" "$2")"
  vetoes_file="$run/vetoes.json"
  [ -e "$vetoes_file" ] || { printf '{"satisfied":[],"unsatisfied":[]}\n'; return 0; }
  records="$(_gaia_veto_fix_records "$run" "$4")" || return 1
  answer="$(jq -c -s --argjson state "$3" --argjson round "$4" --argjson round_keys "$5" --argjson records "$records" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then .[0] else error("malformed vetoes.json") end
    | $state.history.rounds as $rounds
    | def keys_of($j): if $j == $round then $round_keys else ($rounds[$j - 1].snapshot | if type == "object" then .keys else null end) end;
    def fixed_in($k; $key):
      any($records.fixes[]; .round == $k and .key == $key) and any($records.fixed[]; .round == $k and .key == $key)
      and ($rounds[$k - 1].tree as $tree | any($rounds[$k:][]; .tree != $tree))
      and ([range($k + 1; $round + 1) | select(any(($rounds[. - 1].members // [])[]; . == $key[0]))] as $dispatched
           | ($dispatched | length) > 0 and all($dispatched[]; keys_of(.) as $keys | ($keys | type) == "array" and (any($keys[]; . == $key) | not)));
    [.keys[] | select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line] as $key
      | {key: $key, satisfied: any(range([.effective_from_round, 1] | max; $round); fixed_in(.; $key))}]
    | {satisfied: map(select(.satisfied) | .key), unsatisfied: map(select(.satisfied | not) | .key)}' <"$vetoes_file" 2>/dev/null)" || return 1
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# gaia_loop_stop_override <main-root> <B> <r> <snapshot-json>: the snapshot
# with `stop_override` added: true when default_stop is true and round r's
# dispositions file holds no `fix` entry on a key in default_stop_keys. An
# absent file holds none; a malformed one reads false, the direction that
# keeps today's checkpoint. A null snapshot prints null unchanged. rc 5 when
# the snapshot is not an object.
gaia_loop_stop_override() {
  local dispositions_file fix_keys=null
  [ "${4:-null}" = null ] && { printf 'null\n'; return 0; }
  dispositions_file="$(gaia_loop_run_directory "$1" "$2")/dispositions-$3.json"
  if [ ! -e "$dispositions_file" ]; then
    fix_keys="[]"
  else
    fix_keys="$(jq -c -s 'if length == 1 and (.[0].entries | type) == "array"
      then [.[0].entries[] | select(.disposition == "fix") | [.member, .finding_class, .path, .line]] else error("malformed") end' <"$dispositions_file" 2>/dev/null)" || fix_keys=null
    [ -n "$fix_keys" ] || fix_keys=null
  fi
  printf '%s' "$4" | jq -c --argjson fix_keys "$fix_keys" 'if type != "object" then error("not a snapshot") else . end
    | . + {stop_override: (.default_stop == true and $fix_keys != null
        and ((.default_stop_keys // []) as $stop_keys | any($fix_keys[]; . as $key | any($stop_keys[]; . == $key)) | not))}' 2>/dev/null || return 5
}

# gaia_loop_reopen_due <main-root> <B> <state-json> <tree>: prints true when
# the bound hook must record a reopened round before it admits a unit on HEAD
# tree <tree> (its header, THE REOPENED ROUND), else false. rc 1 on an
# unreadable or malformed vetoes.json or gate-failure.json: reading either as
# absent would leave its repair no round.
gaia_loop_reopen_due() {
  local run vetoes="[]" failure="{}"
  run="$(gaia_loop_run_directory "$1" "$2")"
  if [ -e "$run/vetoes.json" ]; then
    vetoes="$(jq -c -s 'if length == 1 and .[0].version == 1 and (.[0].keys | type) == "array" then .[0].keys else error("malformed") end' <"$run/vetoes.json" 2>/dev/null)" || return 1
  fi
  if [ -e "$run/gate-failure.json" ]; then
    failure="$(jq -c -s 'if length == 1 and (.[0] | type) == "object" then .[0] else error("malformed") end' <"$run/gate-failure.json" 2>/dev/null)" || return 1
  fi
  printf '%s' "$3" | jq -r --arg tree "$4" --argjson vetoes "$vetoes" --argjson failure "$failure" '
    (.history.rounds | length) as $used | (.history.rounds | last) as $latest | ($latest.tree == $tree) as $unmoved
    | $used > 0
      and (($latest.reopened == true and $unmoved) | not)
      and ((any($vetoes[]; .effective_from_round == $used + 1) and $unmoved)
           or ($failure.after_round == $used and $failure.tree == $tree))' 2>/dev/null
}

# _gaia_loop_fixed_triples <main-root> <B> <r>: the (member, finding_class,
# path) triples of every `fix` entry in dispositions-<k>.json, k < r. A fix
# commit is what shifts lines, so the repeat signal matches the triple, not
# the exact key. An unreadable file contributes nothing.
_gaia_loop_fixed_triples() {
  local run triples="[]" k=1 round_triples
  run="$(gaia_loop_run_directory "$1" "$2")"
  while [ "$k" -lt "$3" ]; do
    if [ -f "$run/dispositions-$k.json" ]; then
      round_triples="$(jq -c '[.entries[]? | select(.disposition == "fix") | [.member, .finding_class, .path]]' <"$run/dispositions-$k.json" 2>/dev/null)" || round_triples=""
      [ -n "$round_triples" ] && triples="$(jq -n -c --argjson accumulated "$triples" --argjson more "$round_triples" '$accumulated + $more | unique')"
    fi
    k=$((k + 1))
  done
  printf '%s\n' "$triples"
}

# _gaia_loop_stop_inputs <main-root> <audited-root> <state-json> <r> <tree>
# <members-json> <findings-json>: the default stop's shell-computed inputs,
# {"honored_keys","marker_gaps","unsatisfied_vetoes"}, or null when a cheap
# term already fails (no audited root, r outside 3..9, missing evidence, a
# member without an incremental review base, an entry neither a non-security
# Minor nor triage-marked). Null makes the stop false. Run it in a command
# substitution: the clearance and roster libraries it sources stay there.
#
# The marker term digests each member at round r's tree, not HEAD's: a later
# commit (a worthiness fix, a veto fix) would otherwise rotate the digest and
# turn an accepted round into a refusal on re-grade. A digest that cannot be
# derived is a gap.
_gaia_loop_stop_inputs() {
  local main="$1" root="$2" state="$3" round="$4" tree="$5" members="$6" findings="$7"
  local scripts="$_GAIA_LOOP_EVAL_DIRECTORY" cheap owned honored member digest gaps="[]" veto_state unsatisfied
  # One test per line, mirroring the snapshot program's clauses.
  [ -n "$root" ] || { printf 'null\n'; return 0; }
  [ "$round" -ge 3 ] || { printf 'null\n'; return 0; }
  [ "$round" -le 9 ] || { printf 'null\n'; return 0; }
  cheap="$(jq -n -r --argjson findings "$findings" --argjson members "$members" "$_GAIA_LOOP_STOP_DEFS_JQ"'
    ($members | length) > 0
    and ($findings.missing_members | length) == 0
    and all($members[]; . as $member | $findings.review_bases[$member] | incremental_base)
    and all($findings.entries[]; .triage == true or (.severity == "minor" and .security == false))
    ' 2>/dev/null)" || cheap=false
  [ "$cheap" = true ] || { printf 'null\n'; return 0; }
  owned="$(_roster_owned_indexes "$root" "$scripts" "$(printf '%s' "$findings" | jq -c '.entries')")" || owned="[]"
  honored="$(jq -n -c --argjson findings "$findings" --argjson owned "$owned" --argjson triage_members "$_TRIAGE_MEMBERS" "$_GAIA_TRIAGE_HONORED_JQ"'
    [$findings.entries | to_entries[] | select(.key | IN($owned[])) | .value | select(triage_honored) | [.member, .finding_class, .path, .line]]' 2>/dev/null)" || honored="[]"
  # shellcheck source=/dev/null
  . "$scripts/../../.claude/hooks/lib/audit-clearance.sh" 2>/dev/null
  while IFS= read -r member; do
    if [[ "$member" =~ ^[A-Za-z0-9_-]+$ ]] && type clearance_acceptable >/dev/null 2>&1 &&
      digest="$(bash "$scripts/audit-member-digest.sh" --root "$root" --member "$member" --ref "$tree" 2>/dev/null)" &&
      clearance_acceptable "$(clearance_earned_path "$main" "$digest" "$member")" "$member" "$digest"; then
      continue
    fi
    gaps="$(jq -n -c --argjson gaps "$gaps" --arg member "$member" '$gaps + [$member]')"
  done < <(printf '%s' "$members" | jq -r '.[]')
  unsatisfied='["unreadable vetoes"]'
  veto_state="$(gaia_veto_keys_state "$main" "$(printf '%s' "$state" | jq -r '.branch')" "$state" "$round" \
    "$(printf '%s' "$findings" | jq -c '.entries | map([.member, .finding_class, .path, .line]) | unique')")" &&
    unsatisfied="$(printf '%s' "$veto_state" | jq -c '.unsatisfied')"
  jq -n -c --argjson honored_keys "$honored" --argjson marker_gaps "$gaps" --argjson unsatisfied_vetoes "${unsatisfied:-[\"unreadable vetoes\"]}" \
    '{honored_keys: $honored_keys, marker_gaps: $marker_gaps, unsatisfied_vetoes: $unsatisfied_vetoes}'
}
