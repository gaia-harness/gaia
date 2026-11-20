#!/usr/bin/env bats
#
# The Quality Gate page is the one home of the smaller gate the audit unit runs.
# The page and audit-gate-owed.sh each carry the Quick check and frontend filter
# patterns; they must stay equal.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Quality Gate.md"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh"
}

# The fenced block that follows the given label line (as in
# quality-gate-skip-predicate.bats).
page_block() {
  awk -v label="$1:" '
    $0 == label { armed = 1; next }
    armed && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$PAGE"
}

page_quick_check_pattern() {
  page_block "Quick check" | sed -n "s/.*grep -E '\(.*\)'\$/\1/p"
}

page_frontend_filter_pattern() {
  page_block "Frontend filter" | sed -n "s/^grep -vE '\(.*\)'\$/\1/p"
}

script_pattern() {
  sed -n "s/^$1='\(.*\)'\$/\1/p" "$SCRIPT"
}

@test "the page Quick check pattern equals the script's" {
  page="$(page_quick_check_pattern)"
  [ -n "$page" ]
  [ "$page" = "$(script_pattern GATE_QUICK_CHECK_PATTERN)" ]
}

@test "the page frontend filter equals the script's" {
  page="$(page_frontend_filter_pattern)"
  [ -n "$page" ]
  [ "$page" = "$(script_pattern GATE_FRONTEND_FILTER_PATTERN)" ]
}
