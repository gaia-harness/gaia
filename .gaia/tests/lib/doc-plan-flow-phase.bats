#!/usr/bin/env bats
#
# Doc-conformance suite for the test-after plan shape.
#
# .claude/skills/gaia/references/plan/planner.md writes plans that name no test,
# and the test stage reference adds, to a spec-derived plan, one closing
# flow-test phase, one task per flow, whose quality gate runs every flow test
# before the commit; pre-audit flow checks run flow-coverage.sh with one named
# fixer and a halt. This suite pins:
#
#   - the planner naming no test and no closing phase, and the test stage's
#     closing phase rule, `Flow test` task line, web and command flow paths;
#   - the closing-phase flow-test gate's run commands and its refusal, and the
#     gate-retry block's one-shot flow-test arm;
#   - the flow-checks block's command, fixer, single re-run, HALTED block and
#     question, and lifecycle.md's matching section;
#   - the spec-less rule: no closing phase and no flow-checks block;
#   - the ledger HALTED form and its two options, unchanged;
#   - the absence of every test-first phrase, and of every phrase barring an
#     executor from editing its own tests.
#
# Every check is a function taking the file it reads; each red twin first
# shows the real file passes, then that a mutated copy fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_MD="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  TEST_STAGE_MD="$REPO_ROOT/.claude/skills/gaia/references/test-stage.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
  S_FLOW='<!-- gaia:orchestrator-step flow-checks -->'
}

# ---------- helpers ----------

# fence_with <file> <literal>: the raw lines (fence lines dropped) of the
# first ``` fence holding a line that trims to <literal>.
fence_with() {
  awk -v want="$2" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ {
      if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
      else { in_fence = 1; buffer = ""; hit = 0 }
      next
    }
    in_fence { buffer = buffer $0 "\n"; if (t == want) hit = 1 }' "$1"
}

# range_of <file> <start fixed string> <end fixed string>
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

# section_of <file> <heading>: a "## " section up to the next "## " heading
# outside a fence.
section_of() {
  awk -v heading="$2" '
    { t = $0; sub(/^[ \t]+/, "", t) }
    t ~ /^```/ { in_fence = !in_fence }
    !in_fence && /^## / { if (inside) exit; if ($0 == heading) inside = 1 }
    inside { print }' "$1"
}

# without <file> <literal> <out>: a copy with every occurrence of <literal>
# replaced by "removed"; fails when the literal is not there.
without() {
  awk -v needle="$2" '{ while ((i = index($0, needle)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(needle)) } { print }' "$1" >"$3"
  if cmp -s "$1" "$3"; then printf "'%s' is not in %s\n" "$2" "$1" >&2; return 1; fi
}

# has_all <text> <needle>...: every needle is in the text.
has_all() {
  local text="$1" needle
  shift
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$text" || { printf 'lacks: %s\n' "$needle" >&2; return 1; }
  done
}

# ---------- checks (each returns non-zero with a reason) ----------

CLOSING_PHASE_NEEDLE='ends with one closing flow-test phase after every build phase'
ONE_TASK_PER_FLOW_NEEDLE='one task per SPEC flow'
NO_SEPARATE_AUTHOR_NEEDLE='written by the implementer'
FLOW_LINE_NEEDLE='- Flow test (<flow_id>): <repo-relative test path>'
WEB_FLOW_PATH_NEEDLE='.playwright/flows/<slug>.spec.ts'
FIXTURES_NEEDLE='apps/web/.playwright/fixtures.ts'
COMMAND_FLOW_NEEDLE='at the flow'"'"'s `test_path`'
PLANNER_NO_TEST_NEEDLE='The planner writes no test list, no test line in a task doc and no closing flow-test phase'

check_closing_phase() {
  local file="$1" text
  text="$(cat "$file")"
  has_all "$text" "$CLOSING_PHASE_NEEDLE" "$ONE_TASK_PER_FLOW_NEEDLE" "$NO_SEPARATE_AUTHOR_NEEDLE" \
    "$FLOW_LINE_NEEDLE" "$WEB_FLOW_PATH_NEEDLE" '@covers' "$FIXTURES_NEEDLE" 'worker-scoped' \
    "$COMMAND_FLOW_NEEDLE" || return 1
  # "The one line" binds the Flow test line: both sit on one paragraph line.
  grep -F 'Flow test' "$file" | grep -qF 'the one line' ||
    { printf 'no line binds the Flow test line to one line per last-phase task doc\n' >&2; return 1; }
  # The @covers header and the worker-scoped fixtures belong to the web flow.
  grep -F "$WEB_FLOW_PATH_NEEDLE" "$file" | grep -F '@covers' | grep -qF "$FIXTURES_NEEDLE" ||
    { printf 'no line gives the web flow path its @covers header and the worker-scoped fixtures\n' >&2; return 1; }
}

check_planner_names_no_test() {
  grep -qF -- "$PLANNER_NO_TEST_NEEDLE" "$1" || { printf 'planner.md lacks: %s\n' "$PLANNER_NO_TEST_NEEDLE" >&2; return 1; }
}

WEB_GATE_NEEDLE='pnpm -C <frontend package> exec playwright test .playwright/flows/<slug>.spec.ts'
BATS_GATE_NEEDLE='pnpm test:shell <test_path> < /dev/null'
VITEST_GATE_NEEDLE='pnpm -C <owning package> test --run <package-relative path>'
GATE_REFUSAL_NEEDLE='A failing run refuses the commit'

check_closing_gate() {
  local file="$1" line
  line="$(grep -F "$WEB_GATE_NEEDLE" "$file" || true)"
  [ -n "$line" ] || { printf 'no line holds the web flow run command\n' >&2; return 1; }
  has_all "$line" "$BATS_GATE_NEEDLE" "$VITEST_GATE_NEEDLE" "$GATE_REFUSAL_NEEDLE"
}

FLOW_ARM_NEEDLE='goes once to a fresh executor for the task whose `Flow test` line names it'
FLOW_ARM_FREE_NEEDLE='free to edit code or test'
FLOW_ARM_HALT_NEEDLE='a second test failure halts'

check_gate_retry_flow_arm() {
  local block
  block="$(fence_with "$1" "$S_RETRY")"
  [ -n "$block" ] || { printf 'no fenced gate-retry block\n' >&2; return 1; }
  grep -F "$FLOW_ARM_NEEDLE" <<<"$block" | grep -F "$FLOW_ARM_FREE_NEEDLE" | grep -qF "$FLOW_ARM_HALT_NEEDLE" ||
    { printf 'gate-retry block has no one-shot flow-test arm (%s; %s; %s)\n' "$FLOW_ARM_NEEDLE" "$FLOW_ARM_FREE_NEEDLE" "$FLOW_ARM_HALT_NEEDLE" >&2; return 1; }
}

FLOW_COMMAND_NEEDLE='bash .gaia/scripts/spec/flow-coverage.sh --spec {SPEC_PATH} --root <RESOLVED_ROOT> --plan-dir {PLAN_DIR} --flow-tests-out <RUN_FOLDER>/flow-tests.tsv'

check_flow_checks_block() {
  local block
  block="$(fence_with "$1" "$S_FLOW")"
  [ -n "$block" ] || { printf 'no fenced flow-checks block\n' >&2; return 1; }
  has_all "$block" "$FLOW_COMMAND_NEEDLE" 'before the wiki promotion' \
    'general-purpose' 'model: "sonnet"' 'free to fix code or test' \
    '{PLAN_DIR}/PROGRESS.md' '## Flow checks' '## Flow checks (HALTED)' 'Reason:' \
    'Stay halted (Recommended)' 'Discuss this' 'The retry bound is one' || return 1
  grep -qiE 're-runs? the script once' <<<"$block" || { printf 'flow-checks block does not re-run the script once\n' >&2; return 1; }
  # The fixer is per owning closing-phase task: the one whose Flow test line
  # names a failing flow.
  grep -F 'general-purpose' <<<"$block" | grep -qF '`Flow test` line' ||
    { printf 'the fixer is not dispatched per closing-phase task by its Flow test line\n' >&2; return 1; }
}

check_lifecycle_flow_section() {
  local file="$1" section contents headings
  section="$(section_of "$file" '## Pre-audit flow checks')"
  [ -n "$section" ] || { printf 'no ## Pre-audit flow checks section\n' >&2; return 1; }
  has_all "$section" 'flow-coverage.sh' '<RUN_FOLDER>/flow-tests.tsv' 'worthiness step' 'presence gate' \
    'flow-checks' || return 1
  local code
  for code in 0 1 2 3; do
    grep -qiE "exit[^.]*\b$code\b" <<<"$section" || { printf 'section does not say what exit %s means\n' "$code" >&2; return 1; }
  done
  # The Contents line lists every section in the order the sections appear.
  contents="$(grep -m1 '^Contents: ' "$file" | sed 's/^Contents: //; s/\.$//' | tr ';' '\n' | sed 's/^ *//; s/ *$//')"
  headings="$(awk '
    { t = $0; sub(/^[ \t]+/, "", t) }
    t ~ /^```/ { in_fence = !in_fence; next }
    !in_fence && /^## / { sub(/^## /, ""); print }' "$file")"
  [ "$(grep -c . <<<"$headings")" -gt 1 ] || { printf 'read too few headings from %s\n' "$file" >&2; return 1; }
  [ "$contents" = "$headings" ] || { printf 'Contents line does not list the sections in order:\n%s\nvs\n%s\n' "$contents" "$headings" >&2; return 1; }
}

NO_CLOSING_NEEDLE='Write no closing flow-test phase'
SPEC_LESS_OMITS_NEEDLE='a spec-less plan omits `flow-checks` and carries the rest'

# check_spec_less_rule <test stage> <planner>: a spec-less plan gets no closing
# phase from the test stage, and the planner omits its flow-checks block.
check_spec_less_rule() {
  grep -qF -- "$NO_CLOSING_NEEDLE" "$1" || { printf 'test stage lacks: %s\n' "$NO_CLOSING_NEEDLE" >&2; return 1; }
  grep -qF -- "$SPEC_LESS_OMITS_NEEDLE" "$2" || { printf 'planner.md lacks: %s\n' "$SPEC_LESS_OMITS_NEEDLE" >&2; return 1; }
}

check_halted_form() {
  local range
  range="$(range_of "$1" '**Stop conditions.**' '**Final summary.**')"
  [ -n "$range" ] || { printf 'no Stop conditions range\n' >&2; return 1; }
  has_all "$range" '`## Phase N, <title> (HALTED)`' '`Stay halted (Recommended)` first' 'then `Discuss this`'
}

BANNED_PHRASES=(
  'edit no test file'
  'edit no Playwright or other test file'
  'Never edit the executable body of a test'
  'New tests:'
  'test author'
  'red-split'
  'test-review'
  'uat-render'
  'uat-gate'
  'uat-pre-audit'
  'RED ledger'
  'routing table'
)

check_no_banned_phrase() {
  local file="$1" phrase hit
  [ "${#BANNED_PHRASES[@]}" -eq 12 ] || { printf 'read %s banned phrases, want 12\n' "${#BANNED_PHRASES[@]}" >&2; return 1; }
  for phrase in "${BANNED_PHRASES[@]}"; do
    hit="$(grep -nF -- "$phrase" "$file" || true)"
    [ -n "$hit" ] && { printf '%s still holds %s: %s\n' "$file" "$phrase" "$hit" >&2; return 1; }
  done
  return 0
}

# ---------- closing phase and build phases ----------

@test "the test stage ends a spec-derived plan with one closing flow-test phase, one task per flow, and planner.md names no test" {
  check_closing_phase "$TEST_STAGE_MD"
  check_planner_names_no_test "$PLANNER_MD"
}

@test "red twin: dropping the closing-phase, flow-line or planner no-test text fails" {
  check_closing_phase "$TEST_STAGE_MD"
  local copy="$BATS_TEST_TMPDIR/test-stage.md" needle
  for needle in "$CLOSING_PHASE_NEEDLE" "$ONE_TASK_PER_FLOW_NEEDLE" "$FLOW_LINE_NEEDLE" 'the one line' \
    "$FIXTURES_NEEDLE" '@covers' "$COMMAND_FLOW_NEEDLE"; do
    without "$TEST_STAGE_MD" "$needle" "$copy"
    run check_closing_phase "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
  without "$PLANNER_MD" "$PLANNER_NO_TEST_NEEDLE" "$copy"
  run check_planner_names_no_test "$copy"
  [ "$status" -ne 0 ]
}

# ---------- closing-phase gate and the gate-retry flow-test arm ----------

@test "the closing phase's gate runs each flow test by its runner and a failing run refuses the commit" {
  check_closing_gate "$TEST_STAGE_MD"
}

@test "the gate-retry block sends a failing flow test once to a fresh executor free to edit code or test, and halts on a second failure" {
  check_gate_retry_flow_arm "$PLANNER_MD"
}

@test "red twin: dropping a gate runner, the refusal or the one-retry sentence fails" {
  check_closing_gate "$TEST_STAGE_MD"
  check_gate_retry_flow_arm "$PLANNER_MD"
  local copy="$BATS_TEST_TMPDIR/planner.md" needle
  for needle in "$BATS_GATE_NEEDLE" "$VITEST_GATE_NEEDLE" "$GATE_REFUSAL_NEEDLE"; do
    without "$TEST_STAGE_MD" "$needle" "$copy"
    run check_closing_gate "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
  # Delete the whole retry sentence from the gate-retry block.
  awk -v needle="$FLOW_ARM_NEEDLE" 'index($0, needle) { next } { print }' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "the flow-test arm sentence is not in planner.md" >&2; return 1; }
  run check_gate_retry_flow_arm "$copy"
  [ "$status" -ne 0 ]
  for needle in "$FLOW_ARM_FREE_NEEDLE" "$FLOW_ARM_HALT_NEEDLE"; do
    without "$PLANNER_MD" "$needle" "$copy"
    run check_gate_retry_flow_arm "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
}

# ---------- pre-audit flow checks ----------

@test "the flow-checks block runs flow-coverage.sh, names a sonnet fixer per closing task, re-runs once and halts with the two options" {
  check_flow_checks_block "$PLANNER_MD"
}

@test "lifecycle.md carries a Pre-audit flow checks section and lists it on its Contents line in order" {
  check_lifecycle_flow_section "$LIFECYCLE_MD"
}

@test "red twin: dropping the flow-checks command, its bound or its halt question fails" {
  check_flow_checks_block "$PLANNER_MD"
  local copy="$BATS_TEST_TMPDIR/planner.md" needle
  for needle in '--flow-tests-out <RUN_FOLDER>/flow-tests.tsv' '--plan-dir {PLAN_DIR} ' 'model: "sonnet"' 'free to fix code or test' \
    'The retry bound is one' '## Flow checks (HALTED)' 'Stay halted (Recommended)'; do
    without "$PLANNER_MD" "$needle" "$copy"
    run check_flow_checks_block "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
}

@test "red twin: a lifecycle.md without the section, or with it missing from Contents, fails" {
  check_lifecycle_flow_section "$LIFECYCLE_MD"
  local copy="$BATS_TEST_TMPDIR/lifecycle.md"
  sed 's/^## Pre-audit flow checks$/## Something else/' "$LIFECYCLE_MD" >"$copy"
  run check_lifecycle_flow_section "$copy"
  [ "$status" -ne 0 ]
  sed -e '/^Contents: /s/Pre-audit flow checks; //' -e '/^Contents: /s/; Pre-audit flow checks\.$/./' "$LIFECYCLE_MD" >"$copy"
  cmp -s "$LIFECYCLE_MD" "$copy" && { echo "Contents line does not name the section" >&2; return 1; }
  run check_lifecycle_flow_section "$copy"
  [ "$status" -ne 0 ]
}

# ---------- spec-less plans and the ledger halt ----------

@test "a spec-less plan has no closing phase and no flow-checks block" {
  check_spec_less_rule "$TEST_STAGE_MD" "$PLANNER_MD"
}

@test "the ledger HALTED form and its Stay halted and Discuss this options are unchanged" {
  check_halted_form "$PLANNER_MD"
}

@test "red twin: dropping the spec-less rule or a HALTED option fails" {
  check_spec_less_rule "$TEST_STAGE_MD" "$PLANNER_MD"
  check_halted_form "$PLANNER_MD"
  local copy="$BATS_TEST_TMPDIR/planner.md" needle
  without "$TEST_STAGE_MD" "$NO_CLOSING_NEEDLE" "$copy"
  run check_spec_less_rule "$copy" "$PLANNER_MD"
  [ "$status" -ne 0 ]
  without "$PLANNER_MD" "$SPEC_LESS_OMITS_NEEDLE" "$copy"
  run check_spec_less_rule "$TEST_STAGE_MD" "$copy"
  [ "$status" -ne 0 ]
  for needle in '(HALTED)`' 'Stay halted (Recommended)' 'Discuss this'; do
    without "$PLANNER_MD" "$needle" "$copy"
    run check_halted_form "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
}

# ---------- no test-first phrase and no bar on editing a test ----------

@test "planner.md holds no test-first phrase and nothing barring an executor from editing its own tests" {
  check_no_banned_phrase "$PLANNER_MD"
}

@test "red twin: re-adding any banned phrase to planner.md fails the absence check" {
  check_no_banned_phrase "$PLANNER_MD"
  local copy="$BATS_TEST_TMPDIR/planner.md" phrase
  for phrase in "${BANNED_PHRASES[@]}"; do
    { cat "$PLANNER_MD"; printf '\nThe executor must %s here.\n' "$phrase"; } >"$copy"
    run check_no_banned_phrase "$copy"
    [ "$status" -ne 0 ] || { echo "re-adding '$phrase' did not fail" >&2; return 1; }
  done
}
