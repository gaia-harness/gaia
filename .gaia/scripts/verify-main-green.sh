#!/usr/bin/env bash
# verify-main-green.sh: refuse a release while main is red. /gaia-release runs
# it before it merges the release pull request and again before it tags.
#
# PR runs of `GAIA: Audit CI Tests` (.github/workflows/audit-ci-tests.yml) run
# only the bats suites a change can affect; every push to main runs them all,
# and is the only run that sees what the scoped legs skip. So a release commit
# is green only when both signals agree:
#
#   - no open issue carries the `ci-red-main` label, which
#     .gaia/tests/report-main-status.sh keeps open while main is red;
#   - the push-to-main run of that workflow on the release commit completed
#     with `success`. The workflow concludes `success` only when its
#     `Audit CI Tests` aggregator job does.
#
# Either one alone refuses. The issue outlives a green run that is not the red
# commit or a descendant of it (the reporter leaves it open then), and the run
# conclusion is the verdict on this commit when the reporter itself failed to
# write the issue. The push concurrency group is one commit, so each commit has
# one push run, its reruns being attempts of that same run.
#
# A run still queued or in progress refuses too, with its own exit code: the
# check is a single read, and waiting is the caller's `gh run watch`, bounded by
# the run itself rather than by a poll loop here.
#
# Usage:
#   verify-main-green.sh [--repo <owner/name>] [--branch <branch>] [--sha <commit>]
#
#   --repo    defaults to `gh repo view --json nameWithOwner`.
#   --branch  defaults to the remote HEAD branch, else `main`.
#   --sha     the release commit; defaults to the branch head on GitHub, not
#             the local checkout, which can lag the remote.
#
# Exit codes:
#   0  main is green at the release commit.
#   1  main is red: an open ci-red-main issue, or a completed run that is not
#      success.
#   2  usage error, or a signal is absent or unreadable (no push run for the
#      commit, a failed gh call, output in an unexpected shape). Refuses.
#   3  the push run for the commit is queued or in progress. Refuses.
#
# No flag skips the check: the repair is fixing main or rerunning a flaky leg.
set -uo pipefail

readonly WORKFLOW_FILE="audit-ci-tests.yml"
readonly WORKFLOW_NAME="GAIA: Audit CI Tests"
readonly LABEL_NAME="ci-red-main"

repo=""
branch=""
release_sha=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--branch|--sha)
      if [ $# -lt 2 ]; then
        echo "verify-main-green: $1 needs a value" >&2
        exit 2
      fi
      case "$1" in
        --repo)   repo="$2" ;;
        --branch) branch="$2" ;;
        --sha)    release_sha="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "verify-main-green: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

refuse_unreadable() {
  printf 'verify-main-green: REFUSED: %s Refusing to release on a signal that could not be read.\n' "$1" >&2
  exit 2
}

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi
[ -n "$repo" ] || refuse_unreadable "could not resolve the repository (pass --repo)."

if [ -z "$branch" ]; then
  branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')
  [ -n "$branch" ] || branch="main"
fi

if [ -z "$release_sha" ]; then
  release_sha=$(gh api "repos/${repo}/commits/${branch}" --jq '.sha' 2>/dev/null) \
    || refuse_unreadable "could not read the head of ${branch} on ${repo}."
fi
case "$release_sha" in
  *[!0-9a-f]* | "") refuse_unreadable "the release commit '${release_sha}' is not a commit sha." ;;
esac

open_issues=$(gh issue list --repo "$repo" --label "$LABEL_NAME" --state open \
  --json number,url --jq '.[] | "\(.number) \(.url)"' 2>/dev/null) \
  || refuse_unreadable "could not list open ${LABEL_NAME} issues on ${repo}."

run_line=$(gh api "repos/${repo}/actions/workflows/${WORKFLOW_FILE}/runs?event=push&branch=${branch}&head_sha=${release_sha}&per_page=100" \
  --jq '.workflow_runs | sort_by(.created_at) | last // empty | "\(.id) \(.status) \(.conclusion // "none") \(.html_url)"' 2>/dev/null) \
  || refuse_unreadable "could not read the ${WORKFLOW_NAME} push runs for ${release_sha} on ${repo}."

if [ -n "$open_issues" ]; then
  echo "verify-main-green: REFUSED: main is red. Open ${LABEL_NAME} issue:" >&2
  printf '%s\n' "$open_issues" | sed 's/^/  #/' >&2
  echo "Fix main. The issue closes itself when a push run of ${WORKFLOW_NAME} on main passes on the red commit or a descendant of it; then re-run this check." >&2
  exit 1
fi

if [ -z "$run_line" ]; then
  refuse_unreadable "no push run of ${WORKFLOW_NAME} exists for ${release_sha} on ${branch}."
fi

read -r run_id run_status run_conclusion run_url extra <<<"$run_line"
case "$run_id" in
  *[!0-9]* | "") refuse_unreadable "the runs query returned an unexpected line: ${run_line}" ;;
esac
if [ -z "$run_url" ] || [ -n "${extra:-}" ]; then
  refuse_unreadable "the runs query returned an unexpected line: ${run_line}"
fi

if [ "$run_status" != "completed" ]; then
  echo "verify-main-green: REFUSED: the ${WORKFLOW_NAME} push run for ${release_sha} is ${run_status}: ${run_url}" >&2
  echo "Wait for it with: gh run watch ${run_id} --exit-status; then re-run this check." >&2
  exit 3
fi

if [ "$run_conclusion" != "success" ]; then
  echo "verify-main-green: REFUSED: main is red. The ${WORKFLOW_NAME} push run for ${release_sha} concluded ${run_conclusion}: ${run_url}" >&2
  echo "Fix main, or if a leg flaked, rerun it with: gh run rerun ${run_id} --failed; then re-run this check." >&2
  exit 1
fi

echo "verify-main-green: main is green at ${release_sha}: ${run_url}"
exit 0
