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

# A veto key's base rounds, the trees its fix is diffed from: the round that
# held the waiver (effective_from_round - 1, for a veto effective from round 2
# or later), and each round k,
# effective_from_round <= k < r, whose dispositions dispose the exact key `fix`
# and whose fixer reports it `fixed`. base_pairs runs on a vetoes.json key with
# $state, $round and $records (_gaia_veto_fix_records) bound as jq arguments,
# and emits [base tree, round tree] for every round after each base through r.
# shellcheck disable=SC2016 # jq program, expanded by jq
_GAIA_VETO_BASE_PAIRS_JQ='
def base_pairs:
  $state.history.rounds as $rounds
  | [.member, .finding_class, .path, .line] as $key | ([.effective_from_round, 1] | max) as $first
  | ((if .effective_from_round >= 2 then [.effective_from_round - 1] else [] end)
    + [$records.fixes[] | select(.key == $key and .round >= $first and .round < $round) | .round as $k
      | select(any($records.fixed[]; .round == $k and .key == $key)) | $k])
  | unique[] as $base | range($base + 1; $round + 1) | [$rounds[$base - 1].tree, $rounds[. - 1].tree];'

# _gaia_veto_changed_paths <main-root> <state-json> <r> <vetoes-file> <records-json>:
# for every veto effective by round r, the paths that differ between each of
# its base trees and each later round tree through r, plus, for every round
# 2..r whether or not a veto exists, the paths that differ from the round
# before, as {"<from-tree>..<round-tree>": [paths]}. A
# pair whose diff cannot be read is left out, which can only leave a veto
# unsatisfied.
_gaia_veto_changed_paths() {
  local main="$1" pairs pair base_tree round_tree changed answer="{}"
  pairs="$(jq -r -s --argjson state "$2" --argjson round "$3" --argjson records "$5" "$_GAIA_VETO_BASE_PAIRS_JQ"'
    $state.history.rounds as $rounds
    | [(.[0].keys[]? | select(.effective_from_round | type == "number" and . <= $round) | base_pairs),
        (range(2; $round + 1) | [$rounds[. - 2].tree, $rounds[. - 1].tree])
      | select(all(.[]; type == "string") and .[0] != .[1]) | join("..")] | unique | .[]' <"$4" 2>/dev/null)" || return 0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    base_tree="${pair%%..*}"
    round_tree="${pair#*..}"
    if ! gaia_loop_is_oid "$base_tree" || ! gaia_loop_is_oid "$round_tree"; then continue; fi
    changed="$(_gaia_loop_git -C "$main" diff-tree -r --name-only "$base_tree" "$round_tree" 2>/dev/null)" || continue
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

# _gaia_veto_rereport_spans <main-root> <state-json> <r> <vetoes-file> <records-json>:
# for every veto effective by round r with an integer line, and each pair of
# one of its base trees and a later round tree through r, the line spans of its
# path where a re-report reads as the vetoed finding, from the diff of the base
# tree to that round tree, as {"<base-tree>..<round-tree>": {"<path>\n<line>":
# [[low, high], ...]}}. A pair whose diff cannot be read or holds no hunk is
# left out, and the caller falls back to ignoring the line, which can only
# leave a veto unsatisfied.
_gaia_veto_rereport_spans() {
  local main="$1" rows base_tree round_tree line path spans answer="{}"
  rows="$(jq -r -s --argjson state "$2" --argjson round "$3" --argjson records "$5" "$_GAIA_VETO_BASE_PAIRS_JQ"'
    .[0].keys[]? | select((.effective_from_round | type == "number" and . <= $round)
        and (.line | type == "number" and . == floor) and (.path | type == "string"))
    | . as $veto | base_pairs | . + [($veto.line | tostring), $veto.path]
    | select((.[0] | type == "string") and (.[1] | type == "string")) | @tsv' <"$4" 2>/dev/null)" || return 0
  while IFS=$'\t' read -r base_tree round_tree line path; do
    [ -n "$path" ] || continue
    if ! gaia_loop_is_oid "$base_tree" || ! gaia_loop_is_oid "$round_tree"; then continue; fi
    # A path is data, never a pathspec pattern.
    spans="$(GIT_LITERAL_PATHSPECS=1 _gaia_loop_git -C "$main" diff -U0 --no-color --no-ext-diff --no-renames "$base_tree" "$round_tree" -- "$path" 2>/dev/null |
      awk -v vetoed_line="$line" "$_GAIA_VETO_SPANS_AWK")" || continue
    [ -n "$spans" ] || continue
    answer="$(printf '%s' "$spans" | jq -R -c --argjson answer "$answer" --arg pair "$base_tree..$round_tree" --arg identity "$path"$'\n'"$line" '
      (split(" ") | map(tonumber)) as $bounds
      | $answer | .[$pair][$identity] = [range(0; $bounds | length; 2) as $index | $bounds[$index:$index + 2]]')" || return 0
  done <<<"$rows"
  printf '%s\n' "$answer"
}

# _gaia_veto_owners <audited-root> <vetoes-file>: _roster_owners over the vetoed paths.
_gaia_veto_owners() { _roster_owners "$1" "$_GAIA_LOOP_EVAL_DIRECTORY" "$(jq -c '[.keys[]? | .path]' <"$2" 2>/dev/null)"; }

# gaia_veto_keys_state <main-root> <B> <state-json> <r> <round-r-keys-json> [<audited-root>]:
# prints {"satisfied":[keys],"unsatisfied":[keys]} over the vetoes effective
# by round r. A key is satisfied by a fix made after the round that held the
# waiver that a member then reviewed, by either of two routes, each counting
# the fix from a base round:
#   fixer: base round k, effective_from_round <= k < r, holds a `fix` entry on
#     the exact key and a fixer result `fixed` on it. The fixer's result is its
#     own claim, written before the verifier and the gate, so it proves no
#     commit; the diff below does.
#   commit: a fix committed outside the loop's fixer (on the main thread)
#     leaves no fixer result, so the base round is the waiver round,
#     effective_from_round - 1. A veto effective from round 1 has no waiver
#     round and only the fixer route.
# Either route then needs one round j, base < j <= r, on a tree whose diff from
# the base round's tree touches the key's path and, past round base + 1, whose
# diff from round j - 1's tree does too, so only a later change to the path
# passes over an earlier round's re-report. It is reviewed over rounds j..r,
# where a finding of the key's member and class on its path is the vetoed one
# re-reported when its line sits within the tolerance of where the diff to
# that round's tree moved the vetoed line, or of a line the fix wrote there. A
# fix can move or rewrite the code a finding is about, so an exact-line match
# would read the same finding re-reported as fixed; any other finding of that
# class on the path is a different one. A diff that cannot be read ignores the
# line, and a pair whose paths cannot be read touches nothing. A fix that
# lands only in another file leaves the key unsatisfied on both routes.
# Reviewed: at least one round in the span dispatched the key's reviewer,
# with the key not re-reported in any such round's keys (round r's from the
# argument, earlier ones from the stored snapshot, where null keys prove
# nothing). The reviewer is the key's member or, for a cross-remit key (the
# roster in <audited-root>, default <main-root>, gives its path to another
# member, so its own member is never re-dispatched on that file), the path's
# owner alone. The owner reports under its own class, so any finding of the owner's
# on the path re-reports the key within the tolerance of the spans the
# base-round diff maps the vetoed line to, else of the vetoed line itself.
# rc 1 on an unreadable or malformed vetoes.json.
gaia_veto_keys_state() {
  local run vetoes_file records changed_paths rereport_spans owners answer
  run="$(gaia_loop_run_directory "$1" "$2")"
  vetoes_file="$run/vetoes.json"
  [ -e "$vetoes_file" ] || { printf '{"satisfied":[],"unsatisfied":[]}\n'; return 0; }
  records="$(_gaia_veto_fix_records "$run" "$4")" || return 1
  owners="$(_gaia_veto_owners "${6:-$1}" "$vetoes_file")"
  [ -n "$owners" ] || owners="{}"
  changed_paths="$(_gaia_veto_changed_paths "$1" "$3" "$4" "$vetoes_file" "$records")"
  [ -n "$changed_paths" ] || changed_paths="{}"
  rereport_spans="$(_gaia_veto_rereport_spans "$1" "$3" "$4" "$vetoes_file" "$records")"
  [ -n "$rereport_spans" ] || rereport_spans="{}"
  answer="$(jq -c -s --argjson state "$3" --argjson round "$4" --argjson round_keys "$5" --argjson records "$records" \
    --argjson changed_paths "$changed_paths" --argjson rereport_spans "$rereport_spans" --argjson owners "$owners" \
    --argjson tolerance "$_GAIA_VETO_REREPORT_TOLERANCE_LINES" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then .[0] else error("malformed vetoes.json") end
    | $state.history.rounds as $rounds
    | def keys_of($j): if $j == $round then $round_keys else ($rounds[$j - 1].snapshot | if type == "object" then .keys else null end) end;
    def owner_of($key): ($owners[$key[2]] // null) | if . == $key[0] then null else . end;
    def reviewers($key): [owner_of($key) // $key[0]];
    # spans_at($base; $key) reads a reviewed round: the spans the diff from the
    # base round maps the vetoed line to there, or null with no such diff.
    def spans_at($base; $key):
      $rereport_spans["\($rounds[$base - 1].tree)..\($rounds[. - 1].tree)"]["\($key[2])\n\($key[3])"] // null;
    # owner_rereports($base; $key) reads [round, reported key]: the path
    # owner reporting any class near the vetoed line on the path of the key.
    def owner_rereports($base; $key):
      .[0] as $reviewed_round | .[1] as $reported | owner_of($key) as $owner
      | ($reviewed_round | spans_at($base; $key)) as $spans
      | $owner != null and $reported[0] == $owner and $reported[2] == $key[2]
        and (($reported[3] | type) != "number"
          or (if $spans != null then any($spans[]; $reported[3] >= .[0] - $tolerance and $reported[3] <= .[1] + $tolerance)
              else ($key[3] | type) != "number" or ($reported[3] - $key[3] | if . < 0 then -. else . end) <= $tolerance end));
    # rereports reads [round, reported key] and is true when that key is the vetoed finding.
    def reviewed_from($first; $key; rereports):
      reviewers($key) as $reviewers
      | [range($first; $round + 1) | select(any(($rounds[. - 1].members // [])[]; IN($reviewers[])))] as $dispatched
      | ($dispatched | length) > 0
        and all($dispatched[]; . as $reviewed_round | keys_of($reviewed_round) as $keys
          | ($keys | type) == "array" and (any($keys[]; [$reviewed_round, .] | rereports) | not));
    def rereported($base; $key):
      .[0] as $reviewed_round | .[1] as $reported
      | ($reported[0:3] == $key[0:3]
          and (($reviewed_round | spans_at($base; $key)) as $spans
            | $spans == null or ($reported[3] | type) != "number"
              or any($spans[]; $reported[3] >= .[0] - $tolerance and $reported[3] <= .[1] + $tolerance)))
        or owner_rereports($base; $key);
    def touched($from; $to; $key):
      any(($changed_paths["\($rounds[$from - 1].tree)..\($rounds[$to - 1].tree)"] // [])[]; . == $key[2]);
    def committed_after($base; $key):
      any(range($base + 1; $round + 1); . as $j
        | touched($base; $j; $key) and ($j == $base + 1 or touched($j - 1; $j; $key))
          and reviewed_from($j; $key; rereported($base; $key)));
    def fixed_in($k; $key):
      any($records.fixes[]; .round == $k and .key == $key) and any($records.fixed[]; .round == $k and .key == $key)
      and committed_after($k; $key);
    [.keys[] | select(.effective_from_round <= $round) | .effective_from_round as $from | [.member, .finding_class, .path, .line] as $key
      | {key: $key, satisfied: (any(range([$from, 1] | max; $round); fixed_in(.; $key))
          or ($from >= 2 and committed_after($from - 1; $key)))}]
    | {satisfied: map(select(.satisfied) | .key), unsatisfied: map(select(.satisfied | not) | .key)}' <"$vetoes_file" 2>/dev/null)" || return 1
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# gaia_veto_reviewers <main-root> <B> <audited-root> <veto-state-json>: the
# veto state with `reviewers` added, the sorted members the unit dispatches full
# (a light clear reviews nothing) for an unsatisfied key: each key's member and
# its path's owner, the superset of who can satisfy it (the path owner alone for
# a cross-remit key). rc 1 when the veto state is not an object.
gaia_veto_reviewers() {
  local vetoes_file owners='{}'
  vetoes_file="$(gaia_loop_run_directory "$1" "$2")/vetoes.json"
  [ -e "$vetoes_file" ] && owners="$(_gaia_veto_owners "$3" "$vetoes_file")"
  [ -n "$owners" ] || owners="{}"
  printf '%s' "$4" | jq -c --argjson owners "$owners" 'if type != "object" then error("not a veto state") else . end
    | . + {reviewers: ([(.unsatisfied // [])[] | ., ($owners[.[2]] // null)] | map(if type == "array" then .[0] else . end)
        | map(select(type == "string")) | unique)}' 2>/dev/null || return 1
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
# _gaia_veto_rereport_spans maps a vetoed line and widened by the same
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
