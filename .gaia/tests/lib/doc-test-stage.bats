#!/usr/bin/env bats
#
# Doc-conformance suite for the test stage reference and its command.
#
# .claude/skills/gaia/references/test-stage.md owns the stage: the record
# written before any test line, the Test lines, the closing flow-test phase,
# the cap, the checks, the review lens and the usage run.
# .claude/commands/gaia-test.md routes to it.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STAGE_MD="$REPO_ROOT/.claude/skills/gaia/references/test-stage.md"
  COMMAND_MD="$REPO_ROOT/.claude/commands/gaia-test.md"
}

# has <file> <literal>: the file holds the literal.
has() {
  grep -qF -- "$2" "$1"
}

# line_of <file> <literal>: the number of the first line holding the literal.
line_of() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

@test "test stage lists tests per task and checks them before recording" {
  has "$STAGE_MD" '`status: running`' || return 1
  has "$STAGE_MD" '- Test (<behavior id>, <layer>, <security kind>): <repo-relative file> › <title>' || return 1
  has "$STAGE_MD" '- Flow test (<flow_id>): <repo-relative test path>' || return 1
  has "$STAGE_MD" '`## Tests`' || return 1
  has "$STAGE_MD" '- Security writer: <k> tests' || return 1
  has "$STAGE_MD" 'node .gaia/scripts/spec/test-stage-check.mjs --plan-dir' || return 1
  has "$STAGE_MD" 'bash .gaia/scripts/spec/plan-verify.sh' || return 1
  has "$STAGE_MD" 'A stage that halts leaves `running`' || return 1

  local running_line first_test_line checks_line ran_line
  running_line="$(line_of "$STAGE_MD" '## Record first')"
  first_test_line="$(line_of "$STAGE_MD" '## Output')"
  checks_line="$(line_of "$STAGE_MD" '## Checks')"
  ran_line="$(line_of "$STAGE_MD" 'Only after both checks pass, write `TEST-STAGE` with `status: ran`')"
  [ "$running_line" -lt "$first_test_line" ]
  [ "$first_test_line" -lt "$checks_line" ]
  [ "$checks_line" -lt "$ran_line" ]
}

@test "test stage records its own usage run" {
  has "$STAGE_MD" 'usage.sh record spec:<SPEC-NNN> --workflow gaia-test' || return 1
  has "$STAGE_MD" 'usage.sh record plan:<PLAN-NNN> --workflow gaia-test' || return 1
  has "$STAGE_MD" 'separate from the `gaia-plan` run' || return 1
  has "$STAGE_MD" 'Never block the stage on its failure' || return 1
}

@test "the review pass confirms each listed test proves a stated behavior" {
  has "$STAGE_MD" '.claude/skills/gaia/references/spec/lens-dispatch.md' || return 1
  has "$STAGE_MD" "test-stage column" || return 1
  has "$STAGE_MD" 'confirms every listed test proves a behavior the SPEC states' || return 1
  has "$STAGE_MD" 'At most one test per stated behavior, at the cheapest layer that proves it' || return 1
  has "$STAGE_MD" 'Flow tests sit outside the cap and every SPEC flow gets one' || return 1
}

@test "the gaia-test command routes to the test stage and runs on a saved plan" {
  has "$COMMAND_MD" 'name: gaia-test' || return 1
  has "$COMMAND_MD" 'argument-hint: "[auto] [SPEC-NNN | plan dir]"' || return 1
  has "$COMMAND_MD" '.claude/skills/gaia/references/test-stage.md' || return 1
  has "$COMMAND_MD" 'saved by `/gaia-plan`' || return 1
  has "$STAGE_MD" 'run it alone on a saved plan' || has "$STAGE_MD" 'runs it alone on a saved plan' || return 1
}
