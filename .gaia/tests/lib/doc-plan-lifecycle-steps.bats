#!/usr/bin/env bats
#
# Doc-conformance suite for the generated orchestrator's lifecycle steps.
#
# planner.md holds the verbatim step blocks a planner copies into a generated
# ORCHESTRATOR.md, each opening with a sentinel line plan-verify.sh checks.
# This suite pins what a script reads or a bad ordering would destroy:
#
#   - the sentinel list for each plan kind, from one array here: each sentinel
#     sits once in planner.md, inside a fenced block, in that order, and the
#     verbatim-block sentence names each in order and the compared set;
#   - nothing is archived or removed before a confirmed MERGED close, and the
#     pre-flight sweep scans before it reaps;
#   - the blocks, assembled the way a planner copies them, pass plan-verify.sh;
#   - the new PROGRESS.md blocks never move plan-resume-point.sh's answer;
#   - the adopter form names no maintainer-only step and markers stay balanced;
#   - a page-markup rule is a plan-time directive.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The orchestrator step blocks of a spec-derived plan, in order. A spec-less
# plan carries the same list without flow-checks. Every step but
# post-merge-close is compared verbatim by plan-verify.sh.
SPEC_DERIVED_STEPS=(
  resume-detection
  yield-handling
  gate-retry
  security-writer
  simplify-pass
  flow-checks
  wiki-promotion
  code-audit
  post-clearance
  post-merge-close
)
SPEC_DERIVED_STEP_COUNT=10
SPEC_ONLY_STEP=flow-checks
UNCOMPARED_STEP=post-merge-close

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLANNER_MD="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  WIKI_PROMOTE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/wiki-promote.md"
  AUDIT_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/audit.md"
  SPEC_TEMPLATE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  PLAN_VERIFY="$REPO_ROOT/.gaia/scripts/spec/plan-verify.sh"
  RESUME_POINT="$REPO_ROOT/.gaia/scripts/plan-resume-point.sh"
  S_FLOW='<!-- gaia:orchestrator-step flow-checks -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
}

# ---------- helpers ----------

# steps_of <spec-derived | spec-less>: the plan kind's step names, in order.
steps_of() {
  local step
  [ "${#SPEC_DERIVED_STEPS[@]}" -eq "$SPEC_DERIVED_STEP_COUNT" ] || { printf 'read %s steps, want %s\n' "${#SPEC_DERIVED_STEPS[@]}" "$SPEC_DERIVED_STEP_COUNT" >&2; return 1; }
  for step in "${SPEC_DERIVED_STEPS[@]}"; do
    [ "$1" = spec-less ] && [ "$step" = "$SPEC_ONLY_STEP" ] && continue
    printf '%s\n' "$step"
  done
}

# sentinel_of <step>: the sentinel line of a step.
sentinel_of() {
  printf '<!-- gaia:orchestrator-step %s -->' "$1"
}

# count_trimmed <file> <literal>: lines equal to <literal> after trimming.
count_trimmed() {
  awk -v want="$2" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { n++ } END { print n + 0 }' "$1"
}

# count_in_fences <file> <literal>: trimmed matches inside ``` fences.
count_in_fences() {
  awk -v want="$2" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ { in_fence = !in_fence; next }
    in_fence && t == want { n++ }
    END { print n + 0 }' "$1"
}

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

# section_of <file> <heading>: a "## " section up to the next "## " heading
# outside a fence (lifecycle.md carries "## " record lines inside fences).
section_of() {
  awk -v heading="$2" '
    { t = $0; sub(/^[ \t]+/, "", t) }
    t ~ /^```/ { in_fence = !in_fence }
    !in_fence && /^## / { if (inside) exit; if ($0 == heading) inside = 1 }
    inside { print }' "$1"
}

# ---------- checks (each returns non-zero with a reason) ----------

check_sentinels_once_in_fences() {
  local file="$1" step sentinel total fenced count=0 want
  while IFS= read -r step; do
    count=$((count + 1))
    sentinel="$(sentinel_of "$step")"
    total="$(count_trimmed "$file" "$sentinel")"
    fenced="$(count_in_fences "$file" "$sentinel")"
    if [ "$total" -ne 1 ] || [ "$fenced" -ne 1 ]; then
      printf '%s: %s appears %s times, %s inside a fence (want 1 and 1)\n' "$file" "$sentinel" "$total" "$fenced" >&2
      return 1
    fi
  done < <(steps_of spec-derived)
  # The planner's own sentinel lines are an independent count of the set, so a
  # block the list does not name, or one it names twice, fails here.
  want="$(grep -cE '^[[:space:]]*<!-- gaia:orchestrator-step [a-z-]+ -->[[:space:]]*$' "$file")"
  [ "$count" -eq "$SPEC_DERIVED_STEP_COUNT" ] && [ "$count" -eq "$want" ] || { printf 'listed %s steps, %s sentinel lines in %s\n' "$count" "$want" "$file" >&2; return 1; }
}

# check_sentinel_file_order <file>: the sentinel lines sit in the list's order,
# so the flow-checks block falls after the simplify pass and before the
# wiki promotion.
check_sentinel_file_order() {
  local file="$1" step line previous=0 previous_step=start
  while IFS= read -r step; do
    line="$(awk -v want="$(sentinel_of "$step")" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
    [ -n "$line" ] || { printf 'no %s sentinel in %s\n' "$step" "$file" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { printf '%s (line %s) is not after %s (line %s)\n' "$step" "$line" "$previous_step" "$previous" >&2; return 1; }
    previous="$line"
    previous_step="$step"
  done < <(steps_of spec-derived)
}

# check_verbatim_sentence <file>: the verbatim-block sentence names every
# step in order and no other, mentions spec-less plans, and
# names every step but post-merge-close among the blocks plan-verify.sh
# compares.
check_verbatim_sentence() {
  local file="$1" sentence order compared step rest listed
  sentence="$(grep -F '**Verbatim step blocks.**' "$file")"
  [ -n "$sentence" ] || { printf 'no verbatim-block sentence in %s\n' "$file" >&2; return 1; }
  order="${sentence#*in this order: }"
  [ "$order" != "$sentence" ] || { printf 'the sentence has no "in this order:" list\n' >&2; return 1; }
  order="${order%%. *}"
  listed="$(grep -oE '`[a-z-]+`' <<<"$order" | grep -c .)"
  [ "$listed" -eq "$SPEC_DERIVED_STEP_COUNT" ] || { printf 'the order list names %s steps, want %s: %s\n' "$listed" "$SPEC_DERIVED_STEP_COUNT" "$order" >&2; return 1; }
  rest="$order"
  while IFS= read -r step; do
    case "$rest" in
      *"\`$step\`"*) rest="${rest#*\`"$step"\`}" ;;
      *) printf 'the order list lacks `%s`, or names it out of order: %s\n' "$step" "$order" >&2; return 1 ;;
    esac
  done < <(steps_of spec-derived)
  # The spec-less omission in any wording: the sentence names spec-less plans.
  grep -qiF -- 'spec-less' <<<"$sentence" ||
    { printf 'the sentence does not say how a spec-less plan treats `%s`\n' "$SPEC_ONLY_STEP" >&2; return 1; }
  compared="${sentence#*compares the text of the }"
  [ "$compared" != "$sentence" ] || { printf 'the sentence names no compared set\n' >&2; return 1; }
  compared="${compared%% blocks*}"
  while IFS= read -r step; do
    if [ "$step" = "$UNCOMPARED_STEP" ]; then
      grep -qF -- "$step" <<<"$compared" && { printf 'the compared set names %s, which plan-verify.sh does not compare\n' "$step" >&2; return 1; }
    else
      grep -qE -- "(^|[ ,])$step(,| and|$)" <<<"$compared" || { printf 'the compared set lacks %s: %s\n' "$step" "$compared" >&2; return 1; }
    fi
  done < <(steps_of spec-derived)
  return 0
}

# Nothing above the post-merge-close sentinel names plan-archive.sh or
# removes SPEC.md / AUDIT.md.
check_plan_close_order() {
  local file="$1" close_line early
  close_line="$(awk -v want="$S_CLOSE" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
  [ -n "$close_line" ] || { printf 'no post-merge-close sentinel in %s\n' "$file" >&2; return 1; }
  early="$(head -n "$((close_line - 1))" "$file" | grep -nF 'plan-archive.sh' || true)"
  [ -z "$early" ] || { printf 'plan-archive.sh named before the post-merge close: %s\n' "$early" >&2; return 1; }
  early="$(head -n "$((close_line - 1))" "$file" | grep -nE '(^|[^a-z])rm [^|;]*(SPEC|AUDIT)\.md' || true)"
  [ -z "$early" ] || { printf 'SPEC.md or AUDIT.md removed before the post-merge close: %s\n' "$early" >&2; return 1; }
}

# lifecycle.md's close confirms MERGED before it archives or removes.
check_lifecycle_close_order() {
  local file="$1" section merged archive removal
  section="$(section_of "$file" '## Post-merge close')"
  [ -n "$section" ] || { printf 'no ## Post-merge close section\n' >&2; return 1; }
  merged="$(grep -nF -m1 'MERGED' <<<"$section" | cut -d: -f1)"
  archive="$(grep -nF -m1 'plan-archive.sh' <<<"$section" | cut -d: -f1)"
  removal="$(grep -nE -m1 'rm [^|;]*SPEC\.md' <<<"$section" | cut -d: -f1)"
  { [ -n "$merged" ] && [ -n "$archive" ] && [ -n "$removal" ]; } || {
    printf 'close section lacks MERGED (%s), plan-archive.sh (%s) or the SPEC.md removal (%s)\n' "$merged" "$archive" "$removal" >&2
    return 1
  }
  [ "$merged" -lt "$archive" ] || { printf 'plan-archive.sh precedes MERGED in the close\n' >&2; return 1; }
  [ "$merged" -lt "$removal" ] || { printf 'SPEC.md removal precedes MERGED in the close\n' >&2; return 1; }
}

check_preflight_sites() {
  local lifecycle="$1" section scan reap
  section="$(section_of "$lifecycle" '## Pre-flight sweep')"
  scan="$(grep -nF -m1 'plan-reconcile.sh "$PWD"' <<<"$section" | cut -d: -f1)"
  reap="$(grep -nF -m1 'plan-archive-merged.sh' <<<"$section" | cut -d: -f1)"
  { [ -n "$scan" ] && [ -n "$reap" ]; } || { printf 'sweep lacks the reconcile scan (%s) or the plan reap (%s)\n' "$scan" "$reap" >&2; return 1; }
  [ "$scan" -lt "$reap" ] || { printf 'the plan reap runs before the reconcile scan\n' >&2; return 1; }
  grep -qF 'GAIA_SPEC_RETENTION_DAYS' <<<"$section" || { printf 'sweep does not name GAIA_SPEC_RETENTION_DAYS\n' >&2; return 1; }
  section="$(section_of "$lifecycle" '## Post-merge close')"
  grep -E 'plan-reconcile\.sh' <<<"$section" | grep -F '"$PLAN_ID"' | grep -qE '"\$PLAN_ID" +"[^"]+"' || { printf 'post-merge close does not pass the PR number to plan-reconcile.sh\n' >&2; return 1; }
}

# assemble_orchestrator <plan.md> <out> <order...>: an ORCHESTRATOR.md made of
# the extracted blocks, indentation kept, in the given sentinel order.
assemble_orchestrator() {
  local source="$1" out="$2" sentinel block
  shift 2
  # The last phase's entry runs the closing phase's flow test in its gate,
  # the run line plan-verify.sh's closing-phase gate check reads.
  printf '# Orchestrator\n\nResume detection, pre-flight isolation, RUNNING sentinel.\n\n**Phase 1, build the checkout.**\n\nQuality gate: pnpm typecheck && pnpm lint.\n\n**Phase 2, closing flow test.**\n\nQuality gate: pnpm typecheck && pnpm lint, then bash .gaia/scripts/bats5.sh %s < /dev/null; a failing run refuses the commit.\n\n' "$FIXTURE_FLOW_TEST" >"$out"
  for sentinel in "$@"; do
    block="$(fence_with "$source" "$sentinel")"
    [ -n "$block" ] || { printf 'no block for %s\n' "$sentinel" >&2; return 1; }
    block="${block//\{SPEC_PATH\}/$FIXTURE_SPEC}"
    block="${block//\{PLAN_DIR\}/$FIXTURE_PLAN}"
    printf '%s\n\nprose between steps\n\n' "$block" >>"$out"
  done
}

# write_plan_fixture: a two-phase plan from a SPEC with one command flow. The
# README task graph names each task by its backticked stem, so Phase 2 is the
# last phase, and its one task doc carries the flow's one Flow test line.
write_plan_fixture() {
  FIXTURE_PLAN="$BATS_TEST_TMPDIR/plan"
  FIXTURE_SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  FIXTURE_FLOW_TEST='.gaia/tests/lib/guest-checkout-confirms-order.bats'
  mkdir -p "$FIXTURE_PLAN"
  cat >"$FIXTURE_SPEC" <<EOF
---
spec_id: SPEC-901
flows:
  - flow_id: FLOW-001
    slug: guest-checkout-confirms-order
    name: A guest checks out and sees the order number
    why: A broken checkout loses the sale
    test_path: $FIXTURE_FLOW_TEST
---
EOF
  cat >"$FIXTURE_PLAN/README.md" <<'EOF'
# Plan

## Task graph

| Phase | Tasks | Model | Notes |
|---|---|---|---|
| Phase 1 | `task-checkout` | sonnet | build |
| Phase 2 | `task-checkout-flow` | sonnet | closing flow-test phase |
EOF
  printf 'You are the orchestrator.\n' >"$FIXTURE_PLAN/KICKOFF.md"
  printf '# Task\n\n- builds checkout\n' >"$FIXTURE_PLAN/task-checkout.md"
  printf '# Task\n\n- tests the checkout flow\n- Flow test (FLOW-001): %s\n- Test (B1, shell, none): %s › guest checkout confirms the order\n' "$FIXTURE_FLOW_TEST" "$FIXTURE_FLOW_TEST" >"$FIXTURE_PLAN/task-checkout-flow.md"
  printf 'status: ran\n' >"$FIXTURE_PLAN/TEST-STAGE"
}

# assembled_sentinels <spec-derived | spec-less>: the plan kind's sentinel
# lines, in order, for assemble_orchestrator.
assembled_sentinels() {
  local step
  while IFS= read -r step; do
    sentinel_of "$step"
    printf '\n'
  done < <(steps_of "$1")
}

# ---------- sentinels and block contents ----------

@test "each orchestrator sentinel sits once in planner.md, inside a fenced block" {
  check_sentinels_once_in_fences "$PLANNER_MD"
}

@test "the sentinels sit in planner.md in the list's order, flow-checks between the simplify pass and the wiki promotion" {
  check_sentinel_file_order "$PLANNER_MD"
}

@test "the verbatim-block sentence names each step in order, the spec-less omission and the compared set" {
  check_verbatim_sentence "$PLANNER_MD"
}

# ---------- close order: nothing irreversible before MERGED ----------

@test "archive, removal and reap run only after a confirmed MERGED close" {
  check_plan_close_order "$PLANNER_MD" || { printf 'case failed: planner.md archives and removes layers only in or after the post-merge close\n' >&2; return 1; }
  check_lifecycle_close_order "$LIFECYCLE_MD" || { printf 'case failed: lifecycle.md post-merge close confirms MERGED before archive and removal\n' >&2; return 1; }
  check_preflight_sites "$LIFECYCLE_MD" || { printf 'case failed: the sweep scans before it reaps and the close passes the PR number\n' >&2; return 1; }
}

# ---------- assembled blocks pass plan-verify.sh ----------

@test "blocks copied as a planner copies them pass plan-verify.sh --spec" {
  local -a order=()
  local sentinel
  while IFS= read -r sentinel; do order+=("$sentinel"); done < <(assembled_sentinels spec-derived)
  [ "${#order[@]}" -eq "$SPEC_DERIVED_STEP_COUNT" ]
  write_plan_fixture
  assemble_orchestrator "$PLANNER_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "${order[@]}"
  # The copy keeps the template's indentation, so the trim rule is exercised.
  grep -qE "^[[:space:]]+<!-- gaia:orchestrator-step flow-checks -->$" "$FIXTURE_PLAN/ORCHESTRATOR.md"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN" --spec "$FIXTURE_SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "blocks copied as a planner copies them pass plan-verify.sh without a spec" {
  local -a order=()
  local sentinel
  while IFS= read -r sentinel; do order+=("$sentinel"); done < <(assembled_sentinels spec-less)
  [ "${#order[@]}" -eq "$((SPEC_DERIVED_STEP_COUNT - 1))" ]
  write_plan_fixture
  assemble_orchestrator "$PLANNER_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "${order[@]}"
  grep -qF "$S_FLOW" "$FIXTURE_PLAN/ORCHESTRATOR.md" && return 1
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---------- the resume helper ignores the new PROGRESS.md blocks ----------

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

@test "the simplify pass, flow checks, wiki promotion and gate HALTED blocks leave the resume point unchanged" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two\nCommit: %s\n\n_No notes._\n' "$SHA_ONE" "$SHA_TWO" >"$PROGRESS_DIR/PROGRESS.md"
  baseline="$(resume_point)"
  [ "$baseline" = "3" ]
  cat >>"$PROGRESS_DIR/PROGRESS.md" <<'EOF'

## Simplify pass
Result: discarded
Reason: the gate failed

## Simplify pass (HALTED)
Reason: the patch could not be saved

## Flow checks
Result: every flow has a test changed on the branch
Flow tests: .gaia/tests/lib/a.bats

## Flow checks (HALTED)
Reason: flow coverage failed after one fixer round
Failures: flow-coverage: a flow test not changed on the branch

## Wiki promotion
Default: ask   Choice: skipped-unattended
Pages: none   Commit: none
Reason: ask with no human present

## Wiki promotion
Pass: pre-audit
Default: yes   Choice: promoted
Pages: wiki/concepts/Page.md   Commit: abc1234

## Worthiness step
Residual: none

## Wiki promotion
Pass: refresh
Default: yes   Choice: promoted
Pages: wiki/concepts/Page.md   Commit: def5678

## Consolidation refresh
Reason: summary-verify.sh failed: no body

## Phase 3, Three (HALTED)
Reason: flow test failed in the closing gate
Failures: .gaia/tests/lib/a.bats failed
EOF
  [ "$(resume_point)" = "$baseline" ]
}

# ---------- adopter form, manifest placement, commit proxies, record arm ----------

# strip_marked <in> <out>: the file with each maintainer-only marker pair and
# the lines between them removed, as the release's strip does, a pair inside a
# fenced block included.
strip_marked() {
  awk '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == "<!-- gaia:maintainer-only:start -->" { skipping = 1; next }
    t == "<!-- gaia:maintainer-only:end -->" { skipping = 0; next }
    !skipping { print }' "$1" >"$2"
}

# check_markers_balanced <file>: starts and ends alternate, ending closed.
check_markers_balanced() {
  awk '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == "<!-- gaia:maintainer-only:start -->" { if (open) bad = 1; open = 1; starts++ }
    t == "<!-- gaia:maintainer-only:end -->" { if (!open) bad = 1; open = 0; ends++ }
    END { exit (bad || open || starts != ends) ? 1 : 0 }' "$1" || { printf '%s: maintainer-only markers are unbalanced\n' "$1" >&2; return 1; }
}

# check_adopter_form <file>: no verify-harness once every marked pair is gone.
check_adopter_form() {
  local file="$1" stripped="$BATS_TEST_TMPDIR/adopter-form.md" count
  strip_marked "$file" "$stripped"
  count="$(grep -c 'verify-harness' "$stripped" || true)"
  [ "$count" -eq 0 ] || { printf '%s names verify-harness outside a marked pair (%s lines)\n' "$file" "$count" >&2; return 1; }
}

@test "adopter form names no maintainer-only step and markers stay balanced" {
  local file
  check_adopter_form "$PLANNER_MD" || { printf 'case failed: planner.md adopter form\n' >&2; return 1; }
  check_adopter_form "$LIFECYCLE_MD" || { printf 'case failed: lifecycle.md adopter form\n' >&2; return 1; }
  grep -qF 'verify-harness' "$PLANNER_MD" || { printf 'case failed: the marked pair holds the verify-harness mention in planner.md\n' >&2; return 1; }
  for file in \
    "$PLANNER_MD" "$LIFECYCLE_MD" "$WIKI_PROMOTE_MD" \
    "$REPO_ROOT/wiki/concepts/Task Orchestration.md" \
    "$REPO_ROOT/wiki/concepts/GAIA Plan.md" \
    "$REPO_ROOT/wiki/concepts/Wiki Consolidate.md" \
    "$REPO_ROOT/.claude/skills/gaia/references/wiki/consolidate.md"; do
    [ -f "$file" ] || { printf 'missing %s\n' "$file" >&2; return 1; }
    check_markers_balanced "$file" || { printf 'case failed: markers balanced in %s\n' "$file" >&2; return 1; }
  done
}

# ---------- a page-markup rule is a directive, never then-clause text ----------

# check_markup_rule_placement <audit> <template>: the SPEC audit's testability
# lens, its refuter and its directive rule send a page-markup or accessibility
# structure rule to one plan-time directive naming the page, and the SPEC
# template keeps such a rule out of a success criterion and a flow name.
check_markup_rule_placement() {
  local audit="$1" template="$2" needle
  for needle in \
    'propose a plan-time directive stating that rule for the page or component it applies to, never flow or success-criterion text' \
    'A finding whose fix is a page-markup or accessibility structure rule is `plan_directive` even when it cites a flow' \
    'is one directive naming the page or component it applies to'; do
    grep -qF -- "$needle" "$audit" || { printf 'audit.md lacks: %s\n' "$needle" >&2; return 1; }
  done
  grep -qF -- 'A page-markup or accessibility structure rule' "$template" ||
    { printf 'spec-template.md then: lacks the markup-rule clause\n' >&2; return 1; }
}

@test "a page-markup rule is a plan-time directive, in the SPEC audit and the SPEC template" {
  check_markup_rule_placement "$AUDIT_MD" "$SPEC_TEMPLATE_MD"
}

