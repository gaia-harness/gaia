#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/update-state-line-lib.sh: the state-line
# functions the update commands hand to gaia_refuse_if_worktree. Run under bash
# 5 through .gaia/scripts/bats5.sh (see .claude/rules/bats-assertions.md).
#
# Two kinds of proof. The expected-output cases pin each function's exact line
# for a fixture cache, under bash and zsh, and a mutated copy of the library
# must be reported. The parity cases compare the library against the inline
# definition in each skill's guard fence for as long as that fence still holds
# one; once a skill sources the library instead, there is nothing inline to
# compare and the parity case skips.

setup() {
  LIBRARY_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/update-state-line-lib.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  CACHE_DIRECTORY="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE_DIRECTORY"
  NO_JQ_PATH="$BATS_TEST_TMPDIR/empty-path"
  mkdir -p "$NO_JQ_PATH"
}

# available_shells: prints the absolute path of every shell the library must
# work under, bash always and zsh when installed.
available_shells() {
  command -v bash
  command -v zsh 2>/dev/null || true
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

# inline_function_text <skill file> <function name>: the function definition as
# written in the skill's fenced block, from its opening line to the closing
# brace at column 0. Empty when the skill no longer defines it inline.
inline_function_text() {
  awk -v name="$2" '
    $0 == name "() {" { in_function = 1 }
    in_function { print }
    in_function && $0 == "}" { exit }
  ' "$1"
}

@test "structural: the library defines both state-line functions and is executable" {
  [ -x "$LIBRARY_SCRIPT" ]
  run bash -c '. "$1"; type gaia_update_deps_state_line >/dev/null && type gaia_update_gaia_state_line >/dev/null && echo OK' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "expected output: every fixture cache renders its exact line, under bash" {
  expected_matches "$(command -v bash)" "$LIBRARY_SCRIPT"
}

@test "expected output: every fixture cache renders its exact line, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  expected_matches "$(command -v zsh)" "$LIBRARY_SCRIPT"
}

@test "expected output: a library with the advisories-unavailable wording changed is reported" {
  local mutated="$BATS_TEST_TMPDIR/mutated-lib.sh"
  sed 's/security advisories unavailable/security advisories missing/' "$LIBRARY_SCRIPT" >"$mutated"
  # The mutation must have landed, or the failing state below proves nothing.
  grep -qF -- "security advisories missing" "$mutated" || return 1
  run expected_matches "$(command -v bash)" "$mutated"
  [ "$status" -eq 1 ]
  grep -qF -- "security advisories missing" <<<"$output" || return 1
}

# parity_matches <function name> <inline text>: runs the inline definition and
# the library's against every fixture cache of the matching function, under
# each available shell, and returns 1 at the first byte of difference.
parity_matches() {
  local function_name="$1" inline_text="$2" inline_file="$BATS_TEST_TMPDIR/inline-$1.sh" checked_at shell_path cache expected actual
  printf '%s\n' "$inline_text" >"$inline_file"
  checked_at="$(fixture_age_checked_at)"
  local caches=()
  if [ "$function_name" = "gaia_update_deps_state_line" ]; then
    caches+=("$(write_cache p-with-count "{\"outdatedCount\":4,\"checkedAt\":$checked_at,\"securityCount\":2,\"securitySource\":\"gh\"}")")
    caches+=("$(write_cache p-unavailable "{\"outdatedCount\":4,\"checkedAt\":$checked_at,\"securityCount\":0,\"securitySource\":\"unavailable\"}")")
    caches+=("$(write_cache p-null-count "{\"outdatedCount\":0,\"checkedAt\":$checked_at}")")
  else
    caches+=("$(write_cache p-gaia-update "{\"gaiaCurrent\":\"1.2.3\",\"gaiaLatest\":\"1.3.0\",\"gaiaHasUpdate\":true}")")
    caches+=("$(write_cache p-gaia-current "{\"gaiaCurrent\":\"1.3.0\",\"gaiaLatest\":\"1.3.0\",\"gaiaHasUpdate\":false}")")
  fi
  caches+=("$CACHE_DIRECTORY/missing.json")
  [ "${#caches[@]}" -ge 3 ] || return 1
  while IFS= read -r shell_path; do
    [ -n "$shell_path" ] || continue
    for cache in "${caches[@]}"; do
      expected="$(call_function "$shell_path" "$inline_file" "$function_name" "$cache")"
      actual="$(call_function "$shell_path" "$LIBRARY_SCRIPT" "$function_name" "$cache")"
      [ "$actual" = "$expected" ] || { echo "$function_name under $shell_path on $cache: library [$actual] vs inline [$expected]" >&2; return 1; }
    done
    expected="$(call_function "$shell_path" "$inline_file" "$function_name" "${caches[0]}" "$NO_JQ_PATH")"
    actual="$(call_function "$shell_path" "$LIBRARY_SCRIPT" "$function_name" "${caches[0]}" "$NO_JQ_PATH")"
    [ "$actual" = "$expected" ] || { echo "$function_name under $shell_path without jq: library [$actual] vs inline [$expected]" >&2; return 1; }
  done < <(available_shells)
  return 0
}

@test "parity: the library matches the inline deps definition in its skill, under every available shell" {
  local skill="$REPO_ROOT/.claude/skills/update-deps/SKILL.md" inline_text
  inline_text="$(inline_function_text "$skill" gaia_update_deps_state_line)"
  [ -n "$inline_text" ] || skip "update-deps no longer defines the function inline"
  parity_matches gaia_update_deps_state_line "$inline_text"
}

@test "parity: the library matches the inline gaia definition in its skill, under every available shell" {
  local skill="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md" inline_text
  inline_text="$(inline_function_text "$skill" gaia_update_gaia_state_line)"
  [ -n "$inline_text" ] || skip "update-gaia no longer defines the function inline"
  parity_matches gaia_update_gaia_state_line "$inline_text"
}
