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
  make_sandbox
}

# A case table calls this again to start a case from a clean repo.
make_sandbox() {
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

# expect_plan <label> <expected plan>: the helper exits 0 and prints exactly the plan.
expect_plan() {
  plan
  [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
  [ "$output" = "$2" ] || { echo "$1: got '$output'"; return 1; }
}

@test "staged paths plan packages by preCommitSource glob, and a retired root app path plans retired-add instead" {
  use_frontend_package
  expect_plan "empty staged set" "" || return 1

  stage_files apps/web/app/x.tsx
  expect_plan "frontend change" $'package\tapps/web' || return 1
  git -C "$REPO" reset --quiet

  stage_files apps/web/README.md docs/a.md .claude/rules/a.md
  expect_plan "no preCommitSource glob matches" "" || return 1
  git -C "$REPO" reset --quiet

  stage_files app/x.tsx
  plan
  [ "$status" -eq 0 ] || { echo "root app: status $status"; return 1; }
  grep -qxF -- "$(printf 'retired-add\tapp/x.tsx\tapps/web/app/x.tsx')" <<<"$output" || { echo "root app: got '$output'"; return 1; }
  [ "$(grep -c '^package' <<<"$output" || true)" -eq 0 ] || { echo "root app: planned a package: '$output'"; return 1; }
  git -C "$REPO" reset --quiet

  # The same staged file under a descriptor that names nothing it matches plans
  # nothing, so the descriptor decides.
  write_descriptor "$REPO/apps/web" web '["nomatch/**"]'
  stage_files apps/web/app/x.tsx
  expect_plan "descriptor gates nothing" "" || return 1
  git -C "$REPO" reset --quiet

  use_frontend_package
  stage_files "apps/web/app/caf"$'\303\251'" x.tsx"
  expect_plan "spaced and non-ASCII path" $'package\tapps/web' || return 1
  git -C "$REPO" reset --quiet

  printf '[{"name":"web","path":"apps/web"},{"name":"admin","path":"admin"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/apps/web" web '["app/**"]'
  write_descriptor "$REPO/admin" admin '["app/**"]'
  stage_files admin/app/y.ts
  expect_plan "two packages, one staged" $'package\tadmin' || return 1
  stage_files apps/web/app/x.ts
  plan
  [ "$(printf '%s\n' "$output" | sort)" = $'package\tadmin\npackage\tapps/web' ] || { echo "two packages, both staged: got '$output'"; return 1; }
  git -C "$REPO" reset --quiet

  use_frontend_package
  stage_files apps/web/app/x.tsx
  git -C "$REPO" commit --quiet -m "add"
  git -C "$REPO" rm --quiet apps/web/app/x.tsx
  expect_plan "deletion" $'package\tapps/web'
}

@test "doctor guard reports a directory with more than one react-doctor config" {
  use_frontend_package
  : > "$REPO/apps/web/doctor.config.ts"
  : > "$REPO/apps/web/doctor.config.json"
  plan
  [ "$status" -eq 0 ] || { echo "two configs: status $status"; return 1; }
  grep -qxF $'doctor\tapps/web' <<<"$output" || { echo "two configs: got '$output'"; return 1; }
  grep -qxF $'doctor-file\tapps/web/doctor.config.json' <<<"$output" || { echo "two configs: got '$output'"; return 1; }
  grep -qxF $'doctor-file\tapps/web/doctor.config.ts' <<<"$output" || { echo "two configs: got '$output'"; return 1; }

  find "$REPO" -name '*doctor.config*' -not -path '*/.git/*' -delete
  : > "$REPO/apps/web/doctor.config.ts"
  : > "$REPO/apps/web/doctor.config.local copy.ts"
  : > "$REPO/apps/web/not-a-config.ts"
  plan
  [ "$status" -eq 0 ] || { echo "spaced name: status $status"; return 1; }
  [ "$(grep -c '^doctor-file' <<<"$output")" -eq 2 ] || { echo "spaced name: got '$output'"; return 1; }
  grep -qxF $'doctor\tapps/web' <<<"$output" || { echo "spaced name: got '$output'"; return 1; }
  grep -qxF $'doctor-file\tapps/web/doctor.config.ts' <<<"$output" || { echo "spaced name: got '$output'"; return 1; }
  grep -qxF $'doctor-file\tapps/web/doctor.config.local copy.ts' <<<"$output" || { echo "spaced name: got '$output'"; return 1; }

  find "$REPO" -name '*doctor.config*' -not -path '*/.git/*' -delete
  printf '[{"name":"root","path":"."}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO" root '["app/**"]'
  : > "$REPO/doctor.config.ts"
  : > "$REPO/react-doctor.config.mjs"
  plan
  [ "$status" -eq 0 ] || { echo "root package: status $status"; return 1; }
  [ "$(grep -c '^doctor-file' <<<"$output")" -eq 2 ] || { echo "root package: got '$output'"; return 1; }
  grep -qxF $'doctor\t.' <<<"$output" || { echo "root package: got '$output'"; return 1; }
  grep -qxF $'doctor-file\tdoctor.config.ts' <<<"$output" || { echo "root package: got '$output'"; return 1; }
  grep -qxF $'doctor-file\treact-doctor.config.mjs' <<<"$output" || { echo "root package: got '$output'"; return 1; }

  find "$REPO" -name '*doctor.config*' -not -path '*/.git/*' -delete
  use_frontend_package
  : > "$REPO/apps/web/doctor.config.ts"
  expect_plan "one config" "" || return 1

  find "$REPO" -name '*doctor.config*' -not -path '*/.git/*' -delete
  : > "$REPO/doctor.config.ts"
  : > "$REPO/doctor.config.json"
  expect_plan "stray root configs" ""
}

# expect_registry_failure <label>: the helper exits 1 with the gaia-packages message.
expect_registry_failure() {
  stage_files apps/web/app/x.tsx
  plan
  [ "$status" -eq 1 ] || { echo "$1: status $status"; return 1; }
  grep -qF -- "gaia-packages: " <<<"$output" || { echo "$1: got '$output'"; return 1; }
}

# bats test_tags=protected
@test "an unparseable registry exits 1 with the gaia-packages message" {
  use_frontend_package
  printf 'not json {\n' > "$REPO/.gaia/packages.json"
  expect_registry_failure "unparseable registry" || return 1

  use_frontend_package
  rm "$REPO/apps/web/gaia.package.json"
  expect_registry_failure "missing descriptor" || return 1

  use_frontend_package
  rm "$REPO/.claude/hooks/lib/gaia-packages.sh"
  expect_registry_failure "missing registry reader"
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

# expect_rename_plan <label> <expected> <pair>...: a fresh sandbox with the
# given pairs staged as exact renames only. The expected plan is
# `package<TAB>apps/web`, `none` (empty), or `not-exempt`.
expect_rename_plan() {
  local label="$1" expected="$2" count
  shift 2
  make_sandbox
  use_frontend_package
  stage_renames "$@"
  count=$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')
  [ "$count" -eq "$#" ] || { echo "$label: staged $count exact renames, expected $#"; return 1; }
  plan
  [ "$status" -eq 0 ] || { echo "$label: status $status"; return 1; }
  case "$expected" in
    none) [ -z "$output" ] || { echo "$label: got '$output'"; return 1; } ;;
    not-exempt) [ "$output" != "exempt" ] || { echo "$label: plan was exempt"; return 1; } ;;
    *) [ "$output" = "$expected" ] || { echo "$label: got '$output'"; return 1; } ;;
  esac
}

# Each refusal stages one entry that must not be exempt; the first two ride
# beside the whole C6 set to prove the exemption is all or nothing.
@test "a rename is exempt only as an exact move to its counterpart; every other rename goes through the normal plan" {
  expect_rename_plan "R100 rename inside apps/web beside the C6 set" $'package\tapps/web' \
    "${C6_PAIRS[@]}" "apps/web/app/utils/a.ts:apps/web/app/utils/b.ts" || return 1
  expect_rename_plan "harness rename outside the C6 units beside the C6 set" not-exempt \
    "${C6_PAIRS[@]}" "wiki/a.md:wiki/b.md" || return 1
  expect_rename_plan "C6 source renamed to a non-counterpart destination" not-exempt \
    "app/x.tsx:src/x.tsx" || return 1
  expect_rename_plan "source renamed under a different name inside apps/web" $'package\tapps/web' \
    "app/x.tsx:apps/web/app/y.tsx" || return 1
  expect_rename_plan ".claude file outside the C6 units" none \
    ".claude/rules/quality-gate.md:apps/web/.claude/rules/quality-gate.md" || return 1
  expect_rename_plan "root config file outside the C6 list" none \
    "package.json:apps/web/package.json" || return 1
  expect_rename_plan "dockerignore pair with a different destination" none \
    ".dockerignore:apps/web/.dockerignore" || return 1

  make_sandbox
  use_frontend_package
  stage_renames "app/x.tsx:apps/web/app/x.tsx"
  printf 'a changed line\n' >> "$REPO/apps/web/app/x.tsx"
  git -C "$REPO" add apps/web/app/x.tsx
  expect_plan "C6 rename carrying a content change" $'package\tapps/web'
}
