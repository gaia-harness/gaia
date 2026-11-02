#!/usr/bin/env bats
#
# Root rule glob guard. A rule in the root .claude/rules anchors its `paths:`
# globs at the repository root from both launch directories, so after the React
# app moved into apps/web/ a glob that still begins with a retired root
# frontend path (app/, test/, public/, .playwright/, .storybook/, or a moved
# config filename) silently stops loading on the frontend files it governs.
#
# Each check is proven able to fail: a scratch copy of the rules directory gets
# a glob reverted to the retired form and the checker must flag it. The match
# check compiles the real rule globs, and a reverted copy, through the package
# reader's glob dialect (.claude/hooks/lib/gaia-packages.sh) by loading them as
# a scratch package descriptor.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): assertions use
# POSIX `[ ]` or an explicit `return 1`, never a bare mid-test `[[ ]]`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULES_DIRECTORY="$REPO_ROOT/.claude/rules"
  SCRATCH_RULES="$BATS_TEST_TMPDIR/rules"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh"
}

# Echoes each `paths:` glob of one rule file, one per line, quotes stripped.
rule_globs() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { in_front = 1; next }
    in_front && /^---[[:space:]]*$/ { exit }
    in_front && /^paths:/ { in_paths = 1; next }
    in_front && in_paths && /^[[:space:]]+-[[:space:]]/ { print; next }
    in_front && in_paths { in_paths = 0 }
  ' "$1" | sed -E "s/^[[:space:]]+-[[:space:]]+//; s/^'//; s/'[[:space:]]*\$//; s/^\"//; s/\"[[:space:]]*\$//"
}

# Echoes "<rule file>: <glob>" for every glob in a rules directory that begins
# with a retired root frontend path. Returns 1 when any is found.
retired_globs_in() {
  local directory="$1" rule_file glob found=0 retired
  retired='^(app|test|public|\.playwright|\.storybook)/|^(vite\.config\.ts|vitest\.config\.ts|playwright\.config\.ts|react-router\.config\.ts|stylelint\.config\.mjs|knip\.config\.ts|doctor\.config\.ts|tsconfig\.json|Dockerfile|\.env\.example|eslint\.config\.mjs|\.lintstagedrc\.json|\.dockerignore)$'
  for rule_file in "$directory"/*.md; do
    while IFS= read -r glob; do
      [ -z "$glob" ] && continue
      if printf '%s\n' "$glob" | grep -Eq "$retired"; then
        printf '%s: %s\n' "$(basename "$rule_file")" "$glob"
        found=1
      fi
    done < <(rule_globs "$rule_file")
  done
  [ "$found" -eq 0 ]
}

# Exit 0 when any glob of the rule file matches the repo-relative path under
# the package descriptor's glob dialect, 1 when none does, 2 when the globs do
# not load. The globs become every key of a scratch descriptor at path `.`, so
# they compile unjoined.
rule_matches_path() {
  local rule_file="$1" candidate_path="$2" root="$BATS_TEST_TMPDIR/matcher" ere
  mkdir -p "$root/.gaia"
  printf '[{"name":"rules","path":"."}]\n' >"$root/.gaia/packages.json"
  rule_globs "$rule_file" | jq -R . | jq -s '{
    schemaVersion: 1, name: "rules",
    globs: {tddUnitTests: ., tddStrictCandidates: ., emergentTests: ., preCommitSource: ., doctorConfigs: ., dependencyManifests: .},
    wiki: {sourcePaths: [], inventoryPaths: [], flowPaths: []}
  }' >"$root/gaia.package.json"
  gaia_packages_load "$root" || return 2
  ere="$(gaia_package_globs_ere tddUnitTests)"
  printf '%s\n' "$candidate_path" | grep -Eq -- "$ere"
}

copy_rules_to_scratch() {
  mkdir -p "$SCRATCH_RULES"
  cp "$RULES_DIRECTORY"/*.md "$SCRATCH_RULES/"
}

write_retired_scratch_rule() {
  printf -- '---\npaths:\n  - '"'"'app/**/*.{ts,tsx}'"'"'\n  - '"'"'.playwright/**/*.ts'"'"'\n---\n\n# Scratch\n' >"$SCRATCH_RULES/scratch-retired.md"
}

@test "no root rule glob begins with a retired root frontend path" {
  run retired_globs_in "$RULES_DIRECTORY"
  if [ "$status" -ne 0 ]; then
    echo "retired-path globs: $output" >&2
    return 1
  fi
}

@test "checker flags a rule glob reverted to a retired frontend folder" {
  copy_rules_to_scratch
  write_retired_scratch_rule
  run retired_globs_in "$SCRATCH_RULES"
  [ "$status" -eq 1 ]
  grep -q "^scratch-retired.md: app/" <<<"$output"
  grep -q "^scratch-retired.md: \.playwright/" <<<"$output"
}

@test "checker flags a rule glob naming a moved config filename" {
  copy_rules_to_scratch
  printf -- '---\npaths:\n  - '"'"'vite.config.ts'"'"'\n---\n\n# Scratch\n' >"$SCRATCH_RULES/scratch-config.md"
  run retired_globs_in "$SCRATCH_RULES"
  [ "$status" -eq 1 ]
  grep -q "^scratch-config.md: vite.config.ts" <<<"$output"
}

@test "checker leaves a harness glob that merely contains app/ alone" {
  copy_rules_to_scratch
  printf -- '---\npaths:\n  - '"'"'**/app/**'"'"'\n  - '"'"'.gaia/app/x.ts'"'"'\n---\n\n# Scratch\n' >"$SCRATCH_RULES/scratch-ok.md"
  run retired_globs_in "$SCRATCH_RULES"
  [ "$status" -eq 0 ]
}

@test "code-comments.md matches the frontend app file and the frontend playwright spec" {
  rule_matches_path "$RULES_DIRECTORY/code-comments.md" "apps/web/app/components/button/index.tsx"
  rule_matches_path "$RULES_DIRECTORY/code-comments.md" "apps/web/.playwright/e2e/hydration.spec.ts"
}

@test "code-comments.md matches workflow YAML, a Dockerfile, a git hook, harness scripts and code in a future package" {
  local code_path
  for code_path in .github/workflows/cli-tests.yml apps/web/Dockerfile .githooks/pre-commit \
    .gaia/scripts/overlap/check-proposals.mjs .gaia/scripts/spec/uat-write.sh \
    packages/example/src/index.ts apps/example/app/root.tsx; do
    rule_matches_path "$RULES_DIRECTORY/code-comments.md" "$code_path" || { echo "code-comments.md missed $code_path" >&2; return 1; }
  done
}

@test "wiki-style.md matches a wiki page and no code file" {
  local code_path
  rule_matches_path "$RULES_DIRECTORY/wiki-style.md" "wiki/concepts/Notebook.md"
  for code_path in apps/web/app/components/button/index.tsx apps/web/.playwright/e2e/hydration.spec.ts \
    .claude/hooks/ports-session-start.sh .gaia/scripts/spec/ledger-lib.sh; do
    run rule_matches_path "$RULES_DIRECTORY/wiki-style.md" "$code_path"
    [ "$status" -eq 1 ] || { echo "wiki-style.md matched $code_path" >&2; return 1; }
  done
}

@test "guards-must-fail.md matches the frontend playwright spec and not the frontend app file" {
  rule_matches_path "$RULES_DIRECTORY/guards-must-fail.md" "apps/web/.playwright/e2e/hydration.spec.ts"
  run rule_matches_path "$RULES_DIRECTORY/guards-must-fail.md" "apps/web/app/components/button/index.tsx"
  [ "$status" -eq 1 ]
}

@test "the match check refuses a rule whose globs are reverted to retired frontend folders" {
  copy_rules_to_scratch
  write_retired_scratch_rule
  run rule_matches_path "$SCRATCH_RULES/scratch-retired.md" "apps/web/app/components/button/index.tsx"
  [ "$status" -eq 1 ]
  run rule_matches_path "$SCRATCH_RULES/scratch-retired.md" "apps/web/.playwright/e2e/hydration.spec.ts"
  [ "$status" -eq 1 ]
}
