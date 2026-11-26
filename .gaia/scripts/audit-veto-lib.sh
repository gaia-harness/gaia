# shellcheck shell=bash
#
# Veto satisfaction, sourced by audit-loop-eval.sh only. The formulas it
# serves are stated once, in audit-loop-eval.sh's header (DEFAULT STOP,
# DECISION); this file implements them and restates none. Needs audit-loop-state-lib.sh and audit-triage-lib.sh
# already sourced. Defines functions only and runs nothing at source time.
# Bash 3.2 compatible. Nothing here writes a file.

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

# _gaia_veto_owners <audited-root> <vetoes-file>: _roster_owners over the vetoed paths and their repair paths.
_gaia_veto_owners() { _roster_owners "$1" "$_GAIA_LOOP_EVAL_DIRECTORY" "$(jq -c '[.keys[]? | .path, (.repair_paths | arrays | .[])]' <"$2" 2>/dev/null)"; }

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
# line, and a pair whose paths cannot be read touches nothing.
# A key whose entry names repair_paths (its repair lands in other files) also
# counts round j's change to one of those paths as touching it, and further
# needs, for every repair path, a later round whose diff touches it, from which
# on the path's roster owner was dispatched and reported no finding on it. An
# unowned repair path never satisfies. Without repair_paths, a fix that lands
# only in another file leaves the key unsatisfied on both routes.
# Reviewed: at least one round in the span dispatched the key's reviewer,
# with the key not re-reported in any such round's keys (round r's from the
# argument, earlier ones from the stored snapshot, where null keys prove
# nothing). The reviewer is the key's member or, for a cross-remit key (the
# roster in <audited-root>, default <main-root>, gives its path to another
# member, so its own member is never re-dispatched on that file), the path's
# owner alone. The owner reports under its own class, so any finding of the owner's
# on the path re-reports the key within the tolerance of the spans the
# base-round diff maps the vetoed line to, else of the vetoed line itself,
# except, for a pr-reviewer key, a finding that an earlier round disposed `fix`
# under its own key and whose fixer reported it `fixed`. That exception, like the
# one for a repair path's owner, never reaches round r's findings.
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
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)
          and (.repair_paths | . == null or (type == "array" and all(.[]; type == "string" and . != "")))))
    then .[0] else error("malformed vetoes.json") end
    | $state.history.rounds as $rounds
    | def keys_of($j): if $j == $round then $round_keys else ($rounds[$j - 1].snapshot | if type == "object" then .keys else null end) end;
    def owner_of($key): ($owners[$key[2]] // null) | if . == $key[0] then null else . end;
    def reviewers($key): [owner_of($key) // $key[0]];
    # spans_at($base; $key) reads a reviewed round: the spans the diff from the
    # base round maps the vetoed line to there, or null with no such diff.
    def spans_at($base; $key):
      $rereport_spans["\($rounds[$base - 1].tree)..\($rounds[. - 1].tree)"]["\($key[2])\n\($key[3])"] // null;
    # resolved_in($k; $reported): round k disposed the reported key `fix` and its
    # fixer reported it `fixed`. Records exist only for rounds before r, so the
    # findings of the latest round never resolve.
    def resolved_in($k; $reported):
      any($records.fixes[]; .round == $k and .key == $reported) and any($records.fixed[]; .round == $k and .key == $reported);
    # owner_rereports($base; $key) reads [round, reported key]: the path
    # owner reporting any class near the vetoed line on the path of the key.
    # For a pr-reviewer key, a finding the loop fixed under its own key in that
    # round is a different defect.
    def owner_rereports($base; $key):
      .[0] as $reviewed_round | .[1] as $reported | owner_of($key) as $owner
      | ($reviewed_round | spans_at($base; $key)) as $spans
      | $owner != null and $reported[0] == $owner and $reported[2] == $key[2]
        and (($key[0] == "pr-reviewer" and resolved_in($reviewed_round; $reported)) | not)
        and (($reported[3] | type) != "number"
          or (if $spans != null then any($spans[]; $reported[3] >= .[0] - $tolerance and $reported[3] <= .[1] + $tolerance)
              else ($key[3] | type) != "number" or ($reported[3] - $key[3] | if . < 0 then -. else . end) <= $tolerance end));
    # rereports reads [round, reported key] and is true when that key is the vetoed finding.
    def reviewed_by($first; $reviewers; rereports):
      [range($first; $round + 1) | select(any(($rounds[. - 1].members // [])[]; IN($reviewers[])))] as $dispatched
      | ($dispatched | length) > 0
        and all($dispatched[]; . as $reviewed_round | keys_of($reviewed_round) as $keys
          | ($keys | type) == "array" and (any($keys[]; [$reviewed_round, .] | rereports) | not));
    def reviewed_from($first; $key; rereports): reviewed_by($first; reviewers($key); rereports);
    def rereported($base; $key):
      .[0] as $reviewed_round | .[1] as $reported
      | ($reported[0:3] == $key[0:3]
          and (($reviewed_round | spans_at($base; $key)) as $spans
            | $spans == null or ($reported[3] | type) != "number"
              or any($spans[]; $reported[3] >= .[0] - $tolerance and $reported[3] <= .[1] + $tolerance)))
        or owner_rereports($base; $key);
    def touched($from; $to; $paths):
      any(($changed_paths["\($rounds[$from - 1].tree)..\($rounds[$to - 1].tree)"] // [])[]; IN($paths[]));
    def changed_at($base; $j; $paths): touched($base; $j; $paths) and ($j == $base + 1 or touched($j - 1; $j; $paths));
    # repair_reviewed($base; $path): the repair path changed after the base and
    # its owner, dispatched from that change on, reported nothing on it but
    # findings an earlier round fixed under their own keys.
    def repair_reviewed($base; $path):
      ($owners[$path] // null) as $owner
      | $owner != null
        and any(range($base + 1; $round + 1); . as $j | changed_at($base; $j; [$path])
          and reviewed_by($j; [$owner]; .[0] as $reviewed_round | .[1] as $reported
            | $reported[0] == $owner and $reported[2] == $path and (resolved_in($reviewed_round; $reported) | not)));
    def committed_after($base; $key; $repairs):
      all($repairs[]; repair_reviewed($base; .))
      and any(range($base + 1; $round + 1); . as $j
        | changed_at($base; $j; [$key[2]] + $repairs) and reviewed_from($j; $key; rereported($base; $key)));
    def fixed_in($k; $key; $repairs):
      any($records.fixes[]; .round == $k and .key == $key) and any($records.fixed[]; .round == $k and .key == $key)
      and committed_after($k; $key; $repairs);
    [.keys[] | select(.effective_from_round <= $round) | .effective_from_round as $from | [.member, .finding_class, .path, .line] as $key
      | (.repair_paths // []) as $repairs
      | {key: $key, satisfied: (any(range([$from, 1] | max; $round); fixed_in(.; $key; $repairs))
          or ($from >= 2 and committed_after($from - 1; $key; $repairs)))}]
    | {satisfied: map(select(.satisfied) | .key), unsatisfied: map(select(.satisfied | not) | .key)}' <"$vetoes_file" 2>/dev/null)" || return 1
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# gaia_veto_reviewers <main-root> <B> <audited-root> <veto-state-json>: the
# veto state with `reviewers` added, the sorted members the unit dispatches full
# (a light clear reviews nothing) for an unsatisfied key: each key's member, its
# path's owner and each of its repair paths' owners, the superset of who can
# satisfy it (the path owner alone for a cross-remit key). rc 1 when the veto
# state is not an object.
gaia_veto_reviewers() {
  local vetoes_file owners='{}' repairs='[]'
  vetoes_file="$(gaia_loop_run_directory "$1" "$2")/vetoes.json"
  if [ -e "$vetoes_file" ]; then
    owners="$(_gaia_veto_owners "$3" "$vetoes_file")"
    repairs="$(jq -c '[.keys[]? | {key: [.member, .finding_class, .path, .line], paths: (.repair_paths | arrays)}]' <"$vetoes_file" 2>/dev/null)" || repairs='[]'
  fi
  [ -n "$owners" ] || owners="{}"
  [ -n "$repairs" ] || repairs='[]'
  printf '%s' "$4" | jq -c --argjson owners "$owners" --argjson repairs "$repairs" 'if type != "object" then error("not a veto state") else . end
    | . + {reviewers: ([(.unsatisfied // [])[] | . as $key | ., ($owners[.[2]] // null),
          ($repairs[] | select(.key == $key) | .paths[] | $owners[.] // null)]
        | map(if type == "array" then .[0] else . end) | map(select(type == "string")) | unique)}' 2>/dev/null || return 1
}
