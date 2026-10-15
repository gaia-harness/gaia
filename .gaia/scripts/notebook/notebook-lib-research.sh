# shellcheck shell=bash
#
# Research eligibility for the notebook library: the GitHub citation query, the
# landed verdict and the keep rules that decide whether a closed research
# folder may be reaped. Sourced by research-reaper.sh; it sources
# notebook-lib.sh itself. Defines functions only.
#
# Exit codes follow notebook-lib.sh. gaia_notebook_research_citations and
# gaia_notebook_research_landed print their answer and return 0 even when
# GitHub could not answer: the answer says so.
#
# Every GitHub read is bounded in time and its text is data: it is matched
# with jq and never evaluated, and no remote text reaches a reason string.
#
# Keep rules, first applicable wins (the rule name is what `kept` reports):
#   no-row                       the folder has no catalog row
#   status-<status>              the row is not closed
#   snoozed                      snoozed_until is in the future (or unreadable)
#   too-young                    status_changed_at, or the newest README.md or
#                                STATE.md mtime, is inside the retention window
#   cited-by-spec                a draft or ready spec row links the slug
#   cited-by-plan                a ready plan row links the slug, directly or
#                                through its linked spec
#   cited-in-memory              an auto-memory file names the slug under the
#                                old or the notebook research prefix
#   citation-query-unanswered    GitHub could not answer, so nothing is eligible
#   named-by-open-issue-or-pr    an open issue or pull request names the slug
# Two more refuse before those: invalid-slug (an id that could name a path
# outside the research folder) and no-folder (a closed row with nothing to
# reap).
# A spec or plan row that is abandoned, merged or carries a reap record never
# cites.
#
# Window: GAIA_RESEARCH_RETENTION_DAYS, default 30 (the same default as
# GAIA_SPEC_RETENTION_DAYS: long enough that a folder from the last thread of
# work is still around when someone returns to it, short enough that a closed
# folder does not sit for a season); a non-numeric value falls back to 30.

_gaia_research_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f gaia_notebook_rows >/dev/null 2>&1; then
  # shellcheck source=SCRIPTDIR/notebook-lib.sh
  source "$_gaia_research_library_directory/notebook-lib.sh"
fi

# Longest wait for one GitHub read. A paginated read of a few hundred open
# items takes single-digit seconds on a healthy link; this only has to outlast
# a slow one while staying short of the point where the person at the prompt
# gives up and interrupts the command. GAIA_RESEARCH_GH_TIMEOUT_SECONDS
# overrides it (a non-numeric or zero value falls back).
_GAIA_RESEARCH_GH_TIMEOUT_DEFAULT_SECONDS=30

_gaia_research_gh_timeout_seconds() {
  local seconds="${GAIA_RESEARCH_GH_TIMEOUT_SECONDS:-$_GAIA_RESEARCH_GH_TIMEOUT_DEFAULT_SECONDS}"
  case "$seconds" in '' | *[!0-9]* | 0) seconds="$_GAIA_RESEARCH_GH_TIMEOUT_DEFAULT_SECONDS" ;; esac
  printf '%s\n' "$seconds"
}

gaia_notebook_research_retention_days() {
  local days="${GAIA_RESEARCH_RETENTION_DAYS:-30}"
  case "$days" in '' | *[!0-9]*) days=30 ;; esac
  printf '%s\n' "$days"
}

# Runs a command with output redirected to files, killing it after <limit>
# seconds. Returns 124 on a timeout. No timeout(1) on stock macOS.
_gaia_research_run_bounded() {
  local limit="$1" output_file="$2" error_file="$3" command_pid watcher_pid command_status
  shift 3
  "$@" >"$output_file" 2>"$error_file" </dev/null &
  command_pid=$!
  ( sleep "$limit"; kill "$command_pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher_pid=$!
  { wait "$command_pid"; } 2>/dev/null
  command_status=$?
  pkill -P "$watcher_pid" 2>/dev/null
  kill "$watcher_pid" 2>/dev/null
  { wait "$watcher_pid"; } 2>/dev/null
  if [ "$command_status" -eq 143 ]; then
    return 124
  fi
  return "$command_status"
}

# _gaia_research_gh_read <work-dir> <gh args...>: gh output lands in
# <work-dir>/out. On failure, a one-line reason is written to <work-dir>/reason
# and the return is non-zero.
_gaia_research_gh_read() {
  local work_directory="$1" read_status limit
  shift
  limit="$(_gaia_research_gh_timeout_seconds)"
  if ! command -v gh >/dev/null 2>&1; then
    printf 'the GitHub CLI is not installed' >"$work_directory/reason"
    return 1
  fi
  _gaia_research_run_bounded "$limit" "$work_directory/out" "$work_directory/err" gh "$@"
  read_status=$?
  [ "$read_status" -eq 0 ] && return 0
  if [ "$read_status" -eq 124 ]; then
    printf 'the GitHub query timed out after %s seconds' "$limit" >"$work_directory/reason"
  elif grep -qiE 'gh auth login|not logged in|authentication' "$work_directory/err" 2>/dev/null; then
    printf 'the GitHub CLI is not authenticated; run gh auth login' >"$work_directory/reason"
  else
    printf 'the GitHub query failed (gh exit status %s)' "$read_status" >"$work_directory/reason"
  fi
  return "$read_status"
}

# Prints owner/repo of the first GitHub remote, preferring origin; rc 1 when
# the main checkout has none.
_gaia_research_repository_name() {
  local main remote_name url remainder
  main="$(_gaia_notebook_main)" || return 1
  for remote_name in origin $(git -C "$main" remote 2>/dev/null); do
    url="$(git -C "$main" remote get-url "$remote_name" 2>/dev/null)" || continue
    case "$url" in
      *github.com[:/]*) ;;
      *) continue ;;
    esac
    remainder="${url#*github.com[:/]}"
    remainder="${remainder%/}"
    remainder="${remainder%.git}"
    if LC_ALL=C _gaia_notebook_matches "$remainder" '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
      printf '%s\n' "$remainder"
      return 0
    fi
  done
  return 1
}

_gaia_research_unanswered_json() {
  jq -cn --arg reason "$1" '{answered: false, reason: $reason, counts: {}}'
}

# gaia_notebook_research_citations <slug>...: one read of the open issues and
# pull requests, matched locally against the exact slug strings. Prints
# {"answered": bool, "reason": string|null, "counts": {"<slug>": n}}.
gaia_notebook_research_citations() {
  local repository work_directory slugs_json reason counts
  if [ "$#" -eq 0 ]; then
    jq -cn '{answered: true, reason: null, counts: {}}'
    return 0
  fi
  if ! repository="$(_gaia_research_repository_name)"; then
    _gaia_research_unanswered_json "no GitHub remote on the main checkout"
    return 0
  fi
  work_directory="$(mktemp -d "${TMPDIR:-/tmp}/gaia-research-gh.XXXXXX")" || {
    _gaia_research_unanswered_json "no scratch space for the GitHub query"
    return 0
  }
  # The issues endpoint lists pull requests too, so one paginated read covers
  # both.
  if ! _gaia_research_gh_read "$work_directory" api --paginate "repos/$repository/issues?state=open&per_page=100"; then
    reason="$(cat "$work_directory/reason" 2>/dev/null)"
    rm -rf "${work_directory:?}"
    _gaia_research_unanswered_json "${reason:-the GitHub query failed}"
    return 0
  fi
  slugs_json="$(printf '%s\n' "$@" | jq -R . | jq -cs .)"
  # Pages arrive as concatenated arrays; anything that is not an array of
  # objects (an error body, HTML) is not an answer.
  counts="$(jq -cs --argjson slugs "$slugs_json" '
    if all(.[]; type == "array") and all(.[][]; type == "object") then
      ([.[][] | ((.title // "") + "\n" + (.body // ""))]) as $texts
      | reduce $slugs[] as $slug ({};
          ($slug | gsub("\\."; "\\.")) as $escaped
          | ("(^|[^A-Za-z0-9._-])" + $escaped + "($|[^A-Za-z0-9_-]|\\.($|[^A-Za-z0-9_-]))") as $pattern
          | .[$slug] = ([$texts[] | select(test($pattern))] | length))
    else null end' "$work_directory/out" 2>/dev/null)"
  rm -rf "${work_directory:?}"
  if [ -z "$counts" ] || [ "$counts" = "null" ]; then
    _gaia_research_unanswered_json "GitHub returned an answer that is not a list of issues"
    return 0
  fi
  jq -cn --argjson counts "$counts" '{answered: true, reason: null, counts: $counts}'
}

# Reads once and keeps the answer for the keep rules and the verdicts, which
# run in command substitutions that cannot hand state back.
gaia_notebook_research_prefetch_citations() {
  _GAIA_RESEARCH_CITATIONS_JSON="$(gaia_notebook_research_citations "$@")"
}

# Sets _GAIA_RESEARCH_PULL_REQUESTS_JSON to a JSON array of
# {number, state, headRefName} for every pull request, or to the word
# unavailable when GitHub cannot answer.
gaia_notebook_research_prefetch_pull_requests() {
  local repository work_directory
  _GAIA_RESEARCH_PULL_REQUESTS_JSON="unavailable"
  repository="$(_gaia_research_repository_name)" || return 0
  work_directory="$(mktemp -d "${TMPDIR:-/tmp}/gaia-research-gh.XXXXXX")" || return 0
  if _gaia_research_gh_read "$work_directory" pr list --repo "$repository" --state all --limit 1000 --json number,state,headRefName \
    && jq -e 'type == "array"' "$work_directory/out" >/dev/null 2>&1; then
    _GAIA_RESEARCH_PULL_REQUESTS_JSON="$(jq -c . "$work_directory/out")"
  fi
  rm -rf "${work_directory:?}"
}

_gaia_research_load_usage() {
  declare -f gaia_usage_keys_json >/dev/null 2>&1 && return 0
  # shellcheck source=SCRIPTDIR/../usage-lib.sh
  source "$_gaia_research_library_directory/../usage-lib.sh" 2>/dev/null || return 1
  # shellcheck source=SCRIPTDIR/../usage-resolve-lib.sh
  source "$_gaia_research_library_directory/../usage-resolve-lib.sh" 2>/dev/null || return 1
  declare -f gaia_usage_keys_json >/dev/null 2>&1
}

# Prints a JSON array of the children linked to research:<slug> by a live
# Usage Ledger edge, or returns non-zero when the ledger cannot be read.
_gaia_research_edge_children() {
  local slug="$1" main telemetry_directory keys_json links_file
  main="$(_gaia_notebook_main)" || return 1
  _gaia_research_load_usage || return 1
  telemetry_directory="$(gaia_usage_telemetry_directory "$main")"
  links_file="$telemetry_directory/links.jsonl"
  if [ ! -f "$links_file" ] || ! grep -qF -- "research:$slug" "$links_file"; then
    printf '[]\n'
    return 0
  fi
  keys_json="$(gaia_usage_keys_json "$main" "$telemetry_directory/usage.jsonl" "$telemetry_directory/links.jsonl")" || return 1
  # The keys object reaches jq on stdin: one argument over 128 KiB is refused
  # on Linux, and a long branch history passes that.
  printf '%s' "$keys_json" | jq -nc --rawfile links_store "$links_file" --arg parent "research:$slug" \
    "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
    input as $keys
    | [usage_edges(usage_rows($links_store); $keys)[] | select(.parent == $parent) | .child]'
}

# gaia_notebook_research_landed <slug>: landed | not landed | no evidence |
# unknown, from every link the slug has (spec rows, plan rows, pull requests
# and Usage Ledger edges).
gaia_notebook_research_landed() {
  local slug="${1:-}" catalog children facts link_count needs_pull_requests pull_requests head_keys="[]"
  local branch_name head_name
  gaia_notebook_valid_id research "$slug" || return 2
  catalog="$(gaia_notebook_catalog_read)" || return $?
  if ! children="$(_gaia_research_edge_children "$slug")"; then
    printf 'unknown\n'
    return 0
  fi
  facts="$(printf '%s' "$catalog" | jq -c --arg slug "$slug" --argjson children "$children" '
    def research_links:
      ((.links // {}) | if type == "object" then .research // [] else [] end)
      | if type == "array" then . elif type == "string" then [.] else [] end;
    def linked_spec: (.links // {}) | if type == "object" then .spec else null end;
    ([.items[] | select(.kind == "spec" and (research_links | any(. == $slug))) | .id]) as $slug_specs
    | ([$children[] | select(startswith("spec:")) | sub("^spec:"; "")]) as $edge_specs
    | (($slug_specs + $edge_specs) | unique) as $spec_ids
    | [.items[] | select(.kind == "spec" and (.id as $id | $spec_ids | index($id) != null))] as $specs
    | [.items[] | select(.kind == "plan"
        and ((research_links | any(. == $slug))
          or (linked_spec as $spec_id | $spec_id != null and ($spec_ids | index($spec_id) != null))))] as $plans
    | ($specs + $plans) as $rows
    | {
        states: (
          [$rows[] | ({merged: "merged", draft: "open", ready: "open"}[.status] // "neutral")]
          + [$edge_specs[] | select(. as $id | [$specs[].id] | index($id) == null) | "neutral"]),
        pull_requests: (
          [$rows[] | ((.links // {} | if type == "object" then .pr else null end), .pr_number)
            | select(. != null) | tonumber?] | unique),
        branches: [$children[] | select(startswith("branch:"))]
      }')" || { printf 'unknown\n'; return 0; }
  link_count="$(printf '%s' "$facts" | jq -r '(.states | length) + (.pull_requests | length) + (.branches | length)')"
  if [ "$link_count" -eq 0 ]; then
    printf 'no evidence\n'
    return 0
  fi
  needs_pull_requests="$(printf '%s' "$facts" | jq -r '((.pull_requests | length) + (.branches | length)) > 0')"
  pull_requests="[]"
  if [ "$needs_pull_requests" = "true" ]; then
    if [ -z "${_GAIA_RESEARCH_PULL_REQUESTS_JSON+x}" ]; then
      gaia_notebook_research_prefetch_pull_requests
    fi
    pull_requests="$_GAIA_RESEARCH_PULL_REQUESTS_JSON"
    if [ "$pull_requests" = "unavailable" ]; then
      printf 'unknown\n'
      return 0
    fi
    # A hashed branch key cannot be reversed, so key every head instead.
    if printf '%s' "$facts" | jq -e 'any(.branches[]; startswith("branch:%"))' >/dev/null; then
      _gaia_research_load_usage || { printf 'unknown\n'; return 0; }
      head_keys="$(
        while IFS= read -r head_name; do
          branch_name="$(gaia_usage_branch_key "$head_name")" || continue
          jq -cn --arg key "$branch_name" --arg head "$head_name" '{key: $key, head: $head}'
        done < <(printf '%s' "$pull_requests" | jq -r '[.[].headRefName] | unique | .[]') | jq -cs .
      )"
    fi
  fi
  printf '%s' "$facts" | jq -r --argjson pull_requests "$pull_requests" --argjson head_keys "$head_keys" '
    def pull_request_state: ({MERGED: "merged", OPEN: "open"}[.state] // "neutral");
    . as $facts
    | ([$facts.pull_requests[] as $number
        | ([$pull_requests[] | select(.number == $number)] | first) as $pull_request
        | if $pull_request == null then "unknown" else ($pull_request | pull_request_state) end]
      + [$facts.branches[] as $branch
        | ($branch | sub("^branch:"; "")) as $name
        | ([$head_keys[] | select(.key == $branch) | .head] | first // $name) as $head
        | ([$pull_requests[] | select(.headRefName == $head)] | map(pull_request_state))[]]
      + $facts.states) as $states
    | if any($states[]; . == "unknown") then "unknown"
      elif any($states[]; . == "open") then "not landed"
      elif any($states[]; . == "merged") then "landed"
      else "not landed" end'
}

_gaia_research_escape_dots() {
  printf '%s' "$1" | sed 's/\./\\./g'
}

# 0 when an auto-memory file names the slug under the old research prefix or
# the notebook research prefix.
_gaia_research_cited_in_memory() {
  local slug="$1" memory_directory main kind_directory old_prefix new_prefix prefix pattern
  memory_directory="$(gaia_notebook_memory_directory 2>/dev/null)" || return 1
  [ -d "$memory_directory" ] || return 1
  main="$(_gaia_notebook_main)" || return 1
  kind_directory="$(gaia_notebook_kind_directory research)" || return 1
  old_prefix="$(gaia_notebook_legacy_prefix research)" || return 1
  new_prefix="${kind_directory#"$main/"}/"
  for prefix in "$old_prefix" "$new_prefix"; do
    pattern="$(_gaia_research_escape_dots "$prefix$slug")"
    if grep -rqE -e "$pattern"'($|[^A-Za-z0-9_-]|\.($|[^A-Za-z0-9_-]))' -- "$memory_directory" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Newest mtime among README.md and STATE.md inside the folder, or nothing when
# neither exists.
_gaia_research_newest_mtime() {
  local folder="$1" candidate newest="" modified stat_gnu=0
  stat -c %Y / >/dev/null 2>&1 && stat_gnu=1
  for candidate in "$folder/README.md" "$folder/STATE.md"; do
    [ -f "$candidate" ] || continue
    if [ "$stat_gnu" -eq 1 ]; then
      modified="$(stat -c %Y "$candidate" 2>/dev/null)" || continue
    else
      modified="$(stat -f %m "$candidate" 2>/dev/null)" || continue
    fi
    case "$modified" in '' | *[!0-9]*) continue ;; esac
    if [ -z "$newest" ] || [ "$modified" -gt "$newest" ]; then
      newest="$modified"
    fi
  done
  [ -n "$newest" ] && printf '%s\n' "$newest"
  return 0
}

# gaia_notebook_research_eligibility <slug>: prints `eligible` or `kept <rule>`.
# The citation answer comes from gaia_notebook_research_prefetch_citations
# when it ran; otherwise it is read for this slug alone.
gaia_notebook_research_eligibility() {
  local slug="${1:-}" catalog facts now_epoch retention_days window_seconds folder newest_mtime
  local has_row status snooze age_ok cited_spec cited_plan citations count answered
  if ! gaia_notebook_valid_id research "$slug" 2>/dev/null; then
    printf 'kept invalid-slug\n'
    return 0
  fi
  catalog="$(gaia_notebook_catalog_read)" || return $?
  now_epoch="$(date -u +%s)"
  retention_days="$(gaia_notebook_research_retention_days)"
  window_seconds=$((retention_days * 86400))
  facts="$(printf '%s' "$catalog" | jq -c --arg slug "$slug" --argjson now "$now_epoch" --argjson window "$window_seconds" '
    def research_links:
      ((.links // {}) | if type == "object" then .research // [] else [] end)
      | if type == "array" then . elif type == "string" then [.] else [] end;
    def epoch: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
    def citing: (has("reap") | not);
    .items as $catalog_items
    | ([$catalog_items[] | select(.kind == "research" and .id == $slug)] | first) as $row
    | {
        has_row: ($row != null),
        status: ($row.status // ""),
        snooze: (if $row == null or ($row | has("snoozed_until") | not) then "none"
                 else (($row.snoozed_until | if type == "string" then epoch else null end) as $until
                       | if $until == null or $until > $now then "future" else "none" end) end),
        age_ok: ($row != null
                 and (($row.status_changed_at | if type == "string" then epoch else null end) as $changed
                      | $changed != null and ($now - $changed) >= $window)),
        cited_spec: any($catalog_items[]; .kind == "spec" and citing and (.status == "draft" or .status == "ready")
                                  and (research_links | any(. == $slug))),
        cited_plan: any($catalog_items[]; .kind == "plan" and citing and .status == "ready"
                                  and ((research_links | any(. == $slug))
                                    or (((.links // {}) | if type == "object" then .spec else null end) as $spec_id
                                        | $spec_id != null
                                          and any($catalog_items[]; .kind == "spec" and .id == $spec_id
                                                                    and (research_links | any(. == $slug))))))
      }' 2>/dev/null)" || {
    printf 'kept unreadable-catalog\n'
    return 0
  }
  has_row="$(printf '%s' "$facts" | jq -r '.has_row')"
  [ "$has_row" = "true" ] || { printf 'kept no-row\n'; return 0; }
  status="$(printf '%s' "$facts" | jq -r '.status')"
  [ "$status" = "closed" ] || { printf 'kept status-%s\n' "$status"; return 0; }
  snooze="$(printf '%s' "$facts" | jq -r '.snooze')"
  [ "$snooze" = "none" ] || { printf 'kept snoozed\n'; return 0; }
  age_ok="$(printf '%s' "$facts" | jq -r '.age_ok')"
  [ "$age_ok" = "true" ] || { printf 'kept too-young\n'; return 0; }
  folder="$(gaia_notebook_item_directory research "$slug" 2>/dev/null)" || folder=""
  if [ -z "$folder" ] || [ ! -d "$folder" ]; then
    printf 'kept no-folder\n'
    return 0
  fi
  newest_mtime="$(_gaia_research_newest_mtime "$folder")"
  if [ -n "$newest_mtime" ] && [ $((now_epoch - newest_mtime)) -lt "$window_seconds" ]; then
    printf 'kept too-young\n'
    return 0
  fi
  cited_spec="$(printf '%s' "$facts" | jq -r '.cited_spec')"
  [ "$cited_spec" = "false" ] || { printf 'kept cited-by-spec\n'; return 0; }
  cited_plan="$(printf '%s' "$facts" | jq -r '.cited_plan')"
  [ "$cited_plan" = "false" ] || { printf 'kept cited-by-plan\n'; return 0; }
  if _gaia_research_cited_in_memory "$slug"; then
    printf 'kept cited-in-memory\n'
    return 0
  fi
  citations="${_GAIA_RESEARCH_CITATIONS_JSON-}"
  [ -n "$citations" ] || citations="$(gaia_notebook_research_citations "$slug")"
  answered="$(printf '%s' "$citations" | jq -r '.answered' 2>/dev/null)"
  count="$(printf '%s' "$citations" | jq -r --arg slug "$slug" '.counts[$slug] // "none"' 2>/dev/null)"
  if [ "$answered" != "true" ] || [ "$count" = "none" ]; then
    printf 'kept citation-query-unanswered\n'
    return 0
  fi
  if [ "$count" -gt 0 ]; then
    printf 'kept named-by-open-issue-or-pr\n'
    return 0
  fi
  printf 'eligible\n'
}
