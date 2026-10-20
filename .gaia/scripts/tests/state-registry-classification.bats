#!/usr/bin/env bats
#
# State-registry classification of specific .gaia/local paths: the context
# readings, local settings, the checkpoint override and the audit-loop state.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/state-registry-classification.bats < /dev/null
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_REGISTRY="$(cd "$SCRIPTS_DIRECTORY/.." && pwd)/state-registry.json"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
}

# ---------- registry rows ----------

# make_registry_repo: a fixture repo whose main-root registry is a scratch copy
# of the real one, with the lib beside it. Sets REGISTRY_REPO and REGISTRY_FILE.
make_registry_repo() {
  REGISTRY_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/reg.XXXXXX")"
  REGISTRY_REPO="$(cd "$REGISTRY_REPO" && pwd -P)"
  mkdir -p "$REGISTRY_REPO/.gaia/scripts"
  cp "$SCRIPTS_DIRECTORY/state-registry-lib.sh" "$SCRIPTS_DIRECTORY/main-root-lib.sh" "$REGISTRY_REPO/.gaia/scripts/"
  cp "$REAL_REGISTRY" "$REGISTRY_REPO/.gaia/state-registry.json"
  REGISTRY_FILE="$REGISTRY_REPO/.gaia/state-registry.json"
  git -C "$REGISTRY_REPO" init -q
}

classify() {
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify "$2"' _ "$REGISTRY_REPO" "$1"
}

@test "registry: a context file classifies via the context-readings row, not cache-shared" {
  make_registry_repo
  # Give the new row a scope no other row has, so reaching it is observable.
  jq '(.entries[] | select(.id == "context-readings") | .scope) = "per-tree"' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "cache/shared/context/abc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "per-tree" ]
  classify "cache/shared/update-check.json"
  [ "$output" = "shared" ]
}

@test "registry: the real registry classifies a context file and the update cache as shared" {
  make_registry_repo
  classify "cache/shared/context/abc.json"
  [ "$output" = "shared" ]
  classify "cache/shared/update-check.json"
  [ "$output" = "shared" ]
}

@test "registry: settings.json maps to local-settings exactly, settings.json.bak does not" {
  make_registry_repo
  classify "settings.json"
  [ "$output" = "shared" ]
  classify "settings.json.bak"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the local-settings row settings.json classifies unknown" {
  make_registry_repo
  jq '.entries |= map(select(.id != "local-settings"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "settings.json"
  [ "$output" = "unknown" ]
}

@test "registry: protected/checkpoint-override.json maps to checkpoint-override exactly, its .bak sibling does not" {
  make_registry_repo
  run jq -r '.entries[] | select(.path == "protected/checkpoint-override.json") | .id' "$REAL_REGISTRY"
  [ "$output" = "checkpoint-override" ]
  classify "protected/checkpoint-override.json"
  [ "$output" = "shared" ]
  classify "protected/checkpoint-override.json.bak"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the checkpoint-override row protected/checkpoint-override.json classifies unknown" {
  make_registry_repo
  jq '.entries |= map(select(.id != "checkpoint-override"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "protected/checkpoint-override.json"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the audit-loop-state row a protected/audit-loop state file classifies unknown" {
  make_registry_repo
  classify "protected/audit-loop/feat/x.json"
  [ "$output" = "main-only" ]
  jq '.entries |= map(select(.id != "audit-loop-state"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "protected/audit-loop/feat/x.json"
  [ "$output" = "unknown" ]
}
