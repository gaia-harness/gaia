#!/usr/bin/env bats
# .gaia/scripts/gate-member-warnings.sh and the recursive root gate scripts.
#
# The warning script runs against literal sandbox workspaces. The root script
# text is read from the live package.json and run, verbatim, in a mktemp -d
# workspace of stub members with no dependencies, so no install happens and
# nothing touches the real checkout. Assertion style per
# .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/gate-member-warnings.sh"
  [ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; return 1; }

  WORKSPACE="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/gate.XXXXXX")" && pwd -P)"
  mkdir -p "$WORKSPACE/.gaia" "$WORKSPACE/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$WORKSPACE/.claude/hooks/lib/"
}

# add_member <name> <test_globs_json> <scripts_json> [file...]
add_member() {
  local name="$1" test_globs="$2" scripts="$3"
  shift 3
  mkdir -p "$WORKSPACE/packages/$name"
  cat > "$WORKSPACE/packages/$name/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "$name",
  "globs": {
    "tddUnitTests": $test_globs,
    "tddStrictCandidates": [],
    "emergentTests": [],
    "preCommitSource": [],
    "doctorConfigs": [],
    "dependencyManifests": ["package.json"]
  },
  "wiki": { "sourcePaths": [], "inventoryPaths": [], "flowPaths": [] }
}
JSON
  printf '{"name":"%s","version":"0.0.0","private":true,"scripts":%s}\n' "$name" "$scripts" \
    > "$WORKSPACE/packages/$name/package.json"
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "$WORKSPACE/packages/$name/$file")"
    : > "$WORKSPACE/packages/$name/$file"
  done
}

write_registry() {
  local entries='' name
  for name in "$@"; do
    entries="${entries:+$entries,}{\"name\":\"$name\",\"path\":\"packages/$name\"}"
  done
  printf '[%s]\n' "$entries" > "$WORKSPACE/.gaia/packages.json"
}

@test "a member with test files and no test:ci draws a warning and exit 0" {
  add_member lib '["src/**/*.test.ts"]' '{}' src/a.test.ts
  write_registry lib
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN lib (packages/lib): has test files and no test:ci"* ]]
}

@test "a member with test files and test:ci draws no warning" {
  add_member lib '["src/**/*.test.ts"]' '{"test:ci":"true","typecheck":"true"}' src/a.test.ts
  write_registry lib
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a member with no test files and no test:ci draws no warning" {
  add_member lib '["src/**/*.test.ts"]' '{}' src/a.js
  write_registry lib
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty tddUnitTests list falls back to test and spec files" {
  add_member lib '[]' '{}' src/b.spec.js
  write_registry lib
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN lib (packages/lib): has test files and no test:ci"* ]]
}

@test "typescript sources without typecheck draw a warning, declaration files alone do not" {
  add_member typed '[]' '{}' src/a.tsx
  add_member declared '[]' '{}' src/types.d.ts
  add_member checked '[]' '{"typecheck":"true"}' src/a.ts
  write_registry typed declared checked
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN typed (packages/typed): has TypeScript sources and no typecheck"* ]]
  [[ "$output" == *"declared"* ]] && return 1
  [[ "$output" == *"checked"* ]] && return 1
  true
}

@test "node_modules content is never counted" {
  add_member lib '[]' '{}' node_modules/dep/x.test.js node_modules/dep/x.ts
  write_registry lib
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a malformed registry exits non-zero with the reader's message" {
  printf 'not json\n' > "$WORKSPACE/.gaia/packages.json"
  run bash "$SCRIPT" "$WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gaia-packages: .gaia/packages.json is malformed"* ]]
}

# scratch_workspace: root scripts copied from the live package.json
scratch_workspace() {
  PNPM_ROOT="$(mktemp -d)"
  printf 'packages:\n  - "m/*"\n' > "$PNPM_ROOT/pnpm-workspace.yaml"
  local script_name root_scripts='{'
  for script_name in typecheck lint test:ci; do
    root_scripts="$root_scripts\"$script_name\":$(jq -c --arg s "$script_name" '.scripts[$s]' "$REPO_ROOT/package.json"),"
  done
  printf '{"name":"root","private":true,"scripts":%s}}\n' "${root_scripts%,}" > "$PNPM_ROOT/package.json"
}

stub_member() {
  local name="$1" scripts="$2"
  mkdir -p "$PNPM_ROOT/m/$name"
  printf '{"name":"%s","version":"0.0.0","private":true,"scripts":%s}\n' "$name" "$scripts" \
    > "$PNPM_ROOT/m/$name/package.json"
}

@test "root typecheck exits non-zero and names every failing member" {
  scratch_workspace
  stub_member alpha '{"typecheck":"echo alpha-type-error >&2; exit 1"}'
  stub_member beta '{"typecheck":"echo beta-type-error >&2; exit 1"}'
  stub_member gamma '{"typecheck":"echo gamma-ok"}'
  run pnpm -C "$PNPM_ROOT" typecheck
  rm -rf "$PNPM_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha-type-error"* ]]
  [[ "$output" == *"beta-type-error"* ]]
}

@test "root test:ci skips a member with no test:ci script" {
  scratch_workspace
  stub_member has '{"test:ci":"echo has-ran"}'
  stub_member lacks '{}'
  run pnpm -C "$PNPM_ROOT" test:ci
  rm -rf "$PNPM_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has-ran"* ]]
}

@test "root test:ci runs members one at a time" {
  scratch_workspace
  stub_member one '{"test:ci":"echo start >> ../trace; sleep 1; echo end >> ../trace"}'
  stub_member two '{"test:ci":"echo start >> ../trace; sleep 1; echo end >> ../trace"}'
  run pnpm -C "$PNPM_ROOT" test:ci
  local trace
  trace="$(tr '\n' ' ' < "$PNPM_ROOT/m/trace")"
  rm -rf "$PNPM_ROOT"
  [ "$status" -eq 0 ]
  [ "$trace" = "start end start end " ]
}
