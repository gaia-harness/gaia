#!/usr/bin/env bats
#
# SPEC-092 UAT-019: the shipped CI path filters select the app's files under
# apps/web/ and skip the retired root forms. A filter that still reads root
# `app/` reports a required check green without running anything.
#
#   tests.yml     the ERE in `pattern='...'` (matched with grep -E)
#   chromatic.yml the dorny/paths-filter `code:` globs (picomatch semantics)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_YML="$REPO_ROOT/.github/workflows/tests.yml"
  CHROMATIC_YML="$REPO_ROOT/.github/workflows/chromatic.yml"
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

@test "tests.yml: the path filter selects the frontend app, e2e, manifest and lockfile and skips harness, wiki and a bare root app/" {
  local pattern candidate
  pattern="$(tests_pattern)"
  [ -n "$pattern" ] || return 1
  for candidate in apps/web/app/routes/x.tsx apps/web/.playwright/a.spec.ts apps/web/package.json pnpm-lock.yaml \
    apps/web/test/a.test.ts apps/web/vite.config.ts apps/web/gaia.package.json .gaia/packages.json \
    apps/web/dev-ports.ts apps/web/dev-ports-vite-plugin.ts apps/web/dev-ports-reuse.ts \
    apps/web/react-compiler.config.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
  for candidate in wiki/a.md .claude/rules/a.md .gaia/scripts/a.sh app/x.tsx .playwright/a.spec.ts test/a.test.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "chromatic.yml: the code filter lists the descriptor entries, selects storybook inputs and the setup action, and skips wiki and a bare root app/" {
  local globs candidate
  globs="$(chromatic_globs)"
  printf '%s\n' "$globs" | grep -qxF 'apps/web/app/**' || return 1
  printf '%s\n' "$globs" | grep -qxF 'apps/web/gaia.package.json' || return 1
  printf '%s\n' "$globs" | grep -qxF '.gaia/packages.json' || return 1
  printf '%s\n' "$globs" | grep -qxF '.github/actions/**' || return 1
  for candidate in apps/web/app/components/X/index.tsx apps/web/public/a.png apps/web/vite.config.ts apps/web/tsconfig.json \
    apps/web/react-compiler.config.ts apps/web/.storybook/main.ts apps/web/package.json pnpm-workspace.yaml .github/actions/gaia-setup-node/action.yml; do
    [ "$(glob_verdict "$globs" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
  for candidate in wiki/a.md app/x.tsx public/a.png .storybook/main.ts; do
    [ "$(glob_verdict "$globs" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

# Every path-bearing key in both workflows resolves under apps/web/, or is the
# one root workspace lockfile.
@test "workflows: every path, build dir, artifact and external resolves under apps/web/, never a bare app/, .playwright/ or storybook-static" {
  local offenders
  offenders="$(grep -nE "$BARE_PATH_ERE" \
    "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
  # Shell-line uses of the build output and the playwright runner.
  offenders="$(grep -nE "(^|[[:space:]])(-d |-rl '[^']*' )storybook-static|run: pnpm exec (playwright|storybook)" "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
  grep -qE "^[[:space:]]+path: apps/web/\.playwright/output$" "$TESTS_YML" || return 1
  grep -qE "storybookBuildDir: 'apps/web/storybook-static'" "$CHROMATIC_YML" || return 1
  grep -qE "externals: 'apps/web/app/styles/tailwind\.css'" "$CHROMATIC_YML" || return 1
  grep -qE "pnpm -C apps/web exec playwright test" "$TESTS_YML" || return 1
  grep -qE "pnpm -C apps/web exec storybook build" "$CHROMATIC_YML"
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

@test "a root lockfile-only change arms the distribution job and the required CLI job" {
  local row workflow job globs
  for row in "distribution-harness.yml|distribution-harness" "cli-tests.yml|cli-tests"; do
    workflow=${row%%|*}; job=${row#*|}
    globs="$(workflow_job_globs "$REPO_ROOT/.github/workflows/$workflow" "$job")"
    [ -n "$globs" ] || { echo "row $row: no code globs"; return 1; }
    [ "$(glob_verdict "$globs" pnpm-lock.yaml)" = select ] || { echo "row $row: pnpm-lock.yaml not selected"; return 1; }
    [ "$(glob_verdict "$globs" pnpm-workspace.yaml)" = select ] || { echo "row $row: pnpm-workspace.yaml not selected"; return 1; }
  done
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
