#!/usr/bin/env bats
#
# Doc-conformance suite for the rendered orchestrator: the planner reference
# tells the planner to write the parts file and run the renderer (and never to
# read the template), and the test stage writes its closing phase and security
# writer line into the parts file and re-renders, so the renderer stays the one
# writer of the orchestrator and kickoff files.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016 # the pinned literals carry backticks as literal Markdown

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_MD="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  STAGE_MD="$REPO_ROOT/.claude/skills/gaia/references/test-stage.md"
  RENDERER="$REPO_ROOT/.gaia/scripts/spec/orchestrator-render.sh"
}

# has <file> <literal>: the file holds the literal.
has() {
  grep -qF -- "$2" "$1"
}

@test "planner.md names the render command and the six parts and holds no template path, no sentinel fence and no instruction to read the template" {
  local heading
  has "$PLANNER_MD" 'bash .gaia/scripts/spec/orchestrator-render.sh <PLAN_DIR> --parts <PLAN_DIR>/orchestrator-parts.md --audit <AUDIT_PATH or unset> --branch <BRANCH_ID> [--spec <SPEC_PATH>]' || return 1
  for heading in '## Title' '## Pushes' '## Phase loop' '## Phase entries' '## Kickoff goal' '## Kickoff outline'; do
    has "$PLANNER_MD" "\`$heading\`" || { echo "planner.md does not name $heading" >&2; return 1; }
  done
  has "$PLANNER_MD" 'overwriting any hand-typed `ORCHESTRATOR.md` and `KICKOFF.md`' || return 1
  grep -q 'gaia:orchestrator-step' "$PLANNER_MD" && return 1
  grep -q 'orchestrator-template' "$PLANNER_MD" && return 1
  grep -qE '^[[:space:]]*```' "$PLANNER_MD" && return 1
  true
}

@test "test-stage.md writes its closing entry and security writer line into orchestrator-parts.md, replaces the previous entry on a re-run, re-runs the renderer and never edits ORCHESTRATOR.md or KICKOFF.md, and a re-render keeps the closing entry" {
  local plan="$BATS_TEST_TMPDIR/plan"
  mkdir -p "$plan"

  has "$STAGE_MD" "\`## Phase entries\` entry in \`<PLAN_DIR>/orchestrator-parts.md\`" || return 1
  has "$STAGE_MD" '`## Kickoff outline`' || return 1
  has "$STAGE_MD" 'each `- Security writer:` line' || return 1
  has "$STAGE_MD" 'the closing phase entry' || return 1
  has "$STAGE_MD" 're-run the renderer' || return 1
  has "$STAGE_MD" 'never edits `ORCHESTRATOR.md` or `KICKOFF.md`' || return 1
  has "$STAGE_MD" 'halt with one line' || return 1
  [ -z "$(grep -iE '(edit|write)s? .*(ORCHESTRATOR|KICKOFF)\.md' "$STAGE_MD" | grep -vi 'never' || true)" ] || return 1

  cat >"$plan/orchestrator-parts.md" <<'PARTS'
## Title
Demo plan
Type: feat
Slug: demo plan

## Phase loop
Dispatch each phase's tasks in parallel, run the gate, commit, push.

## Phase entries
**Phase 1, Build**
- Tasks: task-a

**Phase 2, Closing flow tests**
- Tasks: task-flow

## Kickoff goal
Build the demo.

## Kickoff outline
- Phase 1, Build
- Phase 2, Closing flow tests
PARTS
  bash "$RENDERER" "$plan" --parts "$plan/orchestrator-parts.md" --audit unset --branch demo-plan || return 1
  bash "$RENDERER" "$plan" --parts "$plan/orchestrator-parts.md" --audit unset --branch demo-plan || return 1
  has "$plan/ORCHESTRATOR.md" '**Phase 2, Closing flow tests**' || return 1
  has "$plan/KICKOFF.md" 'The plan has 2 phases' || return 1
}
