#!/usr/bin/env bash
#
# The stopped /gaia-debt fixes: prints `<issue>\t<branch>` for every local
# debt branch that names a claimed issue and has no open pull request, one line
# per branch, and nothing else. It changes nothing; a caller resumes the branch
# (.claude/skills/gaia/references/debt/resume.md) or offers it as a job
# (.gaia/scripts/gaia-next.sh pick).
#
# A fix is STOPPED when all of these hold:
#   claim   the branch names the issue as a debt member, read through
#           .gaia/scripts/branch-name-lib.sh (every member of a batch branch
#           counts, and the worktree spelling counts as `debt/<n>-<slug>`),
#           and the issue is open, labelled `tech-debt` and `in-progress`
#   local   the branch is a local branch: a remote-tracking ref alone cannot
#           be re-entered from this clone
#   no PR   no open pull request has the branch as its head
# The issue printed is the lowest claimed member of the branch, or the one
# --issue names.
#
# FAIL-CLOSED: when the claims, the pull requests or the branches cannot be
# read, this prints nothing on stdout, names what failed on stderr, and exits
# 3, so a caller never resumes a branch an open pull request already owns.
#
# Usage:
#   bash .gaia/scripts/debt-stuck-fixes.sh [--dir <repo>] [--issue <number>]
#
# Test seams (each replaces one live read): --claims-json <file> (the
# `gh issue list` array of {number}), --prs-json <file> (the `gh pr list` array
# of {headRefName}) and --branches <file> (local branch names, one per line).
#
# Exit: 0 verdict printed (possibly empty), 2 usage error, 3 an input could not
# be read.

set -uo pipefail

directory="."
issue=""
claims_file=""
prs_file=""
branches_file=""

die_usage() {
  printf 'debt-stuck-fixes: %s\n' "$1" >&2
  exit 2
}
die_input() {
  printf 'debt-stuck-fixes: %s; no fix is reported stopped\n' "$1" >&2
  exit 3
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir | --issue | --claims-json | --prs-json | --branches)
      [ "$#" -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --dir) directory="$2" ;;
        --issue) issue="$2" ;;
        --claims-json) claims_file="$2" ;;
        --prs-json) prs_file="$2" ;;
        --branches) branches_file="$2" ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown argument $1" ;;
  esac
done

case "$issue" in *[!0-9]*) die_usage "--issue must be an issue number" ;; esac

command -v jq >/dev/null 2>&1 || die_input "jq is not installed"

branch_library="$(dirname "${BASH_SOURCE[0]}")/branch-name-lib.sh"
[ -r "$branch_library" ] || die_input "branch library $branch_library is missing or unreadable"
# shellcheck source=/dev/null
. "$branch_library" || die_input "branch library $branch_library failed to load"

if [ -n "$claims_file" ]; then
  claims="$(cat "$claims_file")" || die_input "cannot read $claims_file"
else
  claims="$(gh issue list --label tech-debt --label in-progress --state open \
    --limit 1000 --json number)" \
    || die_input "gh issue list failed (auth, network, or rate limit)"
fi
printf '%s' "$claims" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_input "the claims list is not a JSON array"
claimed="$(printf '%s' "$claims" | jq -r '.[].number')" \
  || die_input "the claims list could not be read"
[ -n "$claimed" ] || exit 0

if [ -n "$prs_file" ]; then
  prs="$(cat "$prs_file")" || die_input "cannot read $prs_file"
else
  prs="$(gh pr list --state open --limit 1000 --json headRefName)" \
    || die_input "gh pr list failed (auth, network, or rate limit)"
fi
printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_input "the pull-request list is not a JSON array"
pr_heads="$(printf '%s' "$prs" | jq -r '.[].headRefName // empty')" \
  || die_input "the pull-request head branches could not be read"

if [ -n "$branches_file" ]; then
  branches="$(cat "$branches_file")" || die_input "cannot read $branches_file"
else
  git -C "$directory" rev-parse --git-dir >/dev/null 2>&1 \
    || die_input "$directory is not a git repository, so no branch can be read"
  branches="$(git -C "$directory" for-each-ref --format='%(refname:lstrip=2)' refs/heads)" \
    || die_input "the local branches could not be listed"
fi

while IFS= read -r branch_name; do
  [ -n "$branch_name" ] || continue
  grep -qxF -- "$branch_name" <<<"$pr_heads" && continue
  first_claimed=""
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    grep -qxF -- "$member" <<<"$claimed" || continue
    if [ -n "$issue" ]; then
      [ "$member" = "$issue" ] && first_claimed="$member"
    else
      [ -n "$first_claimed" ] || first_claimed="$member"
    fi
  done < <(gaia_branch_members "$branch_name")
  [ -n "$first_claimed" ] && printf '%s\t%s\n' "$first_claimed" "$branch_name"
done <<<"$branches"
exit 0
