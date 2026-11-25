#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by a gh stub that answers `gh pr view` with a PR body carrying a
# complete, finding-free `## PR review` section. The merge gates never read that
# section as the record, so the stub plants the matching local record too.
#
#   plant_review_record <branch> <pr-number> <head-sha> [<dir> [<findings-json-array>]]
#
# Writes the record under the main checkout of <dir> (default: the cwd), in the
# run folder of <branch>, holding <findings-json-array> (default none). A <dir> that is no repository plants nothing.

plant_review_record() {
  local branch="$1" pr="$2" head="$3" dir="${4:-$PWD}" findings="${5:-[]}" common main_root record
  local helper_root
  helper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  main_root="$(dirname "$common")"
  record="$(
    # shellcheck source=/dev/null
    . "$helper_root/.gaia/scripts/pr-body-sections-lib.sh"
    # shellcheck source=/dev/null
    . "$helper_root/.claude/hooks/lib/pr-review-verdict.sh"
    r="$(jq -n -c --argjson pr "$pr" --arg head "$head" --argjson findings "$findings" '{pr: $pr, reviewed_head: $head, spec: "present", outcome: "ran", findings: $findings}')"
    jq -c --arg digest "$(pr_review_findings_digest "$r")" '.findings_sha256 = $digest' <<<"$r"
  )"
  mkdir -p "$main_root/.gaia/local/runs/$branch"
  printf '%s\n' "$record" > "$main_root/.gaia/local/runs/$branch/pr-review.json"
}
