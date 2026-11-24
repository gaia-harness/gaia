#!/usr/bin/env bats
#
# Flow test: a commit that stages only a shell file selects none of the
# Quality Gate's source steps, yet the value-set step still runs and passes.
# The commands come from the Quality Gate page itself and run against the
# committed CLI bundle inside a temporary git work tree.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Quality Gate.md"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/.gaia/cli" "$TREE/scripts" "$TREE/node_modules"
  cp "$REPO_ROOT/.gaia/cli/gaia" "$TREE/.gaia/cli/gaia"
  ln -s "$REPO_ROOT/.gaia/cli/node_modules/typescript" "$TREE/node_modules/typescript"
  cat >"$TREE/scripts/new.sh" <<'SH'
#!/usr/bin/env bash
echo hello
SH
  git -C "$TREE" init -q
  git -C "$TREE" add -- scripts/new.sh
}

# The fenced block that follows the "Quick check:" line.
page_quick_check() {
  awk '
    /^Quick check:$/ { armed = 1; next }
    armed && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$PAGE"
}

# The command the page's Steps section gives for the value-set step.
page_value_set_command() {
  # shellcheck disable=SC2016 # the sed program holds literal backticks, nothing to expand
  awk '
    /^## Steps$/ { in_steps = 1; next }
    in_steps && /^\*\*Value sets\*\*/ { print; exit }
  ' "$PAGE" | sed -n 's/^[^`]*`\([^`]*\)`.*/\1/p'
}

@test "a commit staging only a shell file matches no quick-check path, and the value-set step still runs and exits 0" {
  local quick_check value_set_command
  quick_check="$(page_quick_check)"
  [ -n "$quick_check" ] || { echo "quick-check block is empty"; return 1; }
  value_set_command="$(page_value_set_command)"
  [ -n "$value_set_command" ] || { echo "value-set command not found on the page"; return 1; }

  run bash -c 'cd "$1" && { bash -c "$2" || true; }' _ "$TREE" "$quick_check"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "quick check selected: $output"; return 1; }

  run bash -c 'cd "$1" && bash -c "$2"' _ "$TREE" "$value_set_command"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
