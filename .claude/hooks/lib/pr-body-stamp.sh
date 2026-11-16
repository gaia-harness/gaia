#!/usr/bin/env bash
# The PR body's head stamp: one hidden line naming the head commit the body's
# summary was last checked against. Sourced, never executed; does no work at
# source time.
#
#   pr_body_stamp_verdict <body> <head-sha>   exit 0 when current; else 1 and
#                                             one reason line on stdout
#   pr_body_restamp <body> <head-sha>         the body with every stamp line
#                                             removed and one current stamp
#                                             appended, on stdout
#
# The stamp proves the re-verify step was reached for this head, not that the
# reading was done well: a stamp moved with no body change passes by design,
# since a re-read can find nothing false.
#
# Any line opening with the stamp comment counts as a stamp, so a malformed or
# second stamp fails the verdict rather than hiding behind a valid one; prose
# that only mentions the key does not count. GitHub stores
# a body edited in its web form with CRLF endings, so carriage returns are
# dropped before matching.

pr_body_stamp_pattern='^[[:space:]]*<!--[[:space:]]*gaia-pr-body-head:'

pr_body_stamp_line() {
  printf '<!-- gaia-pr-body-head: %s -->' "$1"
}

pr_body_stamp_verdict() {
  local body="$1" head_sha="$2" stamp_lines stamp_count
  stamp_lines="$(printf '%s\n' "$body" | tr -d '\r' | grep -E -- "$pr_body_stamp_pattern" || true)"
  if [ -z "$stamp_lines" ]; then
    printf 'the PR body carries no head stamp\n'
    return 1
  fi
  stamp_count="$(printf '%s\n' "$stamp_lines" | wc -l | tr -d ' ')"
  if [ "$stamp_count" -ne 1 ]; then
    printf 'the PR body carries %s head stamps, not one\n' "$stamp_count"
    return 1
  fi
  if [ "$stamp_lines" != "$(pr_body_stamp_line "$head_sha")" ]; then
    printf 'the PR body stamp is not for head %s: %s\n' "${head_sha:0:12}" "$stamp_lines"
    return 1
  fi
  return 0
}

pr_body_restamp() {
  local body="$1" head_sha="$2" kept
  kept="$(printf '%s\n' "$body" | grep -vE -- "$pr_body_stamp_pattern" || true)"
  printf '%s\n\n%s\n' "$kept" "$(pr_body_stamp_line "$head_sha")"
}
