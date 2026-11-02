#!/usr/bin/env bash
# shellcheck shell=bash
#
# The --until-green half of pr-wait-merge.sh, which sources it and calls
# until_green_reached once per attempt. It reads the parent's PR and REPO, and
# the base_branch each attempt's view read sets; it owns DECLARED_REQUIRED and
# GREEN_BLOCKER, which the parent initializes, reporting GREEN_BLOCKER on
# TIMEOUT.
#
# Bash 3.2 compatible. Never `cd`.

# shellcheck disable=SC2034,SC2154  # the globals cross files: PR, REPO and base_branch are the parent's, and the parent reads GREEN_BLOCKER

# Run over `gh pr checks --required --json name,bucket` with `$declared` bound
# to the base branch's declared required contexts. It names each declared
# context not yet present and passed, because the registered list alone omits a
# required check whose job has not started: a `needs:` aggregator gets no check
# run until its dependencies finish, so it is absent, not pending.
#
# GAIA-Audit is the one declared context an absence does not hold: GREEN means
# CI is green, and the merge gate decides the audit. The merge hook denies a
# merge that owes a marker, and on an out-of-scope or chore(deps) bypass it
# posts the status itself while `gh pr merge` runs, so waiting for it here
# would never end; the base branch's protection or ruleset still requires the
# status to merge. A
# present GAIA-Audit that is pending holds GREEN, and a failing one ends the
# wait as CHECK_FAILED like any required check.
# shellcheck disable=SC2016
GREEN_JQ='. as $checks | [$declared[] | . as $name | select([$checks[] | select(.name == $name)] | if length == 0 then $name != "GAIA-Audit" else any(.bucket != "pass" and .bucket != "skipping") end)] | if ($declared | length) == 0 then "waiting: no required check is declared" elif length == 0 then "green" else "waiting: " + join(", ") end'
# Each prints one JSON-encoded context name per line, so the names reach the
# green filter as jq literals without this script needing jq of its own.
# shellcheck disable=SC2016
PROTECTION_JQ='.protection.required_status_checks.contexts // [] | .[] | tojson'
# shellcheck disable=SC2016
RULESETS_JQ='.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context | tojson'

# `gh api` takes no --repo; GH_REPO is gh's own override for the `{owner}` and
# `{repo}` placeholders, so the declared set is read from the same repository
# as the pull request.
read_api() {
  if [ -n "$REPO" ]; then
    GH_REPO="$REPO" gh api "$1" --jq "$2" 2>/dev/null
  else
    gh api "$1" --jq "$2" 2>/dev/null
  fi
}

# Sets DECLARED_REQUIRED to a JSON array of the required contexts <base>
# declares, the union of branch protection and rulesets since GitHub enforces
# both, and returns 0. On a failed read it sets GREEN_BLOCKER and returns 1, so
# the caller retries on the next attempt. It never records an unread set as
# `[]`, which the parent would hold for the rest of the bound and report as no
# required check declared. Both endpoints answer
# with read access, unlike the protection endpoint proper, which needs admin.
resolve_declared_required() {
  local base="$1" protection rulesets names name
  if ! protection=$(read_api "repos/{owner}/{repo}/branches/$base" "$PROTECTION_JQ") ||
    ! rulesets=$(read_api "repos/{owner}/{repo}/rules/branches/$base" "$RULESETS_JQ"); then
    GREEN_BLOCKER="the required checks declared for $base (branch protection and rulesets) could not be read"
    return 1
  fi
  names=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    names="${names:+$names,}$name"
  done <<EOF
$protection
$rulesets
EOF
  DECLARED_REQUIRED="[$names]"
  return 0
}

# 0 when every declared required context is present and passed or skipped. A
# missing or pending context, an empty declared set and an unreadable answer
# all keep the wait going, with GREEN_BLOCKER saying which: green has to be
# proved, and a repository with no required check times out here rather than
# reporting a green nothing established. The answer is read even when gh exits
# non-zero, as it does while a check is pending.
required_checks_green() {
  local answer filter="$DECLARED_REQUIRED as \$declared | $GREEN_JQ"
  if [ -n "$REPO" ]; then
    answer=$(gh pr checks "$PR" --repo "$REPO" --required --json name,bucket \
      --jq "$filter" 2>/dev/null)
  else
    answer=$(gh pr checks "$PR" --required --json name,bucket \
      --jq "$filter" 2>/dev/null)
  fi
  case "$answer" in
    green) return 0 ;;
    'waiting: '*) GREEN_BLOCKER="not yet present and passed: ${answer#waiting: }" ;;
    *) GREEN_BLOCKER="the required checks on the head could not be read" ;;
  esac
  return 1
}

# Resolves the declared set on the first attempt that can, then holds it for
# the rest of the bound.
until_green_reached() {
  if [ -z "$DECLARED_REQUIRED" ]; then
    if [ -z "$base_branch" ]; then
      GREEN_BLOCKER="the pull request's base branch could not be read"
      return 1
    fi
    resolve_declared_required "$base_branch" || return 1
  fi
  required_checks_green
}
