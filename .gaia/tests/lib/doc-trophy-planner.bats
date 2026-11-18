#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's testing-trophy behavior.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner to cut build
# phases as vertical slices and to bound the tests a task executor writes, and
# the tdd skill's loop carries the matching limit. The testing doctrine owns the
# rules a plan's tests follow (guards, case splits, flow tests, page headings).
# This suite pins that text and the ORCHESTRATOR phase-entry form the
# phase-ownership check reads.
#
# Method: every check takes a root directory and reads the planner reference or
# the tdd skill from it; each red twin mutates one substring of a scratch copy,
# proves the copy changed, and runs the same check against it. Presence and
# absence match on whitespace-normalized text.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  TDD_REL=".claude/skills/tdd/SKILL.md"
  DOCTRINE_REL=".claude/doctrine/testing.md"
  LIMIT_CLAUSE='**The prompt template MUST also limit the tests a sub-agent writes**'
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

lacks() {
  has "$1" "$2" && { printf 'present, must be absent: %s\n' "$2" >&2; return 1; }
  return 0
}

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# mutated_tree <relpath> <old> <new>: copy planner.md, the tdd skill and the
# testing doctrine into a
# scratch tree (TREE), replace the first fixed-string <old> in <relpath> with
# <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$TDD_REL" "$DOCTRINE_REL"; do
    mkdir -p "$TREE/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$TREE/$file"
  done
  content="$(cat "$TREE/$rel"; printf x)"
  mutated="${content/"$old"/"$new"}"
  printf '%s' "${mutated%x}" > "$TREE/$rel"
  if cmp -s "$REPO_ROOT/$rel" "$TREE/$rel"; then
    printf 'mutation left %s unchanged: %s\n' "$rel" "$old" >&2
    return 1
  fi
  return 0
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

# ---------- checks (each takes a root and returns non-zero with a reason) ----------

check_executor_limit() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "$LIMIT_CLAUSE" || return 1
  need "$range" 'it writes the test each of them names, under that line'"'"'s title verbatim, and no other new test' || return 1
}

check_executor_lint() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "**The prompt template MUST also require linting the sub-agent's own files before it returns**, with \`pnpm -C <package dir> exec eslint <its own files>\`, the paths relative to the package and no fix flag" || return 1
  need "$range" 'it rewrites its edit until lint reports no problem its edit caused, error or warning, but `prettier/prettier`' || return 1
  need "$range" 'and a problem its edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased.' || return 1
}

check_vertical_slicing() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" '**Cut build phases as vertical slices.** Each build phase delivers a behavior end to end.' || return 1
}

check_phase_entry_form() {
  local bullet
  bullet="$(range_of "$1/$PLANNER_REL" '- **Phase order**' '- **Sub-agent yield handling.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$bullet" ] || { printf 'Phase order bullet not found\n' >&2; return 1; }
  need "$bullet" '**Phase <N>, <title>' || return 1
}

check_tdd_loop() {
  local text
  text="$(flat "$1/$TDD_REL")"
  need "$text" 'Write a new test only for those behaviors and their acceptance tests' || return 1
  need "$text" 'plus a unit test where `.claude/doctrine/testing.md` allows one' || return 1
  lacks "$text" 'For each remaining behavior' || return 1
  lacks "$text" 'One test at a time' || return 1
}

check_absence_and_cases() {
  local text
  text="$(flat "$1/$DOCTRINE_REL")"
  need "$text" 'every task that adds a way for it to reach the forbidden surface tests its absence on that surface while the value is present upstream' || return 1
  need "$text" 'Assert every case a multi-case requirement lists.' || return 1
  need "$text" "A flow test never stands in for a guard's lower-layer test" || return 1
}

# ---------- tests ----------

@test "the executor template limits the tests a sub-agent writes" {
  green check_executor_limit
}

@test "red twin: deleting the executor limit clause fails" {
  red check_executor_limit "$PLANNER_REL" 'the tests a sub-agent writes**' 'the tests a sub-agent writes (removed)'
}

@test "the executor template requires linting the sub-agent's own files before it returns" {
  green check_executor_lint
}

@test "red twin: naming the lint command without requiring it fails" {
  red check_executor_lint "$PLANNER_REL" '**The prompt template MUST also require linting the sub-agent'"'"'s own files before it returns**, with' '**The prompt template MUST also name the command that lints a sub-agent'"'"'s own files**:'
}

@test "red twin: making the lint pass condition absolute fails" {
  red check_executor_lint "$PLANNER_REL" 'until lint reports no problem its edit caused, error or warning' 'until lint reports no problem, error or warning'
}

@test "red twin: dropping the lint clause's exit for problems its edit did not cause fails" {
  red check_executor_lint "$PLANNER_REL" ', and a problem its edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased.' '.'
}

@test "planner cuts build phases as vertical slices" {
  green check_vertical_slicing
}

@test "red twin: removing the vertical-slice rule fails" {
  red check_vertical_slicing "$PLANNER_REL" 'Each build phase delivers a behavior end to end.' 'Each build phase does some work.'
}

@test "the Phase order bullet requires the ORCHESTRATOR phase entry form" {
  green check_phase_entry_form
}

@test "red twin: removing the ORCHESTRATOR entry form needle fails" {
  red check_phase_entry_form "$PLANNER_REL" 'Open each phase entry with `**Phase <N>, <title>`' 'Open each phase entry with a phase title'
}

@test "the tdd loop limits new tests to named behaviors and both-condition unit tests" {
  green check_tdd_loop
}

@test "red twin: restoring the one-test-at-a-time loop fails" {
  red check_tdd_loop "$TDD_REL" 'Don'"'"'t anticipate future tests.' 'Don'"'"'t anticipate future tests. One test at a time.'
}

@test "an absence requirement counts as a guard and every case of a multi-case row but a non-guard flow case is asserted in the task's named test" {
  green check_absence_and_cases
}

@test "red twin: making the absence requirement optional fails" {
  red check_absence_and_cases "$DOCTRINE_REL" 'every task that adds a way for it to reach the forbidden surface tests its absence' 'a task may add a way for it to reach the forbidden surface'
}

@test "red twin: an absence test with the value never present fails" {
  red check_absence_and_cases "$DOCTRINE_REL" ' while the value is present upstream' ''
}

# check_case_split <root>: the testing doctrine splits a compound condition per
# part and an order-of-checks requirement per adjacent pair.
check_case_split() {
  local plan
  plan="$(flat "$1/$DOCTRINE_REL")"
  need "$plan" 'Split a compound condition into one case per part' || return 1
  need "$plan" 'Split an order-of-checks requirement into one case per adjacent pair of checks, with an input that passes every earlier check, fails both checks of the pair, and asserts the earlier one refused' || return 1
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

@test "red twin: dropping the forged signed value guard fails" {
  red check_forged_value "$DOCTRINE_REL" ', send a forged or edited one and assert the refusal' ''
}

@test "red twin: a signed value test that never forges one fails" {
  red check_forged_value "$DOCTRINE_REL" 'send a forged or edited one' 'send the issued one'
}

@test "the doctrine and the test design lens split compound conditions and check order into cases" {
  green check_case_split
}

@test "red twin: the doctrine order-of-checks case not asserting the earlier check refused fails" {
  red check_case_split "$DOCTRINE_REL" ', fails both checks of the pair, and asserts the earlier one refused' ', fails both checks of the pair'
}

@test "red twin: the doctrine dropping the compound condition split fails" {
  red check_case_split "$DOCTRINE_REL" 'Split a compound condition into one case per part' 'Split a compound condition into one case'
}

@test "red twin: the doctrine pinning check order without a both-failing test fails" {
  red check_case_split "$DOCTRINE_REL" ', with an input that passes every earlier check, fails both checks of the pair, and asserts the earlier one refused' ''
}

@test "red twin: asserting only one case of a multi-case row fails" {
  red check_absence_and_cases "$DOCTRINE_REL" 'Assert every case a multi-case requirement lists.' 'Assert one case a multi-case requirement lists.'
}

@test "red twin: leaving a guard case of a multi-case row to the closing flow fails" {
  red check_absence_and_cases "$DOCTRINE_REL" "A flow test never stands in for a guard's lower-layer test" "A flow test may stand in for a guard's lower-layer test"
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

@test "the test design lens checks the doctrine's barred rows and security kinds" {
  green check_lens_doctrine_rows
}

@test "red twin: other-layer wiring as a floor rather than one case per outcome fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'holds one case per outcome to prove the wiring' 'keeps one row per outcome to prove the wiring'
}

@test "red twin: a stated case left as a second wiring case fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'goes into the table as a case citing that requirement, never into a second wiring case' 'gets its own wiring row'
}

@test "red twin: the builder-directing exemption limited to scope boundaries fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'A scope boundary or audit directive that directs the builder' 'A scope boundary that directs the builder'
}

@test "red twin: the shared-guard ban limited to unit tests fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'never a test, at any layer, that hand-calls the middleware function' 'never a unit test that hand-calls the middleware function'
}

@test "red twin: the doctrine dropping the app's response to an upstream refusal from the middleware guard fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" " The app's own response to an upstream refusal (no session created, the error shown) is still an access row; only the upstream's verdict itself is unprovable." ''
}

@test "red twin: the doctrine letting a case-table row name its cases by class fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'names each case it holds by its values' 'names the cases it holds'
}

@test "red twin: the doctrine testing a value mapping only in a story fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'with one case per value, at the layer the layer rule picks for the code that maps it' 'in a story'
}

@test "red twin: the doctrine counting a set-stated rule's roles by their refusals only fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'each role or relationship, inside its set or out,' 'each role or relationship outside its set,'
}

@test "red twin: the doctrine counting a set-stated rule's statuses by their refusals only fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'each status, inside its from-statuses or out,' 'each status outside its from-statuses,'
}

@test "red twin: the doctrine leaving set-stated cases free to vary the other dimension fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" " Each role or relationship case takes a status inside the action's from-statuses, and each status case a role or relationship inside its set, so each case refuses or allows on its own dimension alone." ''
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

@test "a flow row holds only the doctrine's allow-list in the doctrine, the test design lens and the planner" {
  green check_flow_row_allow_list
}

@test "red twin: the doctrine letting a flow hold any step fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" 'It holds only the journey' 'It holds the journey'
}

@test "red twin: the doctrine keeping any multi-session effect on a flow fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" "the happy path's effects that take several" 'the effects that take several'
}

@test "red twin: the doctrine keeping a refusal staged across sessions on a flow fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" ', however many requests or sessions the refusal takes to stage,' ','
}

@test "red twin: the doctrine no longer saying a refusal-shaped happy-path effect stays fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" " A happy-path step's own result that the user sees as a refusal (after sign-out the protected page redirects to sign-in) is a happy-path effect and stays." ''
}

@test "red twin: the doctrine giving a stated error path a native post fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" 'A stated no-JavaScript error path gets no native post' 'A stated no-JavaScript error path gets a native post'
}

@test "red twin: the served HTML rule letting a flow post an error fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" ', never an error post' ''
}

@test "red twin: the doctrine letting a flow assert a lower-layer literal fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" ', and asserts no stated literal or state a lower-layer test owns' ''
}

@test "red twin: the doctrine keeping a value the SPEC flow's statement names on the flow fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" ", even one the SPEC flow's own statement names: a flow that sees a placed order with its total lands on the order's page, and the total stays on its route and story tests." '.'
}

# check_covered_flows <root>: a flow whose only steps reach a page to see a
# literal a lower-layer test owns has no journey through the happy path.
check_covered_flows() {
  local doctrine
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  need "$doctrine" "A flow whose only steps reach a page to see a stated literal or state a lower-layer test owns has no journey through the happy path." || return 1
}

@test "red twin: the doctrine counting navigation to a lower-layer literal as a journey fails" {
  red check_covered_flows "$DOCTRINE_REL" " A flow whose only steps reach a page to see a stated literal or state a lower-layer test owns has no journey through the happy path." ''
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

@test "a loader-data heading has a route row and every page story, an error page's included, has the whole landmark check, in the doctrine and the test design lens" {
  green check_page_heading_rows
}

@test "red twin: the doctrine accepting a story alone for a loader-data heading fails" {
  red check_page_heading_rows "$DOCTRINE_REL" ' asserting the loader returns that text, beside the page story that renders it; a story given that text as a prop never shows the loader supplies it.' '.'
}

@test "red twin: the doctrine leaving error pages out of the landmark check fails" {
  red check_page_heading_rows "$DOCTRINE_REL" 'Every page story, an error page an error boundary renders included, carries' 'Every page story carries'
}

@test "red twin: the doctrine letting a heading-only row stand in for the landmark check fails" {
  red check_page_heading_rows "$DOCTRINE_REL" '; a row asserting a stated heading is that check only when it asserts the `main` landmark too.' '.'
}
