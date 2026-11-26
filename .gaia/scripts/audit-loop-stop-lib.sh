# shellcheck shell=bash
#
# The shell inputs of the default stop, the stop override, the reopened-round
# test and the accepted keys, sourced by audit-loop-eval.sh only. The formulas
# they serve are stated once, in
# audit-loop-eval.sh's header (DEFAULT STOP, DECISION) and the bound hook's
# (THE REOPENED ROUND); this file implements them and restates none. Needs
# audit-loop-state-lib.sh, audit-triage-lib.sh and audit-veto-lib.sh already
# sourced. Defines functions only and runs nothing at source time. Bash 3.2
# compatible.
#
# Nothing here writes a file: the override in particular is derived in
# memory on every dispatch and never stored, so the frozen default_stop the
# dispositions grader reads stays exactly as evaluated.

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
# tree <tree> (its header, THE REOPENED ROUND), else false. A new veto reopens
# on a moved tree too: commits outside its member's scope leave that member's
# clearance standing, so no member wave would open the round its fix needs.
# rc 1 on an unreadable or malformed vetoes.json or gate-failure.json: reading
# either as absent would leave its repair no round.
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
      and (any($vetoes[]; .effective_from_round == $used + 1)
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
    "$(printf '%s' "$findings" | jq -c '.entries | map([.member, .finding_class, .path, .line]) | unique')" "$root")" &&
    unsatisfied="$(printf '%s' "$veto_state" | jq -c '.unsatisfied')"
  jq -n -c --argjson honored_keys "$honored" --argjson marker_gaps "$gaps" --argjson unsatisfied_vetoes "${unsatisfied:-[\"unreadable vetoes\"]}" \
    '{honored_keys: $honored_keys, marker_gaps: $marker_gaps, unsatisfied_vetoes: $unsatisfied_vetoes}'
}

# gaia_loop_accept_blockers <main-root> <audited-root> <state-json>
# <head-tree> <snapshot-json>: the latest round's snapshot with
# `accept_blockers` added, {"unsatisfied_vetoes","unreviewed_members"}, what
# an Accept closing round could not finish at <head-tree>. That round runs no
# fixer, so a veto open after the latest round (unsatisfied at it, or
# effective only after it) stays open and the clean stop refuses it. A member
# owed a review of the branch (the set resolve-audit-members.sh resolves at
# <audited-root>, plus the latest round's members) with neither an earned
# marker nor a refusal for its digest at <head-tree> has not reviewed the
# head, so an accept would take hunks no member read; a refusal counts as
# reviewed, since it is how a member reports the open Major an accept
# acknowledges. Owed members come from the branch, not from the latest
# round's list, so a fixer commit into another member's domain and a reopened
# round recorded with no members both surface. Derived in memory
# and never stored, like the stop override. Anything unreadable, the member
# set included, is a blocker: it can only turn an accept recommendation into
# a grant. A null
# snapshot prints null unchanged. Run it in a command substitution: the
# clearance library it sources stays there.
gaia_loop_accept_blockers() {
  local main="$1" root="$2" state="$3" tree="$4" snapshot="${5:-null}" scripts="$_GAIA_LOOP_EVAL_DIRECTORY"
  local branch_key round vetoes_file later_vetoes='[]' veto_state unsatisfied='["unreadable vetoes"]' member digest unreviewed='[]' owed resolved
  [ "$snapshot" = null ] && { printf 'null\n'; return 0; }
  branch_key="$(printf '%s' "$state" | jq -r '.branch')" || return 5
  round="$(printf '%s' "$state" | jq -r '.history.rounds | length')" || return 5
  vetoes_file="$(gaia_loop_run_directory "$main" "$branch_key")/vetoes.json"
  if [ ! -e "$vetoes_file" ] || later_vetoes="$(jq -c --argjson round "$round" \
    '[.keys[] | select(.effective_from_round > $round) | [.member, .finding_class, .path, .line]]' <"$vetoes_file" 2>/dev/null)"; then
    veto_state="$(gaia_veto_keys_state "$main" "$branch_key" "$state" "$round" \
      "$(printf '%s' "$snapshot" | jq -c '.keys // []')" "$root")" &&
      unsatisfied="$(printf '%s' "$veto_state" | jq -c --argjson later "${later_vetoes:-[]}" '.unsatisfied + $later | unique')" ||
      unsatisfied='["unreadable vetoes"]'
  fi
  if resolved="$(bash "$scripts/resolve-audit-members.sh" --root "$root" 2>/dev/null)"; then
    owed="$(printf '%s\n' "$resolved" | jq -R -s -c --argjson state "$state" \
      '[split("\n")[] | select(length > 0)] + [($state.history.rounds | last | .members // [])[] | strings] | unique')" || owed='["unresolvable members"]'
  else
    owed='["unresolvable members"]'
  fi
  # shellcheck source=/dev/null
  . "$scripts/../../.claude/hooks/lib/audit-clearance.sh" 2>/dev/null
  while IFS= read -r member; do
    if gaia_loop_is_oid "$tree" && [[ "$member" =~ ^[A-Za-z0-9_-]+$ ]] && type clearance_member_cleared >/dev/null 2>&1 &&
      digest="$(bash "$scripts/audit-member-digest.sh" --root "$root" --member "$member" --ref "$tree" 2>/dev/null)" &&
      { clearance_member_cleared "$main" "$digest" "$member" || clearance_member_refused "$main" "$digest" "$member"; }; then
      continue
    fi
    unreviewed="$(jq -n -c --argjson unreviewed "$unreviewed" --arg member "$member" '$unreviewed + [$member]')"
  done < <(printf '%s' "$owed" | jq -r '.[]')
  printf '%s' "$snapshot" | jq -c --argjson unsatisfied "${unsatisfied:-[\"unreadable vetoes\"]}" --argjson unreviewed "$unreviewed" \
    'if type != "object" then error("not a snapshot") else . end
    | . + {accept_blockers: {unsatisfied_vetoes: $unsatisfied, unreviewed_members: $unreviewed}}' 2>/dev/null || return 5
}

# gaia_loop_accepted_keys <main-root> <state-json> <head-tree>:
# audit-loop-eval.sh accepted-keys's output, sorted unique
# {key: [member, finding_class, path, line], lines: [low, high]} for each key a
# human accepted: every key of a round whose checkpoint a human answered with an
# accept, plus each audit-accept-finding key. Only the audit loop hooks write
# these fields (the grant hooks the answers and accepted keys, the bound hook
# the checkpoints and round snapshots), so a member can trust this list where a
# run-folder file could be forged. A key is listed only when its round's
# stored counted_keys grade it major or minor with security false, so a
# Critical, a security-class finding, a checkpoint at round 0 (no round's
# findings were before the human) and a round whose keys were not stored all
# contribute none, which fails toward a refusal. lines is where the key's line
# sits at <head-tree>, mapped from its round's tree through the diff the way
# audit-veto-lib.sh's _gaia_veto_rereport_spans maps a vetoed line and widened by the same
# tolerance, because a fix after the accepted round can move the line; an
# unreadable diff keeps the recorded line.
gaia_loop_accepted_keys() {
  local main="$1" head_tree="$3" candidates rows index from_tree line path mapped spans='{}'
  candidates="$(printf '%s' "$2" | jq -c '. as $state
    | ($state.history.rounds // []) as $rounds
    | def accepted_round($index): [$state.history.checkpoints[]? | select(.index == $index) | .at_round
        | select(type == "number" and . >= 1 and . == floor and . <= ($rounds | length))] | first;
    [($state.allowance.answers[]? | select(.kind == "accept") | accepted_round(.checkpoint) | select(. != null)
       | . as $round | ($rounds[$round - 1].snapshot.keys? // [])[] | {key: ., round: $round}),
     (($state.allowance.accepted_keys // [])[] | accepted_round(.checkpoint) as $round | select($round != null)
       | {key, round: $round})]
    | map(. as $candidate | $rounds[$candidate.round - 1] as $accepted
        | select(any(($accepted.snapshot.counted_keys? // [])[]?; [.member, .finding_class, .path, .line] == $candidate.key
            and (.severity == "major" or .severity == "minor") and .security == false))
        | {key, tree: $accepted.tree})
    | unique')" || return 5
  rows="$(printf '%s' "$candidates" | jq -r 'to_entries[] | select(.value.key[3] | type == "number" and . >= 1 and . == floor)
    | [.key, .value.tree, .value.key[3], .value.key[2]] | @tsv')" || return 5
  while IFS=$'\t' read -r index from_tree line path; do
    [ -n "$path" ] || continue
    mapped=""
    if gaia_loop_is_oid "$from_tree" && gaia_loop_is_oid "$head_tree"; then
      # A path is data, never a pathspec pattern.
      mapped="$(GIT_LITERAL_PATHSPECS=1 _gaia_loop_git -C "$main" diff -U0 --no-color --no-ext-diff --no-renames "$from_tree" "$head_tree" -- "$path" 2>/dev/null |
        awk -v vetoed_line="$line" "$_GAIA_VETO_SPANS_AWK")" || mapped=""
    fi
    spans="$(jq -n -c --argjson spans "$spans" --arg index "$index" --arg mapped "$mapped" --argjson line "$line" \
      --argjson tolerance "$_GAIA_VETO_REREPORT_TOLERANCE_LINES" '
      (if $mapped == "" then [$line, $line] else $mapped | split(" ") | map(tonumber) | .[0:2] end) as $span
      | $spans + {($index): [([$span[0] - $tolerance, 1] | max), $span[1] + $tolerance]}')" || return 5
  done <<<"$rows"
  printf '%s' "$candidates" | jq -c --argjson spans "$spans" \
    '[to_entries[] | {key: .value.key, lines: ($spans[.key | tostring] // [.value.key[3], .value.key[3]])}] | unique'
}
