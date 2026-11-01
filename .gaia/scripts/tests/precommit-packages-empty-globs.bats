#!/usr/bin/env bats
# .gaia/scripts/precommit-packages.sh for a member whose preCommitSource list is
# empty: any staged path inside the member plans it, a path outside every member
# plans none, and a member with a non-empty list keeps its narrower match.
# Registry and descriptors are written literally into a sandbox repo.
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REPO="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/precommit-empty.XXXXXX")" && pwd -P)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" >"$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"
}

# write_member <name> <path> <preCommitSource-json>
write_member() {
  mkdir -p "$REPO/$2"
  cat >"$REPO/$2/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "$1",
  "globs": {
    "tddUnitTests": [],
    "tddStrictCandidates": [],
    "emergentTests": [],
    "preCommitSource": $3,
    "doctorConfigs": [],
    "dependencyManifests": []
  },
  "wiki": { "sourcePaths": [], "inventoryPaths": [], "flowPaths": [] }
}
JSON
}

stage_and_plan() {
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    printf '// %s\n' "$path" >"$REPO/$path"
    git -C "$REPO" add -- "$path"
  done
  run bash "$REPO/.gaia/scripts/precommit-packages.sh" "$REPO"
}

@test "a staged path in a member with an empty list plans that member" {
  printf '[{"name":"lib","path":"packages/lib"}]\n' >"$REPO/.gaia/packages.json"
  write_member lib packages/lib '[]'
  stage_and_plan packages/lib/src/deep/value.ts
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tpackages/lib' ]
}

@test "a path outside every member plans none" {
  printf '[{"name":"lib","path":"packages/lib"}]\n' >"$REPO/.gaia/packages.json"
  write_member lib packages/lib '[]'
  stage_and_plan docs/value.ts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a member with a non-empty list keeps its narrower match beside an empty-list member" {
  printf '[{"name":"lib","path":"packages/lib"},{"name":"web","path":"apps/web"}]\n' >"$REPO/.gaia/packages.json"
  write_member lib packages/lib '[]'
  write_member web apps/web '["app/**"]'
  stage_and_plan apps/web/notes/readme.ts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  stage_and_plan apps/web/app/value.ts packages/lib/x.ts
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tapps/web\npackage\tpackages/lib' ] || [ "$output" = $'package\tpackages/lib\npackage\tapps/web' ]
}
