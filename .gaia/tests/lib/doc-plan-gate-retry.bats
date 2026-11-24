#!/usr/bin/env bats
#
# Doc-conformance suite for the plan orchestrator's phase gate retry.
#
# .claude/skills/gaia/references/plan/orchestrator-template.md holds the
# gate-retry step block the renderer emits into a generated ORCHESTRATOR.md,
# the executor's self-check in the task prompt template, the Stop conditions
# halt question, the resume detection's dirty-tree question and the ledger
# record the retry writes. A model executes that text, so an
# edit that drops one clause (the attribution rule, the per-kind cap,
# the conservative first option, the resume-time dirty-tree question) would
# ship silently. This suite pins each clause, and drives plan-resume-point.sh
# over a ledger holding a retry record.
#
# Method: every check takes a root directory and reads one region (a fenced
# block or a bullet range).
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPLATE_REL=".claude/skills/gaia/references/plan/orchestrator-template.md"
  RESUME_POINT="$REPO_ROOT/.gaia/scripts/plan-resume-point.sh"
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
}

# ---------- helpers ----------

# fence_with <file> <literal>: the lines of the first ``` fence holding a line
# that trims to <literal>.
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

# range_of <file> <start> <end>: the lines from the first start match up to,
# not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
}

trim_lines() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# in_order <text> <anchor>...: every anchor appears, each after the one before.
in_order() {
  local rest="$1" anchor after
  shift
  for anchor in "$@"; do
    after="${rest#*"$anchor"}"
    if [ "$after" = "$rest" ]; then
      printf 'anchor missing or out of order: %s\n' "$anchor" >&2
      return 1
    fi
    rest="$after"
  done
}

lacks() {
  case "$1" in
    *"$2"*) printf 'unexpected text present: %s\n' "$2" >&2; return 1 ;;
  esac
  return 0
}

need_text() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
}

# record_lines <text> <heading>: the heading line and the lines after it, up
# to the next blank line.
record_lines() {
  printf '%s\n' "$1" | awk -v heading="$2" '
    !inside && index($0, heading) == 1 { inside = 1 }
    inside && $0 == "" { exit }
    inside { print }'
}

retry_block() { fence_with "$1/$TEMPLATE_REL" "$S_RETRY" | trim_lines; }
invocation_range() { range_of "$1/$TEMPLATE_REL" '## Sub-agent invocation' '## Orchestrator-owned git flow' | trim_lines; }
ledger_range() { range_of "$1/$TEMPLATE_REL" '## Phase findings ledger' '## Stop conditions' | trim_lines; }
stop_range() { range_of "$1/$TEMPLATE_REL" '## Stop conditions' '## Simplify pass' | trim_lines; }
resume_range() { range_of "$1/$TEMPLATE_REL" '**Resume detection (cold-start' '## Pre-flight isolation' | trim_lines; }
summary_range() { range_of "$1/$TEMPLATE_REL" '## Final summary' '**The merge question.**' | trim_lines; }

green() {
  run "$1" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- checks ----------

check_retry_attribution() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '- **Attribute.**' \
    'A failure is attributable only when every error names a file exactly one task declares or a test file several tasks declare.' \
    'An error with no file path, on a file no task declares, or on a non-test file more than one task declares makes the failure unattributable.' \
    'A typecheck or lint error in a test file several tasks declare goes straight to that file'"'"'s **Shared-file executor** under **In-phase arm**, with no check 2.' || return 1
}

check_retry_cap() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '- **Halt instead.**' \
    'An unattributable failure, or a gate failure of a kind this phase already retried (a `(GATE RETRY k)` block for this phase in `{PLAN_DIR}/PROGRESS.md` with that `Kind:` line), halts under Stop conditions.' || return 1
}

# A static fix (typecheck, lint) and a test fix each get their own retry, so a
# lint fix never spends the retry a later test failure needs; two is the bound.
check_retry_kinds() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '**Phase gate retry (one static retry and one test retry per phase).**' \
    '- **Kind.**' \
    'A gate failure holding only typecheck, lint and file-length errors is static; one holding any failing test is a test failure, even with static errors beside it. Its retry takes the same kind.' \
    'A phase runs each kind at most once, so a static fix never spends the retry a later test failure needs, and a phase retries at most twice.' \
    '- **Attribute.**' \
    '- **Halt instead.**' \
    'a gate failure of a kind this phase already retried' \
    '- **Record the retry.**' \
    '`k` being 1 for the phase'"'"'s first retry and 2 for its second.' \
    'One retry writes one block, however many arms fire: its Tasks line lists every task any arm of the retry re-dispatches and every declaring task of a shared test file, and no arm writes another:' \
    '- **Flow-test arm.**' \
    'using the phase'"'"'s test retry; a second test failure halts under Stop conditions.' || return 1
}

check_retry_record() {
  local block record
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  record="$(record_lines "$block" '## Phase N, <title> (GATE RETRY k)')"
  need_text 'gate retry record' "$record" || return 1
  [ "$(printf '%s\n' "$record" | wc -l | tr -d ' ')" -eq 5 ] || { printf 'the retry record is not five lines\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 2p)" = 'Retry: k' ] || { printf 'record line 2 is not "Retry: k"\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 3p)" = 'Kind: <static or test>' ] || { printf 'record line 3 is not the Kind line\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 4p | cut -c1-7)" = 'Tasks: ' ] || { printf 'record line 4 does not name Tasks:\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 5p | cut -c1-10)" = 'Failures: ' ] || { printf 'record line 5 does not name Failures:\n' >&2; return 1; }
  lacks "$record" 'Commit:' || return 1
}

check_retry_redispatch() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '- **Re-dispatch the owning tasks.**' \
    'Leave the working tree as it is: no commit, stash, reset, checkout or discard.' \
    'Dispatch a fresh executor for each owning task' \
    'A task with no attributed error is not re-dispatched.' \
    'carries the original task prompt first, without its `Yield handoff:` line' \
    'then the line `The phase quality gate failed on files this task owns. Fix only these errors, within this task'"'"'s scope, and edit no other file; still run the typecheck and lint your task prompt requires before you return:`' \
    'then the gate output lines for its files.' \
    'A task with a file-length error gets, before that line, the line `A file over its length limit is split: move whole functions or sections into a new lib file beside it, or an existing one no other task of this phase declares, which you may create or edit despite the line below, and name it under ### Deviations from plan. Never trim wording and never raise a limit or ceiling. Re-run the failed file-length check on your files before you return.`' \
    'It carries no `Yield handoff:` line, so a retry executor never yields' \
    'Never continue an executor with SendMessage.' \
    '- **Re-run the gate.**' \
    'run the whole phase gate again' || return 1
}

check_yield_opt_in_excepts_retry() {
  local block
  block="$(fence_with "$1/$TEMPLATE_REL" '<!-- gaia:orchestrator-step yield-handling -->' | trim_lines)"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" 'Every task executor dispatch except a phase gate retry opts into the sub-agent context checkpoint' || return 1
}

# A Playwright test from outside the phase that the phase's own code breaks
# goes to the phase's implementers once: the test passed at a known point, so
# the phase's app diff is the likely cause. A harness or environment failure,
# or a test with no known-green point, still halts, and a failure set that
# holds any halting failure halts whole.
check_outside_arm() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    'When a failing Playwright test is in an outside Playwright file and passes the three checks below, send it to the candidate tasks'"'"' implementers (the outside arm below).' \
    'Never fix it on the main thread.' \
    'One retry carries every arm the failure set needs; a failure that halts halts the whole set.' \
    '- **Playwright test outside this phase.**' \
    'otherwise it halts under Stop conditions with no retry, `Reason: a Playwright test outside this phase fails in this phase'"'"'s gate`' \
    'naming each `file › test name`' \
    '(`known-green: phase <k> gate`)' \
    '(`known-green: merge-base`)' \
    'at least one test in the same run passed, and the failure is raised inside a test body' \
    'not by the web server start, global setup, a setup file, a module import or a missing build.' \
    'declares a non-test file the phase changed' \
    '- **Halt instead.**' \
    'or each `file › test name` of an outside Playwright failure followed by its `known-green: phase <k> gate` or `known-green: merge-base`' \
    '- **Outside arm.**' \
    'For an outside Playwright failure that passes all three checks, in place of **Attribute**,' \
    'record the retry as above with each candidate on its Tasks line, then dispatch a fresh executor for each candidate task' \
    'Fix the code, or update the test when this phase changed the asserted behavior on purpose, and say which under ### Deviations from plan.' \
    'If the cause is not in this task'"'"'s files, edit nothing and say so under ### Findings.' \
    'A candidate that also owns a failing flow test gets one executor whose prompt carries both arms'"'"' lines.' \
    'When no candidate edits a file, the phase halts under Stop conditions with no re-run, `Reason: a Playwright test outside this phase fails in this phase'"'"'s gate`, naming each `file › test name`.' \
    '- **Re-run the gate.**' || return 1
}

# A failing test in a file one task of this phase declares goes to that task's
# fresh executor inside the phase's one test retry; a file several tasks
# declare goes to one executor limited to that file, whose named cause file is
# forwarded like the single-owner arm's. An environment failure still halts.
check_in_phase_arm() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    'When a failing test of any runner is in a file a task of this phase declares and passes check 2 below, send it to that task, or to one executor for the file when several tasks declare it (the in-phase arm below).' \
    'Never fix it on the main thread.' \
    'Any other gate failure halts under Stop conditions with no retry.' \
    'each `file › test name` of a failing in-phase test' \
    '- **In-phase arm.**' \
    'For a failing test in a file a task of this phase declares, other than a flow test the flow-test arm takes, in place of **Attribute**, the test file alone decides the owner.' \
    '- **Who owns the failure.** When check 2 under **Playwright test outside this phase** holds, the failure goes to the task that declares it when exactly one task declares it, and to a shared-file executor when several tasks of this phase declare it;' \
    'otherwise it halts under Stop conditions with no retry.' \
    '- **Single-owner executor.** For one declaring task, record the retry as above, then dispatch a fresh executor for that task:' \
    'the original task prompt, without its `Yield handoff:` line, then the line `A test in a file this task declares fails in this phase'"'"'s gate. Fix the code, or update the test when this phase changed the asserted behavior on purpose, and say which under ### Deviations from plan. The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in this task'"'"'s files, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The failing tests:`' \
    'A task that another arm or **Re-dispatch the owning tasks** also re-dispatches gets one executor whose prompt carries each one'"'"'s lines, each line followed by its own failures and applying only to them; its edit limit is then the files the task declares, plus the lib file of a file-length split when the task carries a file-length error.' \
    '- **Shared-file executor.** For several declaring tasks, record the retry as above, then dispatch one fresh executor per such test file, separate from any executor this retry sends a declaring task:' \
    'the original task prompt of the declaring task with the lowest task number, without its `Yield handoff:` line, then the line `Read these task docs for context; they do not widen what you may edit:`, then each other declaring task'"'"'s `task-*.md` path,' \
    'then the line `A test in a file several tasks of this phase declare fails in this phase'"'"'s gate. Edit only that test file, and in it only its failing tests and the shared setup they use, such as mocks and beforeEach, updating them when this phase changed the asserted behavior on purpose, and say what you changed under ### Deviations from plan. The task docs and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in the test file, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The failing tests:`' \
    'A typecheck or lint error in that test file goes to the same executor:' \
    'its prompt carries the `A test in a file several tasks` line and the failing tests only when a test there fails, and the line `The phase quality gate failed on this test file. Fix these errors in it when their cause is in this test file, such as a call to code this phase changed on purpose, edit no other file, and still run the typecheck and lint your task prompt requires before you return. The task docs and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide whether the test file or the code it calls is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in the test file, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The errors:`, then the gate output lines for that file.' \
    'Each line applies only to the failures that follow it.' \
    'Every other executor this retry sends a declaring task ends its prompt with the line `Leave <test file> alone: another executor owns it in this retry.`' \
    '- **Cause forwarding.** When the single-owner or shared-file executor edits no file and its `Cause file:` names a file exactly one task of this phase declares and, for a single-owner executor, that task is not its own task, the same retry goes on to that task:' \
    'append `Cause owner: task-<T>.md (<cause file>)` to `{PLAN_DIR}/PROGRESS.md` under the retry record, then, once any executor this retry already sent that task has returned, dispatch a fresh executor for it:' \
    'Another executor traced a failure in this phase'"'"'s gate to a file this task declares.' \
    'Fix the cause within this task'"'"'s files, edit no other file, and say what you changed under ### Deviations from plan.' \
    'then that executor'"'"'s ### Findings, then the failing test or gate output lines it was sent.' \
    '- **Halt.** When the single-owner or shared-file executor edits no file and names no such file, or no executor this retry sent the cause owner edited a file, the phase halts under Stop conditions with no re-run, `Reason: a test file this phase declares fails in this phase'"'"'s gate`, naming each `file › test name` and each `file:line` error.' \
    '- **Outside arm.**' \
    '- **Re-run the gate.** Once every re-dispatched executor returns, including a cause owner'"'"'s,' || return 1
}

# The gate-retry block alone owns which gate failures retry: every other
# failure halts under Stop conditions, and Stop conditions defers to the retry.
check_step_owns_no_retry() {
  local block range
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    'Any other gate failure halts under Stop conditions with no retry.' || return 1
  range="$(stop_range "$1")"
  need_text 'Stop conditions' "$range" || return 1
  in_order "$range" 'a quality-gate failure the phase gate retry does not settle' || return 1
}

check_executor_self_check() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    'the project'"'"'s typecheck script or route typegen' \
    'Typecheck your own work before you return' \
    'in a wave of one task, `pnpm -C <package dir> typecheck`' \
    'in a wave of more than one, `pnpm -C <package dir> exec tsc --noEmit`' \
    'In either wave act only on errors in files your task owns' \
    'goes under `### Findings`' || return 1
}

check_stop_question() {
  local range
  range="$(stop_range "$1")"
  need_text 'Stop conditions' "$range" || return 1
  in_order "$range" \
    'On any sub-agent failure, or a quality-gate failure the phase gate retry does not settle: STOP and surface to the user.' \
    '`## Phase N, <title> (HALTED)`' \
    '`Gate retries: <0, 1 or 2>`' \
    'then ask one `AskUserQuestion`' \
    '`Stay halted (Recommended)` first, which ends the run with the phase' \
    '`Discuss this`' \
    '`Answered: <label>`' || return 1
}

check_ledger_documents_retry_block() {
  local range
  range="$(ledger_range "$1")"
  need_text 'phase findings ledger bullet' "$range" || return 1
  in_order "$range" \
    'A gate retry block is headed exactly `## Phase N, <title> (GATE RETRY k)`, its first content line is `Retry: k`, its second is `Kind: static` or `Kind: test`' \
    'then a `Cause owner:` line when the in-phase arm sent the failure on, and it has no `Commit:` line. The gate-retry step writes it.' || return 1
}

check_summary_retries_line() {
  local range
  range="$(summary_range "$1")"
  need_text 'Final summary' "$range" || return 1
  in_order "$range" \
    'a yields line, a gate retries line' \
    '`Gate retries: Phase <N>, Phase <M>`' \
    '`Gate retries: none`' || return 1
}

check_dirty_resume_question() {
  local range
  range="$(resume_range "$1")"
  need_text 'Resume detection' "$range" || return 1
  in_order "$range" \
    '**Failed reconnect:**' \
    '- **Dirty tree on resume.**' \
    'one `AskUserQuestion`' \
    '`Stay halted (Recommended)` first, which ends the run' \
    '`Discuss this`' \
    'It never offers to stash, discard or commit the edits' \
    '`Reason: dirty working tree`' \
    '`Answered: <label>`' || return 1
}

# ---------- resume-point fixtures ----------

resume_fixture() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m one
  SHA_ONE="$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m two
  SHA_TWO="$(git -C "$REPO" rev-parse --short HEAD)"
  PROGRESS_DIR="$BATS_TEST_TMPDIR/progress"
  mkdir -p "$PROGRESS_DIR"
}

resume_point() {
  bash "$RESUME_POINT" --plan-dir "$PROGRESS_DIR" --phases 3 --git-dir "$REPO" | sed -n 1p
}

# ---------- tests ----------

@test "a failure is attributable only when every error names a file exactly one task declares" {
  green check_retry_attribution
}

@test "each retry kind runs at most once per phase and an unattributable failure halts" {
  green check_retry_cap
}

@test "a static retry and a test retry each run once per phase, so a static fix never spends the test retry" {
  green check_retry_kinds
}

@test "the retry record carries no Commit line" {
  green check_retry_record
}

@test "the retry re-dispatches only owning tasks, fresh, with the original prompt then the gate output" {
  green check_retry_redispatch
}

@test "the yield-handling block exempts a gate retry from the yield opt-in" {
  green check_yield_opt_in_excepts_retry
}

@test "an outside Playwright test this phase broke goes to the phase's implementers once, else halts naming the case" {
  green check_outside_arm
}

@test "an in-phase test of any runner goes to the one task that declares it, once, else halts" {
  green check_in_phase_arm
}

@test "the gate-retry block alone owns which gate failures retry, every other failure halting" {
  green check_step_owns_no_retry
}

@test "the executor typechecks its own work, wave-safe" {
  green check_executor_self_check
}

@test "the halt asks a question with Stay halted recommended first and records the pick" {
  green check_stop_question
}

@test "the ledger documents the gate retry block" {
  green check_ledger_documents_retry_block
}

@test "the final summary prints a gate retries line" {
  green check_summary_retries_line
}

@test "a dirty tree on resume asks with Stay halted recommended first and offers no discard" {
  green check_dirty_resume_question
}

@test "a gate retry block with no later commit resumes at its phase" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (GATE RETRY 1)\nRetry: 1\nTasks: task-db.md\nFailures: app/db.ts:26 TS2578\n' "$SHA_ONE" >"$PROGRESS_DIR/PROGRESS.md"
  [ "$(resume_point)" = "2" ]
}

@test "a commit block after the gate retry block completes the phase" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (GATE RETRY 1)\nRetry: 1\nTasks: task-db.md\nFailures: app/db.ts:26 TS2578\n\n## Phase 2, Two\nCommit: %s\n\n_No notes._\n' "$SHA_ONE" "$SHA_TWO" >"$PROGRESS_DIR/PROGRESS.md"
  [ "$(resume_point)" = "3" ]
}

# ---------- human-only halt (kept apart from the gate-retry arm cases) ----------

# check_human_only_halt <root>: a failure only the human can clear may lead with
# a verified continuing option, and a failed rerun ends the run with no new
# question, so a picker taking the recommendation stops one rerun later.
check_human_only_halt() {
  local range
  range="$(stop_range "$1")"
  need_text 'Stop conditions' "$range" || return 1
  in_order "$range" \
    '`Stay halted (Recommended)` first, which ends the run with the phase' \
    '`Answered: <label>`' \
    'A failure only the human can clear' \
    '`I did it (Recommended)` first, which reruns the whole phase gate from its first step (for a sub-agent failure, it re-dispatches that sub-agent first) and continues only on a pass' \
    'then `Stay halted`' \
    'A failed rerun appends `Rerun: failed` and its error under the `Answered:` line, then ends the run and asks no new question.' || return 1
}

@test "a failure only the human can clear recommends the verified rerun, bounded to one" {
  green check_human_only_halt
}

