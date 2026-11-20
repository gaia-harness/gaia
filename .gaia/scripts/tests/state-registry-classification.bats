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

@test "classify maps registry paths exactly: context readings, settings.json, checkpoint-override and their .bak siblings" {
  make_registry_repo
  run jq -r '.entries[] | select(.path == "protected/checkpoint-override.json") | .id' "$REAL_REGISTRY"
  [ "$output" = "checkpoint-override" ]
  local row path expected
  for row in \
    "cache/shared/context/abc.json|shared" \
    "cache/shared/update-check.json|shared" \
    "settings.json|shared" \
    "settings.json.bak|unknown" \
    "protected/checkpoint-override.json|shared" \
    "protected/checkpoint-override.json.bak|unknown"; do
    path="${row%%|*}"
    expected="${row#*|}"
    classify "$path"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    [ "$output" = "$expected" ] || { echo "row $row: got '$output'"; return 1; }
  done

  # Give the context row a scope no other row has, so reaching it, rather than
  # the cache-shared row, is observable.
  jq '(.entries[] | select(.id == "context-readings") | .scope) = "per-tree"' "$REGISTRY_FILE" >"$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "cache/shared/context/abc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "per-tree" ]
  classify "cache/shared/update-check.json"
  [ "$output" = "shared" ]
}
