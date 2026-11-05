#!/usr/bin/env bats
#
# Doc-conformance suite for the plan orchestrator's phase gate retry.
#
# .claude/skills/gaia/references/plan/planner.md holds the gate-retry step
# block a planner copies into a generated ORCHESTRATOR.md, the executor's
# self-check in the task prompt template, the Stop conditions halt question,
# the resume detection's dirty-tree question and the ledger record the retry
# writes. A model executes that text, so an
# edit that drops one clause (the attribution rule, the once-per-phase cap,
# the conservative first option, the resume-time dirty-tree question) would
# ship silently. This suite pins each clause, and drives plan-resume-point.sh
# over a ledger holding a retry record.
#
# Method: every check takes a root directory and reads one region (a fenced
# block or a bullet range); each red twin mutates one clause of a scratch
# copy, proves the copy changed, and runs the same check against it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
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

retry_block() { fence_with "$1/$PLANNER_REL" "$S_RETRY" | trim_lines; }
invocation_range() { range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | trim_lines; }
ledger_range() { range_of "$1/$PLANNER_REL" '**Phase findings ledger (' '- **Stop conditions.**' | trim_lines; }
stop_range() { range_of "$1/$PLANNER_REL" '- **Stop conditions.**' '- **Final summary.**' | trim_lines; }
resume_range() { range_of "$1/$PLANNER_REL" '**Resume detection (cold-start' '- **Pre-flight isolation.**' | trim_lines; }
summary_range() { grep -F -- '- **Final summary.**' "$1/$PLANNER_REL" | trim_lines; }

# mutated_tree <old> <new>: a scratch copy of planner.md (TREE) with the first
# fixed-string <old> replaced by <new>, proved changed.
mutated_tree() {
  local content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE/$(dirname "$PLANNER_REL")"
  content="$(cat "$REPO_ROOT/$PLANNER_REL"; printf x)"
  mutated="${content/"$1"/"$2"}"
  printf '%s' "${mutated%x}" >"$TREE/$PLANNER_REL"
  if cmp -s "$REPO_ROOT/$PLANNER_REL" "$TREE/$PLANNER_REL"; then
    printf 'mutation left planner.md unchanged: %s\n' "$1" >&2
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

# ---------- checks ----------

check_retry_scope() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '**Phase gate retry (at most once per phase).**' \
    'When the phase'"'"'s `pnpm typecheck` or `pnpm lint` fails' \
    'Never fix it on the main thread.' \
    'Any other gate failure, the owning-phase UAT gate included, halts under Stop conditions with no retry.' || return 1
}

check_red_deny_halts() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    'Any other gate failure, the owning-phase UAT gate included, halts under Stop conditions with no retry.' \
    'A phase commit the RED gate (`.claude/hooks/red-verify-commit-check.sh`) denies halts the same way' \
    'once the implementation exists no honest run can fail' \
    'never edit, revert or set aside implementation, here or through an executor and in any number of calls, to record a RED' \
    'the HALTED block names each denied test (file, test name, why no RED exists).' || return 1
}

check_retry_attribution() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '- **Attribute.**' \
    'A failure is attributable only when every error names a file exactly one task declares.' \
    'An error with no file path, or on a file no task or more than one task declares, makes the failure unattributable.' || return 1
}

check_retry_cap() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    '- **Halt instead.**' \
    'An unattributable failure, or a gate failure in a phase that already has a `(GATE RETRY 1)` block in `{PLAN_DIR}/PROGRESS.md`, halts under Stop conditions.' || return 1
}

check_retry_record() {
  local block record
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  record="$(record_lines "$block" '## Phase N, <title> (GATE RETRY 1)')"
  need_text 'gate retry record' "$record" || return 1
  [ "$(printf '%s\n' "$record" | wc -l | tr -d ' ')" -eq 4 ] || { printf 'the retry record is not four lines\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 2p)" = 'Retry: 1' ] || { printf 'record line 2 is not "Retry: 1"\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 3p | cut -c1-7)" = 'Tasks: ' ] || { printf 'record line 3 does not name Tasks:\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 4p | cut -c1-10)" = 'Failures: ' ] || { printf 'record line 4 does not name Failures:\n' >&2; return 1; }
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
    'then the line `The phase quality gate failed on files this task owns. Fix only these errors, within this task'"'"'s scope, and edit no other file:`' \
    'then the gate output lines for its files.' \
    'It carries no `Yield handoff:` line, so a retry executor never yields' \
    'Never continue an executor with SendMessage.' \
    '- **Re-run the gate.**' \
    'run the whole phase gate again' || return 1
}

check_yield_opt_in_excepts_retry() {
  local block
  block="$(fence_with "$1/$PLANNER_REL" '<!-- gaia:orchestrator-step yield-handling -->' | trim_lines)"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" 'Every task executor dispatch except a phase gate retry opts into the sub-agent context checkpoint' || return 1
}

check_retry_not_a_grant() {
  local block
  block="$(retry_block "$1")"
  need_text 'gate-retry block' "$block" || return 1
  in_order "$block" \
    'The retry is not a grant:' \
    'never widens a task'"'"'s scope' \
    'the rendered UAT block in the original prompt still binds' || return 1
}

check_executor_self_check() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    'the project'"'"'s typecheck script or route typegen' \
    '**The prompt template MUST also require a typecheck of the sub-agent'"'"'s own work before it returns**' \
    'in a wave of one task, `pnpm -C <package dir> typecheck`' \
    'in a wave of more than one, `pnpm -C <package dir> exec tsc --noEmit`' \
    'in either wave the sub-agent acts only on errors in files its task owns' \
    'goes under `### Findings`' || return 1
}

check_stop_question() {
  local range
  range="$(stop_range "$1")"
  need_text 'Stop conditions' "$range" || return 1
  in_order "$range" \
    'On any sub-agent failure, or a quality-gate failure the phase gate retry does not settle: STOP and surface to the user.' \
    '`## Phase N, <title> (HALTED)`' \
    '`Gate retries: <0 or 1>`' \
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
    'A gate retry block is headed exactly `## Phase N, <title> (GATE RETRY 1)`, its first content line is `Retry: 1`' \
    'and it has no `Commit:` line. The gate-retry step writes it.' || return 1
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

@test "the gate-retry block retries only typecheck and lint, never inline, and halts on any other gate" {
  green check_retry_scope
}

@test "red twin: a retry that also covers the UAT gate fails" {
  red check_retry_scope 'the owning-phase UAT gate included, halts' 'the owning-phase UAT gate included, retries'
}

@test "a RED-gate commit deny halts, and implementation is never broken to record a RED" {
  green check_red_deny_halts
}

@test "red twin: a RED deny that retries instead of halting fails" {
  red check_red_deny_halts 'denies halts the same way' 'denies gets one retry'
}

@test "red twin: a RED rule that lets an executor set implementation aside fails" {
  red check_red_deny_halts 'here or through an executor and in any number of calls' 'here, in one call'
}

@test "a failure is attributable only when every error names a file exactly one task declares" {
  green check_retry_attribution
}

@test "red twin: attribution that accepts a file several tasks declare fails" {
  red check_retry_attribution 'names a file exactly one task declares.' 'names a file some task declares.'
}

@test "the retry runs at most once per phase and an unattributable failure halts" {
  green check_retry_cap
}

@test "red twin: a second retry in the same phase fails" {
  red check_retry_cap 'already has a `(GATE RETRY 1)` block in' 'already has two `(GATE RETRY 1)` blocks in'
}

@test "the retry record carries no Commit line" {
  green check_retry_record
}

@test "red twin: a retry record carrying a Commit line fails" {
  red check_retry_record $'Retry: 1\n            Tasks: <task-<T>.md' $'Retry: 1\n            Commit: abc1234'
}

@test "the retry re-dispatches only owning tasks, fresh, with the original prompt then the gate output" {
  green check_retry_redispatch
}

@test "red twin: a retry that commits first fails" {
  red check_retry_redispatch 'Leave the working tree as it is: no commit, stash, reset, checkout or discard. Dispatch a fresh executor' 'Commit the working tree first. Dispatch a fresh executor'
}

@test "red twin: a retry prompt that opts into yielding fails" {
  red check_retry_redispatch 'It carries no `Yield handoff:` line, so a retry executor never yields' 'It ends with a `Yield handoff:` line'
}

@test "red twin: a retry that continues the executor with SendMessage fails" {
  red check_retry_redispatch 'Never continue an executor with SendMessage.' 'Continue the executor with SendMessage.'
}

@test "the yield-handling block exempts a gate retry from the yield opt-in" {
  green check_yield_opt_in_excepts_retry
}

@test "red twin: a yield block that opts every dispatch in fails" {
  red check_yield_opt_in_excepts_retry 'dispatch except a phase gate retry opts' 'dispatch opts'
}

@test "the retry grants nothing and the UAT block still binds" {
  green check_retry_not_a_grant
}

@test "red twin: a retry that drops the UAT binding fails" {
  red check_retry_not_a_grant 'the rendered UAT block in the original prompt still binds' 'the UAT block is lifted'
}

@test "the executor typechecks its own work, wave-safe" {
  green check_executor_self_check
}

@test "red twin: a multi-task wave that acts on every error fails" {
  red check_executor_self_check 'acts only on errors in files its task owns' 'acts on every error'
}

@test "the halt asks a question with Stay halted recommended first and records the pick" {
  green check_stop_question
}

@test "red twin: a halt that recommends discussing first fails" {
  red check_stop_question '`Stay halted (Recommended)` first, which ends the run with' '`Discuss this (Recommended)` first, which ends the run with'
}

@test "the ledger documents the gate retry block" {
  green check_ledger_documents_retry_block
}

@test "red twin: a ledger retry block carrying a Commit line fails" {
  red check_ledger_documents_retry_block 'and it has no `Commit:` line. The gate-retry step' 'and it has a `Commit:` line. The gate-retry step'
}

@test "the final summary prints a gate retries line" {
  green check_summary_retries_line
}

@test "red twin: a summary without the gate retries line fails" {
  red check_summary_retries_line 'a yields line, a gate retries line' 'a yields line'
}

@test "a dirty tree on resume asks with Stay halted recommended first and offers no discard" {
  green check_dirty_resume_question
}

@test "red twin: a resume question that offers to discard the edits fails" {
  red check_dirty_resume_question 'It never offers to stash, discard or commit the edits' 'It offers to discard the edits'
}

@test "red twin: a resume question that recommends discussing first fails" {
  red check_dirty_resume_question '`Stay halted (Recommended)` first, which ends the run' '`Discuss this (Recommended)` first, which ends the run'
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
