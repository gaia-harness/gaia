#!/usr/bin/env bats
#
# Doc-conformance suite for the overlap pass reference and the fidelity judge's
# surface-neutral wording.
#
# .claude/skills/gaia/references/overlap-pass.md owns the overlap pass of a plan
# run. This suite pins:
#
#   - each numbered rule of the step: the skip, the reuse branch and its HEAD
#     check, the dispatch named once, the classification before use, the
#     did-not-run ending, the check, the review list, the fixer, the post-fix
#     re-check and the HALTED heading, the unattended arm, the report and the
#     never line;
#   - the `--root` and `--post-fix` spellings;
#   - the lowest-layer purpose, the fixer's replacement for a sibling-less
#     demote and the post-fix refusal of one with no replacement;
#   - the judge and the divergence policy: a builder meets a Given cosmetically,
#     a stubbed guard, a request-only body under a browser-only clause and a
#     refusal check without the redirect, status and actor assertions diverge.
#
# Every check is a function taking the file it reads, so each red twin runs the
# same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REF="$REPO_ROOT/.claude/skills/gaia/references/overlap-pass.md"
  JUDGE="$REPO_ROOT/.claude/agents/uat-fidelity-judge.md"
  DIVERGENCE="$REPO_ROOT/.claude/skills/gaia/references/spec/uat-divergence.md"
  UAT_WRITE="$REPO_ROOT/.claude/skills/gaia/references/spec/uat-write.md"
}

# has_all <file> <literal>...: every literal is in the file.
has_all() {
  local file="$1" literal
  shift
  for literal in "$@"; do
    grep -qF -- "$literal" "$file" || { printf '%s lacks: %s\n' "$file" "$literal" >&2; return 1; }
  done
}

# mutate <file> <from> <to> <out>: a copy with the first occurrence replaced.
mutate() {
  awk -v from="$2" -v to="$3" '{ if (!done && (i = index($0, from)) > 0) { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); done = 1 } print }' "$1" >"$4"
  ! cmp -s "$1" "$4" || { printf '"%s" is not in %s\n' "$2" "$1" >&2; return 1; }
}

# line_of <file> <literal>: the first line number holding <literal>, or empty.
line_of() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# ---------- rule 1: skip ----------

check_skip() {
  has_all "$1" \
    '### 1. Skip' \
    'An exact `## Overlap pass` heading already in the plan folder'"'"'s `PROGRESS.md` ends the step with no dispatch and no commit' \
    'A did-not-run block suppresses a retry too' \
    'bash .gaia/scripts/overlap-check.sh route --root <RESOLVED_ROOT>' \
    '`Outcome: skipped (<reason>)` in `PROGRESS.md`, with no commit'
}

@test "the skip rule: exact heading, did-not-run suppression and the route skip record" {
  check_skip "$REF"
}

@test "red twin: dropping the did-not-run suppression or the route command fails the skip check" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'A did-not-run block suppresses a retry too' 'A did-not-run block is retried' "$copy"
  run check_skip "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'overlap-check.sh route --root' 'overlap-check.sh route' "$copy"
  run check_skip "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rule 2: reuse ----------

check_reuse() {
  has_all "$1" \
    '### 2. Reuse' \
    '<RUN_FOLDER>/overlap-proposals.json' \
    'its `head` field equals the current HEAD' \
    'skip steps 3 to 5' \
    'Otherwise discard the file' \
    'Step 5 writes that `head` field'
}

@test "the reuse branch skips the dispatch only on a file whose head equals HEAD" {
  check_reuse "$REF"
}

@test "red twin: a reuse branch without the HEAD check fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'its `head` field equals the current HEAD' 'it exists' "$copy"
  run check_reuse "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rules 3 and 4: dispatch and classification ----------

# check_dispatch <file>: the dispatch is named once, the status capture sits
# before it, and the classification precedes the check.
check_dispatch() {
  local file="$1" count
  count="$(grep -cF 'Agent(subagent_type: "overlap-evaluator")' "$file")"
  [ "$count" -eq 1 ] || { printf 'the dispatch is named %s times, want 1\n' "$count" >&2; return 1; }
  has_all "$file" \
    'bash .gaia/scripts/overlap-check.sh changed --root <RESOLVED_ROOT>' \
    'rm -f' \
    '`Proposals file: <path>` line, says the file is JSON' \
    'git -C <RESOLVED_ROOT> status --porcelain' \
    'is a HALT' \
    'bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <proposals file>' \
    'Pass no count' \
    'A no-op re-dispatches once' \
    '`Outcome: did not run`' \
    'lists it in the final summary' \
    'the run continues to the wiki promotion' \
    '`### The terminal action, stated once`' \
    'nothing depends on this pass' || return 1
  [ "$(line_of "$file" 'overlap-check.sh changed')" -lt "$(line_of "$file" 'audit-noop-detect.sh')" ] || { printf 'changed does not precede classification\n' >&2; return 1; }
  [ "$(line_of "$file" 'audit-noop-detect.sh')" -lt "$(line_of "$file" 'overlap-check.sh check --root')" ] || { printf 'classification does not precede the check\n' >&2; return 1; }
}

@test "the dispatch is named once, status-checked, classified before use and ends did-not-run" {
  check_dispatch "$REF"
}

@test "red twin: a second dispatch line, a missing status check or a count flag fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  { cat "$REF"; printf '\nAgent(subagent_type: "overlap-evaluator")\n'; } >"$copy"
  run check_dispatch "$copy"
  [ "$status" -ne 0 ]
  sed 's/status --porcelain/status/g' "$REF" >"$copy"
  run check_dispatch "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'Outcome: did not run' 'Outcome: failed' "$copy"
  run check_dispatch "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rule 5: check ----------

check_check_step() {
  has_all "$1" \
    'bash .gaia/scripts/overlap-check.sh check --root <RESOLVED_ROOT> --proposals <proposals file>' \
    'Write its output plus the current HEAD as the `head` field to `<RUN_FOLDER>/overlap-proposals.json` first' \
    'A `discarded` entry is logged as unverified'
}

@test "the check step writes the head field before any question and logs discarded entries" {
  check_check_step "$REF"
}

@test "red twin: dropping the head write or the discarded log fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'plus the current HEAD as the `head` field' 'alone' "$copy"
  run check_check_step "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'is logged as unverified' 'is ignored' "$copy"
  run check_check_step "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rules 6 and 7: dispose ----------

check_dispose() {
  has_all "$1" \
    '`.claude/rules/user-questions.md`' \
    'property, actor, action and the cited sibling' \
    'whether the sibling asserts the same property for the same actor and action' \
    'List report-only entries as information' \
    '`Accept all as recommended (Recommended)` or `Revise`' \
    'disposition `offer`' \
    'one fresh `general-purpose` fixer on `model: "sonnet"`' \
    'same prompt constraints as the worthiness Fix step' \
    'either the original proposals file or the kept list' \
    'bash .gaia/scripts/overlap-check.sh check --root <RESOLVED_ROOT> --proposals <file> --post-fix' \
    'run the Quality Gate, commit with a `test(<scope>):` subject, push, and run one more worthiness step' \
    '`## Overlap pass (HALTED)`' \
    'a heading the skip in step 1 does not match' \
    'Unattended: nothing changes' || return 1
  [ "$(line_of "$1" '--post-fix')" -lt "$(line_of "$1" 'run the Quality Gate')" ] || { printf 'the post-fix re-check does not precede the Quality Gate\n' >&2; return 1; }
}

@test "disposal: review list fields, one question, fixer, post-fix re-check, gate, commit, HALTED heading and unattended arm" {
  check_dispose "$REF"
}

@test "red twin: dropping a review-list field, the post-fix flag or the HALTED heading fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'property, actor, action and the cited sibling' 'the proposal' "$copy"
  run check_dispose "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" '--proposals <file> --post-fix' '--proposals <file>' "$copy"
  run check_dispose "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" '## Overlap pass (HALTED)' '## Overlap pass' "$copy"
  run check_dispose "$copy"
  [ "$status" -ne 0 ]
}

# ---------- purpose and the sibling-less demote ----------

check_lowest_layer_purpose() {
  has_all "$1" \
    'across the unit, route, real-server and browser layers' \
    'each one sits on the lowest layer that shows its property, so the pass also moves a test down to that layer'
}

check_sibling_less_fixer() {
  has_all "$1" \
    'For each approved sibling-less demote (a `target` and no `sibling`), the fixer writes the replacement real-server test (the request fixture only, no page)' \
    'lists it in its JSON result as `{file, fullName, replacement: {file, line, fullName, assertion}}`' \
    'The orchestrator merges each `replacement` into the kept list'"'"'s entry with that `file` and `fullName` before running `--post-fix`' || return 1
  [ "$(line_of "$1" 'the fixer writes the replacement real-server test')" -le "$(line_of "$1" '--proposals <file> --post-fix')" ] || { printf 'the replacement merge does not precede the post-fix re-check\n' >&2; return 1; }
}

check_post_fix_refusal() {
  has_all "$1" 'a sibling-less demote with no replacement is refused there'
}

@test "the page states the lowest-layer purpose beside duplication" {
  check_lowest_layer_purpose "$REF"
}

@test "red twin: a purpose naming only duplication fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" ', and that each one sits on the lowest layer that shows its property, so the pass also moves a test down to that layer' '' "$copy"
  run check_lowest_layer_purpose "$copy"
  [ "$status" -ne 0 ]
}

@test "the fixer writes and lists a replacement for each sibling-less demote, merged before the post-fix re-check" {
  check_sibling_less_fixer "$REF"
}

@test "red twin: a fixer that writes no replacement, or a missing merge, fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'the fixer writes the replacement real-server test (the request fixture only, no page)' 'the fixer deletes the subject' "$copy"
  run check_sibling_less_fixer "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'The orchestrator merges each `replacement`' 'The orchestrator ignores each `replacement`' "$copy"
  run check_sibling_less_fixer "$copy"
  [ "$status" -ne 0 ]
}

@test "the post-fix re-check refuses a sibling-less demote with no replacement" {
  check_post_fix_refusal "$REF"
}

@test "red twin: a post-fix sentence that accepts a missing replacement fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'a sibling-less demote with no replacement is refused there' 'a sibling-less demote needs nothing more' "$copy"
  run check_post_fix_refusal "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rules 8 and 9: report and never ----------

check_report_and_never() {
  has_all "$1" \
    'Only after disposal completes, append to `PROGRESS.md`' \
    '## Overlap pass' \
    'Outcome:' \
    'put the block in the final summary' \
    '## What it never does' \
    'It files no tech debt, records no accepted residual, and edits no report-only test.'
}

@test "the report is written after disposal and the never line holds" {
  check_report_and_never "$REF"
}

@test "red twin: a never line that allows tech debt fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'It files no tech debt, records no accepted residual, and edits no report-only test.' 'It files tech debt.' "$copy"
  run check_report_and_never "$copy"
  [ "$status" -ne 0 ]
}

@test "the page names no working-document id" {
  run grep -nE 'SPEC-[0-9]+|UAT-[0-9]+|PLAN-[0-9]+' "$REF"
  [ "$status" -eq 1 ]
}

# ---------- judge and divergence wording ----------

check_judge() {
  has_all "$1" \
    'Playwright e2e specs and Vitest route tests' \
    '`Spec: <uat_id> <absolute path to the rendered test>`' \
    '`Guard: <uat_id> <absolute path to the guard file>`' \
    'Meeting a Given through a builder or fixture is cosmetic too, unless the UAT'"'"'s flow is that setup' \
    'stubs or mocks a guard a `Guard:` line names' \
    'only makes a request where the Then-clause is something only a browser shows' \
    'sets no `maxRedirects: 0`, asserts no status and `Location`, or states no actor' \
    'tools: Read, Write'
}

check_divergence() {
  has_all "$1" \
    'a Playwright e2e spec or a Vitest route test' \
    'Meeting a Given through a builder, a fixture or a helper that sets up the state is cosmetic too, unless the UAT'"'"'s flow is that setup' \
    'A body that makes only a request where the Then-clause is something only a browser shows (focus, hydration, client navigation) is a logical divergence'
}

@test "the judge is surface-neutral and names the builder, stubbed-guard, request-only and refusal-check divergences" {
  check_judge "$JUDGE"
}

@test "the divergence policy is surface-neutral and carries the builder and request-only rules" {
  check_divergence "$DIVERGENCE"
}

@test "red twin: removing any judge or divergence clause fails its check" {
  local copy="$BATS_TEST_TMPDIR/copy.md" clause
  for clause in 'Meeting a Given through a builder or fixture is cosmetic too' 'stubs or mocks a guard a `Guard:` line names' 'only makes a request where the Then-clause is something only a browser shows' 'sets no `maxRedirects: 0`' 'Playwright e2e specs and Vitest route tests'; do
    mutate "$JUDGE" "$clause" 'removed' "$copy"
    run check_judge "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$clause' did not fail" >&2; return 1; }
  done
  mutate "$DIVERGENCE" 'cosmetic too, unless the UAT'"'"'s flow is that setup' 'removed' "$copy"
  run check_divergence "$copy"
  [ "$status" -ne 0 ]
}

@test "uat-write.md describes the route file shape and the removal of .fails" {
  has_all "$UAT_WRITE" \
    'test.fails(' \
    'becomes `test(`' \
    'calls the route module'"'"'s loader or action directly' \
    'Skipped: no e2e-routed or route-routed UATs'
}
