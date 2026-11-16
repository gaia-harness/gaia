#!/usr/bin/env bash
# Writes or checks the PR body's head stamp (.claude/hooks/lib/pr-body-stamp.sh).
#
#   pr-body-stamp.sh write [--pr <n>]   stamp the body with the PR's head
#   pr-body-stamp.sh check [--pr <n>]   exit 0 when the stamp names the head
#
# Without --pr, gh resolves the pull request of the current branch. The head is
# the one GitHub reports, so push before writing: a stamp written before the
# push names the old head and is stale once the push lands.
#
# `write` replaces every stamp line and appends one current stamp, leaving the
# rest of the body as it was; a body already current is left untouched. The
# summary re-read the stamp attests to is the caller's job, done before this
# runs.
#
# Exit codes: 0 written or current; 1 check found the stamp stale (one reason
# line on stdout); 2 usage; 3 gh could not read or edit the pull request.
#
# Bash 3.2 compatible.
set -u

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.claude/hooks/lib/pr-body-stamp.sh
. "$script_directory/../../.claude/hooks/lib/pr-body-stamp.sh" || {
  printf 'pr-body-stamp.sh: cannot load the stamp library .claude/hooks/lib/pr-body-stamp.sh\n' >&2
  exit 2
}

usage() {
  printf 'usage: pr-body-stamp.sh write|check [--pr <n>]\n' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
action="$1"
shift
case "$action" in
  write | check) ;;
  *) usage ;;
esac

pr_number=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || usage
      pr_number="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
case "$pr_number" in
  *[!0-9]*) usage ;;
esac

# shellcheck disable=SC2086 # an empty $pr_number must vanish, not pass ""
pr_record="$(gh pr view $pr_number --json number,body,headRefOid 2>/dev/null)" || pr_record=""
head_sha="$(printf '%s' "$pr_record" | jq -r '.headRefOid // ""' 2>/dev/null || true)"
resolved_number="$(printf '%s' "$pr_record" | jq -r '.number // ""' 2>/dev/null || true)"
if [ -z "$head_sha" ] || [ -z "$resolved_number" ]; then
  printf 'pr-body-stamp: cannot read the pull request%s; next step: gh auth status\n' "${pr_number:+ #$pr_number}" >&2
  exit 3
fi
body="$(printf '%s' "$pr_record" | jq -r '.body // ""')"

if [ "$action" = check ]; then
  pr_body_stamp_verdict "$body" "$head_sha" || exit 1
  printf 'stamp: current %s\n' "${head_sha:0:12}"
  exit 0
fi

if pr_body_stamp_verdict "$body" "$head_sha" >/dev/null; then
  printf 'stamp: current %s\n' "${head_sha:0:12}"
  exit 0
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
pr_body_restamp "$body" "$head_sha" > "$body_file"
if ! gh pr edit "$resolved_number" --body-file "$body_file" >/dev/null; then
  printf 'pr-body-stamp: gh pr edit %s failed; the body is unchanged\n' "$resolved_number" >&2
  exit 3
fi
printf 'stamp: written %s\n' "${head_sha:0:12}"
