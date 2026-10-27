#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-dispatch-cost-report.sh: the reader of the audit dispatch cost events in
# the maintainer-only telemetry log. It prints, per Code Audit Team member and
# dispatch kind (member or light_reviewer), the median cost of a dispatch over
# a window of recent branches, and the dispatches the recorder never saw.
#
#   audit-dispatch-cost-report.sh [--root <r>] [--window <n>]
#
# Log: <main>/.gaia/local/telemetry/audit-light-routing.jsonl, <main> from
# main-root-lib.sh. The report only reads; it writes nothing, and carries no
# maintainer-marker check because the log exists only in the maintainer repo.
#
# Exit 0 (an absent log prints nothing), 1 when jq is absent or the log is
# unreadable, 2 on a usage error.
#
# One line per (member, kind) with at least one non-zero count among
# dispatches, not_dispatched and unrecorded, sorted by member, member kind
# before light_reviewer. Fields are separated by one space:
#
#   <member> <kind> branches=<b> dispatches=<n> dollars=<median> calls=<median>
#   wall_s=<median> dollars_with_children=<median> calls_with_children=<median>
#   wall_s_with_children=<median> not_dispatched=<n> transcript_missing=<n>
#   transcript_unparsed=<n> incomplete=<n> unrecorded=<n>
#
# Window: per member, the last --window (default 30) branches holding a
# dispatch_cost or member_result event for that member, ranked by the log
# position of the branch's last such event. Every figure for the member counts
# only events on those branches. A branch is a pull request: the log records no
# merge.
#
# Medians use only complete measured dispatches (state ok, incomplete false);
# the with-children medians also require children_state ok. An even count takes
# the mean of the two middle values. A median with no qualifying value is n/a.
#
# Unrecorded counts the dispatches the recorder missed: results (member_result
# for kind member, light_outcome for kind light_reviewer) that no cost event of
# the same kind, member, branch and digest accounts for. Only results at or
# after the first dispatch_cost event on their branch count, because earlier
# results predate the recorder and a branch with no cost event is a legacy one.
# The kind match is why a light reviewer that escalates cannot hide a full
# member that was never recorded.
#
# Bash 3.2 compatible, BWK awk safe. Never `cd`.
set -u

DEFAULT_WINDOW_BRANCHES=30
LOG_RELATIVE_PATH=".gaia/local/telemetry/audit-light-routing.jsonl"

usage() {
  cat >&2 <<'EOF'
usage: audit-dispatch-cost-report.sh [--root <r>] [--window <n>]
EOF
}

root=""
window_branches="$DEFAULT_WINDOW_BRANCHES"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root | --window)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      case "$1" in
        --root) root="$2" ;;
        --window) window_branches="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$window_branches" in
  '' | *[!0-9]* | 0*)
    printf 'audit-dispatch-cost-report: --window must be a positive integer\n' >&2
    exit 2
    ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'audit-dispatch-cost-report: jq is required\n' >&2
  exit 1
}

self_directory="${BASH_SOURCE[0]%/*}"
# shellcheck source=/dev/null
. "$self_directory/main-root-lib.sh"

main="$(gaia_resolve_main_root "${root:-$PWD}" 2>/dev/null)" || main=""
[ -n "$main" ] || exit 0
log="$main/$LOG_RELATIVE_PATH"
[ -f "$log" ] || exit 0
[ -r "$log" ] || {
  printf 'audit-dispatch-cost-report: cannot read %s\n' "$log" >&2
  exit 1
}

# One tab-separated row per reported (member, kind); awk then formats the
# numbers, because jq has no printf. A torn line is dropped.
rows="$(jq -R -c 'fromjson? // empty' "$log" 2>/dev/null | jq -s -r --argjson window "$window_branches" '
  def median: sort | length as $count
    | if $count == 0 then null
      else (.[(($count - 1) / 2) | floor] + .[($count / 2) | floor]) / 2 end;
  def named_branch: (.branch | type) == "string" and .branch != "";
  def join_cost($kind): .event == "dispatch_cost" and .kind == $kind and .state != "not_dispatched";
  def numbers: [.[] | select(type == "number")];
  def children_values($key): [(.children // {})[] | .[$key] | select(type == "number")];
  . as $all
  | [range(0; $all | length) as $position
      | $all[$position]
      | select(type == "object"
               and (.event == "dispatch_cost" or .event == "member_result" or .event == "light_outcome"))
      | . + {position: $position}] as $events
  | ([$events[] | select(.event == "dispatch_cost" and named_branch)]
     | group_by(.branch)
     | map({key: .[0].branch, value: (map(.position) | min)})
     | from_entries) as $cutoffs
  | ([$events[] | select(.member | type == "string") | .member] | unique[]) as $member
  | ([$events[] | select(.member == $member and (.event == "dispatch_cost" or .event == "member_result") and named_branch)]
     | group_by(.branch)
     | map({branch: .[0].branch, last: (map(.position) | max)})
     | sort_by(.last)
     | .[-$window:]
     | map(.branch)) as $branches
  | [$events[] | select(.member == $member and named_branch
                        and (.branch as $branch | any($branches[]; . == $branch)))] as $windowed
  | ["member", "light_reviewer"][] as $kind
  | [$windowed[] | select(.event == "dispatch_cost" and .kind == $kind)] as $costs
  | [$costs[] | select(.state == "ok" or .state == "transcript_missing" or .state == "transcript_unparsed")] as $dispatched
  | [$costs[] | select(.state == "ok" and .incomplete == false)] as $complete
  | [$complete[] | select(.children_state == "ok")] as $with_children
  | (if $kind == "member"
     then [$costs[] | select(.state == "not_dispatched") | .digest] | unique | length
     else 0 end) as $not_dispatched
  | ([$windowed[] | select(join_cost($kind))]) as $joinable
  | ([$windowed[]
      | select(.event == (if $kind == "member" then "member_result" else "light_outcome" end)
               and named_branch
               and $cutoffs[.branch] != null
               and .position >= $cutoffs[.branch])]
     | group_by([.branch, .digest])
     | map(. as $group
           | ($group[0] | [.branch, .digest]) as $key
           | ($group | length) - ([$joinable[] | select([.branch, .digest] == $key)] | length)
           | if . < 0 then 0 else . end)
     | add // 0) as $unrecorded
  | select(($dispatched | length) > 0 or $not_dispatched > 0 or $unrecorded > 0)
  | [$member, $kind, ($branches | length), ($dispatched | length),
     ([$complete[] | .own.dollars] | numbers | median // "n/a"),
     ([$complete[] | .own.calls] | numbers | median // "n/a"),
     ([$complete[] | .own.wall_s] | numbers | median // "n/a"),
     ([$with_children[]
       | select((.own.dollars | type) == "number" and (.children_dollars | type) == "number")
       | .own.dollars + .children_dollars] | median // "n/a"),
     ([$with_children[]
       | select((.own.calls | type) == "number")
       | .own.calls + (children_values("calls") | add // 0)] | median // "n/a"),
     ([$with_children[]
       | select((.own.wall_s | type) == "number")
       | ([.own.wall_s] + children_values("longest_wall_s")) | max] | median // "n/a"),
     $not_dispatched,
     ([$costs[] | select(.state == "transcript_missing")] | length),
     ([$costs[] | select(.state == "transcript_unparsed")] | length),
     ([$costs[] | select(.state == "ok" and .incomplete == true)] | length),
     $unrecorded]
  | @tsv' 2>/dev/null)" || {
  printf 'audit-dispatch-cost-report: cannot read %s\n' "$log" >&2
  exit 1
}

[ -n "$rows" ] || exit 0

printf '%s\n' "$rows" | awk -F '\t' '
  function format(value, pattern) {
    return value == "n/a" ? value : sprintf(pattern, value)
  }
  {
    printf "%s %s branches=%s dispatches=%s dollars=%s calls=%s wall_s=%s", $1, $2, $3, $4, format($5, "%.6f"), format($6, "%.1f"), format($7, "%.3f")
    printf " dollars_with_children=%s calls_with_children=%s wall_s_with_children=%s", format($8, "%.6f"), format($9, "%.1f"), format($10, "%.3f")
    printf " not_dispatched=%s transcript_missing=%s transcript_unparsed=%s incomplete=%s unrecorded=%s\n", $11, $12, $13, $14, $15
  }'
exit 0
