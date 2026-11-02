#!/usr/bin/env bats
#
# SPEC-092 UAT-019: the shipped CI path filters select the app's files under
# apps/web/ and skip the retired root forms. A filter that still reads root
# `app/` reports a required check green without running anything.
#
#   tests.yml     the ERE in `pattern='...'` (matched with grep -E)
#   chromatic.yml the dorny/paths-filter `code:` globs (picomatch semantics)
#
# The "base" controls are inline copies of the pre-move filters, so the guard
# is proven able to fail without reading git history (this PR is squash-merged).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_YML="$REPO_ROOT/.github/workflows/tests.yml"
  CHROMATIC_YML="$REPO_ROOT/.github/workflows/chromatic.yml"
  OLD_TESTS_PATTERN='^(app|test)/|^\.playwright/|^\.storybook/|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|\.npmrc|\.node-version)$|^tsconfig[^/]*\.json$|^(vite|vitest|playwright|eslint|react-router|doctor|knip|prettier|stylelint)\.config\.|^\.github/workflows/tests\.yml$'
  NO_COMPILER_TESTS_PATTERN='^apps/web/(app|test)/|^apps/web/\.playwright/|^apps/web/\.storybook/|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|\.npmrc|\.node-version)$|^apps/web/package\.json$|^apps/web/tsconfig[^/]*\.json$|^apps/web/dev-ports[^/]*\.ts$|^apps/web/components\.json$|^apps/web/(vite|vitest|playwright|eslint|react-router|doctor|knip|prettier|stylelint)\.config\.|^\.gaia/packages\.json$|^apps/web/gaia\.package\.json$|^\.github/workflows/tests\.yml$'
  OLD_CHROMATIC_GLOBS="app/**
.storybook/**
public/**
package.json
pnpm-lock.yaml
tsconfig*.json
vite.config.*
.github/workflows/chromatic.yml
.github/actions/**"
  BARE_PATH_ERE="(path|working-directory|storybookBuildDir|externals):[[:space:]]*['\"]?(\./)?(\.playwright|storybook-static|app)(/|['\"]?[[:space:]]*$)"
}

tests_pattern() {
  sed -n "s/^[[:space:]]*pattern='\(.*\)'[[:space:]]*$/\1/p" "$TESTS_YML"
}

# The quoted entries of the `code:` list inside the paths-filter `filters:` block.
chromatic_globs() {
  awk '
    /^[[:space:]]+code:[[:space:]]*$/ { in_code = 1; next }
    in_code && /^[[:space:]]*-[[:space:]]*'"'"'/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*'"'"'/, "", line)
      sub(/'"'"'[[:space:]]*$/, "", line)
      print line
      next
    }
    in_code && /^[[:space:]]*#/ { next }
    in_code { in_code = 0 }
  ' "$CHROMATIC_YML"
}

# Prints "select" or "skip" for one path against a newline-separated glob list.
# picomatch (dorny/paths-filter's matcher, dot:true) when a copy sits in a
# node_modules tree; otherwise node:path matchesGlob, which agrees on every
# glob used here.
glob_verdict() {
  local globs="$1" candidate="$2" picomatch_path
  # gaia-lint-ignore whole-tree-mark-guard: the find reads installed node_modules trees, which are not the tracked tree
  picomatch_path="$(find "$REPO_ROOT/node_modules" "$REPO_ROOT/apps/web/node_modules" "$REPO_ROOT/.gaia/cli/node_modules" \
    -path '*/picomatch/index.js' -not -path '*/test/*' 2>/dev/null | head -n 1)"
  GLOBS="$globs" CANDIDATE="$candidate" PICOMATCH="$picomatch_path" node -e '
    const globs = process.env.GLOBS.split("\n").filter(Boolean);
    const candidate = process.env.CANDIDATE;
    let hit;
    if (process.env.PICOMATCH) {
      const picomatch = require(process.env.PICOMATCH);
      hit = globs.some((glob) => picomatch(glob, { dot: true })(candidate));
    } else {
      hit = globs.some((glob) => require("node:path").matchesGlob(candidate, glob));
    }
    process.stdout.write(hit ? "select" : "skip");
  '
}

tests_verdict() {
  if printf '%s\n' "$2" | grep -qE "$1"; then printf 'select'; else printf 'skip'; fi
}

@test "tests.yml: the extracted pattern is non-empty" {
  [ -n "$(tests_pattern)" ]
}

@test "tests.yml: frontend app, e2e, manifest and lockfile changes select" {
  local pattern candidate
  pattern="$(tests_pattern)"
  for candidate in apps/web/app/routes/x.tsx apps/web/.playwright/a.spec.ts apps/web/package.json pnpm-lock.yaml \
    apps/web/test/a.test.ts apps/web/vite.config.ts apps/web/gaia.package.json .gaia/packages.json \
    apps/web/dev-ports.ts apps/web/dev-ports-vite-plugin.ts apps/web/dev-ports-reuse.ts \
    apps/web/react-compiler.config.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "tests.yml: harness, wiki and the retired root app/ skip" {
  local pattern candidate
  pattern="$(tests_pattern)"
  for candidate in wiki/a.md .claude/rules/a.md .gaia/scripts/a.sh app/x.tsx .playwright/a.spec.ts test/a.test.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "tests.yml: the pre-move pattern skips apps/web/app (the guard can fail)" {
  [ "$(tests_verdict "$OLD_TESTS_PATTERN" apps/web/app/routes/x.tsx)" = skip ]
}

@test "tests.yml: the pattern without react-compiler skips the compiler config (the guard can fail)" {
  [ "$(tests_verdict "$NO_COMPILER_TESTS_PATTERN" apps/web/react-compiler.config.ts)" = skip ]
}

@test "chromatic.yml: extracted globs include the descriptor entries" {
  local globs
  globs="$(chromatic_globs)"
  printf '%s\n' "$globs" | grep -qxF 'apps/web/app/**'
  printf '%s\n' "$globs" | grep -qxF 'apps/web/gaia.package.json'
  printf '%s\n' "$globs" | grep -qxF '.gaia/packages.json'
  printf '%s\n' "$globs" | grep -qxF '.github/actions/**'
}

@test "chromatic.yml: frontend storybook inputs and the setup action select" {
  local globs candidate
  globs="$(chromatic_globs)"
  for candidate in apps/web/app/components/X/index.tsx apps/web/public/a.png apps/web/vite.config.ts apps/web/tsconfig.json \
    apps/web/react-compiler.config.ts apps/web/.storybook/main.ts apps/web/package.json pnpm-workspace.yaml .github/actions/gaia-setup-node/action.yml; do
    [ "$(glob_verdict "$globs" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "chromatic.yml: the globs without react-compiler skip the compiler config (the guard can fail)" {
  local globs
  globs="$(chromatic_globs | grep -vxF 'apps/web/react-compiler.config.*')"
  [ "$(glob_verdict "$globs" apps/web/react-compiler.config.ts)" = skip ]
}

@test "chromatic.yml: wiki and the retired root app/ skip" {
  local globs candidate
  globs="$(chromatic_globs)"
  for candidate in wiki/a.md app/x.tsx public/a.png .storybook/main.ts; do
    [ "$(glob_verdict "$globs" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "chromatic.yml: the pre-move globs skip apps/web/app (the guard can fail)" {
  [ "$(glob_verdict "$OLD_CHROMATIC_GLOBS" apps/web/app/components/X/index.tsx)" = skip ]
}

# Every path-bearing key in both workflows resolves under apps/web/, or is the
# one root workspace lockfile.
@test "workflows: no bare app/, .playwright/ or storybook-static reference" {
  local offenders
  offenders="$(grep -nE "$BARE_PATH_ERE" \
    "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
  # Shell-line uses of the build output and the playwright runner.
  offenders="$(grep -nE "(^|[[:space:]])(-d |-rl '[^']*' )storybook-static|run: pnpm exec (playwright|storybook)" "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
}

@test "workflows: artifact, build dir and externals resolve under apps/web/" {
  grep -qE "^[[:space:]]+path: apps/web/\.playwright/output$" "$TESTS_YML"
  grep -qE "storybookBuildDir: 'apps/web/storybook-static'" "$CHROMATIC_YML"
  grep -qE "externals: 'apps/web/app/styles/tailwind\.css'" "$CHROMATIC_YML"
  grep -qE "pnpm -C apps/web exec playwright test" "$TESTS_YML"
  grep -qE "pnpm -C apps/web exec storybook build" "$CHROMATIC_YML"
}

@test "workflows: the bare-path assertion can fail (it flags a pre-move value)" {
  local scratch
  scratch="$BATS_TEST_TMPDIR/old.yml"
  printf '          path: .playwright/output\n          storybookBuildDir: '"'"'storybook-static'"'"'\n' > "$scratch"
  run grep -nE "$BARE_PATH_ERE" "$scratch"
  [ "$status" -eq 0 ]
}

@test "gaia-setup-node: cache-dependency-path stays the single root lockfile" {
  run grep -nE 'cache-dependency-path:[[:space:]]*apps/web/' "$REPO_ROOT/.github/actions/gaia-setup-node/action.yml" "$TESTS_YML" "$CHROMATIC_YML"
  [ "$status" -eq 1 ]
}

# The quoted entries of one job's `code:` filter list in a workflow file. The
# job is named by its two-space-indented key, so a sibling job's identical
# entry never answers for it.
workflow_job_globs() {
  local workflow="$1" job="$2"
  awk -v job="$job" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($1 == job ":"); in_code = 0; next }
    in_job && /^[[:space:]]+code:[[:space:]]*$/ { in_code = 1; next }
    in_job && in_code && /^[[:space:]]*-[[:space:]]*'"'"'/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*'"'"'/, "", line)
      sub(/'"'"'[[:space:]]*$/, "", line)
      print line
      next
    }
    in_job && in_code && /^[[:space:]]*#/ { next }
    in_job && in_code { in_code = 0 }
  ' "$workflow"
}

# Writes the workflow to $4 with one job's `code:` entry for glob $3 removed.
workflow_without_job_glob() {
  local workflow="$1" job="$2" glob="$3" destination="$4"
  awk -v job="$job" -v drop="- '$glob'" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($1 == job ":") }
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    in_job && line == drop { next }
    { print }
  ' "$workflow" > "$destination"
}

@test "distribution-harness.yml: a root lockfile-only change arms the distribution job" {
  local globs
  globs="$(workflow_job_globs "$REPO_ROOT/.github/workflows/distribution-harness.yml" distribution-harness)"
  [ -n "$globs" ]
  [ "$(glob_verdict "$globs" pnpm-lock.yaml)" = select ]
  [ "$(glob_verdict "$globs" pnpm-workspace.yaml)" = select ]
}

@test "cli-tests.yml: a root lockfile-only change arms the required CLI job" {
  local globs
  globs="$(workflow_job_globs "$REPO_ROOT/.github/workflows/cli-tests.yml" cli-tests)"
  [ -n "$globs" ]
  [ "$(glob_verdict "$globs" pnpm-lock.yaml)" = select ]
  [ "$(glob_verdict "$globs" pnpm-workspace.yaml)" = select ]
}

@test "distribution-harness.yml: the distribution job without the lockfile line skips a lockfile-only change (the guard can fail)" {
  local scratch="$BATS_TEST_TMPDIR/distribution-harness.yml" globs
  workflow_without_job_glob "$REPO_ROOT/.github/workflows/distribution-harness.yml" distribution-harness pnpm-lock.yaml "$scratch"
  globs="$(workflow_job_globs "$scratch" distribution-harness)"
  [ -n "$globs" ]
  [ "$(glob_verdict "$globs" pnpm-lock.yaml)" = skip ]
}

# The values the composite's install steps compare `inputs.install` against,
# one per line, sorted.
composite_install_modes() {
  grep -oE "inputs\.install == '[a-z]+'" "$1" | sed "s/.*== '\\([a-z]*\\)'/\\1/" | sort -u
}

# The `run:` command of the composite step armed by the `cli` install mode.
composite_cli_command() {
  awk '
    /if: inputs\.install == .cli./ { armed = 1; next }
    armed && /^[[:space:]]+run:/ { sub(/^[[:space:]]+run:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

composite_is_single_root_install() {
  local action="$1" command
  [ "$(composite_install_modes "$action")" = "$(printf 'cli\nroot')" ] || return 1
  command="$(composite_cli_command "$action")"
  case "$command" in *--filter*) ;; *) return 1 ;; esac
  case "$command" in *--frozen-lockfile*) ;; *) return 1 ;; esac
  case "$command" in *'-C .gaia/cli'*) return 1 ;; esac
  return 0
}

@test "gaia-setup-node: install takes root and cli only, and cli is a filtered frozen root install" {
  composite_is_single_root_install "$REPO_ROOT/.github/actions/gaia-setup-node/action.yml"
}

@test "gaia-setup-node: restoring the second-root install step fails the composite guard (the guard can fail)" {
  local scratch="$BATS_TEST_TMPDIR/action.yml"
  local second_root_install="pnpm -C .gaia/""cli install --frozen-lockfile"
  local retired_mode="inputs.install == '""both'"
  sed "/if: inputs.install == 'cli'/{n;n;s|run: .*|run: $second_root_install|;}" \
    "$REPO_ROOT/.github/actions/gaia-setup-node/action.yml" > "$scratch"
  run composite_is_single_root_install "$scratch"
  [ "$status" -ne 0 ]
  # A restored `both` arm alone also fails it.
  sed "s/if: inputs.install == 'root'/if: inputs.install == 'root' || $retired_mode/" \
    "$REPO_ROOT/.github/actions/gaia-setup-node/action.yml" > "$scratch"
  run composite_is_single_root_install "$scratch"
  [ "$status" -ne 0 ]
}
