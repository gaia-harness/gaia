#!/usr/bin/env bats
#
# Suite for .claude/hooks/lib/pr-review-verdict.sh, the renderers of the PR
# review session report and the PR body's `## PR review` section. Each case
# sources the library and feeds it a record, asserting the printed lines.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-verdict.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/pr-review-verdict.sh"
  HEAD_SHA="1111111111111111111111111111111111111111"
}

# record <findings-json>: a finished review record holding the findings.
record() {
  jq -n -c --arg head "$HEAD_SHA" --argjson findings "$1" \
    '{pr: 7, reviewed_head: $head, spec: "present", outcome: "ran", findings: $findings}'
}

@test "the report tallies dispositions in order and lists each finding not disposed fix, and the section renders each disposition's text" {
  local findings fix_line dismiss_line file_line
  fix_line='{"file":".gaia/scripts/foo.sh","line":12,"severity":"Major","security":false,"summary":"the guard misses an empty argument","disposition":"fix","fix_state":"fixed"}'
  dismiss_line='{"file":".gaia/tests/foo.bats","line":40,"severity":"Minor","security":false,"summary":"the fixture date is stale","disposition":"dismiss","reason":"the fixture date is the test'"'"'s input, not a claim"}'
  file_line='{"file":"wiki/concepts/Foo.md","line":8,"severity":"Minor","security":false,"summary":"the page names a removed flag","disposition":"file","issue":3801}'
  findings="[$fix_line,$dismiss_line,$file_line]"

  run pr_review_render_report "$(record "$findings")"
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "PR review: 3 findings: 1 fix, 1 dismiss, 1 file" ] || return 1
  [ "${#lines[@]}" -eq 3 ] || return 1
  [ "${lines[1]}" = "- Minor .gaia/tests/foo.bats:40 the fixture date is stale -> dismiss: the fixture date is the test's input, not a claim" ] || return 1
  [ "${lines[2]}" = "- Minor wiki/concepts/Foo.md:8 the page names a removed flag -> file: #3801" ] || return 1

  run pr_review_render_section "$(record "$findings")"
  [ "$status" -eq 0 ] || return 1
  # bats drops the section's blank line from `lines`.
  [ "${#lines[@]}" -eq 7 ] || return 1
  [ "${lines[2]}" = "Reviewed head: $HEAD_SHA" ] || return 1
  [ "${lines[3]}" = "- Major .gaia/scripts/foo.sh:12 the guard misses an empty argument -> fixed" ] || return 1
  [ "${lines[4]}" = "- Minor .gaia/tests/foo.bats:40 the fixture date is stale -> dismiss: the fixture date is the test's input, not a claim" ] || return 1
  [ "${lines[5]}" = "- Minor wiki/concepts/Foo.md:8 the page names a removed flag -> file: #3801" ] || return 1

  run pr_review_render_report "$(record "[$dismiss_line]")"
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "PR review: 1 finding: 1 dismiss" ] || return 1
  [ "${#lines[@]}" -eq 2 ] || return 1

  run pr_review_render_report "$(record '[]')"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "PR review: no findings" ] || return 1
}
