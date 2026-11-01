#!/usr/bin/env bats
#
# The Quality Gate page is the one home of the smaller gate the audit unit runs.
# The page and audit-gate-owed.sh each carry the Quick check and frontend filter
# patterns; they must stay equal. PAGE and SCRIPT may be overridden so a scratch
# copy proves each pin can fail.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="${PAGE:-$REPO_ROOT/wiki/decisions/Quality Gate.md}"
  SCRIPT="${SCRIPT:-$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh}"
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

page_section() {
  awk '/^## The smaller gate$/ { in_section = 1; next } in_section && /^## / { exit } in_section { print }' "$PAGE"
}

@test "the page has a smaller gate section" {
  run page_section
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "the smaller gate section names the three deferred steps" {
  run page_section
  [[ "$output" == *"steps 6, 7 and 8"* ]]
  [[ "$output" == *"Playwright"* ]]
  [[ "$output" == *"dev smoke test"* ]]
  [[ "$output" == *"production build"* ]]
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
