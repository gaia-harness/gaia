#!/usr/bin/env bats
#
# The Quality Gate page's "Quick check" command decides whether a commit skips
# the gate. After the apps/web/ move a commit touching only apps/web/package.json
# or apps/web/tsconfig.json must still select the gate. The test extracts the
# command from the page itself and runs it against staged files in a temp repo.
#
# The maintainer-only "Frontend filter", piped after the Quick check, narrows
# which gate-selecting commits run the web-only steps 6 to 8: CLI, test-harness, and
# harness-script source belongs to no registered package.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Quality Gate.md"
  TMP_REPO="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_REPO"
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

# The maintainer-only fenced block that follows the "Frontend filter:" line,
# appended to the Quick check as a pipeline stage.
page_frontend_check() {
  local filter
  filter="$(awk '
    /^Frontend filter:$/ { armed = 1; next }
    armed && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$PAGE")"
  [ -n "$filter" ] || return 1
  printf '%s | %s\n' "$(page_quick_check)" "$filter"
}

# Stage the given paths in the temp repo, run the command, print its output.
staged_selection() {
  local command="$1" path
  shift
  find "$TMP_REPO" -mindepth 1 -delete
  git -C "$TMP_REPO" init -q
  for path in "$@"; do
    mkdir -p "$TMP_REPO/$(dirname "$path")"
    printf '{}\n' >"$TMP_REPO/$path"
    git -C "$TMP_REPO" add -- "$path"
  done
  (cd "$TMP_REPO" && bash -c "$command") || true
}

@test "the Quality Gate quick-check command selects a commit staging only apps/web package.json or tsconfig.json, the package registry files or root package.json, and skips wiki and rules markdown" {
  local command row paths expected
  command="$(page_quick_check)"
  [ -n "$command" ] || { echo "quick-check block is empty"; return 1; }
  for row in \
    "apps/web/package.json|select" \
    "apps/web/tsconfig.json|select" \
    ".gaia/packages.json apps/web/gaia.package.json|select" \
    "package.json|select" \
    "wiki/a.md .claude/rules/a.md|skip"; do
    paths=${row%%|*}
    expected=${row#*|}
    # shellcheck disable=SC2086
    run staged_selection "$command" $paths
    if [ "$expected" = select ]; then
      [ -n "$output" ] || { echo "row $row: gate skipped"; return 1; }
    else
      [ -z "$output" ] || { echo "row $row: gate selected '$output'"; return 1; }
    fi
  done
}

@test "the maintainer frontend filter skips CLI, test-harness and harness-script source, selects frontend source staged beside it, and still selects root config and the package registry" {
  local command row paths expected
  command="$(page_frontend_check)"
  [ -n "$command" ] || { echo "frontend filter block is empty"; return 1; }
  for row in \
    ".gaia/cli/src/a.ts .gaia/tests/a.ts .gaia/scripts/lib/a.mjs|" \
    ".gaia/cli/src/a.ts apps/web/app/a.tsx|apps/web/app/a.tsx" \
    "package.json .gaia/packages.json apps/web/tsconfig.json|.gaia/packages.json,apps/web/tsconfig.json,package.json"; do
    paths=${row%%|*}
    expected=${row#*|}
    # shellcheck disable=SC2086
    run staged_selection "$command" $paths
    [ "$(printf '%s\n' "$output" | paste -sd, -)" = "$expected" ] || { echo "row $row: got '$output'"; return 1; }
  done
}
