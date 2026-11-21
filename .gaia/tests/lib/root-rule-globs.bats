#!/usr/bin/env bats
#
# Root rule glob guard. A rule in the root .claude/rules anchors its `paths:`
# globs at the repository root from both launch directories, so after the React
# app moved into apps/web/ a glob that still begins with a retired root
# frontend path (app/, test/, public/, .playwright/, .storybook/, or a moved
# config filename) silently stops loading on the frontend files it governs.
# The retired-prefix scan over the rule globs is the retired-path gate's
# (.gaia/scripts/check-retired-paths.sh); this suite checks that the real globs
# still match the files each rule governs.
#
# The match check compiles the real rule globs through the package reader's
# glob dialect (.claude/hooks/lib/gaia-packages.sh) by loading them as a
# scratch package descriptor.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): assertions use
# POSIX `[ ]` or an explicit `return 1`, never a bare mid-test `[[ ]]`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULES_DIRECTORY="$REPO_ROOT/.claude/rules"
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

@test "code-comments.md globs match frontend, workflow, Dockerfile, hook, harness-script and future-package code" {
  local code_path
  for code_path in apps/web/app/components/button/index.tsx apps/web/.playwright/e2e/hydration.spec.ts \
    .github/workflows/cli-tests.yml apps/web/Dockerfile .githooks/pre-commit \
    .gaia/scripts/spec/behaviors.mjs .gaia/scripts/spec/flows-lib.sh \
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
