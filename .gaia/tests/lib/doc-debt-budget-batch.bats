#!/usr/bin/env bats
#
# Doc-conformance suite for the budget batch in /gaia-debt's playbook
# (.claude/skills/gaia/references/debt.md and debt/recommend.md): the
# fail-closed arms of the offer's security read, the degrade-to-plain-offer
# arms, and the revert and claim release of a dropped member.
#
# Each row names one clause and is scoped to the section that owns it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFS="$REPO_ROOT/.claude/skills/gaia/references"
  OFFER_HEADING='## Recommend and present'
}

# extract_section <file> <heading-line-prefix>: the first matching section's
# body, heading included, up to the next heading of the same or shallower
# level. Prints nothing when no heading matches.
extract_section() {
  awk -v want="$2" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "$1"
}

# section_has <file> <heading> <marker> <needle>: the section is
# non-empty and, among its lines containing the marker (all lines when the
# marker is empty), one contains the needle.
section_has() {
  local section lines
  section="$(extract_section "$REFS/$1" "$2")"
  [ -n "$section" ] || return 1
  if [ -n "$3" ]; then
    lines="$(grep -F -- "$3" <<<"$section")" || return 1
  else
    lines="$section"
  fi
  grep -qF -- "$4" <<<"$lines"
}

# check_row <case name> <file> <heading> <marker> <needle>: runs the check and
# names the case that failed.
check_row() {
  local case_name="$1"
  shift
  section_has "$@" || {
    printf 'failed case: %s\n' "$case_name" >&2
    return 1
  }
}

@test "the budget batch's security read fails closed and every member passes the fix-time screen" {
  check_row "an empty list without classifying is the confirmed-PRIVATE arm only" debt/recommend.md "$OFFER_HEADING" 'Confirmed PRIVATE' 'pass an empty list, with no classification'
  check_row "a completed classification that finds nothing passes an empty list and the option still shows" debt/recommend.md "$OFFER_HEADING" 'classification complete on every candidate' 'The list may be empty, and the budget option still shows'
  check_row "PUBLIC counts as non-PRIVATE" debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'PUBLIC'
  check_row "INTERNAL counts as non-PRIVATE" debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'INTERNAL'
  check_row "a failed visibility read counts as non-PRIVATE" debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'a failed visibility read'
  check_row "a failed or absent classification withholds the option and makes no call" debt/recommend.md "$OFFER_HEADING" 'classification failed or absent' 'make no offer-mode call and show no budget option'
  check_row "every budget batch member passes the fix-time security screen" debt.md '## Fix-time security screen' 'This member-level screen is the' 'Every budget batch member passes this screen too'
}

@test "a failed probe or run degrades to the plain offer" {
  check_row "a failed probe runs offer mode without the probe report" debt/recommend.md "$OFFER_HEADING" 'A failed probe' 'run offer mode without `--probe-report`'
  check_row "a failed probe is covered by the fix-time staleness screen" debt/recommend.md "$OFFER_HEADING" 'A failed probe' 'the fix-time staleness screen re-checks the selected part'
  check_row "a failed run costs one reported line" debt/recommend.md "$OFFER_HEADING" 'A failed run' 'report one line saying the budget option could not be computed'
  check_row "a failed run presents the offer without the option" debt/recommend.md "$OFFER_HEADING" 'A failed run' 'present the offer without it'
  check_row "a failed run does not stop the run" debt/recommend.md "$OFFER_HEADING" 'A failed run' 'The run does not stop'
}

@test "a dropped budget batch member is reverted and the claim released" {
  check_row "a revert comes first on a budget batch" debt.md '### Dropping a member after its commits are written' 'Three corrections' 'a revert comes first, ahead of them'
  check_row "a dropped singleton's commit is reverted" debt.md '### Dropping a member after its commits are written' "A dropped singleton's commit" "A dropped singleton's commit is reverted"
  check_row "a dropped cluster member's cluster commit is reverted with its siblings dropped alongside" debt.md '### Dropping a member after its commits are written' "A dropped singleton's commit" "the cluster's siblings are dropped alongside it, since they share that commit"
  check_row "each dropped cluster member takes the three corrections" debt.md '### Dropping a member after its commits are written' "A dropped singleton's commit" 'each dropped member takes the three corrections below'
  check_row "parts that touch one file revert together and drop alongside" debt.md '### Dropping a member after its commits are written' "A dropped singleton's commit" 'so they revert together and every member of that commit is dropped alongside'
  check_row "a revert that conflicts is resolved by hand" debt.md '### Dropping a member after its commits are written' 'A part'"'"'s commit normally reverts alone' 'the revert can conflict; resolve it by hand'
  check_row "a revert uses a Conventional Commits revert subject naming what was dropped" debt.md '### Dropping a member after its commits are written' "The revert's subject" '`revert:` subject that names what was dropped'
  check_row "a member found security-class after its commit needs a history rewrite with a count-only pointer" debt.md '### Dropping a member after its commits are written' 'found security-class after its commit' 'requires a history rewrite that removes the commit from the branch, force-pushed, and leaves a count-only pointer'
  check_row "every part dropped strips every claim and closes the draft pull request unmerged" debt.md '### Dropping a member after its commits are written' '**Every part dropped.**' 'strip every member'"'"'s claim (correction 1 below), close an open draft pull request unmerged, report it'
  check_row "every part dropped ends the run through the cost record" debt.md '### Dropping a member after its commits are written' '**Every part dropped.**' 'end the run through `## Cost record (run end)`, passing `--pr` only when one was opened'
  check_row "every part dropped follows the unmerged-ending release" debt.md '### Dropping a member after its commits are written' '**Every part dropped.**' '`## Releasing the claim on an unmerged ending`'
}
