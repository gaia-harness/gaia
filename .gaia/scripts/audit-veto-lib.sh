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

# _gaia_veto_changed_paths <main-root> <state-json> <r> <vetoes-file>: for
# every veto effective by round r, the paths that differ between the tree of
# the round before its effective_from_round (the round that held the waiver)
# and each round tree from effective_from_round through r, as
# {"<waiver-tree>..<round-tree>": [paths]}. A pair whose diff cannot be read
# is left out, which can only leave a veto unsatisfied.
_gaia_veto_changed_paths() {
  local main="$1" pairs pair waiver_tree round_tree changed answer="{}"
  pairs="$(jq -r -s --argjson state "$2" --argjson round "$3" '
    $state.history.rounds as $rounds
    | [.[0].keys[]? | .effective_from_round | select(type == "number" and . >= 2 and . <= $round)
      | . as $from | range($from; $round + 1) | [$rounds[$from - 2].tree, $rounds[. - 1].tree]
      | select(all(.[]; type == "string") and .[0] != .[1]) | join("..")] | unique | .[]' <"$4" 2>/dev/null)" || return 0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    waiver_tree="${pair%%..*}"
    round_tree="${pair#*..}"
    if ! gaia_loop_is_oid "$waiver_tree" || ! gaia_loop_is_oid "$round_tree"; then continue; fi
    changed="$(_gaia_loop_git -C "$main" diff-tree -r --name-only "$waiver_tree" "$round_tree" 2>/dev/null)" || continue
    answer="$(printf '%s' "$changed" | jq -R -s -c --argjson answer "$answer" --arg pair "$pair" '$answer + {($pair): (split("\n") | map(select(. != "")))}')" || return 0
  done <<<"$pairs"
  printf '%s\n' "$answer"
}

# How far, in lines, a member's re-report may sit from where the fix left the
# vetoed finding and still be read as that finding. A re-reported finding
# lands on or next to the vetoed line's mapped place or a line the fix wrote;
# 3 adds margin for a statement spanning several lines.
_GAIA_VETO_REREPORT_TOLERANCE_LINES=3

# Reads `git diff -U0` of one path on stdin and prints, space-separated, the
# new-side span [low, high] of vetoed_line followed by the new-side span of
# every hunk (the lines the fix wrote). An unchanged line maps through the
# net offset of the hunks above it; a line inside a changed hunk maps to that
# hunk's whole new side. A deletion writes no line, so its span is the two
# lines around the gap. No hunk exits 1 and prints nothing.
# shellcheck disable=SC2016 # awk program, expanded by awk
_GAIA_VETO_SPANS_AWK='
/^@@ / {
  split($2, old_side, ","); split($3, new_side, ",")
  old_start = substr(old_side[1], 2) + 0; old_count = (old_side[2] == "" ? 1 : old_side[2] + 0)
  new_start = substr(new_side[1], 2) + 0; new_count = (new_side[2] == "" ? 1 : new_side[2] + 0)
  hunks++
  written_low[hunks] = new_start
  written_high[hunks] = (new_count > 0 ? new_start + new_count - 1 : new_start + 1)
  if (mapped) next
  if (old_count > 0 && vetoed_line >= old_start && vetoed_line <= old_start + old_count - 1) {
    low = written_low[hunks]; high = written_high[hunks]; mapped = 1; next
  }
  if ((old_count > 0 && old_start + old_count - 1 < vetoed_line) || (old_count == 0 && old_start < vetoed_line)) {
    offset += new_count - old_count; next
  }
  low = vetoed_line + offset; high = low; mapped = 1
}
END {
  if (!hunks) exit 1
  if (!mapped) { low = vetoed_line + offset; high = low }
  printf "%d %d", low, high
  for (hunk = 1; hunk <= hunks; hunk++) printf " %d %d", written_low[hunk], written_high[hunk]
  printf "\n"
}'

# _gaia_veto_rereport_spans <main-root> <state-json> <r> <vetoes-file>: for
# every veto effective from round 2 through r with an integer line, and each
# round tree from its effective_from_round through r, the line spans of its path where a re-report
# reads as the vetoed finding, from the diff of the waiver round's tree to that
# round tree, as {"<waiver-tree>..<round-tree>": {"<path>\n<line>": [[low,
# high], ...]}}. A pair whose diff cannot be read or holds no hunk is left
# out, and the caller falls back to ignoring the line, which can only leave a
# veto unsatisfied.
_gaia_veto_rereport_spans() {
  local main="$1" rows waiver_tree round_tree line path spans answer="{}"
  rows="$(jq -r -s --argjson state "$2" --argjson round "$3" '
    $state.history.rounds as $rounds
    | .[0].keys[]? | select((.effective_from_round | type == "number" and . >= 2 and . <= $round)
        and (.line | type == "number" and . == floor) and (.path | type == "string"))
    | . as $veto | range($veto.effective_from_round; $round + 1)
    | [$rounds[$veto.effective_from_round - 2].tree, $rounds[. - 1].tree, ($veto.line | tostring), $veto.path]
    | select((.[0] | type == "string") and (.[1] | type == "string")) | @tsv' <"$4" 2>/dev/null)" || return 0
  while IFS=$'\t' read -r waiver_tree round_tree line path; do
    [ -n "$path" ] || continue
    if ! gaia_loop_is_oid "$waiver_tree" || ! gaia_loop_is_oid "$round_tree"; then continue; fi
    # A path is data, never a pathspec pattern.
    spans="$(GIT_LITERAL_PATHSPECS=1 _gaia_loop_git -C "$main" diff -U0 --no-color --no-ext-diff --no-renames "$waiver_tree" "$round_tree" -- "$path" 2>/dev/null |
      awk -v vetoed_line="$line" "$_GAIA_VETO_SPANS_AWK")" || continue
    [ -n "$spans" ] || continue
    answer="$(printf '%s' "$spans" | jq -R -c --argjson answer "$answer" --arg pair "$waiver_tree..$round_tree" --arg identity "$path"$'\n'"$line" '
      (split(" ") | map(tonumber)) as $bounds
      | $answer | .[$pair][$identity] = [range(0; $bounds | length; 2) as $index | $bounds[$index:$index + 2]]')" || return 0
  done <<<"$rows"
  printf '%s\n' "$answer"
}

# gaia_veto_keys_state <main-root> <B> <state-json> <r> <round-r-keys-json>:
# prints {"satisfied":[keys],"unsatisfied":[keys]} over the vetoes effective
# by round r. A key is satisfied by a fix made after the round that held the
# waiver that a member then reviewed, by either of two routes:
#   fixer: one round k, effective_from_round <= k < r, holds a `fix` entry on
#     the exact key, a fixer result `fixed` on it, and a later recorded round
#     on a different tree than round k (the fix was committed); reviewed over
#     rounds k+1..r.
#   commit: a fix committed outside the loop's fixer (on the main thread)
#     leaves no fixer result, so instead one round j, effective_from_round <= j
#     <= r, sits on a tree whose diff from the waiver round's tree (round
#     effective_from_round - 1) touches the key's path; reviewed over rounds
#     j..r, where a finding of the key's member and class on its path is the
#     vetoed one re-reported when its line sits within the tolerance of where
#     the diff to that round's tree moved the vetoed line, or of a line the
#     fix wrote there. A fix can move or rewrite the code a finding is about,
#     so an exact-line match would read the same finding re-reported as
#     fixed; any other finding of that class on the path is a different one.
#     A diff that cannot be read ignores the line. A veto effective from round
#     1 has no waiver round and only the fixer route.
# Reviewed: at least one round in the span dispatched the key's member, with
# the key not re-reported in any such round's keys (round r's from the
# argument, earlier ones from the stored snapshot, where null keys prove
# nothing). rc 1 on an unreadable or malformed vetoes.json.
gaia_veto_keys_state() {
  local run vetoes_file records changed_paths rereport_spans answer
  run="$(gaia_loop_run_directory "$1" "$2")"
  vetoes_file="$run/vetoes.json"
  [ -e "$vetoes_file" ] || { printf '{"satisfied":[],"unsatisfied":[]}\n'; return 0; }
  records="$(_gaia_veto_fix_records "$run" "$4")" || return 1
  changed_paths="$(_gaia_veto_changed_paths "$1" "$3" "$4" "$vetoes_file")"
  [ -n "$changed_paths" ] || changed_paths="{}"
  rereport_spans="$(_gaia_veto_rereport_spans "$1" "$3" "$4" "$vetoes_file")"
  [ -n "$rereport_spans" ] || rereport_spans="{}"
  answer="$(jq -c -s --argjson state "$3" --argjson round "$4" --argjson round_keys "$5" --argjson records "$records" \
    --argjson changed_paths "$changed_paths" --argjson rereport_spans "$rereport_spans" --argjson tolerance "$_GAIA_VETO_REREPORT_TOLERANCE_LINES" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then .[0] else error("malformed vetoes.json") end
    | $state.history.rounds as $rounds
    | def keys_of($j): if $j == $round then $round_keys else ($rounds[$j - 1].snapshot | if type == "object" then .keys else null end) end;
    # rereports reads [round, reported key] and is true when that key is the vetoed finding.
    def reviewed_from($first; $key; rereports):
      [range($first; $round + 1) | select(any(($rounds[. - 1].members // [])[]; . == $key[0]))] as $dispatched
      | ($dispatched | length) > 0
        and all($dispatched[]; . as $reviewed_round | keys_of($reviewed_round) as $keys
          | ($keys | type) == "array" and (any($keys[]; [$reviewed_round, .] | rereports) | not));
    def fixed_in($k; $key):
      any($records.fixes[]; .round == $k and .key == $key) and any($records.fixed[]; .round == $k and .key == $key)
      and ($rounds[$k - 1].tree as $tree | any($rounds[$k:][]; .tree != $tree))
      and reviewed_from($k + 1; $key; .[1][0:4] == $key);
    def rereported_after_commit($from; $key):
      .[0] as $reviewed_round | .[1] as $reported
      | $reported[0:3] == $key[0:3]
        and (($rereport_spans["\($rounds[$from - 2].tree)..\($rounds[$reviewed_round - 1].tree)"]["\($key[2])\n\($key[3])"] // null) as $spans
          | $spans == null or ($reported[3] | type) != "number"
            or any($spans[]; $reported[3] >= .[0] - $tolerance and $reported[3] <= .[1] + $tolerance));
    def committed_by($j; $from; $key):
      ($changed_paths["\($rounds[$from - 2].tree)..\($rounds[$j - 1].tree)"] // []) as $paths
      | any($paths[]; . == $key[2]) and reviewed_from($j; $key; rereported_after_commit($from; $key));
    [.keys[] | select(.effective_from_round <= $round) | .effective_from_round as $from | [.member, .finding_class, .path, .line] as $key
      | {key: $key, satisfied: (any(range([$from, 1] | max; $round); fixed_in(.; $key))
          or ($from >= 2 and any(range($from; $round + 1); committed_by(.; $from; $key))))}]
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
