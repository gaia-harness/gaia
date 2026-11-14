#!/usr/bin/env bats
#
# Doc-conformance suite for the Test What Matters principle: the confirmed
# coding-guidelines section 3, no shipped TDD-as-rule wording, an opt-in /tdd
# that verifies its own red step with no hook or ledger, a Playwright rule that
# points at the Test Layering browser rung, and test-after pipeline claims.
#
# Every check is a function taking the file it reads, so each red twin runs the
# same function against a mutated copy and proves it can fail. A twin first
# asserts the check passes on the real file, so it cannot pass vacuously.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned phrases carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUIDELINES="$REPO_ROOT/.claude/rules/coding-guidelines.md"
  TDD_SKILL="$REPO_ROOT/.claude/skills/tdd/SKILL.md"
  STEP="$REPO_ROOT/.claude/skills/gaia/references/worthiness-step.md"
  PW_RULE="$REPO_ROOT/apps/web/.claude/rules/playwright.md"
  README="$REPO_ROOT/README.md"
  DEBT="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
}

# ---------- helpers ----------

# copy_with <source> <name> <sed expression>: a mutated copy that must differ.
copy_with() {
  local copy="$BATS_TEST_TMPDIR/$2"
  sed "$3" "$1" >"$copy"
  cmp -s "$1" "$copy" && { echo "mutation changed nothing" >&2; return 1; }
  printf '%s' "$copy"
}

# section_three <file>: from the "## 3." heading to the line before "## 4.".
section_three() {
  awk '/^## 3\./{on=1} /^## 4\./{on=0} on' "$1"
}

# check_section_three <file>: section 3 equals the confirmed block.
check_section_three() {
  local expected actual
  expected=$(cat <<'BLOCK'
## 3. Test What Matters

Write tests, not too many, mostly integration (the testing trophy). Which test to write and at which layer: `.claude/doctrine/testing.md`. Test-first with `/tdd` is a tool for logic where it helps, not a rule.

- The frontend stack (Vitest, Storybook, Playwright) is in `apps/web/CLAUDE.md` (`## Tests and prerequisites`) and the `tdd-react` skill
BLOCK
)
  actual=$(section_three "$1")
  [ -n "$actual" ] || return 1
  [ "$actual" = "$expected" ]
}

# states_tdd_as_rule <file>: succeeds when the file states TDD as a rule.
states_tdd_as_rule() {
  grep -qE 'Always Use Test Driven Development|Always Use TDD|^#+ .*Test Driven Development' "$1"
}

# check_tdd_skill_clean <file>: no hook, ledger or rendered-spec wording.
check_tdd_skill_clean() {
  local needle
  for needle in 'RED ledger' 'red-verify' 'RED gate' 'RED-gated' 'rendered UAT' 'gaia-uat-contract'; do
    grep -qF -- "$needle" "$1" && { echo "banned: $needle" >&2; return 1; }
  done
  return 0
}

# check_tdd_red_step <file>: the skill names running the new test and seeing it fail first.
check_tdd_red_step() {
  grep -qF -- 'pnpm -C <package dir> test --run <test-file>' "$1" || return 1
  grep -qF -- 'for the right reason' "$1" || return 1
  grep -qE 'before implementing' "$1"
}

# arm_text <file>: the tdd arm section of the step page, else the whole file.
arm_text() {
  case "$1" in
    *worthiness-step.md) awk '/^## The tdd arm/{on=1;next} /^## /{on=0} on' "$1" ;;
    *) cat "$1" ;;
  esac
}

# check_arm_job <file>: states the arm dispatches the evaluator and records
# verdicts, and never says it replaces the RED gate.
check_arm_job() {
  local text
  text=$(arm_text "$1")
  [ -n "$text" ] || return 1
  printf '%s\n' "$text" | grep -qE 'dispatch' || return 1
  printf '%s\n' "$text" | grep -qE 'records?' || return 1
  printf '%s\n' "$text" | grep -iE 'RED gate' | grep -qiE 'replac|stand(s)? in|place of' && return 1
  return 0
}

# check_audit_routing <file>: the emergent/route/strict audit phrase.
check_audit_routing() {
  grep -qF -- 'emergent, route and strict tests on honesty and worth' "$1" || return 1
  grep -qF -- 'strict tests on worth only' "$1" && return 1
  return 0
}

# check_playwright_pointer <file>
check_playwright_pointer() {
  grep -qF -- '.claude/doctrine/testing.md' "$1" || return 1
  grep -qwE 'UATs?' "$1" && return 1
  grep -qF -- 'planner.md' "$1" && return 1
  return 0
}

# check_readme <file>: test-after pipeline claims.
check_readme() {
  grep -qwE 'UATs?' "$1" && return 1
  grep -qF -- 'red-state' "$1" && return 1
  return 0
}

# check_debt <file>
check_debt() {
  grep -qF -- '(Test What Matters, surgical changes)' "$1" || return 1
  grep -qF -- '(TDD,' "$1" && return 1
  return 0
}

# ---------- section 3 ----------

@test "coding-guidelines section 3 is the confirmed Test What Matters block, byte for byte" {
  check_section_three "$GUIDELINES"
}

@test "red twin: a section 3 with one word changed fails the verbatim comparison" {
  local copy
  check_section_three "$GUIDELINES" || return 1
  copy=$(copy_with "$GUIDELINES" guidelines-mutated.md 's/mostly integration/mostly unit/') || return 1
  check_section_three "$copy" && return 1
  true
}

# ---------- no TDD-as-rule wording ----------

# bats test_tags=whole-tree
@test "no shipped rule, skill or README states TDD as a rule" {
  local files count file
  files=$(cd "$REPO_ROOT" && {
    find .claude/rules apps/web/.claude/rules .claude/skills apps/web/.claude/skills -type f -name '*.md'
    printf '%s\n' README.md
  } | sort)
  count=$(printf '%s\n' "$files" | grep -c .)
  [ "$count" -gt 1 ] || return 1
  while IFS= read -r file; do
    states_tdd_as_rule "$REPO_ROOT/$file" && { echo "TDD-as-rule wording in $file" >&2; return 1; }
  done <<<"$files"
  true
}

@test "red twin: a file restoring the TDD-as-rule wording is caught" {
  local copy
  copy=$(copy_with "$README" readme-tdd.md '1s/^/## Always Use TDD /') || return 1
  states_tdd_as_rule "$copy"
}

# ---------- /tdd skill ----------

@test "tdd skill names running the new test and seeing it fail for the right reason before implementing" {
  check_tdd_red_step "$TDD_SKILL"
}

@test "tdd skill carries no RED ledger, hook, gate or rendered spec wording" {
  check_tdd_skill_clean "$TDD_SKILL"
}

@test "red twin: a tdd skill restoring the RED gate wording fails the clean check" {
  local copy
  check_tdd_skill_clean "$TDD_SKILL" || return 1
  copy=$(copy_with "$TDD_SKILL" tdd-red-gate.md '1s/$/ RED gate/') || return 1
  check_tdd_skill_clean "$copy" && return 1
  true
}

@test "tdd skill states the arm dispatches and records and never replaces the RED gate" {
  check_arm_job "$TDD_SKILL"
}

@test "worthiness step tdd arm states it dispatches and records and never replaces the RED gate" {
  check_arm_job "$STEP"
}

@test "red twin: an arm that takes the place of the RED gate fails" {
  local copy
  check_arm_job "$STEP" || return 1
  copy=$(copy_with "$STEP" step-replaces.md 's/dispatches and records/stands in for the RED gate, dispatches and records/') || return 1
  check_arm_job "$copy" && return 1
  true
}

@test "tdd skill audit paragraph routes emergent, route and strict tests on honesty and worth" {
  check_audit_routing "$TDD_SKILL"
}

@test "red twin: the old strict-on-worth-only routing fails" {
  local copy
  check_audit_routing "$TDD_SKILL" || return 1
  copy=$(copy_with "$TDD_SKILL" tdd-routing.md 's/emergent, route and strict tests on honesty and worth/emergent and route tests on honesty and worth, strict tests on worth only/') || return 1
  check_audit_routing "$copy" && return 1
  true
}

# ---------- Playwright rule ----------

@test "playwright rule points at the testing doctrine and carries no UAT or planner pointer" {
  check_playwright_pointer "$PW_RULE"
}

@test "red twin: a playwright rule without the doctrine pointer fails" {
  local copy
  check_playwright_pointer "$PW_RULE" || return 1
  copy=$(copy_with "$PW_RULE" pw-nopointer.md 's/\.claude\/doctrine\/testing\.md/gone/g') || return 1
  check_playwright_pointer "$copy" && return 1
  true
}

# ---------- README and debt reference ----------

@test "README carries no UAT word and no red-state claim" {
  check_readme "$README"
}

@test "red twin: a README restoring red-state fails" {
  local copy
  check_readme "$README" || return 1
  copy=$(copy_with "$README" readme-redstate.md '1s/$/ red-state/') || return 1
  check_readme "$copy" && return 1
  true
}

@test "debt reference names Test What Matters in its conventions list and no TDD" {
  check_debt "$DEBT"
}

@test "red twin: a debt reference restoring TDD fails" {
  local copy
  check_debt "$DEBT" || return 1
  copy=$(copy_with "$DEBT" debt-tdd.md 's/(Test What Matters, surgical changes)/(TDD, surgical changes)/') || return 1
  check_debt "$copy" && return 1
  true
}
