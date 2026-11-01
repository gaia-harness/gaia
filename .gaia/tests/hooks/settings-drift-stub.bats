#!/usr/bin/env bats
# Generated settings for a mixed workspace: a web member and an opted-in member
# get full generated settings, every other member gets a one-hook warning stub,
# and a hand-written settings file is never touched. The drift check requires
# the file only for the first two and warns, without failing, on a missing or
# edited stub.
#
# The CLI runs from source through a wrapper in the scratch tree, so this suite
# does not depend on the committed bundle being rebuilt. Assertion style:
# .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  TREE=$(cd "$(mktemp -d -t settings-drift-stub-XXXXXX)" && pwd -P)
  mkdir -p "$TREE/.claude/hooks/lib" "$TREE/.gaia/scripts" "$TREE/.gaia/cli"
  cp "$REPO_ROOT/.claude/settings.json" "$TREE/.claude/settings.json"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$TREE/.claude/hooks/lib/"
  cp "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$TREE/.gaia/scripts/"
  printf '#!/bin/sh\nexec "%s" -C "%s/.gaia/cli" exec tsx src/index.ts "$@"\n' "$(command -v pnpm)" "$REPO_ROOT" >"$TREE/.gaia/cli/gaia"
  chmod +x "$TREE/.gaia/cli/gaia"
  printf '[{"name":"web","path":"apps/web"},{"name":"optin","path":"libs/optin"},{"name":"api","path":"apps/api"},{"name":"tool","path":"tools/tool"}]\n' >"$TREE/.gaia/packages.json"
  write_member web apps/web ',"stack":"web"'
  write_member optin libs/optin ',"generatedSettings":true'
  write_member api apps/api ''
  write_member tool tools/tool ''
  mkdir -p "$TREE/tools/tool/.claude"
  printf '{"permissions":{"allow":["Bash(ls)"]}}\n' >"$TREE/tools/tool/.claude/settings.json"
  HAND_WRITTEN_SUM=$(cksum <"$TREE/tools/tool/.claude/settings.json")
}

teardown() {
  [ -n "${TREE:-}" ] && rm -rf "$TREE"
  return 0
}

# write_member <name> <path> <extra-descriptor-members>
write_member() {
  mkdir -p "$TREE/$2"
  cat >"$TREE/$2/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "$1"$3,
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
}

sync_settings() {
  run "$TREE/.gaia/cli/gaia" packages sync-settings --repo-root "$TREE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

run_drift() {
  run bash "$TREE/.gaia/scripts/check-settings-drift.sh" "$TREE"
}

@test "sync gives web and opted-in members full settings, others a single SessionStart hook, and leaves a hand-written file alone" {
  sync_settings
  jq -e '.permissions.additionalDirectories | index("../..") != null' "$TREE/apps/web/.claude/settings.json"
  jq -e '.permissions.additionalDirectories | index("../..") != null' "$TREE/libs/optin/.claude/settings.json"
  jq -e '.permissions.deny | index("Edit(../../.env)") != null' "$TREE/apps/web/.claude/settings.json"
  jq -e '(.hooks | keys) == ["SessionStart"] and (.hooks.SessionStart | length) == 1 and .hooks.SessionStart[0].matcher == "startup|resume"' "$TREE/apps/api/.claude/settings.json"
  [ "$(cksum <"$TREE/tools/tool/.claude/settings.json")" = "$HAND_WRITTEN_SUM" ]
}

@test "the stub's hook command runs on its own and says the guards are off" {
  sync_settings
  local command
  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TREE/apps/api/.claude/settings.json")
  run env -i /bin/sh -c "$command"
  [ "$status" -eq 0 ]
  jq -e '.systemMessage == "GAIA guards are off in this session. Launch from the repo root." and .hookSpecificOutput.additionalContext == "GAIA guards are off in this session. Launch from the repo root."' <<<"$output"
}

@test "the drift check is clean and silent about a current stub and a hand-written file" {
  sync_settings
  run_drift
  [ "$status" -eq 0 ]
  grep -qF -- "warning" <<<"$output" && return 1
  grep -qF -- "check-settings-drift: clean" <<<"$output"
}

@test "a deleted stub is a warning naming the member and the exit status stays 0" {
  sync_settings
  rm "$TREE/apps/api/.claude/settings.json"
  run_drift
  [ "$status" -eq 0 ]
  grep -qF -- "warning: member api" <<<"$output"
}

@test "an edited stub is a warning naming the member and the exit status stays 0" {
  sync_settings
  sed -i.bak 's/startup/other/' "$TREE/apps/api/.claude/settings.json"
  run_drift
  [ "$status" -eq 0 ]
  grep -qF -- "warning: member api" <<<"$output"
}

@test "sync restores a deleted or edited stub" {
  sync_settings
  local original
  original=$(cksum <"$TREE/apps/api/.claude/settings.json")
  rm "$TREE/apps/api/.claude/settings.json"
  sync_settings
  [ "$(cksum <"$TREE/apps/api/.claude/settings.json")" = "$original" ]
  sed -i.bak 's/startup/other/' "$TREE/apps/api/.claude/settings.json"
  sync_settings
  [ "$(cksum <"$TREE/apps/api/.claude/settings.json")" = "$original" ]
}

@test "a missing file on a web member fails the drift check" {
  sync_settings
  rm "$TREE/apps/web/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/.claude/settings.json" <<<"$output"
}

@test "a stale file on an opted-in member fails the drift check" {
  sync_settings
  printf '{}\n' >"$TREE/libs/optin/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
}

@test "a stale file on a web member fails the drift check" {
  sync_settings
  printf '{}\n' >"$TREE/apps/web/.claude/settings.json"
  run_drift
  [ "$status" -eq 1 ]
}
