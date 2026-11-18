#!/usr/bin/env bats
#
# Doc-conformance suite: the plan review runs three lenses with no refuter and
# skips a trivial plan, the planner is one top-model agent, the test stage is
# offered after the review and its skip says it also skips the security tests,
# the plan closes its own run before the stage opens, the lenses check flows
# and the start-crash scenario, and localized fixes pass the drop check.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016 # fixed-string greps for literal backticks
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  AUDIT="$REPO_ROOT/.claude/skills/gaia/references/plan/decomposition-audit.md"
}

# Print a "### <heading prefix>" section of a file, flattened to one line.
h3_text() {
  awk -v h="$2" '
    /^#{1,3} / { on = (index($0, "### " h) == 1) ; next }
    on { print }
  ' "$1" | tr '\n' ' ' | tr -s ' '
}

@test "plan review runs three lenses with no refuter and skips a trivial plan" {
  local review text
  review="$(h3_text "$PLAN" "4.6.")"
  text="$(tr '\n' ' ' <"$AUDIT" | tr -s ' ')"
  grep -qF 'A trivial plan (one or two tasks, a single phase, no cross-task interface contract) skips the review' <<<"$review" || return 1
  grep -qF 'all in one turn' <<<"$text" || return 1
  grep -qF '(`DP.json`, `CG.json`, `COV.json`)' <<<"$text" || return 1
  grep -qF 'three checks that exist only at plan stage, and no refutation pass' <<<"$text" || return 1
  grep -qiE 'refuter|\(id prefix `TD`' "$AUDIT" && return 1
  true
}

@test "plan spawns one top-model planner" {
  local text
  text="$(tr '\n' ' ' <"$PLAN" | tr -s ' ')"
  grep -qF 'launch one `general-purpose` planner Agent, pinned to the step-2 top-tier model' <<<"$text" || return 1
  grep -qF 'Opus and Fable are both top-tier planning models' <<<"$text" || return 1
  true
}

@test "plan offers the test stage after its review and auto runs it" {
  local review offer text
  review="$(grep -n '^### 4.6. ' "$PLAN" | cut -d: -f1)"
  offer="$(grep -n '^### 5. Offer the test stage' "$PLAN" | cut -d: -f1)"
  [ -n "$review" ] && [ -n "$offer" ] && [ "$review" -lt "$offer" ] || return 1
  text="$(h3_text "$PLAN" "5.")"
  grep -qF 'Run the test stage (Recommended)' <<<"$text" || return 1
  grep -qF 'With `auto_mode` true' <<<"$text" || return 1
  grep -qF 'take Run with no question' <<<"$text" || return 1
  grep -qF 'a spec-less plan is offered it too' <<<"$text" || return 1
  grep -qF 'invoke the `gaia-test` skill' <<<"$text" || return 1
  grep -qF 'status: skipped' <<<"$text" || return 1
  grep -qF 'never continue to step 6 with the stage neither run nor its skip written' <<<"$text" || return 1
  true
}

@test "skip says it also skips the security tests" {
  local offer report
  offer="$(h3_text "$PLAN" "5.")"
  report="$(h3_text "$PLAN" "6.")"
  grep -qF 'The rule-written security tests are skipped with it' <<<"$offer" || return 1
  grep -qF 'say so and that the security tests were skipped with it' <<<"$report" || return 1
  true
}

@test "plan closes its own run before the test stage opens" {
  local record offer
  record="$(grep -n '^### 4.7. ' "$PLAN" | cut -d: -f1)"
  offer="$(grep -n '^### 5. Offer the test stage' "$PLAN" | cut -d: -f1)"
  [ -n "$record" ] && [ -n "$offer" ] && [ "$record" -lt "$offer" ] || return 1
  grep -qF -- '--workflow gaia-plan' "$PLAN" || return 1
  grep -qF 'The `gaia-plan` run is closed (step 4.7), so the test stage opens its own run' "$PLAN" || return 1
  true
}

@test "coverage lens reads flows and the plan lenses check the start-crash scenario" {
  local dp cg cov
  dp="$(grep -F -- '- **Decomposition & dependency soundness' "$AUDIT")"
  cg="$(grep -F -- '- **Contract grounding' "$AUDIT")"
  cov="$(grep -F -- '- **SPEC coverage' "$AUDIT")"
  [ -n "$dp" ] && [ -n "$cg" ] && [ -n "$cov" ] || return 1
  grep -qF 'start-crash scenario' <<<"$dp" || return 1
  grep -qF 'an env default the production start never sets' <<<"$dp" || return 1
  grep -qF 'start-crash scenario' <<<"$cg" || return 1
  grep -qF 'SPEC flows, `success_criteria`, `scope_boundaries` and answered clarifications' <<<"$cov" || return 1
  grep -qF 'REQUIREMENTS.md' <<<"$cov" || return 1
  grep -qF 'UAT' "$AUDIT" && return 1
  true
}

@test "localized plan fixes pass the drop-destination check" {
  local text
  text="$(tr '\n' ' ' <"$AUDIT" | tr -s ' ')"
  grep -qF 'save a pre-fix copy of `README.md` and every `task-*.md`' <<<"$text" || return 1
  grep -qF 'after any re-spawn' <<<"$text" || return 1
  grep -qF 'drop-check.mjs --mode plan' <<<"$text" || return 1
  grep -qF -- '--pre <pre-fix copy>' <<<"$text" || return 1
  grep -qF 'with route `plan` and no `edits` or `drops`' <<<"$text" || return 1
  grep -qF 'a second refusal records the dropped cases in the README' <<<"$text" || return 1
  grep -qF 'Log every applied fix in the README' <<<"$text" || return 1
  true
}
