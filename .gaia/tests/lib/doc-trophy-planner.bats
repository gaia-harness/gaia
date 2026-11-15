#!/usr/bin/env bats
#
# Doc-conformance suite for the planner's testing-trophy behavior.
#
# .claude/skills/gaia/references/plan/planner.md tells a planner to name
# behaviors and the acceptance tests that own them, to drive a guard red at the
# lowest layer that shows the refusal (an absence requirement included), to
# assert every case of a multi-case SPEC row but a non-guard flow case (a
# compound condition one case per part, an order-of-checks row one per adjacent
# pair), to cut
# build phases as vertical slices, and to bound the tests a task executor writes. The tdd skill's loop carries the
# matching limit. This suite pins that text, the decomposition audit's test
# design lens that checks the plan per case, and the ORCHESTRATOR phase-entry
# form the phase-ownership check reads.
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
  AUDIT_REL=".claude/skills/gaia/references/plan/decomposition-audit.md"
  TABLE_REL=".claude/skills/gaia/references/plan/test-table.md"
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

# mutated_tree <relpath> <old> <new>: copy planner.md, the decomposition audit,
# the test-design table reference, the tdd skill and the testing doctrine into a
# scratch tree (TREE), replace the first fixed-string <old> in <relpath> with
# <new>, and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$AUDIT_REL" "$TABLE_REL" "$TDD_REL" "$DOCTRINE_REL"; do
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

check_acceptance_text() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'Name the behavior the task delivers and its `- Test:` lines' || return 1
  need "$text" 'never a list of tests per function' || return 1
  need "$text" 'or wording each call for is `.claude/doctrine/testing.md`.' || return 1
  need "$text" '.claude/rules/guards-must-fail.md' || return 1
  lacks "$text" 'One criterion per guard, refusal, or gate' || return 1
}

check_executor_limit() {
  local range
  range="$(range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$range" ] || { printf 'executor template range not found\n' >&2; return 1; }
  need "$range" "$LIMIT_CLAUSE" || return 1
  need "$range" 'it writes the test of each of its task'"'"'s rows under the planned title verbatim and no other new test' || return 1
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

check_task_doc_test_naming() {
  local text
  text="$(flat "$1/$PLANNER_REL")"
  need "$text" 'A task doc names tests only on the `- Test:`, `- Flow test` and `- Pin update:` lines' || return 1
  need "$text" 'a test worth having that no requirement names is no row, and goes under `## Follow-ups` in `README.md`' || return 1
}

check_absence_and_cases() {
  local text
  text="$(flat "$1/$DOCTRINE_REL")"
  need "$text" 'every task that adds a way for it to reach the forbidden surface tests its absence on that surface while the value is present upstream' || return 1
  need "$text" 'Assert every case a multi-case requirement lists.' || return 1
  need "$text" "A flow test never stands in for a guard's lower-layer test" || return 1
}

# ---------- tests ----------

@test "planner names behaviors and acceptance tests and drops the per-guard criterion line" {
  green check_acceptance_text
}

@test "red twin: restoring the per-guard criterion line fails" {
  red check_acceptance_text "$PLANNER_REL" 'never a list of tests per function' 'never a list of tests per function. One criterion per guard, refusal, or gate'
}

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

@test "a task doc names a test only on a Test line, a Pin update line names a falsified pin, and an unrequired test goes to README follow-ups" {
  green check_task_doc_test_naming
}

@test "red twin: letting a task doc name any test the planner judges worthwhile fails" {
  red check_task_doc_test_naming "$PLANNER_REL" 'A task doc names tests only on the' 'A task doc may name any test on the'
}

@test "red twin: dropping the Pin update line form fails" {
  red check_task_doc_test_naming "$PLANNER_REL" '`- Flow test` and `- Pin update:` lines' '`- Flow test` lines'
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

# check_case_split <root>: the testing doctrine and the test design lens both split a
# compound condition per part and an order-of-checks row per adjacent pair, and
# the lens reads every SPEC section a guard case lives in.
check_case_split() {
  local plan lens
  plan="$(flat "$1/$DOCTRINE_REL")"
  lens="$(range_of "$1/$AUDIT_REL" '- **Test design' '## 4.6a-ii' | tr '\n' ' ' | tr -s ' ')"
  need "$plan" 'Split a compound condition into one case per part' || return 1
  need "$plan" 'Split an order-of-checks requirement into one case per adjacent pair of checks, with an input that passes every earlier check, fails both checks of the pair, and asserts the earlier one refused' || return 1
  need "$lens" '`success_criteria` + `scope_boundaries` + `clarifications.answered`' || return 1
  need "$lens" 'one row per case' || return 1
  need "$lens" 'a compound condition one per part' || return 1
  need "$lens" 'an order-of-checks row one per adjacent pair of checks' || return 1
  need "$lens" 'a guard case with no test a task names below the closing flow' || return 1
  need "$lens" 'an order-of-checks pair with no test that passes every earlier check, fails both, and asserts the earlier of the pair refused' || return 1
  need "$lens" 'a signed or encrypted value (a cookie, a session, a token) with no test sending a forged or edited one' || return 1
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

@test "red twin: the test design lens dropping the forged signed value hole fails" {
  red check_case_split "$AUDIT_REL" ' a signed or encrypted value (a cookie, a session, a token) with no test sending a forged or edited one,' ''
}

@test "the doctrine and the test design lens split compound conditions and check order into cases" {
  green check_case_split
}

@test "red twin: the test design lens checking rows instead of cases fails" {
  red check_case_split "$AUDIT_REL" 'one row per case' 'one row per SPEC row'
}

@test "red twin: the doctrine order-of-checks case not asserting the earlier check refused fails" {
  red check_case_split "$DOCTRINE_REL" ', fails both checks of the pair, and asserts the earlier one refused' ', fails both checks of the pair'
}

@test "red twin: the test design lens order-of-checks hole not asserting the earlier check refused fails" {
  red check_case_split "$AUDIT_REL" ', fails both, and asserts the earlier of the pair refused' ', fails both'
}

@test "red twin: the test design lens skipping scope_boundaries and clarifications.answered fails" {
  red check_case_split "$AUDIT_REL" ' + `scope_boundaries` + `clarifications.answered` ↔ rows' ' ↔ rows'
}

@test "red twin: the test design lens dropping the uncovered guard case hole fails" {
  red check_case_split "$AUDIT_REL" 'a guard case with no test a task names below the closing flow, ' ''
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

# check_lens_doctrine_rows <root>: the test design lens names each doctrine-barred
# row kind and flags by the doctrine's security kinds, sign-in and its refusals
# included (the app's response to an upstream refusal too, since a refuter read
# the upstream-verdict line as clearing it), judged
# per case in the lens and the planner's table step alike, since a per-row
# judgment reads a refusal case sharing a test with an allowed case as unflagged;
# and the apply step holds every row a fix adds, changes or trims, the lens's own
# included, to the same checks, since no check ran on that row as applied, and a
# row a finding folds into is such a change, since a fold let a mock self-test
# serve as the app test cited to decline later findings. The bar counts another app
# test in any phase, since a per-phase reading admitted a mock test that later-phase
# route tests cover. A test of a double is judged by what it can catch beyond
# that app test, and a wiring gap takes no new row. The review list's security
# retire items come from the table after fixes apply, since minor fixes apply
# after the list. A retire or change row whose source is a security requirement
# takes that requirement's kind in the doctrine, the table step and the lens,
# since keying only on the retired test's own kind left a retire made for a
# secret requirement flagged none.
check_lens_doctrine_rows() {
  local doctrine lens apply interactive table decomposition
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  table="$(flat "$1/$TABLE_REL")"
  lens="$(range_of "$1/$AUDIT_REL" '- **Test design' '## 4.6a-ii' | tr '\n' ' ' | tr -s ' ')"
  apply="$(range_of "$1/$AUDIT_REL" '## 4.6b. Apply findings' '**Interactive:**' | tr '\n' ' ' | tr -s ' ')"
  decomposition="$(range_of "$1/$AUDIT_REL" '- **Decomposition & dependency' '- **Contract grounding' | tr '\n' ' ' | tr -s ' ')"
  interactive="$(range_of "$1/$AUDIT_REL" '**Interactive:**' 'Then return to' | tr '\n' ' ' | tr -s ' ')"
  need "$doctrine" 'with no success-path route test of its own' || return 1
  need "$doctrine" '**Security row.**' || return 1
  need "$doctrine" '**Access**: who may act or see. Sign-in and its refusals,' || return 1
  need "$doctrine" "The app's own response to an upstream refusal (no session created, the error shown) is still an access row; only the upstream's verdict itself is unprovable." || return 1
  need "$doctrine" '**Forgery**: refusal of forged, tampered or server-owned values, and refusal of an untrusted destination the server would send the user or a request to (an off-site redirect target, an unregistered callback URL), or its replacement with an allowed one.' || return 1
  need "$lens" 'a success-path route test for a happy path the closing flow test walks and asserts, unless the row asserts an effect the flow cannot observe' || return 1
  need "$lens" 'a flow observes an effect whose consequence a flow step asserts' || return 1
  need "$lens" "by the doctrine's \`**Security row.**\` kinds: an access row (sign-in and its refusals included), a forgery row (a redirect or callback target included)," || return 1
  need "$doctrine" "Judge each case, not each row: a row is judged by its \`caseKey\` when it has one, by its title otherwise" || return 1
  need "$doctrine" "Two cases that share a test and carry different kinds" || return 1
  need "$doctrine" "each get their own row, keyed by \`caseKey\`" || return 1
  need "$doctrine" "keeps its flag on the row narrowed to its own kind's cases, and each moved case takes its own kind" || return 1
  need "$lens" "Judge each case by the doctrine's \`**One kind per case.**\`" || return 1
  need "$lens" 'its fix trims the row to the kind its flag names and adds a row for each other kind' || return 1
  need "$table" "Split a test whose cases carry different kinds per the doctrine's \`**One kind per case.**\`" || return 1
  need "$doctrine" "So does a retire or change row whose \`source\` is a security requirement (one another flagged row cites), whatever the existing test asserted: it carries that requirement's kind, and such a retire is a security retire." || return 1
  need "$table" "and one whose \`source\` is a security requirement carries that requirement's kind, whatever the existing test asserted" || return 1
  need "$lens" "or whose \`source\` is a security requirement (then that requirement's kind, whatever the existing test asserted)" || return 1
  need "$lens" "where the fix keeps the row on the layer the doctrine's layer rule picks" || return 1
  need "$apply" "**Applied rows** (a \`tests.json\` row any lens's fix adds, changes or trims, the Test design lens's own included, and a row another finding is folded into): hold it to the Test design lens's checks above, in its new form, before applying it" || return 1
  need "$apply" "A fold never changes the target row's \`source\`" || return 1
  need "$doctrine" 'once another app test, existing or planned in any phase, exercises that path. Judge by what the test can catch, not the code it calls' || return 1
  need "$lens" "judged by the doctrine's rule on what it can catch beyond that app test" || return 1
  need "$decomposition" 'fix the setup in the task that owns it, through its acceptance criteria, or as a structural finding when the setup lands after the test that needs it, never with a new test row' || return 1
  need "$apply" "reshaped when one change passes every check (a fix's offered trim counts as that change), else dropped" || return 1
  need "$apply" "Dropping an add leaves it out; dropping a change or trim leaves the row in its prior form, unless a Test design check bars that prior form too, and then the row is removed" || return 1
  need "$apply" 'record it as an uncovered requirement (a missing-row finding at the severity the missing-row check gives it, recommending a row every check passes, or in auto-mode in `## Audit notes`), not only as a dropped row' || return 1
  need "$apply" 'a trim narrows an existing row to a subset of its cases and is a kind of change' || return 1
  need "$apply" "A fix applied on this thread, from any lens or check, that would remove a security row (a row of the doctrine's kinds, or any row flagged) or clear a row's flag is not applied to that row unless the user rules it wrong on the review list" || return 1
  need "$apply" 'The row is kept and goes on the review list as its own item, even from a minor finding, recommending it be kept' || return 1
  need "$interactive" "one item per security-flagged \`retire\` row (\`security\` not \`none\`) in the table as it will stand once every fix applies, \`minor\` ones included" || return 1
}

@test "the test design lens checks the doctrine's barred rows and security kinds" {
  green check_lens_doctrine_rows
}

@test "red twin: the apply step dropping the fold clause fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" ', and a row another finding is folded into' ''
}

@test "red twin: the test design lens dropping the success-path route test check fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'a success-path route test for a happy path the closing flow test walks' 'a route test for a happy path the closing flow test walks'
}

@test "red twin: an effect the flow observes through its consequence keeping its route test fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'a flow observes an effect whose consequence a flow step asserts' 'a flow observes only an effect a flow step asserts'
}

@test "red twin: the test design lens flagging authorization refusals only fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" ' an access row (sign-in and its refusals included),' ' an authorization refusal,'
}

@test "red twin: the test design lens duplicate check naming no surviving row fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" ", where the fix keeps the row on the layer the doctrine's layer rule picks" ''
}

@test "red twin: the apply step dropping a security-flagged row fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'The row is kept and goes on the review list as its own item, even from a minor finding, recommending it be kept' 'The row is dropped'
}

@test "red twin: the security-row rule scoped to one lens fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'A fix applied on this thread, from any lens or check, that would remove' 'A Test design fix that would remove'
}

@test "red twin: the apply step skipping rows another lens's fix adds fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" "hold it to the Test design lens's checks above, in its new form, before applying it" 'apply it'
}

@test "red twin: the apply step skipping rows the test design lens's own fix adds fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" ", the Test design lens's own included," ','
}

@test "red twin: the apply step taking a trim that fails a check fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" "(a fix's offered trim counts as that change), else dropped" ', else trimmed'
}

@test "red twin: a drop that leaves a requirement without a row recorded only as a dropped row fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'record it as an uncovered requirement' 'record it as a dropped row'
}

@test "red twin: a dropped change deleting the row without a bar fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'dropping a change or trim leaves the row in its prior form' 'dropping a change or trim deletes the row'
}

@test "red twin: security retire items taken from the table before minor fixes apply fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" ' in the table as it will stand once every fix applies, `minor` ones included,' ''
}

@test "red twin: the doctrine dropping redirect targets from forgery fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" ', and refusal of an untrusted destination the server would send the user or a request to (an off-site redirect target, an unregistered callback URL), or its replacement with an allowed one.' '.'
}

@test "red twin: the test design lens dropping redirect targets from forgery rows fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'a forgery row (a redirect or callback target included),' 'a forgery row,'
}

@test "red twin: the doctrine dropping sign-in from access fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" '**Access**: who may act or see. Sign-in and its refusals,' '**Access**: who may act or see.'
}

@test "red twin: the doctrine dropping sign-in refusals from access fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'Sign-in and its refusals,' 'Sign-in,'
}

@test "red twin: the doctrine dropping the app's response to an upstream refusal from the middleware guard fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" " The app's own response to an upstream refusal (no session created, the error shown) is still an access row; only the upstream's verdict itself is unprovable." ''
}

@test "red twin: the test design lens judging the flag per row fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" "Judge each case by the doctrine's \`**One kind per case.**\`" "Judge each row by the doctrine's \`**One kind per case.**\`"
}

@test "red twin: the planner's table step dropping the pointer to the split rule fails" {
  red check_lens_doctrine_rows "$TABLE_REL" "Split a test whose cases carry different kinds per the doctrine's" 'Split a test per the'
}

@test "red twin: the doctrine keying a retire's flag only on the retired test's kind fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" " So does a retire or change row whose \`source\` is a security requirement (one another flagged row cites), whatever the existing test asserted: it carries that requirement's kind, and such a retire is a security retire." ''
}

@test "red twin: the doctrine's source-kind retire not counted as a security retire fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" ', and such a retire is a security retire.' '.'
}

@test "red twin: the planner's table step dropping the source-kind retire flag fails" {
  red check_lens_doctrine_rows "$TABLE_REL" ", and one whose \`source\` is a security requirement carries that requirement's kind, whatever the existing test asserted" ''
}

@test "red twin: the test design lens dropping the source-kind retire flag fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" " or whose \`source\` is a security requirement (then that requirement's kind, whatever the existing test asserted)" ''
}

@test "red twin: the doctrine judging the flag per row fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'Judge each case, not each row: a row is judged by' 'Judge each row: a row is judged by'
}

@test "red twin: the doctrine splitting only a security case beside none fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'Two cases that share a test and carry different kinds' 'Two cases that share a test and carry a security kind and none'
}

@test "red twin: the doctrine dropping the own row for a shared case fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" 'each get their own row, keyed by' 'each get a flag, keyed by'
}

@test "red twin: the doctrine clearing the flag on a split fails" {
  red check_lens_doctrine_rows "$DOCTRINE_REL" "keeps its flag on the row narrowed to its own kind's cases" 'clears its flag'
}

@test "red twin: the test design lens fixing a mixed row by deleting it fails" {
  red check_lens_doctrine_rows "$AUDIT_REL" 'its fix trims the row to the kind its flag names and adds a row for each other kind' 'its fix removes the row'
}

# check_flow_row_allow_list <root>: a flow row holds only the doctrine's
# allow-list, and the lens and the planner say so, since a planner writing a
# SPEC flow named around a refusal or a stated literal copied it into the flow
# row and no lens check caught it. A stated no-JavaScript error path stays on
# the route layer, since the native-post check read a stated error path as a
# post the flow owns. A SPEC flow's only row is trimmed, never dropped, since
# the flow's requirement key and its Flow test line still need a row.
check_flow_row_allow_list() {
  local doctrine lens table
  doctrine="$(flat "$1/$DOCTRINE_REL")"
  table="$(flat "$1/$TABLE_REL")"
  lens="$(range_of "$1/$AUDIT_REL" '- **Test design' '## 4.6a-ii' | tr '\n' ' ' | tr -s ' ')"
  need "$doctrine" 'It holds only the journey through the happy path, the effects that take several requests or sessions to stage' || return 1
  need "$doctrine" "A stated no-JavaScript error path gets no native post: the action's route test and the page's story cover it" || return 1
  need "$doctrine" 'and asserts no stated literal or state a lower-layer test owns' || return 1
  need "$doctrine" "checks its happy path's native form posts page-less in its flow test, never an error post" || return 1
  need "$lens" "a flow row step outside the doctrine's \`**Flow test.**\` allow-list" || return 1
  need "$lens" "such as a refusal a build task's row or another flow owns, a native error post, or a stated literal or state a lower-layer row owns" || return 1
  need "$lens" "drops it when nothing is left, unless it is its SPEC flow's only row, which keeps the navigation the journey needs" || return 1
  need "$table" "each refusal it names, and each stated literal or state a lower-layer row already owns, maps to the delivering task's lower-layer row" || return 1
}

@test "a flow row holds only the doctrine's allow-list in the doctrine, the test design lens and the planner" {
  green check_flow_row_allow_list
}

@test "red twin: the doctrine letting a flow hold any step fails" {
  red check_flow_row_allow_list "$DOCTRINE_REL" 'It holds only the journey' 'It holds the journey'
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

@test "red twin: the test design lens dropping the flow allow-list check fails" {
  red check_flow_row_allow_list "$AUDIT_REL" "a flow row step outside the doctrine's" "a flow row repeating a step outside the doctrine's"
}

@test "red twin: the test design lens flagging refusals only fails" {
  red check_flow_row_allow_list "$AUDIT_REL" ', a native error post, or a stated literal or state a lower-layer row owns' ''
}

@test "red twin: the test design lens dropping a SPEC flow's only row fails" {
  red check_flow_row_allow_list "$AUDIT_REL" ", unless it is its SPEC flow's only row, which keeps the navigation the journey needs" ''
}

@test "red twin: the planner mapping refusals to the flow row fails" {
  red check_flow_row_allow_list "$TABLE_REL" "maps to the delivering task's lower-layer row" "maps to the flow row"
}
