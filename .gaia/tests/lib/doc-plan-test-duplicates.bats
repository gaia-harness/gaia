#!/usr/bin/env bats
#
# Doc-conformance suite for the rules that keep a plan from naming a
# test another test already proves.
#
# A model plans from planner.md, the SPEC audit's directive rule, Test
# Layering and the Playwright rule. Without these clauses a plan turns a
# markup directive into a real-server assertion, re-asserts page content in
# the served-status check, writes one rule's case table at both the unit and
# the route layer, and gives a happy path the flow test walks its own route
# test. Each clause is pinned in the paragraph that carries it, and the
# guard's failing-state duty those clauses must never weaken is pinned too.
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
  LAYERING_REL="wiki/decisions/Test Layering.md"
  PLAYWRIGHT_REL="apps/web/.claude/rules/playwright.md"

  MARKUP_PLANNER='A page-markup or accessibility directive constrains the code, and adds a real-server assertion only when the rendered HTML is itself the requirement'
  MARKUP_AUDIT='naming the page or component it applies to, written as the constraint the code meets'
  REFUSAL_LAYERING='asserting only the served status and any `Location` header, never page content a route test shows'
  REFUSAL_PLAYWRIGHT='asserts the status and any `Location` header, never page content a route test shows'
  TABLE_LAYERING='has exactly one case table, at the layer this page picks, holding every case of the rule; a test of that rule at any other layer keeps one row per outcome'
  TABLE_PLANNER="when that unit test carries a rule's case table, each route test of that rule keeps one row per outcome"
  TWIN_PLANNER='a happy path the closing flow test walks names that flow test instead when that flow asserts the effect, with no success-path route test of its own; an effect the flow cannot observe keeps its route test, and a guard on that path still gets the failing-state test below'
  GUARD_DUTY='must be driven into its failing state by a named acceptance test in this task that asserts it refuses'
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
criteria_bullet() { line_with "$1/$PLANNER_REL" '- Acceptance criteria (concrete and testable).'; }
naming_para() { line_with "$1/$PLANNER_REL" 'A task doc names a test only for the flow test it owns'; }
audit_directive() { line_with "$1/$AUDIT_REL" '- **Plan-time directive** ('; }
layering_rule() { line_with "$1/$LAYERING_REL" 'Every transition, status or role rule has'; }
layering_refusal() { line_with "$1/$LAYERING_REL" 'A plan carries one real-server check per guarded route module'; }
playwright_refusal() { line_with "$1/$PLAYWRIGHT_REL" '- A request-fixture refusal check'; }

# ---------- checks ----------

check_markup_directive() {
  holds 'planner.md AUDIT_PATH paragraph' "$(directive_para "$1")" "$MARKUP_PLANNER" || return 1
  holds 'audit.md plan-time directive bullet' "$(audit_directive "$1")" "$MARKUP_AUDIT" || return 1
}

check_refusal_status_only() {
  holds 'Test Layering refusal paragraph' "$(layering_refusal "$1")" "$REFUSAL_LAYERING" || return 1
  holds 'playwright.md refusal bullet' "$(playwright_refusal "$1")" "$REFUSAL_PLAYWRIGHT" || return 1
}

check_one_case_table() {
  holds 'Test Layering rule paragraph' "$(layering_rule "$1")" "$TABLE_LAYERING" || return 1
  holds 'planner.md test-naming paragraph' "$(naming_para "$1")" "$TABLE_PLANNER" || return 1
}

check_happy_path_twin() {
  local bullet
  bullet="$(criteria_bullet "$1")"
  holds 'planner.md acceptance-criteria bullet' "$bullet" "$TWIN_PLANNER" || return 1
  case "$bullet" in
    *'may name that flow test'*) printf 'acceptance-criteria bullet still lets a happy path skip the flow test\n' >&2; return 1 ;;
  esac
  holds 'planner.md acceptance-criteria bullet' "$bullet" "$GUARD_DUTY" || return 1
}

# mutated_tree <file rel> <old> <new>: a scratch tree (TREE) holding every
# checked file, with the first <old> in <file rel> replaced by <new>.
mutated_tree() {
  local rel content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for rel in "$PLANNER_REL" "$AUDIT_REL" "$LAYERING_REL" "$PLAYWRIGHT_REL"; do
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
  red check_refusal_status_only "$PLAYWRIGHT_REL" "$REFUSAL_PLAYWRIGHT" 'removed'
}

@test "a rule's case table lives at one layer, in Test Layering and planner.md" {
  green check_one_case_table
}

@test "red twin: dropping either one-table clause fails" {
  red check_one_case_table "$LAYERING_REL" "$TABLE_LAYERING" 'removed'
  red check_one_case_table "$LAYERING_REL" ', holding every case of the rule;' ';'
  red check_one_case_table "$PLANNER_REL" "$TABLE_PLANNER" 'removed'
}

@test "a happy path the flow test walks and asserts names that flow test, and every guard keeps its failing-state test" {
  green check_happy_path_twin
}

@test "red twin: a permissive happy path or a dropped guard duty fails" {
  red check_happy_path_twin "$PLANNER_REL" "$TWIN_PLANNER" 'only a happy path the closing flow test walks may name that flow test instead'
  red check_happy_path_twin "$PLANNER_REL" "$GUARD_DUTY" 'removed'
  red check_happy_path_twin "$PLANNER_REL" ' when that flow asserts the effect,' ','
  red check_happy_path_twin "$PLANNER_REL" ' an effect the flow cannot observe keeps its route test, and' ''
}
