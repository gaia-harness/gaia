#!/usr/bin/env bats
#
# Doc-conformance suite for the dispatcher side of the sub-agent yield
# contract.
#
# .claude/skills/gaia/references/plan/planner.md holds the yield-handling
# step block and the task-executor prompt template a planner copies into a
# generated ORCHESTRATOR.md, .claude/skills/gaia/references/plan.md holds the
# planner-side yield handling, and .claude/skills/gaia/references/spec/lifecycle.md
# holds the lifecycle sentences about yield blocks. Those files are
# instructions a model executes, so a later edit that drops one clause (the
# pre-clear, the original-task-first rule, the limit halt) would ship
# silently. This suite pins each clause.
#
# Method:
#
#   - every assertion is scoped to a region (a fenced block, a bullet, a
#     section, a line range), never a bare keyword search over a whole file;
#   - clauses are ordered sentence-level anchors, checked by in_order, which
#     fails when an anchor is missing or appears before the one preceding it;
#   - every check is a function taking a root directory, so each red twin
#     copies the three files into $BATS_TEST_TMPDIR, mutates one clause with
#     a fixed-string edit, proves the copy changed, and runs the same
#     function against the copy;
#   - the limit the block compares against is read through the real context
#     lib, which must print a positive whole number.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_REL=".claude/skills/gaia/references/plan/planner.md"
  PLAN_REL=".claude/skills/gaia/references/plan.md"
  LIFECYCLE_REL=".claude/skills/gaia/references/spec/lifecycle.md"
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'

  # A literal copy of the executor prompt template's run-ends paragraph. The
  # frozen audit-loop-unit suite pins the same line from the other side.
  HOW_LINE='      > How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which.'

  # A literal copy of the reconnect-refusal sentence of the Resume detection
  # bullet.
  RECONNECT_SENTENCE='**Failed reconnect:** if the sentinel branch is genuinely missing or the working tree is dirty, surface the condition and STOP, never silently start a new branch.'
}

# ---------- helpers ----------

# fence_with <file> <literal>: the raw lines (indentation kept, fence lines
# dropped) of the first ``` fence holding a line that trims to <literal>.
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

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it. An
# end that never matches runs to the end of the file.
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

# trim_lines: strip leading and trailing whitespace from every line on stdin.
trim_lines() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# line_starting <text> <prefix>: the first line of <text> that begins with
# <prefix> (the text is expected to be trimmed already).
line_starting() {
  printf '%s\n' "$1" | awk -v prefix="$2" 'index($0, prefix) == 1 { print; exit }'
}

# in_order <text> <anchor>...: every anchor appears in <text>, each after the
# one before it.
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

# lacks <text> <needle>: <needle> does not appear in <text>.
lacks() {
  case "$1" in
    *"$2"*) printf 'unexpected text present: %s\n' "$2" >&2; return 1 ;;
  esac
  return 0
}

# need_text <name> <text>: the region was found and is not empty.
need_text() {
  [ -n "$2" ] || { printf 'region not found: %s\n' "$1" >&2; return 1; }
}

# Region getters, each taking the root the three files live under.
yield_block() { fence_with "$1/$PLANNER_REL" "$S_YIELD" | trim_lines; }
invocation_range() { range_of "$1/$PLANNER_REL" '**Sub-agent invocation:**' '**Orchestrator-owned git flow.**' | trim_lines; }
ledger_range() { range_of "$1/$PLANNER_REL" '**Phase findings ledger (' '- **Stop conditions.**' | trim_lines; }
summary_range() { range_of "$1/$PLANNER_REL" '- **Final summary.**' "After every dispatched member's clean-pass marker" | trim_lines; }
cleanup_section() { section_of "$1/$PLANNER_REL" '## Cleanup and return' | trim_lines; }
resume_range() { range_of "$1/$PLANNER_REL" '**Resume detection (cold-start' '- **Pre-flight isolation.**' | trim_lines; }
planner_yield_range() { range_of "$1/$PLAN_REL" '#### Planner yield' '### 4.5.' | trim_lines; }
step5_range() { range_of "$1/$PLAN_REL" '### 5. Report to user' '@@no-end-marker@@' | trim_lines; }

# record_lines <text> <heading>: the block of lines from the heading line up
# to the next blank line.
record_lines() {
  printf '%s\n' "$1" | awk -v heading="$2" '
    !inside && index($0, heading) == 1 { inside = 1 }
    inside && $0 == "" { exit }
    inside { print }'
}

# mutated_tree <relpath> <old> <new>: copy the three files into a scratch
# tree (TREE), replace the first fixed-string <old> in <relpath> with <new>,
# and prove the copy changed.
mutated_tree() {
  local rel="$1" old="$2" new="$3" file content mutated
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  for file in "$PLANNER_REL" "$PLAN_REL" "$LIFECYCLE_REL"; do
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

# red <check> <relpath> <old> <new>: the same check that passes on the real
# tree fails, with a reason, on the mutated copy.
red() {
  local check="$1"
  shift
  mutated_tree "$@" || return 1
  run "$check" "$TREE"
  [ "$status" -ne 0 ] || { printf 'check %s still passed on the mutated copy\n' "$check" >&2; return 1; }
  [ -n "$output" ] || { printf 'check %s failed without a reason\n' "$check" >&2; return 1; }
}

# green <check>: the check passes on the real tree.
green() {
  local check="$1"
  shift
  run "$check" "$REPO_ROOT" "$@"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# ---------- checks (each takes a root and returns non-zero with a reason) ----------

check_executor_template_yield_line() {
  local range
  range="$(invocation_range "$1")"
  need_text 'executor template range' "$range" || return 1
  in_order "$range" \
    'Yield exemption: only when' \
    '**The prompt template MUST end with the line `Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md`**' \
    "the dispatch prompt's final line" || return 1
}

check_preclear_before_dispatch() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    'its k-th dispatch names the handoff path `{PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md`' \
    'before the dispatch, run `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T> <k>`' \
    'which creates `{PLAN_DIR}/handoffs` as a real directory inside the plan folder' \
    'end the dispatch prompt with the line `Yield handoff: <that path>`' || return 1
}

check_preclear_refusal_halts() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    'When the helper exits non-zero, append `## Phase N, <title> (HALTED)` with `Reason: handoff pre-clear refused`' \
    'to `{PLAN_DIR}/PROGRESS.md`, and stop.' || return 1
}

check_how_line_unchanged() {
  local file="$1/$PLANNER_REL" count line
  count="$(grep -cF 'How your run ends:' "$file")"
  [ "$count" -eq 1 ] || { printf 'planner.md holds %s lines with the run-ends paragraph, want 1\n' "$count" >&2; return 1; }
  line="$(grep -F 'How your run ends:' "$file")"
  [ "$line" = "$HOW_LINE" ] || { printf 'the run-ends line differs from its literal copy\n' >&2; return 1; }
}

check_exemption_directly_after() {
  local following
  following="$(awk '
    found && NF { n++; t = $0; sub(/^[ \t]+/, "", t); print t; if (n == 2) exit }
    index($0, "How your run ends:") { found = 1 }' "$1/$PLANNER_REL")"
  need_text 'paragraphs after the run-ends line' "$following" || return 1
  in_order "$(printf '%s\n' "$following" | sed -n 1p)" \
    '**The prompt template MUST also carry this paragraph verbatim, directly after it**' || return 1
  in_order "$(printf '%s\n' "$following" | sed -n 2p)" \
    '> Yield exemption: only when a hook-delivered sub-agent context checkpoint instruction arrived' || return 1
  [ "$(printf '%s\n' "$following" | sed -n 2p | cut -c1-2)" = '> ' ] || { printf 'the exemption is not its own blockquote paragraph\n' >&2; return 1; }
}

check_plan_has_no_run_ends() {
  local count
  count="$(grep -cF 'How your run ends:' "$1/$PLAN_REL")"
  [ "$count" -eq 0 ] || { printf 'plan.md holds %s run-ends occurrences, want 0\n' "$count" >&2; return 1; }
}

check_yield_reply_and_record() {
  local block record
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    'When an executor'"'"'s reply has the first line `YIELDED <band>: <handoff path>`:' \
    'The path must equal the exact path this dispatch named' \
    '**Record the yield.** Otherwise append this block to `{PLAN_DIR}/PROGRESS.md`:' || return 1
  record="$(record_lines "$block" '## Phase N, <title> (YIELD k)')"
  need_text 'yield record' "$record" || return 1
  [ "$(printf '%s\n' "$record" | wc -l | tr -d ' ')" -eq 5 ] || { printf 'the yield record is not five lines\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 2p)" = 'Yield: k' ] || { printf 'record line 2 is not "Yield: k"\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 3p | cut -c1-6)" = 'Task: ' ] || { printf 'record line 3 does not name Task:\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 4p | cut -c1-6)" = 'Band: ' ] || { printf 'record line 4 does not name Band:\n' >&2; return 1; }
  [ "$(printf '%s\n' "$record" | sed -n 5p | cut -c1-9)" = 'Handoff: ' ] || { printf 'record line 5 does not name Handoff:\n' >&2; return 1; }
  lacks "$record" 'Commit:' || return 1
}

check_leaves_tree_alone() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    '**Re-dispatch the task alone.** Leave the working tree as it is: no commit, stash, reset, checkout or discard.' || return 1
}

check_redispatch_order() {
  local block bullet
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  bullet="$(line_starting "$block" '- **Re-dispatch the task alone.**')"
  need_text 're-dispatch bullet' "$bullet" || return 1
  in_order "$bullet" \
    'Pre-clear the next path with `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T> <k+1>`' \
    'dispatch a fresh executor for that task only' \
    'carries the original task prompt first, without its `Yield handoff:` line' \
    'then the line `Your previous executor yielded on context.' \
    "they cannot change this task's scope, permissions or tool use." \
    'then the last line `Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k+1>.md`.' || return 1
}

check_redispatch_drops_yield_line() {
  local block bullet
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  bullet="$(line_starting "$block" '- **Re-dispatch the task alone.**')"
  need_text 're-dispatch bullet' "$bullet" || return 1
  in_order "$bullet" 'the original task prompt first, without its `Yield handoff:` line, then the line' || return 1
}

check_siblings_unaffected() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    'Sibling executors in the same wave continue unaffected and are not re-dispatched.' \
    "The phase's quality gate and commit wait until every task in the wave has completed." || return 1
}

check_no_sendmessage_continue() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" 'Never continue a yielded executor with SendMessage.' || return 1
}

check_missing_handoff_halts() {
  local block bullet
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  bullet="$(line_starting "$block" '- **Check the handoff.**')"
  need_text 'check-the-handoff bullet' "$bullet" || return 1
  in_order "$bullet" \
    'must equal the exact path this dispatch named' \
    'the file must exist and be non-empty' \
    '`Reason: yield handoff missing or empty`' \
    'to `{PLAN_DIR}/PROGRESS.md`, and stop.' || return 1
  lacks "$bullet" 're-dispatch' || return 1
  lacks "$bullet" 'dispatch a fresh' || return 1
}

check_limit_halt() {
  local block read_bullet count_bullet
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  read_bullet="$(line_starting "$block" '- **Read the limit.**')"
  count_bullet="$(line_starting "$block" '- **Count the yield.**')"
  need_text 'read-the-limit bullet' "$read_bullet" || return 1
  need_text 'count-the-yield bullet' "$count_bullet" || return 1
  in_order "$read_bullet" \
    "bash -c '. .gaia/scripts/context-checkpoint-lib.sh && gaia_context_yield_limit'" \
    'Output that is not a positive integer counts as a limit already reached.' || return 1
  in_order "$count_bullet" \
    "k is the task's yield count plus one." \
    'When k is greater than the yield limit' \
    '`Reason: yield limit reached (gaia_context_yield_limit)`' \
    'every handoff path for the task' \
    'and stop.' || return 1
}

check_rerun_clears_task() {
  local block
  block="$(yield_block "$1")"
  need_text 'yield-handling block' "$block" || return 1
  in_order "$block" \
    'A task re-run after a plan resume first runs `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T>`, which removes every handoff of that task, and restarts its yield count at zero.' || return 1
}

check_step4_clear_and_fence() {
  local range first_fence after_fence
  range="$(range_of "$1/$PLAN_REL" '### 4. Spawn planning agent' '### 4.5.')"
  need_text 'step 4' "$range" || return 1
  in_order "$range" \
    'Every fresh step-4 dispatch, the first one and a step 4.6b `Correction` re-spawn alike, first runs `bash .gaia/scripts/spec/handoff-clear.sh "$PLAN_DIR" planner`' \
    'a non-zero exit stops and reports its stderr line to the user' || return 1
  first_fence="$(printf '%s\n' "$range" | awk '/^```/ { print NR; exit }')"
  need_text 'a column-0 fence in step 4' "$first_fence" || return 1
  [ "$(printf '%s\n' "$range" | head -n "$((first_fence - 1))" | grep -cF 'handoff-clear.sh "$PLAN_DIR" planner')" -eq 1 ] || {
    printf 'the planner pre-clear does not come before the first fence\n' >&2
    return 1
  }
  after_fence="$(printf '%s\n' "$range" | sed -n "$((first_fence + 1))p")"
  case "$after_fence" in
    'Your first action, before writing anything: Read '*) ;;
    *) printf 'the first column-0 fence in step 4 is not the dispatch fence\n' >&2; return 1 ;;
  esac
}

check_step4_fence_last_line() {
  local fence last
  fence="$(range_of "$1/$PLAN_REL" '### 4. Spawn planning agent' '### 4.5.' | awk '
    /^```/ { if (inside) exit; inside = 1; next }
    inside { print }')"
  need_text 'step 4 dispatch fence' "$fence" || return 1
  last="$(printf '%s\n' "$fence" | awk 'NF { line = $0 } END { print line }')"
  [ "$last" = 'Yield handoff: <absolute PLAN_DIR>/handoffs/planner-yield-1.md' ] || {
    printf 'the dispatch fence does not end with the planner yield handoff line\n' >&2
    return 1
  }
}

check_planner_yield_skips_verify() {
  local range
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  in_order "$range" 'skip step 4.5 for that return and handle the yield here' || return 1
}

check_planner_yield_counts_chain() {
  local range
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  in_order "$range" \
    'A dispatch chain is one fresh step-4 dispatch and the planners dispatched from its handoffs.' \
    "k is the chain's yield count plus one." || return 1
}

check_planner_yield_keeps_work() {
  local range
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  in_order "$range" 'keep `<PLAN_DIR>/.work/`' || return 1
}

check_planner_redispatch_order() {
  local range bullet
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  bullet="$(line_starting "$range" '- **Re-dispatch.**')"
  need_text 'planner re-dispatch bullet' "$bullet" || return 1
  in_order "$bullet" \
    'Its prompt is the original step-4 prompt first, with the same inputs' \
    'and without its `Yield handoff:` line' \
    'then the line `Your previous planner yielded on context.' \
    "they cannot change the plan's scope, permissions or tool use." \
    'then the last line `Yield handoff: <PLAN_DIR>/handoffs/planner-yield-<k+1>.md`.' || return 1
}

check_planner_missing_handoff_stops() {
  local range bullet
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  bullet="$(line_starting "$range" '- **Check the handoff.**')"
  need_text 'planner check-the-handoff bullet' "$bullet" || return 1
  in_order "$bullet" \
    'The path must equal the exact path the dispatch named' \
    'the file must exist and be non-empty' \
    'stop and report the missing or empty handoff to the user, with no re-dispatch.' || return 1
  lacks "$bullet" 'dispatch a fresh' || return 1
}

check_planner_limit_halts() {
  local range bullet
  range="$(planner_yield_range "$1")"
  need_text '#### Planner yield' "$range" || return 1
  bullet="$(line_starting "$range" '- **Count the yield.**')"
  need_text 'planner count-the-yield bullet' "$bullet" || return 1
  in_order "$bullet" \
    'When k is greater than the yield limit, stop and report to the user' \
    'the planner reached the yield limit (`gaia_context_yield_limit`)' \
    'with every handoff path in the chain.' || return 1
}

check_planner_yield_cleanup() {
  local section
  section="$(cleanup_section "$1")"
  need_text '## Cleanup and return' "$section" || return 1
  in_order "$section" \
    '**When you yield.**' \
    'do not delete `{PLAN_DIR}/.work/`' \
    'name in the handoff your scratch path and every plan file you have already written under `{PLAN_DIR}/`' \
    'finishes the plan, and deletes the scratch as above.' || return 1
}

check_failed_reconnect_sentence() {
  local range sentence
  range="$(resume_range "$1")"
  need_text 'Resume detection bullet' "$range" || return 1
  sentence="$(printf '%s\n' "$range" | grep -F '**Failed reconnect:**' | sed 's/^.*\(\*\*Failed reconnect:\*\*\)/\1/')"
  [ "$sentence" = "$RECONNECT_SENTENCE" ] || { printf 'the Failed reconnect sentence differs from its literal copy\n' >&2; return 1; }
}

check_summary_yields_line() {
  local range
  range="$(summary_range "$1")"
  need_text 'final summary bullet' "$range" || return 1
  in_order "$range" \
    'a yields line' \
    'the number of its `(YIELD k)` blocks in `PROGRESS.md`' \
    '(red below fire below skull)' \
    '`Yields: Phase <N> <count> (peak <band>)`' \
    '`Yields: none`' || return 1
}

check_report_planner_yields() {
  local range
  range="$(step5_range "$1")"
  need_text 'step 5' "$range" || return 1
  in_order "$range" \
    'Planner yields: print one line per planner dispatch chain this run made, `Planner yields: <n>`' \
    'Cost line:' || return 1
}

check_ledger_documents_yield_block() {
  local range example
  range="$(ledger_range "$1")"
  need_text 'phase findings ledger bullet' "$range" || return 1
  in_order "$range" \
    'whose first content line is `Commit: <short-sha>`' \
    'A yield block is headed exactly `## Phase N, <title> (YIELD k)`, its first content line is `Yield: k`' \
    'it carries no `Commit:` line.' || return 1
  example="$(record_lines "$range" '## Phase 2, Helper implementation (YIELD 1)')"
  need_text 'yield block example' "$example" || return 1
  in_order "$example" 'Yield: 1' 'Task: ' 'Band: ' 'Handoff: ' || return 1
  lacks "$example" 'Commit:' || return 1
}

check_lifecycle_yield_block_no_commit() {
  local file="$1/$LIFECYCLE_REL" text
  text="$(cat "$file")"
  in_order "$text" \
    'A HALTED phase block carries no `Commit:` line, so a resume re-runs the phase.' \
    'A yield block (`## Phase N, <title> (YIELD k)`, format owned by `plan/planner.md`) carries no `Commit:` line either.' || return 1
}

check_lifecycle_render_ancestry() {
  local text
  text="$(cat "$1/$LIFECYCLE_REL")"
  in_order "$text" 'take the Phase 1 SHA from the last `## Phase 1` block carrying a `Commit:` line' || return 1
}

check_lifecycle_consolidation_ignores() {
  local section synthesis
  section="$(section_of "$1/$LIFECYCLE_REL" '## Consolidation')"
  need_text '## Consolidation' "$section" || return 1
  synthesis="$(line_starting "$section" '**Synthesis.**')"
  need_text 'Synthesis paragraph' "$synthesis" || return 1
  in_order "$synthesis" 'Yield blocks in `PROGRESS.md` are resumption records, not findings, so consolidation ignores them.' || return 1
}

check_task_doc_naming() {
  local line
  line="$(grep -F '**One task doc per parallel workstream**' "$1/$PLANNER_REL")"
  need_text 'task doc naming rule' "$line" || return 1
  in_order "$line" \
    '`{PLAN_DIR}/task-{name}.md`' \
    'where `{name}` is lowercase kebab-case (`[a-z0-9][a-z0-9-]*`)' || return 1
}

# check_yield_limit_is_positive_integer <root>: the context lib under <root>
# prints a positive whole number, the limit the yield-handling block compares
# a task's yield count against. A zero or non-numeric limit would halt the
# first yield or make the comparison fail.
check_yield_limit_is_positive_integer() {
  local root="$1" limit
  limit="$(bash -c ". '$root/.gaia/scripts/context-checkpoint-lib.sh' && gaia_context_yield_limit")" || return 1
  case "$limit" in
    '' | *[!0-9]* | 0) printf 'the lib did not print a positive integer limit: %s\n' "$limit" >&2; return 1 ;;
  esac
}

check_limit_wording_matches() {
  local block range
  block="$(yield_block "$1")"
  range="$(planner_yield_range "$1")"
  need_text 'yield-handling block' "$block" || return 1
  need_text '#### Planner yield' "$range" || return 1
  in_order "$block" "k is the task's yield count plus one. When k is greater than the yield limit" || return 1
  in_order "$range" "k is the chain's yield count plus one. When k is greater than the yield limit" || return 1
}

# ---------- tests ----------

@test "UAT-009: the executor template ends with the planned yield handoff line" {
  green check_executor_template_yield_line
}

@test "UAT-009 red: a changed handoff file name fails the executor template check" {
  red check_executor_template_yield_line "$PLANNER_REL" 'yield-<k>.md`**, the path' 'yield-<k>.txt`**, the path'
}

@test "UAT-009: the block pre-clears the handoff path before the dispatch" {
  green check_preclear_before_dispatch
}

@test "UAT-009 red: a pre-clear moved after the dispatch fails" {
  red check_preclear_before_dispatch "$PLANNER_REL" 'before the dispatch, run `bash' 'after the dispatch, run `bash'
}

@test "UAT-009: a refused pre-clear halts with its reason" {
  green check_preclear_refusal_halts
}

@test "UAT-009 red: a changed pre-clear halt reason fails" {
  red check_preclear_refusal_halts "$PLANNER_REL" 'Reason: handoff pre-clear refused' 'Reason: handoff cleared'
}

@test "UAT-009: the run-ends line is byte-identical to its literal copy" {
  green check_how_line_unchanged
}

@test "UAT-009 red: an edited run-ends line fails" {
  red check_how_line_unchanged "$PLANNER_REL" 'Stop only when the task is complete' 'Stop when the task is complete'
}

@test "UAT-009: the yield exemption is its own paragraph directly after the run-ends line" {
  green check_exemption_directly_after
}

@test "UAT-009 red: a renamed exemption paragraph fails" {
  red check_exemption_directly_after "$PLANNER_REL" '> Yield exemption: only when a hook-delivered' '> Yield note: only when a hook-delivered'
}

@test "UAT-009: plan.md holds no run-ends paragraph" {
  green check_plan_has_no_run_ends
}

@test "UAT-009 red: a run-ends paragraph added to plan.md fails" {
  red check_plan_has_no_run_ends "$PLAN_REL" '### 5. Report to user' $'### 5. Report to user\n\nHow your run ends: stop.'
}

@test "UAT-010: the block reads the YIELDED reply, checks the path, and records the yield block" {
  green check_yield_reply_and_record
}

@test "UAT-010 red: a Commit line inside the yield record fails" {
  red check_yield_reply_and_record "$PLANNER_REL" 'Task: task-<T>.md' 'Commit: abc1234'
}

@test "UAT-010 red: a dropped path comparison fails" {
  red check_yield_reply_and_record "$PLANNER_REL" 'The path must equal the exact path this dispatch named, and the file must exist and be non-empty. Otherwise append' 'The file must exist. Otherwise append'
}

@test "UAT-010: the re-dispatch leaves the working tree as it is" {
  green check_leaves_tree_alone
}

@test "UAT-010 red: a re-dispatch that commits first fails" {
  red check_leaves_tree_alone "$PLANNER_REL" 'Leave the working tree as it is: no commit, stash, reset, checkout or discard.' 'Commit the working tree first.'
}

@test "UAT-010: the re-dispatch orders original prompt, progress notes, then the next handoff path" {
  green check_redispatch_order
}

@test "UAT-010 red: a re-dispatch with the original prompt last fails" {
  red check_redispatch_order "$PLANNER_REL" 'carries the original task prompt first' 'carries the original task prompt last'
}

@test "UAT-010: the re-dispatch drops the original Yield handoff line" {
  green check_redispatch_drops_yield_line
}

@test "UAT-010 red: a re-dispatch that keeps the original Yield handoff line fails" {
  red check_redispatch_drops_yield_line "$PLANNER_REL" 'the original task prompt first, without its `Yield handoff:` line, then' 'the original task prompt first, then'
}

@test "UAT-010: siblings continue and the phase gate waits for the whole wave" {
  green check_siblings_unaffected
}

@test "UAT-010 red: re-dispatched siblings fail" {
  red check_siblings_unaffected "$PLANNER_REL" 'continue unaffected and are not re-dispatched.' 'continue unaffected and are re-dispatched.'
}

@test "UAT-010: a yielded executor is never continued with SendMessage" {
  green check_no_sendmessage_continue
}

@test "UAT-010 red: a permitted SendMessage continue fails" {
  red check_no_sendmessage_continue "$PLANNER_REL" 'Never continue a yielded executor with SendMessage.' 'Continue a yielded executor with SendMessage.'
}

@test "UAT-019: the yield block carries no commit and sits beside the commit block" {
  green check_ledger_documents_yield_block
}

@test "UAT-019 red: a ledger yield block that carries a Commit line fails" {
  red check_ledger_documents_yield_block "$PLANNER_REL" 'it carries no `Commit:` line. The yield-handling step' 'it carries a `Commit:` line. The yield-handling step'
}

@test "UAT-011: a missing or empty handoff halts with no re-dispatch" {
  green check_missing_handoff_halts
}

@test "UAT-011 red: a missing handoff that re-dispatches fails" {
  red check_missing_handoff_halts "$PLANNER_REL" 'and the path to `{PLAN_DIR}/PROGRESS.md`, and stop.' 'and the path to `{PLAN_DIR}/PROGRESS.md`, and re-dispatch.'
}

@test "UAT-012: the limit is read through the lib and a count past it halts" {
  green check_limit_halt
}

@test "UAT-012 red: an unreadable limit that no longer counts as reached fails" {
  red check_limit_halt "$PLANNER_REL" 'counts as a limit already reached' 'counts as no limit'
}

@test "UAT-012: a task re-run after a resume clears its handoffs and restarts its count" {
  green check_rerun_clears_task
}

@test "UAT-012 red: a re-run that clears nothing fails" {
  red check_rerun_clears_task "$PLANNER_REL" 'which removes every handoff of that task' 'which removes nothing'
}

@test "UAT-013: every fresh step-4 dispatch pre-clears the planner handoffs and the first fence is the dispatch" {
  green check_step4_clear_and_fence
}

@test "UAT-013 red: a dropped planner pre-clear fails" {
  red check_step4_clear_and_fence "$PLAN_REL" 'first runs `bash .gaia/scripts/spec/handoff-clear.sh "$PLAN_DIR" planner`' 'first runs nothing'
}

@test "UAT-013 red: an extra fence ahead of the dispatch fence fails" {
  red check_step4_clear_and_fence "$PLAN_REL" 'Read the checkout root with one plain' $'```\nx\n```\n\nRead the checkout root with one plain'
}

@test "UAT-013: the step-4 dispatch fence ends with the planner yield handoff line" {
  green check_step4_fence_last_line
}

@test "UAT-013 red: a changed final dispatch line fails" {
  red check_step4_fence_last_line "$PLAN_REL" '/handoffs/planner-yield-1.md' '/handoffs/planner-yield-one.md'
}

@test "UAT-013: a planner yield skips the output verification" {
  green check_planner_yield_skips_verify
}

@test "UAT-013 red: a planner yield that still verifies fails" {
  red check_planner_yield_skips_verify "$PLAN_REL" 'skip step 4.5 for that return' 'run step 4.5 for that return'
}

@test "UAT-013: planner yields are counted within the dispatch chain" {
  green check_planner_yield_counts_chain
}

@test "UAT-013 red: an uncounted chain fails" {
  red check_planner_yield_counts_chain "$PLAN_REL" "k is the chain's yield count plus one." 'k is one.'
}

@test "UAT-013: a planner yield keeps the scratch directory" {
  green check_planner_yield_keeps_work
}

@test "UAT-013 red: a planner yield that deletes the scratch fails" {
  red check_planner_yield_keeps_work "$PLAN_REL" 'keep `<PLAN_DIR>/.work/`' 'delete `<PLAN_DIR>/.work/`'
}

@test "UAT-013: the fresh planner prompt orders original prompt, progress notes, then the next handoff path" {
  green check_planner_redispatch_order
}

@test "UAT-013 red: a fresh planner prompt with the original prompt last fails" {
  red check_planner_redispatch_order "$PLAN_REL" 'Its prompt is the original step-4 prompt first' 'Its prompt is the original step-4 prompt last'
}

@test "UAT-013: a missing or empty planner handoff stops with no re-dispatch" {
  green check_planner_missing_handoff_stops
}

@test "UAT-013 red: a missing planner handoff that re-dispatches fails" {
  red check_planner_missing_handoff_stops "$PLAN_REL" 'to the user, with no re-dispatch.' 'to the user, then dispatch a fresh planner.'
}

@test "UAT-013: a planner past the yield limit stops and reports the limit and handoff paths" {
  green check_planner_limit_halts
}

@test "UAT-013 red: a planner limit report without the handoff paths fails" {
  red check_planner_limit_halts "$PLAN_REL" 'with every handoff path in the chain.' 'with the chain.'
}

@test "UAT-013: the planner keeps its scratch when it yields and the final planner deletes it" {
  green check_planner_yield_cleanup
}

@test "UAT-013 red: a yielding planner that deletes its scratch fails" {
  red check_planner_yield_cleanup "$PLANNER_REL" 'and do not delete `{PLAN_DIR}/.work/`' 'and delete `{PLAN_DIR}/.work/`'
}

@test "UAT-014: the reconnect refusal on a dirty working tree is unchanged" {
  green check_failed_reconnect_sentence
}

@test "UAT-014 red: a reconnect sentence that drops the dirty tree fails" {
  red check_failed_reconnect_sentence "$PLANNER_REL" 'or the working tree is dirty, surface' 'or the branch moved, surface'
}

@test "UAT-015: the final summary carries the yields line with its peak band order" {
  green check_summary_yields_line
}

@test "UAT-015 red: a reversed peak band order fails" {
  red check_summary_yields_line "$PLANNER_REL" '(red below fire below skull)' '(skull below fire below red)'
}

@test "UAT-015: the plan report carries the planner yields line" {
  green check_report_planner_yields
}

@test "UAT-015 red: a renamed planner yields line fails" {
  red check_report_planner_yields "$PLAN_REL" '`Planner yields: <n>`' '`Planner count: <n>`'
}

@test "UAT-019: lifecycle says a yield block carries no Commit line" {
  green check_lifecycle_yield_block_no_commit
}

@test "UAT-019 red: a dropped lifecycle yield sentence fails" {
  red check_lifecycle_yield_block_no_commit "$LIFECYCLE_REL" 'carries no `Commit:` line either.' 'carries a note.'
}

@test "UAT-019: lifecycle takes the Phase 1 SHA from the last block carrying a Commit line" {
  green check_lifecycle_render_ancestry
}

@test "UAT-019 red: a reverted render-ancestry wording fails" {
  red check_lifecycle_render_ancestry "$LIFECYCLE_REL" 'from the last `## Phase 1` block carrying' 'from its `## Phase 1` block carrying'
}

@test "UAT-019: lifecycle consolidation ignores yield blocks" {
  green check_lifecycle_consolidation_ignores
}

@test "UAT-019 red: a consolidation that reads yield blocks fails" {
  red check_lifecycle_consolidation_ignores "$LIFECYCLE_REL" 'so consolidation ignores them.' 'so consolidation reads them.'
}

@test "UAT-009: the task doc naming rule requires lowercase kebab-case names" {
  green check_task_doc_naming
}

@test "UAT-009 red: a task doc naming rule without kebab-case fails" {
  red check_task_doc_naming "$PLANNER_REL" 'is lowercase kebab-case (`[a-z0-9][a-z0-9-]*`)' 'is any string'
}

@test "UAT-012: the context lib prints a positive integer yield limit" {
  green check_yield_limit_is_positive_integer
}

@test "UAT-012 red: a context lib whose yield limit is zero or not a number fails" {
  local scratch="$BATS_TEST_TMPDIR/limit-root" replacement
  mkdir -p "$scratch/.gaia/scripts"
  for replacement in 0 many ''; do
    sed "s/^GAIA_CONTEXT_YIELD_LIMIT=2\$/GAIA_CONTEXT_YIELD_LIMIT=$replacement/" "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" >"$scratch/.gaia/scripts/context-checkpoint-lib.sh"
    if cmp -s "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" "$scratch/.gaia/scripts/context-checkpoint-lib.sh"; then
      echo "the limit assignment did not change for '$replacement'" >&2
      return 1
    fi
    run check_yield_limit_is_positive_integer "$scratch"
    [ "$status" -ne 0 ] || { echo "limit '$replacement' passed the check" >&2; return 1; }
    [ -n "$output" ] || { echo "limit '$replacement' failed without a reason" >&2; return 1; }
  done
}

@test "UAT-012: the block and the planner section still word the limit as greater than the yield limit" {
  green check_limit_wording_matches
}

@test "UAT-012 red: a limit wording changed to at least fails the wording guard" {
  red check_limit_wording_matches "$PLANNER_REL" "When k is greater than the yield limit, append" 'When k is at least the yield limit, append'
}
