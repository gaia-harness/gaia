#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's testing-trophy behavior.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner to lint a
# task executor's own files and to open each ORCHESTRATOR phase entry in the
# form the phase-ownership check reads. The testing doctrine owns the rules a
# plan's tests follow (guards, case splits, flow tests, page headings). This
# suite pins that text.
#
# Presence matches on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  DOCTRINE_REL=".claude/doctrine/testing.md"
}

# ---------- helpers ----------

# flat <file>: the file's text with newlines and runs of spaces collapsed.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }

# has <text> <needle>: the fixed needle occurs in the text.
has() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

need() {
  has "$1" "$2" || { printf 'missing: %s\n' "$2" >&2; return 1; }
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

green() {
  run "$1" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- checks (each takes a root and returns non-zero with a reason) ----------

check_executor_lint() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "**The prompt template MUST also require linting the sub-agent's own files before it returns**, with \`pnpm -C <package dir> exec eslint <its own files>\`, the paths relative to the package and no fix flag" || return 1
  need "$range" 'it rewrites its edit until lint reports no problem its edit caused, error or warning, but `prettier/prettier`' || return 1
  need "$range" 'and a problem its edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased.' || return 1
}

check_phase_entry_form() {
  local bullet
  bullet="$(range_of "$1/$PLANNER_REL" '- **Phase order**' '- **Sub-agent yield handling.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$bullet" ] || { printf 'Phase order bullet not found\n' >&2; return 1; }
  need "$bullet" '**Phase <N>, <title>' || return 1
}

check_absence_and_cases() {
  local text
  text="$(flat "$1/$DOCTRINE_REL")"
  need "$text" 'every task that adds a way for it to reach the forbidden surface tests its absence on that surface while the value is present upstream' || return 1
  need "$text" 'Assert every case a multi-case requirement lists.' || return 1
  need "$text" "A flow test never stands in for a guard's lower-layer test" || return 1
}

# ---------- tests ----------

@test "the executor template requires linting the sub-agent's own files before it returns" {
  green check_executor_lint
}

@test "the Phase order bullet requires the ORCHESTRATOR phase entry form" {
  green check_phase_entry_form
}

@test "an absence requirement counts as a guard and every case of a multi-case row but a non-guard flow case is asserted in the task's named test" {
  green check_absence_and_cases
}

# check_forged_value <root>: the testing doctrine requires a test that sends a
# forged or edited value for a value the app issued.
check_forged_value() {
  local text
  text="$(flat "$1/$DOCTRINE_REL")"
  need "$text" 'For a signed or encrypted value the app issues (a cookie, a session, a token), send a forged or edited one and assert the refusal' || return 1
}

@test "the doctrine requires a forged-value test for a value the app issued" {
  green check_forged_value
}

# check_lens_doctrine_rows <root>: the doctrine keeps the rules a plan's tests
# follow: a happy path the closing flow walks has no success-path route test of
# its own, a middleware guard is proven through the real chain and never by
# hand-calling the function (the app's own response to an upstream refusal
# stays tested), a rule at another layer holds one wiring case per outcome with
# a case another requirement states joining the rule's one case table, a
# builder-directing scope boundary or audit directive names no behavior, a
# case table names each case by its values, a stated value-to-display mapping
# has one case per value, a rule stated as sets has one case per member and
# each case varies one dimension alone, and a test of a double is judged by
# what it can catch beyond the app test.
check_lens_doctrine_rows() {
  local doctrine
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" 'with no success-path route test of its own' || return 1
  need "$doctrine" "The app's own response to an upstream refusal (no session created, the error shown) is still an access row; only the upstream's verdict itself is unprovable." || return 1
  need "$doctrine" "A case table names each case it holds by its values" || return 1
  need "$doctrine" "- Test a stated mapping from a value the app reads (an API field, a stored or query value) to what the user sees (a stored \`status: 2\` shown as \`Shipped\`) with one case per value, at the layer the layer rule picks for the code that maps it: the route test of a loader or action that maps it, the unit test of a helper that meets the unit-test conditions, or, when a component maps it, itself or through a small helper it calls, one story per value given the raw value. A story given the mapped props never runs the mapping." || return 1
  need "$doctrine" "has one case per action and each role or relationship, inside its set or out, and one per action and each status, inside its from-statuses or out" || return 1
  need "$doctrine" "Each role or relationship case takes a status inside the action's from-statuses, and each status case a role or relationship inside its set, so each case refuses or allows on its own dimension alone." || return 1
  need "$doctrine" 'once another app test, existing or planned in any phase, exercises that path. Judge by what the test can catch, not the code it calls' || return 1
  need "$doctrine" 'A test of that rule at another layer holds one case per outcome to prove the wiring' || return 1
  need "$doctrine" 'a case another requirement states goes into the table as a case citing that requirement, never into a second wiring case of the same outcome' || return 1
  need "$doctrine" 'A scope boundary or audit directive that directs the builder rather than stating what the app does' || return 1
  need "$doctrine" 'never a test, at any layer, that hand-calls the middleware function; a new case for that guard extends the row that runs the real chain' || return 1
}

@test "the doctrine keeps the barred rows a plan's tests follow" {
  green check_lens_doctrine_rows
}

# check_flow_row_allow_list <root>: a flow row holds only the doctrine's
# allow-list. A stated no-JavaScript error path stays on the route layer, since
# a native-post check read a stated error path as a post the flow owns.
check_flow_row_allow_list() {
  local doctrine
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" "It holds only the journey through the happy path, the happy path's effects that take several requests or sessions to stage" || return 1
  need "$doctrine" "repeats no refusal a build task's test or another flow owns, however many requests or sessions the refusal takes to stage," || return 1
  need "$doctrine" "A stated no-JavaScript error path gets no native post: the action's route test and the page's story cover it" || return 1
  need "$doctrine" 'and asserts no stated literal or state a lower-layer test owns' || return 1
  need "$doctrine" "even one the SPEC flow's own statement names: a flow that sees a placed order with its total lands on the order's page, and the total stays on its route and story tests." || return 1
  need "$doctrine" "checks its happy path's native form posts page-less in its flow test, never an error post" || return 1
  need "$doctrine" "A happy-path step's own result that the user sees as a refusal (after sign-out the protected page redirects to sign-in) is a happy-path effect and stays." || return 1
}

@test "a flow row holds only the doctrine's allow-list" {
  green check_flow_row_allow_list
}

# check_covered_flows <root>: a flow whose only steps reach a page to see a
# literal a lower-layer test owns has no journey through the happy path.
check_covered_flows() {
  local doctrine
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" "A flow whose only steps reach a page to see a stated literal or state a lower-layer test owns has no journey through the happy path." || return 1
}

@test "a flow whose only steps reach a page to see a lower-layer literal has no journey through the happy path" {
  green check_covered_flows
}

# check_page_heading_rows <root>: a heading whose text is loader data gets a
# route test that the loader returns it, and every page story, an error page's
# included, carries both halves of the landmark check.
check_page_heading_rows() {
  local doctrine
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" "A heading whose text is data the loader returns is a route test asserting the loader returns that text, beside the page story that renders it; a story given that text as a prop never shows the loader supplies it." || return 1
  need "$doctrine" "Every page story, an error page an error boundary renders included, carries the landmark check, one \`.test()\` asserting one level-1 heading and one \`main\` landmark; a row asserting a stated heading is that check only when it asserts the \`main\` landmark too." || return 1
}

@test "a loader-data heading has a route row and every page story, an error page's included, has the whole landmark check" {
  green check_page_heading_rows
}
