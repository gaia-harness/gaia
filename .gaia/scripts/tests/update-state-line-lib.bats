#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/update-state-line-lib.sh: the state-line
# functions the update commands hand to gaia_refuse_if_worktree. Run under bash
# 5 through .gaia/scripts/bats5.sh (see .claude/rules/bats-assertions.md).

setup() {
  LIBRARY_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/update-state-line-lib.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CACHE_DIRECTORY="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE_DIRECTORY"
  NO_JQ_PATH="$BATS_TEST_TMPDIR/empty-path"
  mkdir -p "$NO_JQ_PATH"
}

# write_cache <name> <json>: writes a fixture cache file and prints its path.
write_cache() {
  printf '%s\n' "$2" >"$CACHE_DIRECTORY/$1.json"
  printf '%s' "$CACHE_DIRECTORY/$1.json"
}

# call_function <shell> <source file> <function> <cache> [path]: sources the
# file in a fresh <shell> and prints what the function prints. A fifth
# argument replaces PATH, which is how the no-jq case hides jq.
call_function() {
  local shell_path="$1" source_file="$2" function_name="$3" cache_file="$4" path_override="${5:-}"
  if [ -n "$path_override" ]; then
    env PATH="$path_override" "$shell_path" -c '. "$1"; "$2" "$3"' _ "$source_file" "$function_name" "$cache_file"
  else
    "$shell_path" -c '. "$1"; "$2" "$3"' _ "$source_file" "$function_name" "$cache_file"
  fi
}

# fixture_age_checked_at: a checkedAt three days and a little in the past, so
# the rendered age is a stable "3d" for the length of a test run.
fixture_age_checked_at() {
  echo $(($(date +%s) - 3 * 86400 - 600))
}

# expected_matches <shell> <library file>: drives every fixture cache through
# both functions and returns 1 at the first output that differs from the
# literal expected line, printing which case differed.
expected_matches() {
  local shell_path="$1" library_file="$2" checked_at cache actual
  checked_at="$(fixture_age_checked_at)"

  cache="$(write_cache deps-with-count "{\"outdatedCount\":4,\"checkedAt\":$checked_at,\"securityCount\":2,\"securitySource\":\"gh\"}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_deps_state_line "$cache")"
  [ "$actual" = "Cached on main: 4 packages outdated, 2 open security advisories (last checked 3d ago)." ] || { echo "deps with count: got [$actual]" >&2; return 1; }

  cache="$(write_cache deps-unavailable "{\"outdatedCount\":4,\"checkedAt\":$checked_at,\"securityCount\":0,\"securitySource\":\"unavailable\"}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_deps_state_line "$cache")"
  [ "$actual" = "Cached on main: 4 packages outdated, security advisories unavailable (last checked 3d ago)." ] || { echo "deps unavailable: got [$actual]" >&2; return 1; }

  cache="$(write_cache deps-null-count "{\"outdatedCount\":0,\"checkedAt\":$checked_at}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_deps_state_line "$cache")"
  [ "$actual" = "Cached on main: 0 packages outdated, security advisories unavailable (last checked 3d ago)." ] || { echo "deps null count: got [$actual]" >&2; return 1; }

  actual="$(call_function "$shell_path" "$library_file" gaia_update_deps_state_line "$CACHE_DIRECTORY/missing.json")"
  [ -z "$actual" ] || { echo "deps missing cache: got [$actual]" >&2; return 1; }

  cache="$(write_cache deps-no-jq "{\"outdatedCount\":4,\"checkedAt\":$checked_at}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_deps_state_line "$cache" "$NO_JQ_PATH")"
  [ -z "$actual" ] || { echo "deps no jq: got [$actual]" >&2; return 1; }

  cache="$(write_cache gaia-update "{\"gaiaCurrent\":\"1.2.3\",\"gaiaLatest\":\"1.3.0\",\"gaiaHasUpdate\":true}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_gaia_state_line "$cache")"
  [ "$actual" = "Cached on main: GAIA 1.2.3 installed; latest 1.3.0 (update available)." ] || { echo "gaia update available: got [$actual]" >&2; return 1; }

  cache="$(write_cache gaia-current "{\"gaiaCurrent\":\"1.3.0\",\"gaiaLatest\":\"1.3.0\",\"gaiaHasUpdate\":false}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_gaia_state_line "$cache")"
  [ "$actual" = "Cached on main: GAIA 1.3.0 installed; latest 1.3.0 (update not-available)." ] || { echo "gaia current: got [$actual]" >&2; return 1; }

  actual="$(call_function "$shell_path" "$library_file" gaia_update_gaia_state_line "$CACHE_DIRECTORY/missing.json")"
  [ -z "$actual" ] || { echo "gaia missing cache: got [$actual]" >&2; return 1; }

  cache="$(write_cache gaia-no-jq "{\"gaiaCurrent\":\"1.2.3\",\"gaiaLatest\":\"1.3.0\"}")"
  actual="$(call_function "$shell_path" "$library_file" gaia_update_gaia_state_line "$cache" "$NO_JQ_PATH")"
  [ -z "$actual" ] || { echo "gaia no jq: got [$actual]" >&2; return 1; }

  return 0
}

@test "expected output: every fixture cache renders its exact line, under bash and, when installed, zsh" {
  local shell_path
  expected_matches "$(command -v bash)" "$LIBRARY_SCRIPT" || { echo "case bash: differs" >&2; return 1; }
  if command -v zsh >/dev/null 2>&1; then
    shell_path="$(command -v zsh)"
    expected_matches "$shell_path" "$LIBRARY_SCRIPT" || { echo "case zsh: differs" >&2; return 1; }
  fi
}
