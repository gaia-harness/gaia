#!/usr/bin/env bash
# Builds the crossed monorepo fixture: a 2.3.1-shaped project that the real
# `crossing` verbs have carried across to the workspace standard layout. Sourced
# by suites; defines functions only and does nothing at source time.
#
# The tree starts keyed on the old app root with a second app, an API app, three
# libraries and an infrastructure member, each registered with a descriptor that
# loads at 2.3.1 (every glob list non-empty, since that release refuses an empty
# one). The helper then runs `crossing preflight`, `crossing move` and
# `crossing roster` from the binary the caller names, so nothing the crossing
# writes (the registry, the web stack on the descriptor, the opt-in on the API
# app, the infrastructure claim, the roster edits) is stood in for by a copy.
# After the crossing it empties one library's glob lists, for the empty-list
# cases.
#
# CALLER CONTRACT
#   CROSSED_FIXTURE_GAIA   Path to an executable `gaia`. Falls back to
#                          GAIA_CROSSING_CLI. Required: with neither set the
#                          build fails rather than guessing a binary.
#
#   crossed_fixture_build <dir> [<web name>]
#       <dir> must not exist. The web member's name defaults to `frontend`,
#       which the crossing renames to `web` at apps/web. A given name is kept by
#       the crossing, and the finished tree then places that member at
#       apps/<name>. Prints nothing on success and sets, in the caller's shell:
#         CROSSED_WEB_NAME  CROSSED_WEB_PATH
#       Returns non-zero at the first failing step, names the step on stderr and
#       removes <dir>, so a partial tree can never be mistaken for the fixture.
#
# Member names are generic on purpose. Lives under .gaia/tests/, so it never
# ships.

# _crossed_fixture_fail <dir> <message>: report, remove the partial tree, fail.
_crossed_fixture_fail() {
  printf 'crossed-fixture: %s\n' "$2" >&2
  rm -rf "$1"
  return 1
}

# _crossed_fixture_descriptor <file> <name>: a descriptor that loads at 2.3.1.
_crossed_fixture_descriptor() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<EOF
{
  "schemaVersion": 1,
  "name": "$2",
  "globs": {
    "tddUnitTests": ["src/**/*.test.ts"],
    "tddStrictCandidates": ["src/lib/**"],
    "emergentTests": ["src/**/*.spec.ts"],
    "preCommitSource": ["src/**", "app/**"],
    "doctorConfigs": ["doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": {
    "sourcePaths": ["src/", "app/"],
    "inventoryPaths": ["src/generated/"],
    "flowPaths": ["src/flows/"]
  }
}
EOF
}

# _crossed_fixture_member <dir> <path> <name>: package.json, descriptor and a
# source file for one member.
_crossed_fixture_member() {
  local root="$1" member_path="$2" name="$3"
  mkdir -p "$root/$member_path/src"
  printf '{\n  "name": "%s",\n  "private": true\n}\n' "$name" >"$root/$member_path/package.json"
  printf 'export const value = 1;\n' >"$root/$member_path/src/index.ts"
  _crossed_fixture_descriptor "$root/$member_path/gaia.package.json" "$name"
}

# _crossed_fixture_crossing <dir> <verb>: one real crossing verb, from <dir>.
_crossed_fixture_crossing() {
  local root="$1" verb="$2" log
  log="$1/../.crossed-fixture-$(basename "$1")-$2.log"
  if ! (cd "$root" && "$_CROSSED_FIXTURE_CLI" update crossing "$verb") >"$log" 2>&1; then
    local detail
    detail="$(head -c 600 "$log" 2>/dev/null || true)"
    rm -f "$log"
    _crossed_fixture_fail "$root" "crossing $verb failed: $detail"
    return 1
  fi
  rm -f "$log"
}

crossed_fixture_build() {
  local root="${1:-}" web_name="${2:-frontend}" legacy=frontend
  _CROSSED_FIXTURE_CLI="${CROSSED_FIXTURE_GAIA:-${GAIA_CROSSING_CLI:-}}"

  [ -n "$root" ] || { printf 'crossed-fixture: a target directory is required\n' >&2; return 1; }
  [ ! -e "$root" ] || { printf 'crossed-fixture: %s already exists\n' "$root" >&2; return 1; }
  if [ -z "$_CROSSED_FIXTURE_CLI" ] || [ ! -x "$_CROSSED_FIXTURE_CLI" ]; then
    printf 'crossed-fixture: set CROSSED_FIXTURE_GAIA to an executable gaia\n' >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'crossed-fixture: jq is required\n' >&2; return 1; }

  mkdir -p "$root/.gaia" || return 1
  _crossed_fixture_git_init "$root" || { _crossed_fixture_fail "$root" 'git init failed'; return 1; }

  # The app at the old root: language files and a components folder for the
  # scaffolders, a heading for the rename step.
  mkdir -p "$root/$legacy/app/components" "$root/$legacy/app/languages/en"
  printf '{\n  "name": "%s",\n  "private": true\n}\n' "$web_name" >"$root/$legacy/package.json"
  printf 'export const index = 1;\n' >"$root/$legacy/app/index.ts"
  : >"$root/$legacy/app/components/.gitkeep"
  printf "export default {\n  siteName: 'Placeholder',\n};\n" >"$root/$legacy/app/languages/en/common.ts"
  _crossed_fixture_descriptor "$root/$legacy/gaia.package.json" "$web_name"

  _crossed_fixture_member "$root" apps/mobile mobile
  _crossed_fixture_member "$root" apps/api api
  _crossed_fixture_member "$root" packages/kit kit
  _crossed_fixture_member "$root" packages/shared shared
  _crossed_fixture_member "$root" packages/tokens tokens
  _crossed_fixture_member "$root" infra infra
  # An API app with its own Claude settings file is the one the crossing opts in.
  mkdir -p "$root/apps/api/.claude"
  printf '{}\n' >"$root/apps/api/.claude/settings.json"

  printf '# Project\n' >"$root/CLAUDE.md"
  printf '{\n  "name": "project",\n  "private": true\n}\n' >"$root/package.json"
  printf '.gaia/local\n.notebook\nnode_modules\n' >"$root/.gitignore"
  jq -n --arg web "$web_name" '[
    {name: $web, path: "frontend"},
    {name: "mobile", path: "apps/mobile"},
    {name: "api", path: "apps/api"},
    {name: "kit", path: "packages/kit"},
    {name: "shared", path: "packages/shared"},
    {name: "tokens", path: "packages/tokens"},
    {name: "infra", path: "infra"}
  ]' >"$root/.gaia/packages.json"
  printf 'packages:\n  - %s\n  - apps/mobile\n  - apps/api\n  - packages/kit\n  - packages/shared\n  - packages/tokens\n  - infra\n  - .gaia/cli\n' \
    "$legacy" >"$root/pnpm-workspace.yaml"
  printf 'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "%s/app/**"\n      - "package.json"\n    audience: adopter\n    default: true\nunowned:\n  - "apps/mobile/**"\n  - "packages/**"\n  - "*.md"\n' \
    "$legacy" >"$root/.gaia/audit-ci.yml"
  jq -n --arg k "$legacy/app/index.ts" '{files: {($k): "owned", ".gaia/VERSION": "owned"}, version: "2.3.1"}' \
    >"$root/.gaia/manifest.json"
  printf '2.3.1\n' >"$root/.gaia/VERSION"

  _crossed_fixture_commit "$root" 'seed' || { _crossed_fixture_fail "$root" 'seed commit failed'; return 1; }

  _crossed_fixture_crossing "$root" preflight || return 1
  _crossed_fixture_crossing "$root" move || return 1
  _crossed_fixture_commit "$root" 'move' || { _crossed_fixture_fail "$root" 'move commit failed'; return 1; }
  _crossed_fixture_crossing "$root" roster || return 1
  _crossed_fixture_commit "$root" 'roster' || { _crossed_fixture_fail "$root" 'roster commit failed'; return 1; }

  CROSSED_WEB_NAME="$(jq -r '.[0].name' "$root/.gaia/packages.json")"
  CROSSED_WEB_PATH="$(jq -r '.[0].path' "$root/.gaia/packages.json")"
  [ -d "$root/$CROSSED_WEB_PATH" ] || { _crossed_fixture_fail "$root" "the crossing left no app at $CROSSED_WEB_PATH"; return 1; }

  # A kept name lives at apps/<name>, which is where an adopter who named the
  # app puts it.
  if [ "$CROSSED_WEB_NAME" != web ] && [ "$CROSSED_WEB_PATH" = apps/web ]; then
    git -C "$root" mv apps/web "apps/$CROSSED_WEB_NAME" || { _crossed_fixture_fail "$root" 'relocating the web member failed'; return 1; }
    if ! {
      jq --arg name "$CROSSED_WEB_NAME" '(.[] | select(.name == $name) | .path) = "apps/" + $name' \
        "$root/.gaia/packages.json" >"$root/.gaia/packages.json.next" \
        && mv "$root/.gaia/packages.json.next" "$root/.gaia/packages.json"
    }; then
      _crossed_fixture_fail "$root" 'rewriting the registry failed'
      return 1
    fi
    CROSSED_WEB_PATH="apps/$CROSSED_WEB_NAME"
  fi

  # The library with nothing to glob: every list empty, which the readers accept.
  if ! {
    jq '.globs |= map_values([]) | .wiki |= map_values([])' "$root/packages/kit/gaia.package.json" \
      >"$root/packages/kit/gaia.package.json.next" \
      && mv "$root/packages/kit/gaia.package.json.next" "$root/packages/kit/gaia.package.json"
  }; then
    _crossed_fixture_fail "$root" 'emptying the library globs failed'
    return 1
  fi
  _crossed_fixture_commit "$root" 'settle' || { _crossed_fixture_fail "$root" 'final commit failed'; return 1; }
}

_crossed_fixture_git_init() {
  git -C "$1" init -q -b main \
    && git -C "$1" config user.email crossed@example.com \
    && git -C "$1" config user.name Crossed \
    && git -C "$1" config commit.gpgsign false \
    && git -C "$1" config core.hooksPath /dev/null
}

_crossed_fixture_commit() {
  git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m "$2"
}
