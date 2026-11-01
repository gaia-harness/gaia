#!/usr/bin/env bash
# Names every registered workspace member the root gate silently skips.
#
# The root typecheck, lint and test:ci scripts run with --if-present, so a
# member without the script drops out of the gate with no sign. This prints one
# WARN line per such member:
#   - it has test files and no test:ci script
#   - it has .ts or .tsx sources and no typecheck script
#
# Usage: gate-member-warnings.sh [repo-root]   (default: this script's repo)
#
# Exit 0 whenever the registry reads, warnings or not: this is advice, not a
# gate. A registry that fails to read exits with the reader's status and prints
# its message to stderr, because an unreadable registry would otherwise look
# like a workspace with nothing to warn about.
#
# Test files are found by the last segment of each tddUnitTests glob (the
# descriptor's own globs, e.g. `*.test.ts`), or `*.test.*` and `*.spec.*` when
# the list is empty. Matching on the segment alone can over-count a nested path
# the full glob would exclude; that errs toward a warning, the safe side.

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="${1:-$(cd "$script_directory/../.." && pwd)}"

# shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
source "$repository_root/.claude/hooks/lib/gaia-packages.sh"

load_status=0
gaia_packages_load "$repository_root" || load_status=$?
if [ "$load_status" -ne 0 ]; then
  printf '%s\n' "$GAIA_PACKAGES_ERROR" >&2
  exit "$load_status"
fi

has_script() {
  local package_file="$1" script_name="$2"
  jq -e --arg s "$script_name" '(.scripts // {}) | has($s)' "$package_file" >/dev/null 2>&1
}

has_any_file() {
  local member_directory="$1"
  shift
  [ -n "$(find "$member_directory" -type f \( "$@" \) -not -path '*/node_modules/*' -print -quit)" ]
}

while IFS=$'\t' read -r member_name member_path; do
  [ -n "$member_name" ] || continue
  member_directory="$repository_root/$member_path"
  package_file="$member_directory/package.json"
  [ -f "$package_file" ] || continue

  descriptor_file="$member_directory/gaia.package.json"
  test_names=()
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    test_names+=("${glob##*/}")
  done < <(jq -r '.globs.tddUnitTests[]?' "$descriptor_file")
  if [ "${#test_names[@]}" -eq 0 ]; then
    test_names=('*.test.*' '*.spec.*')
  fi
  test_expression=()
  for test_name in ${test_names[@]+"${test_names[@]}"}; do
    if [ "${#test_expression[@]}" -gt 0 ]; then
      test_expression+=(-o)
    fi
    test_expression+=(-name "$test_name")
  done

  if ! has_script "$package_file" test:ci && has_any_file "$member_directory" ${test_expression[@]+"${test_expression[@]}"}; then
    printf 'WARN %s (%s): has test files and no test:ci script, so the root test:ci skips it\n' "$member_name" "$member_path"
  fi
  if ! has_script "$package_file" typecheck \
    && has_any_file "$member_directory" -name '*.ts' -not -name '*.d.ts' -o -name '*.tsx'; then
    printf 'WARN %s (%s): has TypeScript sources and no typecheck script, so the root typecheck skips it\n' "$member_name" "$member_path"
  fi
done < <(gaia_packages_list)

exit 0
