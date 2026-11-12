#!/usr/bin/env bats
#
# Doc-conformance suite for the overlap pass reference.
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
#   - the trophy-layer purpose, the fixer's replacement for a sibling-less
#     demote and the post-fix refusal of one with no replacement;
#   - the evaluator proposing an unsettled pair flagged `Uncertain:` rather
#     than skipping it, and naming each changed file it skipped; the pass
#     listing those proposals last and persisting and reporting the skipped
#     files.
#
# Every check is a function taking the file it reads, so each red twin runs the
# same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REF="$REPO_ROOT/.claude/skills/gaia/references/overlap-pass.md"
  EVALUATOR="$REPO_ROOT/.claude/agents/overlap-evaluator.md"
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

# check_skip_token <file>: the route's no-change token is the any-test one and
# the old playwright-only token is gone.
check_skip_token() {
  has_all "$1" 'A printed `skip-no-test-change` or `skip-no-base`' || return 1
  ! grep -qF 'skip-no-playwright-change' "$1" || { printf '%s still names skip-no-playwright-change\n' "$1" >&2; return 1; }
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

@test "the skip token is skip-no-test-change and the playwright-only token is gone" {
  check_skip_token "$REF"
}

@test "red twin: the old playwright-only skip token fails the skip token check" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'A printed `skip-no-test-change`' 'A printed `skip-no-playwright-change`' "$copy"
  run check_skip_token "$copy"
  [ "$status" -ne 0 ]
  { cat "$REF"; printf '\nskip-no-playwright-change\n'; } >"$copy"
  run check_skip_token "$copy"
  [ "$status" -ne 0 ]
}

# ---------- rule 2: reuse ----------

check_reuse() {
  has_all "$1" \
    '### 2. Reuse' \
    '<RUN_FOLDER>/overlap-proposals.json' \
    'its `head` field equals the current HEAD' \
    'skip steps 3 to 5' \
    'and its `format` field is `2`' \
    'Otherwise discard the file before any disposal' \
    'Step 5 writes `"format": 2` and that `head` field'
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

@test "red twin: a reuse branch without the format requirement fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'and its `format` field is `2`' 'and nothing else' "$copy"
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
    'Write its output, the current HEAD as the `head` field,' \
    '`"format": 2` as the `format` field' \
    'to `<RUN_FOLDER>/overlap-proposals.json` first, before any question' \
    'A `discarded` entry is logged as unverified'
}

@test "the check step writes the head field before any question and logs discarded entries" {
  check_check_step "$REF"
}

@test "red twin: dropping the head write or the discarded log fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'the current HEAD as the `head` field,' 'nothing else,' "$copy"
  run check_check_step "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'is logged as unverified' 'is ignored' "$copy"
  run check_check_step "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" '`"format": 2` as the `format` field' 'nothing more' "$copy"
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

check_trophy_purpose() {
  has_all "$1" \
    'across the unit, route, real-server and browser layers' \
    'sits on the layer the trophy rule in `wiki/decisions/Test Layering.md` picks'
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

@test "the page states the trophy purpose beside duplication" {
  check_trophy_purpose "$REF"
}

@test "red twin: a purpose that drops the trophy layer rule fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'sits on the layer the trophy rule in `wiki/decisions/Test Layering.md` picks' 'sits somewhere' "$copy"
  run check_trophy_purpose "$copy"
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

# ---------- fold-up disposal and report-only routing ----------

check_fold_up_fixer() {
  has_all "$1" \
    'For each approved fold-up, the fixer deletes the subject tests' \
    'a subject file left with no test is deleted' \
    'and writes no test' \
    '`--post-fix` runs over the kept list for a fold-up'
}

check_report_only_excluded() {
  has_all "$1" 'Report-only entries (`needs-new-test` among them) are listed as information and never sent to the fixer'
}

check_pr_body_entries() {
  has_all "$1" \
    '`needs-new-test` entries also go into the PR body (`gh pr edit` with a body file) under a short heading'
}

@test "a fold-up has its subjects deleted and no test written, re-verified over the kept list" {
  check_fold_up_fixer "$REF"
}

@test "red twin: a fixer that writes a test for a fold-up fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'and writes no test' 'and writes the folded test' "$copy"
  run check_fold_up_fixer "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'the fixer deletes the subject tests' 'the fixer rewrites the subject tests' "$copy"
  run check_fold_up_fixer "$copy"
  [ "$status" -ne 0 ]
}

@test "report-only entries are listed and never sent to the fixer" {
  check_report_only_excluded "$REF"
}

@test "red twin: dropping the report-only exclusion from the fixer fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'and never sent to the fixer' 'and sent to the fixer' "$copy"
  run check_report_only_excluded "$copy"
  [ "$status" -ne 0 ]
}

@test "needs-new-test entries reach the PR body" {
  check_pr_body_entries "$REF"
}

@test "red twin: removing the PR-body line fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" '`needs-new-test` entries also go into the PR body' '`needs-new-test` entries stay in PROGRESS.md' "$copy"
  run check_pr_body_entries "$copy"
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
    'It files no tech debt, records no accepted residual, and edits no report-only test and writes no new test for a fold-up.'
}

@test "the report is written after disposal and the never line holds" {
  check_report_and_never "$REF"
}

@test "red twin: a never line that allows tech debt fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'It files no tech debt, records no accepted residual, and edits no report-only test and writes no new test for a fold-up.' 'It files tech debt.' "$copy"
  run check_report_and_never "$copy"
  [ "$status" -ne 0 ]
}

# ---------- uncertain proposals and skipped files ----------

# check_evaluator_flags_uncertainty <file>: the evaluator proposes a pair it
# cannot settle, flagged, keeps every changed file in scope, and names each
# file it made no proposal for.
check_evaluator_flags_uncertainty() {
  has_all "$1" \
    'begin `property` with `Uncertain:`' \
    '`seam: true` whenever you are unsure' \
    'Every changed test file is in scope, fixture and harness specs included' \
    'each changed test file you made no proposal for, with a one-line reason' || return 1
  grep -qF 'propose nothing for it' "$1" && { printf '%s still skips an unsettled pair\n' "$1" >&2; return 1; }
  true
}

check_pass_orders_uncertain_and_reports_skips() {
  has_all "$1" \
    'Proposals whose `property` begins `Uncertain:` come last.' \
    'as a `skipped` field (`[{file, reason}]`)' \
    '<one line per `skipped` entry: file, reason>'
}

@test "the evaluator flags an unsettled pair instead of skipping it, and names every file it skipped" {
  check_evaluator_flags_uncertainty "$EVALUATOR"
}

@test "red twin: a skip-on-doubt rule, a scope exemption or a missing skip list fails the evaluator check" {
  local copy="$BATS_TEST_TMPDIR/evaluator.md"
  { cat "$EVALUATOR"; printf '\nWhen a pair is a judgment call, propose nothing for it.\n'; } >"$copy"
  run check_evaluator_flags_uncertainty "$copy"
  [ "$status" -ne 0 ]
  mutate "$EVALUATOR" 'fixture and harness specs included' 'fixture and harness specs excluded' "$copy"
  run check_evaluator_flags_uncertainty "$copy"
  [ "$status" -ne 0 ]
  mutate "$EVALUATOR" 'each changed test file you made no proposal for, with a one-line reason' 'counts per kind' "$copy"
  run check_evaluator_flags_uncertainty "$copy"
  [ "$status" -ne 0 ]
}

@test "the pass lists uncertain proposals last and reports every skipped file" {
  check_pass_orders_uncertain_and_reports_skips "$REF"
}

@test "red twin: dropping the ordering line, the skipped field or the skipped-file report line fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  mutate "$REF" 'Proposals whose `property` begins `Uncertain:` come last.' '' "$copy"
  run check_pass_orders_uncertain_and_reports_skips "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" '<one line per `skipped` entry: file, reason>' '' "$copy"
  run check_pass_orders_uncertain_and_reports_skips "$copy"
  [ "$status" -ne 0 ]
  mutate "$REF" 'as a `skipped` field' 'as nothing' "$copy"
  run check_pass_orders_uncertain_and_reports_skips "$copy"
  [ "$status" -ne 0 ]
}

# ---------- sole lower-layer driver ----------

# check_evaluator_keeps_sole_driver <file>: the evaluator never proposes removing
# the only test below the browser layer that drives a guard into its failing
# state on the strength of a browser or flow test, or of a sibling also proposed
# for removal.
check_evaluator_keeps_sole_driver() {
  has_all "$1" \
    'is the only test below the browser layer (`wiki/decisions/Test Layering.md`)' \
    'driving a guard, refusal or validation into its failing state is never' \
    'proposed for `drop`, `merge`, `demote` or `fold-up` on the strength of a browser' \
    'test or a flow test, even when it asserts the same property, nor on a sibling' \
    'also proposed for removal, a fold-up target included; propose `keep-both` with' \
    'its `bug`, or nothing. This overrides the drop default under `keep-both`: with' \
    'no bug that fails the subject and passes the sibling, propose nothing.'
}

@test "the evaluator never proposes removing the only lower-layer test driving a guard on a browser or flow sibling" {
  check_evaluator_keeps_sole_driver "$EVALUATOR"
}

@test "red twin: a prompt without the sole-driver rule, or one that allows a drop, fails" {
  local copy="$BATS_TEST_TMPDIR/evaluator.md"
  local section='**Sole lower-layer driver.**'
  awk -v marker="$section" 'index($0, marker) { skip = 1 } skip && /^$/ { skip = 0; next } !skip' "$EVALUATOR" >"$copy"
  cmp -s "$EVALUATOR" "$copy" && return 1
  run check_evaluator_keeps_sole_driver "$copy"
  [ "$status" -ne 0 ]
  mutate "$EVALUATOR" 'proposed for `drop`, `merge`, `demote` or `fold-up`' 'proposed for `merge`, `demote` or `fold-up`' "$copy"
  run check_evaluator_keeps_sole_driver "$copy"
  [ "$status" -ne 0 ]
}

@test "the page names no working-document id" {
  run grep -nE 'SPEC-[0-9]+|UAT-[0-9]+|PLAN-[0-9]+' "$REF"
  [ "$status" -eq 1 ]
}
