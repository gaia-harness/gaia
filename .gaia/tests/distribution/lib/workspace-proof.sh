#!/usr/bin/env bash
# Helpers for the scenarios that run the staged bundle's own machinery against a
# small multi-member project (20, 21). Sourced after lib.sh and
# crossed-fixture.sh; defines functions only.
#
# API:
#   proof_tool_bin                    - installs the staged scaffold and prints
#                                       its directory of tsc and vitest, or fails
#   proof_install_machinery STAGING DIR
#                                     - copies the staged hooks, scripts, agents
#                                       and audit libraries into DIR and commits
#   proof_enable_hooks DIR HOOKS_DIR  - points DIR's commits at its own pre-commit
#                                       hook through a wrapper kept in HOOKS_DIR
#   proof_member DIR PATH NAME        - a member: package.json, descriptor, source
#   proof_write_registry DIR NAME=PATH...
#                                     - writes .gaia/packages.json

# The tools come from an install of the staged scaffold, never the checkout's
# node_modules, which a CI runner does not install. The fixture tree itself
# stays uninstalled, so its members' scripts run only these binaries.
proof_tool_bin() {
  local tool_directory="$SCAFFOLD/apps/web/node_modules/.bin"
  run_logged "pnpm install --frozen-lockfile (scaffold tools)" "$WORK/tools-install.log" \
    pnpm -C "$SCAFFOLD" install --frozen-lockfile
  [ -x "$tool_directory/tsc" ] && [ -x "$tool_directory/vitest" ] \
    || { fail "the scaffold install left no tsc and vitest at $tool_directory"; return 1; }
  printf '%s' "$tool_directory"
}

proof_install_machinery() {
  local staging="$1" dir="$2" path
  mkdir -p "$dir/.claude" "$dir/.github" "$dir/.gaia"
  for path in .githooks .claude/hooks .claude/agents .gaia/scripts .github/audit; do
    [ ! -e "$staging/$path" ] || { rm -rf "${dir:?}/$path"; cp -R "$staging/$path" "$dir/$path"; }
  done
  _crossed_fixture_commit "$dir" 'machinery'
}

# Only the pre-commit hook is armed: the commit-msg hook needs an installed
# commitlint, which a scratch tree has no reason to carry. The wrapper execs the
# staged hook by its own path, so the hook still finds its sibling scripts.
proof_enable_hooks() {
  local dir="$1" hooks_directory="$2"
  mkdir -p "$hooks_directory"
  printf '#!/bin/sh\nexec "%s/.githooks/pre-commit" "$@"\n' "$dir" >"$hooks_directory/pre-commit"
  chmod +x "$hooks_directory/pre-commit"
  git -C "$dir" config core.hooksPath "$hooks_directory"
}

proof_member() {
  local dir="$1" member_path="$2" name="$3"
  mkdir -p "$dir/$member_path/src"
  printf '{\n  "name": "%s",\n  "private": true\n}\n' "$name" >"$dir/$member_path/package.json"
  printf 'export const value: number = 1;\n' >"$dir/$member_path/src/index.ts"
  _crossed_fixture_descriptor "$dir/$member_path/gaia.package.json" "$name"
}

proof_write_registry() {
  local dir="$1" pair entries=()
  shift
  for pair in "$@"; do
    entries+=("{\"name\":\"${pair%%=*}\",\"path\":\"${pair#*=}\"}")
  done
  mkdir -p "$dir/.gaia"
  printf '[%s]\n' "$(IFS=,; printf '%s' "${entries[*]}")" >"$dir/.gaia/packages.json"
}
