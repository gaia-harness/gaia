#!/usr/bin/env bash
#
# Maintainer-only report on the source line that tech-debt filings carry. This
# script is release-excluded and reads GitHub only; it writes no issue, label
# or file outside its own temporary directory.
#
# SUBCOMMANDS (each prints its lines, nothing else, and exits 0 unless noted):
#
#   filed --branch <name> [--threshold <n>] [--repo <owner/name>] [--issues-file <path>]
#       filed <n>
#       verdict pass|over        exit 0 when n <= threshold (default 4), else 1
#     Counts tech-debt issues, open or closed, created at any time, whose body
#     holds the source line for <name>.
#
#   baseline --since <date|timestamp> [--repo <owner/name>] [--issues-file <path>] [--prs-file <path>]
#       single-minor prs <n> filings <f> mean <f/n>
#       multi-minor prs <n> members <m> filings <f> per-member <f/m>
#       other prs <n> filings <f> mean <f/n>
#     Filings per merged pull request, over pulls created and merged on or
#     after --since. A pull's head is read through gaia_branch_classify and
#     gaia_branch_members. single-minor is a drain of one member and
#     multi-minor a drain of two or more, every member an issue whose severity
#     labels are exactly severity:minor; every other pull is other, a member
#     missing from the fetched issues included. A group's filings sum, over its
#     distinct head digests, the issues holding that digest's line, so two
#     pulls on one head count as two pulls sharing one digest's filings once.
#     Means have two decimals, or `none` for a zero divisor.
#
#   coverage --since <date|timestamp> [--repo <owner/name>] [--issues-file <path>] [--prs-file <path>]
#       keyed <k> sourced <s> missing <m> unknown <u> unkeyed <x>
#       unattributed <a>
#       sound yes|no             yes when missing and unknown are both zero
#     Over issues created on or after --since. keyed holds a dedup key line;
#     of those, sourced holds a valid source line, unknown holds only the
#     unknown line, and missing is the rest. unattributed counts sourced
#     issues whose first valid line is `detached` or whose digest matches no
#     head of a pull merged on or after --since.
#
# --since is YYYY-MM-DD (read as T00:00:00Z) or YYYY-MM-DDTHH:MM:SSZ. Window
# tests are string comparisons on that form, which GitHub's created_at and
# merged_at share. An option a subcommand does not list is a usage error.
#
# THE READ. `gh api --paginate`, never `gh issue list` or `gh pr list
# --search`: search-backed lists stop at 1000 results whatever --limit says
# and the tech-debt set is larger. The path is repos/<repo>/issues?labels=
# tech-debt&state=all&per_page=100 and repos/<repo>/pulls?state=closed&
# per_page=100, with <repo> being --repo or gh's own {owner}/{repo}
# placeholder. gh may print one merged array or consecutive arrays; both are
# joined, and anything else (a non-array page, unparseable output, a non-zero
# exit) is a failed read, never a count.
#
# SEAMS. --issues-file and --prs-file replace the matching read with one JSON
# array in the same REST shape, and go through the same projection: issues
# drop entries with a pull_request key and keep only those labeled tech-debt;
# pulls keep only those merged on or after --since.
#
# MATCHING. A body line matches only when the whole line, with one trailing
# carriage return removed, equals the expected line; an issue counts once per
# digest however many matching lines it holds. All matching happens in jq and
# a branch name reaches jq and the library only as data.
#
# EXIT. 0 or 1 as above. 2 with empty stdout and one `debt-source-report: `
# stderr line for a usage error, an unreadable or non-array seam, a failed or
# partial read, a missing jq or a missing SHA-256 tool. Everything is computed
# before anything prints, so a late failure leaves stdout empty.
#
# BASH 3.2 and jq 1.6: no associative arrays, and only jq builtins 1.6 has.

set -u

script_directory="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)" || script_directory="."
# shellcheck disable=SC1091
. "$script_directory/debt-source-lib.sh"

work_directory=""
trap '[ -z "$work_directory" ] || rm -rf "$work_directory"' EXIT

die() {
  printf 'debt-source-report: %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

# normalize_since <value>: prints the T00:00:00Z form or dies.
normalize_since() {
  local pattern='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])(T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z)?$'
  [[ "$1" =~ $pattern ]] || die "--since must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"
  case "$1" in
    *T*) printf '%s' "$1" ;;
    *) printf '%sT00:00:00Z' "$1" ;;
  esac
}

# read_array <label> <rest-of-path> <seam-file> <output-file>
read_array() {
  local label="$1" rest="$2" seam="$3" output_file="$4" raw="$4.raw"
  if [ -n "$seam" ]; then
    [ -r "$seam" ] && [ -f "$seam" ] || die "cannot read $label file: $seam"
    cp "$seam" "$raw" || die "cannot read $label file: $seam"
  else
    gh api --paginate "repos/$repo_path/$rest" >"$raw" 2>/dev/null || die "gh read of $label failed"
  fi
  jq -s 'if length > 0 and all(.[]; type == "array") then add else error("not arrays") end' \
    "$raw" >"$output_file" 2>/dev/null || die "$label read is not a JSON array"
}

subcommand="${1-}"
[ -n "$subcommand" ] || die "usage: debt-source-report.sh filed|baseline|coverage [options]"
shift
case "$subcommand" in
  filed) allowed=" --branch --threshold --repo --issues-file " ;;
  baseline | coverage) allowed=" --since --repo --issues-file --prs-file " ;;
  *) die "unknown subcommand: $subcommand" ;;
esac

branch="" threshold="4" since="" repo="" issues_file="" prs_file=""
while [ $# -gt 0 ]; do
  case "$allowed" in
    *" $1 "*) ;;
    *) die "unknown option for $subcommand: $1" ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --branch) branch="$2" ;;
    --threshold) threshold="$2" ;;
    --since) since="$2" ;;
    --repo) repo="$2" ;;
    --issues-file) issues_file="$2" ;;
    --prs-file) prs_file="$2" ;;
  esac
  shift 2
done

[[ "$threshold" =~ ^[0-9]{1,9}$ ]] || die "--threshold must be a non-negative integer"
if [ -n "$repo" ]; then
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo must be owner/name"
  repo_path="$repo"
else
  repo_path="{owner}/{repo}"
fi
if [ "$subcommand" = "filed" ]; then
  [ -n "$branch" ] || die "filed needs --branch"
else
  [ -n "$since" ] || die "$subcommand needs --since"
  since="$(normalize_since "$since")" || exit 2
fi

work_directory="$(mktemp -d)" || die "cannot create a temporary directory"
issues_all="$work_directory/issues-all.json"
issues="$work_directory/issues.json"
pulls_all="$work_directory/pulls-all.json"
pulls="$work_directory/pulls.json"
heads="$work_directory/heads.json"

read_array issues "issues?labels=tech-debt&state=all&per_page=100" "$issues_file" "$issues_all"

# Issues: no pull requests, only tech-debt, with the whole matching lines
# (one trailing carriage return removed) and the label names kept.
jq 'map(select(has("pull_request") | not))
  | map(select([.labels[]? | .name?] | any(. == "tech-debt")))
  | map({
      number,
      created_at,
      labels: [.labels[]? | .name? | select(type == "string")],
      lines: ((.body // "") | split("\n") | map(if endswith("\r") then .[:-1] else . end) | unique)
    })' "$issues_all" >"$issues" 2>/dev/null || die "issues read has an unexpected shape"

if [ "$subcommand" = "filed" ]; then
  expected_line="$(gaia_debt_source_line_for_branch "$branch")" || die "no SHA-256 tool available"
  filed_count="$(jq --arg line "$expected_line" \
    '[.[] | select(.lines | any(.[]; . == $line))] | length' "$issues")" || die "cannot count issues"
  if [ "$filed_count" -gt "$threshold" ]; then
    verdict="over"
    status=1
  else
    verdict="pass"
    status=0
  fi
  printf 'filed %s\nverdict %s\n' "$filed_count" "$verdict"
  exit "$status"
fi

read_array pulls "pulls?state=closed&per_page=100" "$prs_file" "$pulls_all"

# Pulls merged on or after since; baseline also needs creation on or after it.
created_floor=""
[ "$subcommand" = "baseline" ] && created_floor="$since"
jq --arg since "$since" --arg floor "$created_floor" \
  'map(select((.merged_at | type) == "string" and .merged_at >= $since and (.created_at // "") >= $floor))
  | map({ref: .head.ref, created_at})' "$pulls_all" >"$pulls" 2>/dev/null || die "pulls read has an unexpected shape"

# One entry per distinct head: its expected line, drain mode and member numbers.
: >"$heads.lines"
head_refs="$(jq -r '[.[].ref] | unique | .[]' "$pulls")" || die "cannot read pull heads"
while IFS= read -r head_ref; do
  [ -n "$head_ref" ] || continue
  head_line="$(gaia_debt_source_line_for_branch "$head_ref")" || die "no SHA-256 tool available"
  head_mode="$(gaia_branch_classify "$head_ref")"
  head_members="$(gaia_branch_members "$head_ref" | tr '\n' ',')"
  jq -nc --arg ref "$head_ref" --arg line "$head_line" --arg mode "${head_mode%% *}" --arg members "$head_members" \
    '{ref: $ref, line: $line, mode: $mode, members: ($members | split(",") | map(select(. != "") | tonumber))}' \
    >>"$heads.lines" || die "cannot record pull heads"
done <<EOF
$head_refs
EOF
jq -s '.' "$heads.lines" >"$heads" || die "cannot record pull heads"

if [ "$subcommand" = "baseline" ]; then
  report_lines="$(jq -r --slurpfile pulls "$pulls" --slurpfile heads "$heads" '
    def count($line): [.[] | select(.lines | any(.[]; . == $line))] | length;
    def mean($filings; $divisor):
      if $divisor == 0 then "none"
      else ((($filings * 200 + $divisor) / (2 * $divisor)) | floor) as $hundredths
        | "\($hundredths / 100 | floor).\($hundredths % 100 | if . < 10 then "0\(.)" else tostring end)"
      end;
    . as $issues
    | ($heads[0] | map({key: .ref, value: .}) | from_entries) as $by_ref
    | def minor($number):
        [$issues[] | select(.number == $number)] as $found
        | ($found | length) > 0
          and ([$found[0].labels[] | select(startswith("severity:"))] == ["severity:minor"]);
      [$pulls[0][] | $by_ref[.ref] as $head
        | {line: $head.line, members: ($head.members | length),
           kind: (if $head.mode == "drain" and ($head.members | length) > 0
                    and all($head.members[]; minor(.))
                  then (if ($head.members | length) == 1 then "single-minor" else "multi-minor" end)
                  else "other" end)}] as $classified
    | def group($kind):
        [$classified[] | select(.kind == $kind)] as $in_group
        | {prs: ($in_group | length),
           members: ([$in_group[].members] | add // 0),
           filings: ([$in_group[].line] | unique | map(. as $line | $issues | count($line)) | add // 0)};
      group("single-minor") as $single
    | group("multi-minor") as $multi
    | group("other") as $other
    | "single-minor prs \($single.prs) filings \($single.filings) mean \(mean($single.filings; $single.prs))",
      "multi-minor prs \($multi.prs) members \($multi.members) filings \($multi.filings) per-member \(mean($multi.filings; $multi.members))",
      "other prs \($other.prs) filings \($other.filings) mean \(mean($other.filings; $other.prs))"
  ' "$issues")" || die "cannot compute the baseline"
  printf '%s\n' "$report_lines"
  exit 0
fi

detached_line="$(gaia_debt_source_line detached)"
report_lines="$(jq -r --slurpfile heads "$heads" --arg since "$since" --arg detached "$detached_line" \
  --arg valid "$GAIA_DEBT_SOURCE_VALID_RE" --arg unknown "$GAIA_DEBT_SOURCE_UNKNOWN_LINE" \
  --arg key '^<!-- gaia-debt-key: v1 class=[^ ]+ path=.+ line=[0-9]+ -->$' '
  def valid_lines: [.lines[] | select(test($valid))];
  [$heads[0][].line] as $head_lines
  | map(select(.created_at >= $since)) as $window
  | [$window[] | select(any(.lines[]; test($key)))] as $keyed
  | [$keyed[] | select(valid_lines | length > 0)] as $sourced
  | [$keyed[] | select((valid_lines | length) == 0 and any(.lines[]; . == $unknown))] as $unknown_issues
  | [$sourced[] | valid_lines[0]
      | select(. == $detached or ((. as $line | $head_lines | any(.[]; . == $line)) | not))] as $unattributed
  | (($keyed | length) - ($sourced | length) - ($unknown_issues | length)) as $missing
  | "keyed \($keyed | length) sourced \($sourced | length) missing \($missing) unknown \($unknown_issues | length) unkeyed \(($window | length) - ($keyed | length))",
    "unattributed \($unattributed | length)",
    "sound \(if $missing == 0 and ($unknown_issues | length) == 0 then "yes" else "no" end)"
' "$issues")" || die "cannot compute the coverage"
printf '%s\n' "$report_lines"
exit 0
