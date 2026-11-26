#!/usr/bin/env bats
#
# Doc-conformance suite for the PR review procedure reference.
#
# .claude/skills/gaia/references/pr-review.md owns the main thread's PR review
# procedure. This suite pins two of its rules a script cannot enforce:
#
#   - the required checks are read once before the dispatch: a failing one is
#     handled first, a pending one does not hold the dispatch;
#   - a finding that repeats one the audit disposed is new only with evidence
#     that disposition did not weigh, else it is dismissed as already disposed.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REF="$REPO_ROOT/.claude/skills/gaia/references/pr-review.md"
}

# section_text <file> <heading prefix>: the heading line and its body, up to
# the next heading of the same or a higher level.
section_text() {
  awk -v h="$2" '
    function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !on && index($0, h) == 1 { on = 1; start = level($0); print; next }
    on && /^#+ / && level($0) <= start { exit }
    on { print }' "$1"
}

# line_of <file> <fixed string>: the first line number holding the string.
line_of() {
  grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1
}

@test "the PR review reference reads the required checks once and dispatches without waiting on a pending one" {
  local checks reads checks_line dispatch_line
  checks="$(section_text "$REF" '## 2. Read the required checks once')"
  [ -n "$checks" ] || return 1
  grep -qF -- 'gh pr checks <N> --required' <<<"$checks" || return 1
  # Read once: the reference runs the required-checks read in one place only.
  reads="$(grep -cF -- 'gh pr checks <N> --required' "$REF")"
  [ "$reads" -eq 1 ] || return 1
  # Case: a failing required check is handled before the dispatch.
  grep -qF -- 'A failing required check is handled first' <<<"$checks" || return 1
  # Case: a pending check does not hold the dispatch.
  grep -qF -- 'A pending check does not hold the review: dispatch without waiting for it.' <<<"$checks" || return 1
  # The read comes before the reviewer dispatch.
  checks_line="$(line_of "$REF" 'gh pr checks <N> --required')"
  dispatch_line="$(line_of "$REF" 'subagent_type: "pr-reviewer"')"
  [ -n "$checks_line" ] && [ -n "$dispatch_line" ] || return 1
  [ "$checks_line" -lt "$dispatch_line" ]
}

@test "the PR review reference disposes a re-raised audit finding as audit already disposed this unless new evidence" {
  local dispositions bullet
  dispositions="$(section_text "$REF" '## 5. Dispose every finding')"
  [ -n "$dispositions" ] || return 1
  bullet="$(grep -F -- 'repeats one the audit already disposed' <<<"$dispositions")" || return 1
  # Case: a re-raise with no new evidence is dismissed with the audit's reason.
  grep -qF -- 'Without such evidence it takes `dismiss` with the reason `audit already disposed this: <the audit'"'"'s reason>`' <<<"$bullet" || return 1
  # Case: a re-raise with evidence the audit did not weigh is a new finding, fix by default.
  grep -qF -- 'is new only when it carries evidence that disposition did not weigh' <<<"$bullet" || return 1
  grep -qF -- 'disposed like any new finding, `fix` by default' <<<"$bullet"
}
