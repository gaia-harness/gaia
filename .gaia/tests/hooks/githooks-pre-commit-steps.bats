#!/usr/bin/env bats
# The step selection of .githooks/pre-commit: a member runs only the gate steps
# it defines, in order, and a defined step that fails still stops the commit.
#
# Unlike githooks-pre-commit.bats this suite runs the real `pnpm` in a scratch
# tree built by `mktemp -d` that holds no link into this checkout. The members'
# scripts are stubs that append their name to a log, so no install is needed.
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  # The hook calls pnpm, so a leg without Node fails here by name rather than
  # as a 127 inside the hook; the capture also derives this suite's mark.
  [ -n "$(command -v pnpm)" ] || {
    echo 'pnpm not on PATH: this suite needs a leg that sets up Node (needs_node)' >&2
    return 1
  }
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.githooks/pre-commit"
  REPO=$(cd "$(mktemp -d -t githooks-steps-XXXXXX)" && pwd -P)
  STEP_LOG="$REPO/steps.log"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" >"$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib" "$REPO/node_modules/.bin"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"
  : >"$STEP_LOG"
  printf '#!/bin/sh\necho lint-staged >> "%s"\n' "$STEP_LOG" >"$REPO/node_modules/.bin/lint-staged"
  chmod +x "$REPO/node_modules/.bin/lint-staged"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# write_member <path> <package-json-scripts-object> [extra-top-level-json-members]
# Registers one member named `member` with empty globs, so any staged path in it
# plans the member.
write_member() {
  local member_path="$1" scripts="$2" extra="${3:-}"
  mkdir -p "$REPO/.gaia" "$REPO/$member_path"
  printf '[{"name":"member","path":"%s"}]\n' "$member_path" >"$REPO/.gaia/packages.json"
  cat >"$REPO/$member_path/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "member",
  "globs": {
    "tddUnitTests": [],
    "tddStrictCandidates": [],
    "emergentTests": [],
    "preCommitSource": [],
    "doctorConfigs": [],
    "dependencyManifests": []
  },
  "wiki": { "sourcePaths": [], "inventoryPaths": [], "flowPaths": [] }
}
JSON
  printf '{"name":"member","version":"0.0.0","scripts":%s%s}\n' "$scripts" "$extra" >"$REPO/$member_path/package.json"
}

stage_and_run_hook() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "export const value = 1;" >"$REPO/$path"
  git -C "$REPO" add "$path"
  run env PATH="$PATH" sh -c 'cd "$1" && "$2" </dev/null' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

@test "a member runs only its defined steps in order: typecheck only, all three, a lint-staged config file, a path outside every member" {
  local row label member_path scripts extra lintstaged_rc staged_path expected
  for row in \
    "typecheck only|packages/lib|{\"typecheck\":\"echo typecheck >> '$STEP_LOG'\"}|||packages/lib/src/value.ts|typecheck" \
    "all three in order|apps/web|{\"typecheck\":\"echo typecheck >> '$STEP_LOG'\",\"test:lint-staged\":\"echo test >> '$STEP_LOG'\"}|,\"lint-staged\":{\"*.ts\":\"true\"}||apps/web/src/value.ts|typecheck lint-staged test" \
    "lint-staged config file|apps/web|{\"typecheck\":\"echo typecheck >> '$STEP_LOG'\"}||{\"*.ts\":\"true\"}|apps/web/src/value.ts|typecheck lint-staged" \
    "path outside every member|packages/lib|{\"typecheck\":\"echo typecheck >> '$STEP_LOG'\"}|||docs/note.ts|"; do
    IFS='|' read -r label member_path scripts extra lintstaged_rc staged_path expected <<<"$row"
    # Rows share one scratch repo: unstage the previous row's path and clear the log.
    git -C "$REPO" read-tree HEAD
    rm -f "$REPO/apps/web/.lintstagedrc.json"
    : >"$STEP_LOG"
    write_member "$member_path" "$scripts" "$extra"
    [ -z "$lintstaged_rc" ] || echo "$lintstaged_rc" >"$REPO/$member_path/.lintstagedrc.json"
    stage_and_run_hook "$staged_path"
    [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
    [ "$(tr '\n' ' ' <"$STEP_LOG" | sed 's/ $//')" = "$expected" ] || { echo "case $label: steps=[$(cat "$STEP_LOG")] want [$expected]"; return 1; }
  done
}

# bats test_tags=protected
@test "a type error in a typecheck-only member refuses the commit" {
  write_member packages/lib "{\"typecheck\":\"echo typecheck >> '$STEP_LOG'; exit 1\"}"
  stage_and_run_hook packages/lib/src/value.ts
  [ "$status" -ne 0 ]
  [ "$(cat "$STEP_LOG")" = "typecheck" ]
}

@test "the first failing step stops the later ones" {
  write_member apps/web "{\"typecheck\":\"echo typecheck >> '$STEP_LOG'; exit 1\",\"test:lint-staged\":\"echo test >> '$STEP_LOG'\"}" ',"lint-staged":{"*.ts":"true"}'
  stage_and_run_hook apps/web/src/value.ts
  [ "$status" -ne 0 ]
  [ "$(cat "$STEP_LOG")" = "typecheck" ]
}
