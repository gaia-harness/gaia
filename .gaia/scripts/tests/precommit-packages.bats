#!/usr/bin/env bats
# .gaia/scripts/precommit-packages.sh: the plan helper behind .githooks/pre-commit.
#
# The helper reads the staged set and prints one record per line. These tests
# drive it directly in a sandbox repo, so each plan is asserted as data. The
# hook that acts on the plan is covered end to end by
# .gaia/tests/hooks/githooks-pre-commit.bats.
#
# The registry and descriptors are written literally into the sandbox; the live
# files are never copied. Assertion style per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  HELPER="$REPO_ROOT/.gaia/scripts/precommit-packages.sh"
  [ -f "$HELPER" ] || { echo "missing $HELPER" >&2; return 1; }

  REPO="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/precommit-packages.XXXXXX")" && pwd -P)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$HELPER" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"
  SANDBOX_HELPER="$REPO/.gaia/scripts/precommit-packages.sh"
}

write_descriptor() {
  local directory="$1" name="$2" pre_commit_source="$3"
  mkdir -p "$directory"
  cat > "$directory/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "$name",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": ["app/utils/**"],
    "emergentTests": ["app/components/**/*.test.ts"],
    "preCommitSource": $pre_commit_source,
    "doctorConfigs": ["doctor.config.*", "react-doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": { "sourcePaths": ["app/"], "inventoryPaths": ["app/"], "flowPaths": ["app/"] }
}
JSON
}

use_frontend_package() {
  printf '[{"name":"web","path":"apps/web"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/apps/web" web '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

plan() {
  run bash "$SANDBOX_HELPER" "$REPO"
}

# Create and stage files at the given repo-relative paths.
stage_files() {
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    printf '// %s\n' "$path" > "$REPO/$path"
    git -C "$REPO" add -- "$path"
  done
}

# Create, commit, then rename (staged) each `src:dest` pair.
stage_renames() {
  local pair source_path destination_path
  for pair in "$@"; do
    source_path="${pair%%:*}"
    mkdir -p "$REPO/$(dirname "$source_path")"
    # Long enough that one appended line stays a rename above git's similarity
    # threshold, so a content-change rename reads as Rnn rather than D plus A.
    printf '// %s\n' "$source_path" > "$REPO/$source_path"
    seq 1 40 >> "$REPO/$source_path"
    git -C "$REPO" add -- "$source_path"
  done
  git -C "$REPO" commit --quiet -m "seed"
  for pair in "$@"; do
    source_path="${pair%%:*}"
    destination_path="${pair#*:}"
    mkdir -p "$REPO/$(dirname "$destination_path")"
    git -C "$REPO" mv -- "$source_path" "$destination_path"
  done
}

@test "usage: no argument exits 2" {
  run bash "$HELPER"
  [ "$status" -eq 2 ]
}

@test "usage: a root that is not a directory exits 2" {
  run bash "$HELPER" "$REPO/nope"
  [ "$status" -eq 2 ]
}

@test "an empty staged set plans nothing" {
  use_frontend_package
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a frontend change plans the frontend package" {
  use_frontend_package
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web' ]
}

@test "a path matching no preCommitSource glob plans nothing" {
  use_frontend_package
  stage_files apps/web/README.md docs/a.md .claude/rules/a.md
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a root app/ path is not a frontend change when the package is at apps/web/" {
  use_frontend_package
  stage_files app/x.tsx
  plan
  [ "$status" -eq 0 ]
  # Not a package change; it is the MIG-013 retired-path record instead.
  grep -qxF -- "$(printf 'retired-add\tapp/x.tsx\tapps/web/app/x.tsx')" <<<"$output"
  [ "$(grep -c '^package' <<<"$output" || true)" -eq 0 ]
}

# Guard can fail: the same staged file under a descriptor that names nothing it
# matches plans nothing, so the descriptor decides.
@test "a descriptor that gates nothing here plans nothing for a frontend path" {
  use_frontend_package
  write_descriptor "$REPO/apps/web" web '["nomatch/**"]'
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a deletion counts" {
  use_frontend_package
  stage_files apps/web/app/x.tsx
  git -C "$REPO" commit --quiet -m "add"
  git -C "$REPO" rm --quiet apps/web/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web' ]
}

@test "a spaced and a non-ASCII path count and are not C-quoted into a miss" {
  use_frontend_package
  stage_files "apps/web/app/caf"$'\303\251'" x.tsx"
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web' ]
}

@test "two registered packages plan only the one with a staged source path" {
  printf '[{"name":"web","path":"apps/web"},{"name":"admin","path":"admin"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/apps/web" web '["app/**"]'
  write_descriptor "$REPO/admin" admin '["app/**"]'
  stage_files admin/app/y.ts
  plan
  [ "$output" = $'package\tadmin' ]
  stage_files apps/web/app/x.ts
  plan
  [ "$(printf '%s\n' "$output" | sort)" = $'package\tadmin\npackage\tapps/web' ]
}

@test "doctor guard: two configs in a package dir are reported with the directory" {
  use_frontend_package
  : > "$REPO/apps/web/doctor.config.ts"
  : > "$REPO/apps/web/doctor.config.json"
  plan
  [ "$status" -eq 0 ]
  grep -qxF $'doctor\tapps/web' <<<"$output"
  grep -qxF $'doctor-file\tapps/web/doctor.config.json' <<<"$output"
  grep -qxF $'doctor-file\tapps/web/doctor.config.ts' <<<"$output"
}

@test "doctor guard: a config whose name holds a space is counted with the others" {
  use_frontend_package
  : > "$REPO/apps/web/doctor.config.ts"
  : > "$REPO/apps/web/doctor.config.local copy.ts"
  : > "$REPO/apps/web/not-a-config.ts"
  plan
  [ "$status" -eq 0 ]
  [ "$(grep -c '^doctor-file' <<<"$output")" -eq 2 ]
  grep -qxF $'doctor\tapps/web' <<<"$output"
  grep -qxF $'doctor-file\tapps/web/doctor.config.ts' <<<"$output"
  grep -qxF $'doctor-file\tapps/web/doctor.config.local copy.ts' <<<"$output"
}

@test "doctor guard: a package at the repo root reports its configs repo-relative" {
  printf '[{"name":"root","path":"."}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO" root '["app/**"]'
  : > "$REPO/doctor.config.ts"
  : > "$REPO/react-doctor.config.mjs"
  plan
  [ "$status" -eq 0 ]
  [ "$(grep -c '^doctor-file' <<<"$output")" -eq 2 ]
  grep -qxF $'doctor\t.' <<<"$output"
  grep -qxF $'doctor-file\tdoctor.config.ts' <<<"$output"
  grep -qxF $'doctor-file\treact-doctor.config.mjs' <<<"$output"
}

@test "doctor guard: one config in a package dir reports nothing" {
  use_frontend_package
  : > "$REPO/apps/web/doctor.config.ts"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "doctor guard: a stray config at the repo root is not a package config" {
  use_frontend_package
  : > "$REPO/doctor.config.ts"
  : > "$REPO/doctor.config.json"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unparseable registry exits 1 with the gaia-packages message" {
  use_frontend_package
  printf 'not json {\n' > "$REPO/.gaia/packages.json"
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

@test "a missing descriptor exits 1 with the gaia-packages message" {
  use_frontend_package
  rm "$REPO/apps/web/gaia.package.json"
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

@test "a missing registry reader exits 1 rather than allowing" {
  use_frontend_package
  rm "$REPO/.claude/hooks/lib/gaia-packages.sh"
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

# --- C13: the migration-rename exemption ---

# A realistic Phase 4 move: whole directories with nested, spaced, and
# non-ASCII files, every root config file, every frontend-only .claude unit,
# and the one renamed pair. Each source is a retired root path; each
# destination is its C6 counterpart.
C6_PAIRS=(
  "app/routes/home.tsx:apps/web/app/routes/home.tsx"
  "app/components/button/index.tsx:apps/web/app/components/button/index.tsx"
  "app/components/button/tests/index.test.tsx:apps/web/app/components/button/tests/index.test.tsx"
  "app/sessions.server/cookie ü.ts:apps/web/app/sessions.server/cookie ü.ts"
  "test/setup.ts:apps/web/test/setup.ts"
  "public/favicon.ico:apps/web/public/favicon.ico"
  ".storybook/main.ts:apps/web/.storybook/main.ts"
  ".playwright/e2e/home.spec.ts:apps/web/.playwright/e2e/home.spec.ts"
  "vite.config.ts:apps/web/vite.config.ts"
  "vitest.config.ts:apps/web/vitest.config.ts"
  "playwright.config.ts:apps/web/playwright.config.ts"
  "react-router.config.ts:apps/web/react-router.config.ts"
  "stylelint.config.mjs:apps/web/stylelint.config.mjs"
  "knip.config.ts:apps/web/knip.config.ts"
  "doctor.config.ts:apps/web/doctor.config.ts"
  "tsconfig.json:apps/web/tsconfig.json"
  "Dockerfile:apps/web/Dockerfile"
  ".env.example:apps/web/.env.example"
  "eslint.config.mjs:apps/web/eslint.config.mjs"
  ".lintstagedrc.json:apps/web/.lintstagedrc.json"
  ".dockerignore:apps/web/Dockerfile.dockerignore"
  ".claude/skills/a11y-fixes/SKILL.md:apps/web/.claude/skills/a11y-fixes/SKILL.md"
  ".claude/skills/eslint-fixes/SKILL.md:apps/web/.claude/skills/eslint-fixes/SKILL.md"
  ".claude/skills/gaia-react-perf/SKILL.md:apps/web/.claude/skills/gaia-react-perf/SKILL.md"
  ".claude/skills/new-component/SKILL.md:apps/web/.claude/skills/new-component/SKILL.md"
  ".claude/skills/new-hook/SKILL.md:apps/web/.claude/skills/new-hook/SKILL.md"
  ".claude/skills/new-route/SKILL.md:apps/web/.claude/skills/new-route/SKILL.md"
  ".claude/skills/new-service/SKILL.md:apps/web/.claude/skills/new-service/SKILL.md"
  ".claude/skills/playwright-cli/SKILL.md:apps/web/.claude/skills/playwright-cli/SKILL.md"
  ".claude/skills/playwright-cli/references/a.md:apps/web/.claude/skills/playwright-cli/references/a.md"
  ".claude/skills/react-code/SKILL.md:apps/web/.claude/skills/react-code/SKILL.md"
  ".claude/skills/skeleton-loaders/SKILL.md:apps/web/.claude/skills/skeleton-loaders/SKILL.md"
  ".claude/skills/tailwind/SKILL.md:apps/web/.claude/skills/tailwind/SKILL.md"
  ".claude/skills/typescript/SKILL.md:apps/web/.claude/skills/typescript/SKILL.md"
  ".claude/rules/accessibility.md:apps/web/.claude/rules/accessibility.md"
  ".claude/rules/api-service.md:apps/web/.claude/rules/api-service.md"
  ".claude/rules/design-baseline.md:apps/web/.claude/rules/design-baseline.md"
  ".claude/rules/i18n.md:apps/web/.claude/rules/i18n.md"
  ".claude/rules/playwright.md:apps/web/.claude/rules/playwright.md"
  ".claude/rules/react-router-docs.md:apps/web/.claude/rules/react-router-docs.md"
  ".claude/rules/routes.md:apps/web/.claude/rules/routes.md"
  ".claude/rules/state-pattern.md:apps/web/.claude/rules/state-pattern.md"
  ".claude/rules/storybook.md:apps/web/.claude/rules/storybook.md"
  ".claude/rules/tailwind.md:apps/web/.claude/rules/tailwind.md"
  ".claude/instructions/add-locale.md:apps/web/.claude/instructions/add-locale.md"
  ".claude/instructions/remove-i18n.md:apps/web/.claude/instructions/remove-i18n.md"
  ".claude/agents/code-audit-frontend/README.md:apps/web/.claude/agents/code-audit-frontend/README.md"
  ".claude/agents/code-audit-frontend/cn.md:apps/web/.claude/agents/code-audit-frontend/cn.md"
  ".claude/agents/code-audit-frontend/conform.md:apps/web/.claude/agents/code-audit-frontend/conform.md"
  ".claude/agents/code-audit-frontend/form-components.md:apps/web/.claude/agents/code-audit-frontend/form-components.md"
  ".claude/agents/code-audit-frontend/react-i18next.md:apps/web/.claude/agents/code-audit-frontend/react-i18next.md"
)

@test "C13: the whole C6 move set, as renames only, plans exempt with no registry and no descriptor" {
  stage_renames "${C6_PAIRS[@]}"
  # The fixture must really stage every pair as an exact rename, else the
  # exemption is being asserted over a set git did not see as renames.
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq "${#C6_PAIRS[@]}" ]
  [ ! -e "$REPO/.gaia/packages.json" ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" = "exempt" ]
}

# Each negative stages the whole C6 set plus one entry that must not be exempt,
# and asserts the exemption is refused (the plan is not `exempt`). The extra
# pair rides in the same seed commit, so only renames are ever staged.
@test "C13 refusal: an R100 rename inside apps/web/ beside the C6 set is not exempt and plans the package" {
  use_frontend_package
  stage_renames "${C6_PAIRS[@]}" "apps/web/app/utils/a.ts:apps/web/app/utils/b.ts"
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq $((${#C6_PAIRS[@]} + 1)) ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web' ]
}

@test "C13 refusal: a harness rename outside the C6 units beside the C6 set is not exempt" {
  use_frontend_package
  stage_renames "${C6_PAIRS[@]}" "wiki/a.md:wiki/b.md"
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq $((${#C6_PAIRS[@]} + 1)) ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a C6 source renamed to a destination that is not its counterpart is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:src/x.tsx"
  plan
  [ "$status" -eq 0 ]
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a source renamed under a different name inside apps/web/ is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:apps/web/app/y.tsx"
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web' ]
}

@test "C13 refusal: a .claude file outside the C6 units is not exempt" {
  use_frontend_package
  stage_renames ".claude/rules/quality-gate.md:apps/web/.claude/rules/quality-gate.md"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C13 refusal: a root config file outside the C6 list is not exempt" {
  use_frontend_package
  stage_renames "package.json:apps/web/package.json"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C13 refusal: the dockerignore pair with a different destination is not exempt" {
  use_frontend_package
  stage_renames ".dockerignore:apps/web/.dockerignore"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C13 refusal: a C6 rename carrying a content change is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:apps/web/app/x.tsx"
  printf 'a changed line\n' >> "$REPO/apps/web/app/x.tsx"
  git -C "$REPO" add apps/web/app/x.tsx
  plan
  [ "$output" = $'package\tapps/web' ]
}

