#!/usr/bin/env bats
#
# Doc-conformance suite for the rules that keep a plan from naming a
# test another test already proves.
#
# A model plans from planner.md, the SPEC audit's directive rule, Test
# Layering, the test-table procedure and the Playwright rule, and the plan
# audit's Test design lens checks the result. Without these clauses a plan
# turns a markup directive into a real-server assertion, re-asserts page
# content in the served-status check, writes one rule's case table at both
# the unit and the route layer, leaves one of a rule's cases out of its table
# (on a page's story or route test, or with the rule function's contract
# unable to take the input that case varies), and gives a happy path the
# flow test walks its own route test. Each clause is pinned in the paragraph
# that carries it.
#
# Method: every check takes a root directory; each red twin removes or
# reverts one clause in a scratch copy, proves the copy changed, and runs the same
# check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  AUDIT_REL=".claude/skills/gaia/references/spec/audit.md"
  LAYERING_REL=".claude/doctrine/testing.md"
  PLAYWRIGHT_REL="apps/web/.claude/rules/playwright.md"
  TEST_TABLE_REL=".claude/skills/gaia/references/plan/test-table.md"
  DECOMPOSITION_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"

  MARKUP_PLANNER='A page-markup or accessibility directive constrains the code, and adds a real-server assertion only when the rendered HTML is itself the requirement'
  MARKUP_AUDIT='naming the page or component it applies to, written as the constraint the code meets'
  REFUSAL_LAYERING='asserting only the served status and any `Location` header, never page content a route test shows'
  TABLE_LAYERING='exactly one case table holding every case, at the layer the layer rule picks. A test of that rule at another layer keeps one row per outcome'
  TWIN_LAYERING='with no success-path route test of its own; an effect the flow cannot observe keeps its route test'
  WIRING_INPUT_LAYERING='to prove the wiring, with an input clear of every boundary and exception the table cases,'
  CASE_OWNER_LAYERING='A case belongs to the rule whose input it varies, whichever requirement states it and whatever effect it names'
  PAGE_EFFECT_PLANNER='a case another key states as a page effect included'
  WIRING_INPUT_PLANNER='a row of that rule at another layer takes one input per outcome, clear of every boundary and exception the table cases'
  PAGE_EFFECT_LENS='(a case another key states as a page effect, such as an alert shown, included)'
  REPEAT_LENS="or another layer's row of that rule repeating a boundary or exception case the table holds"
  SERVED_ERROR_LAYERING='A real-server row for a served error status (a 404 for an unknown path or a missing record) asserts only the status and any `Location`'
  SERVED_ERROR_ROUTE_LAYERING="Which route answers a path is shown by that route's own served check and route test (a signed-out request its guard redirects), never by a served heading."
  SERVED_ERROR_LENS="A real-server row for a served error status that also asserts its page's heading or other content is trimmed to the status and any \`Location\`, never dropped for it"
  RULE_TABLE_PLANNER="Put every case of one transition, status or role rule in that rule's one case table"
  RULE_INPUT_PLANNER="the rule function's frozen contract takes every input a case varies"
  RULE_TABLE_LENS="whose one case table lacks a case its requirement states, the case sitting only on another layer's row"
  RULE_INPUT_LENS="the rule function's contract not taking the input that case varies"
}

# ---------- helpers ----------

# line_with <file> <anchor>: the first line holding <anchor>.
line_with() {
  grep -F -m 1 -- "$2" "$1"
}

# holds <region name> <text> <needle>
holds() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
  case "$2" in
    *"$3"*) return 0 ;;
  esac
  printf '%s lacks: %s\n' "$1" "$3" >&2
  return 1
}

directive_para() { line_with "$1/$PLANNER_REL" 'Its `## Plan-time directives` section'; }
audit_directive() { line_with "$1/$AUDIT_REL" '- **Plan-time directive** ('; }
layering_rule() { line_with "$1/$LAYERING_REL" 'Give every transition, status or role rule'; }
table_step() { line_with "$1/$TEST_TABLE_REL" "5. Pick each row's layer"; }
lens_rule_table() { line_with "$1/$DECOMPOSITION_REL" '  - a transition, status or role rule whose one case table'; }
layering_refusal() { line_with "$1/$LAYERING_REL" '**Served check.**'; }
layering_served_error() { line_with "$1/$LAYERING_REL" '- A real-server row for a served error status'; }
lens_duplicate() { line_with "$1/$DECOMPOSITION_REL" '  - a duplicate within the plan:'; }

# ---------- checks ----------

check_markup_directive() {
  holds 'planner.md AUDIT_PATH paragraph' "$(directive_para "$1")" "$MARKUP_PLANNER" || return 1
  holds 'audit.md plan-time directive bullet' "$(audit_directive "$1")" "$MARKUP_AUDIT" || return 1
}

check_refusal_status_only() {
  holds 'Test Layering refusal paragraph' "$(layering_refusal "$1")" "$REFUSAL_LAYERING" || return 1
}

check_one_case_table() {
  holds 'Test Layering rule paragraph' "$(layering_rule "$1")" "$TABLE_LAYERING" || return 1
  holds 'Test Layering rule paragraph' "$(layering_rule "$1")" "$WIRING_INPUT_LAYERING" || return 1
  holds 'Test Layering rule paragraph' "$(layering_rule "$1")" "$CASE_OWNER_LAYERING" || return 1
}

check_rule_cases_in_one_table() {
  holds 'test-table.md layer step' "$(table_step "$1")" "$RULE_TABLE_PLANNER" || return 1
  holds 'test-table.md layer step' "$(table_step "$1")" "$RULE_INPUT_PLANNER" || return 1
  holds 'Test design lens rule-table bullet' "$(lens_rule_table "$1")" "$RULE_TABLE_LENS" || return 1
  holds 'Test design lens rule-table bullet' "$(lens_rule_table "$1")" "$RULE_INPUT_LENS" || return 1
  holds 'test-table.md layer step' "$(table_step "$1")" "$PAGE_EFFECT_PLANNER" || return 1
  holds 'test-table.md layer step' "$(table_step "$1")" "$WIRING_INPUT_PLANNER" || return 1
  holds 'Test design lens rule-table bullet' "$(lens_rule_table "$1")" "$PAGE_EFFECT_LENS" || return 1
  holds 'Test design lens rule-table bullet' "$(lens_rule_table "$1")" "$REPEAT_LENS" || return 1
}

check_served_error_status_only() {
  holds 'Test Layering served-error bullet' "$(layering_served_error "$1")" "$SERVED_ERROR_LAYERING" || return 1
  holds 'Test Layering served-error bullet' "$(layering_served_error "$1")" "$SERVED_ERROR_ROUTE_LAYERING" || return 1
  holds 'Test design lens duplicate bullet' "$(lens_duplicate "$1")" "$SERVED_ERROR_LENS" || return 1
}

check_happy_path_twin() {
  holds 'Test Layering flow paragraph' "$(line_with "$1/$LAYERING_REL" 'Name the closing flow test as the owner')" "$TWIN_LAYERING" || return 1
}

# mutated_tree <file rel> <old> <new>: a scratch tree (TREE) holding every
# checked file, with the first <old> in <file rel> replaced by <new>.
mutated_tree() {
  local rel content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for rel in "$PLANNER_REL" "$AUDIT_REL" "$LAYERING_REL" "$PLAYWRIGHT_REL" "$TEST_TABLE_REL" "$DECOMPOSITION_REL"; do
    mkdir -p "$TREE/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$TREE/$rel"
  done
  content="$(cat "$REPO_ROOT/$1"; printf x)"
  mutated="${content/"$2"/"$3"}"
  printf '%s' "${mutated%x}" >"$TREE/$1"
  if cmp -s "$REPO_ROOT/$1" "$TREE/$1"; then
    printf 'mutation left %s unchanged: %s\n' "$1" "$2" >&2
    return 1
  fi
}

red() {
  local check="$1"
  shift
  mutated_tree "$@" || return 1
  run "$check" "$TREE"
  [ "$status" -ne 0 ] || { printf 'check %s still passed on the mutated copy\n' "$check" >&2; return 1; }
  [ -n "$output" ] || { printf 'check %s failed without a reason\n' "$check" >&2; return 1; }
}

green() {
  run "$1" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- tests ----------

@test "a markup or accessibility directive constrains the code, not a real-server test" {
  green check_markup_directive
}

@test "red twin: dropping either markup-directive clause fails" {
  red check_markup_directive "$PLANNER_REL" "$MARKUP_PLANNER" 'removed'
  red check_markup_directive "$AUDIT_REL" "$MARKUP_AUDIT" 'removed'
}

@test "the served-status check asserts the status and Location, never page content" {
  green check_refusal_status_only
}

@test "red twin: dropping either status-only clause fails" {
  red check_refusal_status_only "$LAYERING_REL" "$REFUSAL_LAYERING" 'removed'
}

@test "a rule's case table lives at one layer, in the doctrine" {
  green check_one_case_table
}

@test "red twin: dropping either one-table clause fails" {
  red check_one_case_table "$LAYERING_REL" "$TABLE_LAYERING" 'removed'
  red check_one_case_table "$LAYERING_REL" ' holding every case,' ','
  red check_one_case_table "$LAYERING_REL" "$WIRING_INPUT_LAYERING" 'to prove the wiring,'
  red check_one_case_table "$LAYERING_REL" "$CASE_OWNER_LAYERING" 'removed'
}

@test "a plan keeps every case of a rule in its one table, and the plan audit flags a case left out" {
  green check_rule_cases_in_one_table
}

@test "red twin: dropping any rule-table clause, or the lens bullet, fails" {
  red check_rule_cases_in_one_table "$TEST_TABLE_REL" "$RULE_TABLE_PLANNER" 'removed'
  red check_rule_cases_in_one_table "$TEST_TABLE_REL" "$RULE_INPUT_PLANNER" 'removed'
  red check_rule_cases_in_one_table "$DECOMPOSITION_REL" "$RULE_TABLE_LENS" 'removed'
  red check_rule_cases_in_one_table "$DECOMPOSITION_REL" "$RULE_INPUT_LENS" 'removed'
  red check_rule_cases_in_one_table "$DECOMPOSITION_REL" '  - a transition, status or role rule whose one case table' '  - removed'
  red check_rule_cases_in_one_table "$TEST_TABLE_REL" ", $PAGE_EFFECT_PLANNER" ''
  red check_rule_cases_in_one_table "$TEST_TABLE_REL" ", and $WIRING_INPUT_PLANNER" ''
  red check_rule_cases_in_one_table "$DECOMPOSITION_REL" " $PAGE_EFFECT_LENS" ''
  red check_rule_cases_in_one_table "$DECOMPOSITION_REL" ", $REPEAT_LENS" ''
}

@test "a served error status's real-server row asserts the status, and its page content stays on its story" {
  green check_served_error_status_only
}

@test "red twin: dropping either served-error clause, or the lens trim, fails" {
  red check_served_error_status_only "$LAYERING_REL" "$SERVED_ERROR_LAYERING" 'removed'
  red check_served_error_status_only "$LAYERING_REL" " $SERVED_ERROR_ROUTE_LAYERING" ''
  red check_served_error_status_only "$DECOMPOSITION_REL" " $SERVED_ERROR_LENS" ''
}

@test "a happy path the flow test walks and asserts names that flow test" {
  green check_happy_path_twin
}

@test "red twin: a dropped happy-path ownership rule fails" {
  red check_happy_path_twin "$LAYERING_REL" "$TWIN_LAYERING" 'removed'
}
