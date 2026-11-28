#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh cross-phase check: a file only a later
# phase declares must not catch a file an earlier phase declares, since the
# earlier phase's gate retry re-dispatches only its own declaring tasks. Each
# case runs the script copied into a git fixture tree, so the files a task
# declares exist (or not) and are tracked exactly as the case needs.
#
# Assertion style follows .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016 # fixture text carries literal backticks and $ROOT
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TREE="$BATS_TEST_TMPDIR/tree"
  PLAN="$BATS_TEST_TMPDIR/plan"
  mkdir -p "$TREE/.gaia/scripts" "$PLAN"
  # The copied scripts include plan-verify-lib.sh, so a case that uses it as the earlier-phase file never plants it.
  cp -R "$REPO_ROOT_REAL/.gaia/scripts/spec" "$TREE/.gaia/scripts/spec"
  cp "$REPO_ROOT_REAL/.gaia/scripts/machine-local-ref-lib.sh" "$TREE/.gaia/scripts/"
  git -C "$TREE" init -q
  printf '# Plan\n\n| Phase | Tasks |\n|---|---|\n| Phase 1 | `task-early` |\n| Phase 2 | `task-late` |\n' >"$PLAN/README.md"
}

# plant <repo-relative path> <content>: a tracked file in the fixture tree.
plant() {
  mkdir -p "$(dirname "$TREE/$1")"
  printf '%s\n' "$2" >"$TREE/$1"
  git -C "$TREE" add -- "$1"
}

# task <stem> <Files to touch bullet>...: a task doc whose section lists each bullet.
task() {
  local stem="$1" bullet
  shift
  {
    printf '# Task\n\n## Files to touch\n\n'
    for bullet in "$@"; do printf -- '- %s\n' "$bullet"; done
    printf '\n## Acceptance criteria\n\n- `not/a/declared.sh` stays out of the section\n'
  } >"$PLAN/$stem.md"
}

verify() {
  run bash "$TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
}

# cross_phase_lines: the cross-phase refusals in the last run's output.
cross_phase_lines() {
  grep -F 'a file none of its tasks owns' <<<"$output" || true
}

@test "a later-phase suite that pins an earlier phase's file by path is refused, naming the cheap fix" {
  plant .gaia/tests/lib/doc-code-map-plan.bats 'VERIFY_LIB="$ROOT/.gaia/scripts/spec/plan-verify-lib.sh"'
  task task-early 'RESOLVED_ROOT/.gaia/scripts/spec/plan-verify-lib.sh (add a fourth token to the placeholder loop)'
  task task-late '`.gaia/tests/lib/doc-code-map-plan.bats` (pin the four-token loop)'
  verify
  [ "$status" -eq 1 ]
  local refusals
  refusals="$(cross_phase_lines)"
  [ "$(grep -c . <<<"$refusals")" -eq 1 ]
  [[ "$refusals" == *'Phase 1 (task-early.md) changes .gaia/scripts/spec/plan-verify-lib.sh, which .gaia/tests/lib/doc-code-map-plan.bats checks'* ]]
  [[ "$refusals" == *'only Phase 2 (task-late.md) declares'* ]]
  [[ "$refusals" == *'declare .gaia/tests/lib/doc-code-map-plan.bats in a Phase 1 task as well, or reorder the tasks'* ]]
}

@test "a later-phase allowlist row that names a file an earlier phase creates is refused" {
  plant .gaia/retired-paths-allowlist.tsv '# file<TAB>needle<TAB>reason'
  task task-early '.claude/skills/gaia/references/plan/orchestrator-template.md (new; carries `pnpm -C apps/web exec eslint`)'
  task task-late '.gaia/retired-paths-allowlist.tsv: add a row allowing `pnpm -C apps/web` in .claude/skills/gaia/references/plan/orchestrator-template.md'
  verify
  [ "$status" -eq 1 ]
  local refusals
  refusals="$(cross_phase_lines)"
  [ "$(grep -c . <<<"$refusals")" -eq 1 ]
  [[ "$refusals" == *'Phase 1 (task-early.md) changes .claude/skills/gaia/references/plan/orchestrator-template.md, which .gaia/retired-paths-allowlist.tsv checks'* ]]
}

@test "the earlier phase declaring the catching file too passes, for both arms" {
  plant .gaia/tests/lib/doc-code-map-plan.bats 'VERIFY_LIB="$ROOT/.gaia/scripts/spec/plan-verify-lib.sh"'
  plant .gaia/retired-paths-allowlist.tsv '# file<TAB>needle<TAB>reason'
  task task-early '.gaia/scripts/spec/plan-verify-lib.sh' '.gaia/tests/lib/doc-code-map-plan.bats' \
    '.claude/skills/gaia/references/plan/orchestrator-template.md' '.gaia/retired-paths-allowlist.tsv'
  task task-late '.gaia/tests/lib/doc-code-map-plan.bats' \
    '.gaia/retired-paths-allowlist.tsv: a row for .claude/skills/gaia/references/plan/orchestrator-template.md'
  verify
  [ -z "$(cross_phase_lines)" ]
}

@test "a suite names an earlier file by a basename: unique fires, shared with another tracked file does not" {
  plant apps/web/app/routes/checkout.tsx 'route'
  plant apps/web/app/components/card/index.tsx 'card'
  plant apps/web/app/components/badge/index.tsx 'badge'
  # The suite names both files by basename only, never by repo-relative path.
  plant apps/web/test/pages.test.tsx 'import "./index.tsx"; import "./checkout.tsx"'
  task task-early 'apps/web/app/routes/checkout.tsx' 'apps/web/app/components/card/index.tsx'
  task task-late 'apps/web/test/pages.test.tsx'
  verify
  local refusals
  refusals="$(cross_phase_lines)"
  [ "$(grep -c . <<<"$refusals")" -eq 1 ]
  [[ "$refusals" == *'changes apps/web/app/routes/checkout.tsx, which apps/web/test/pages.test.tsx checks'* ]]
  [[ "$refusals" != *'index.tsx'* ]]
}

@test "a later source file naming an earlier file beside it is a consumer, not a check, and passes" {
  plant apps/web/app/routes/checkout.tsx 'import { useCart } from "~/hooks/use-cart.ts"'
  task task-early 'apps/web/app/hooks/use-cart.ts (new)'
  task task-late 'apps/web/app/routes/checkout.tsx: import useCart from apps/web/app/hooks/use-cart.ts'
  verify
  [ -z "$(cross_phase_lines)" ]
  # The same line with an allowlist in place of the source file fires: the arm is live.
  plant .gaia/review-allowlist.txt 'rows'
  task task-late '.gaia/review-allowlist.txt: allow apps/web/app/hooks/use-cart.ts'
  verify
  [ "$(cross_phase_lines | grep -c .)" -eq 1 ]
}

@test "a path named outside the Files to touch section is not declared" {
  plant .gaia/tests/lib/doc-code-map-plan.bats 'not/a/declared.sh'
  task task-early '.gaia/scripts/spec/plan-verify-lib.sh'
  task task-late '.gaia/tests/lib/doc-code-map-plan.bats'
  verify
  [ -z "$(cross_phase_lines)" ]
}
