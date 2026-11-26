#!/usr/bin/env bash
# The one predicate for "this pull request needs no PR review record because it
# is a GAIA release". Sourced by the merge hook and the GAIA-Audit status
# poster, which both require a complete review record and both exempt a release
# through this function, so they cannot disagree. Defines a function only.
#
# A release pull request bumps version strings, graduates the CHANGELOG and
# rewrites the wiki state, over a tree main already verified; there is no code
# for a reviewer to read. Two checks must both hold, because neither is enough
# alone: the title is a claim any author can type, so a title on a diff that is
# not release bookkeeping still gets the review; and a release-shaped diff
# under another title is not a release the author declared.
#
# Every failure direction is "not waived", which is over-review: an empty
# argument, an unreadable script, a branch that edits the predicate script it
# is judged by, or any non-zero answer from it. The shipped copy never waives,
# because the release scrub strips the maintainer-only definition below and an
# adopter clone has no release pull requests.
#
# Bash 3.2 compatible. Never `cd`.

# shellcheck disable=SC2329 # the shipped copy's one definition; the block below overrides it here
pr_review_release_waived() { return 1; }
# gaia:maintainer-only:start
# pr_review_release_waived <root> <title> <base-commit> <head-commit>: exit 0
# when the pull request is a release whose whole change is bookkeeping,
# non-zero otherwise.
pr_review_release_waived() {
  local root="${1:-}" title="${2:-}" base="${3:-}" head="${4:-}" predicate head_blob
  [ -n "$root" ] && [ -n "$title" ] && [ -n "$base" ] && [ -n "$head" ] || return 1
  [[ "$title" =~ ^chore\(release\):\ v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  predicate="$root/.gaia/scripts/release-bookkeeping-check.sh"
  [ -f "$predicate" ] || return 1
  # The predicate judges the change, so a branch must not be able to loosen
  # it: a committed or working-tree edit to it is not waived. An untracked
  # copy is in no diff and is trusted as is.
  head_blob="$(git -C "$root" rev-parse --verify --quiet "${head}:.gaia/scripts/release-bookkeeping-check.sh" 2>/dev/null)" || head_blob=""
  [ "$head_blob" = "$(git -C "$root" rev-parse --verify --quiet "${base}:.gaia/scripts/release-bookkeeping-check.sh" 2>/dev/null)" ] || return 1
  [ -z "$head_blob" ] || [ "$head_blob" = "$(git -C "$root" hash-object -- "$predicate" 2>/dev/null)" ] || return 1
  bash "$predicate" diff --base "$base" --head "$head" --root "$root" >/dev/null 2>&1
}
# gaia:maintainer-only:end
