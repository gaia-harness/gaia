#!/usr/bin/env bats
#
# Doc-conformance suite for the generated orchestrator's lifecycle steps.
#
# .claude/skills/gaia/references/plan/planner.md, the file the planner
# sub-agent reads, holds the verbatim step blocks a planner copies into a
# generated ORCHESTRATOR.md, each opening with a sentinel line plan-verify.sh
# checks: the resume detection, the sub-agent yield handling, the phase gate
# retry, the pre-audit flow checks, the worthiness step, the overlap pass, the
# wiki promotion, the code audit, the post-clearance step and the post-merge
# close. .claude/skills/gaia/references/spec/lifecycle.md holds the procedures
# those blocks point at, and .claude/skills/gaia/references/plan.md, the
# /gaia-plan entry file, keeps the pre-flight sweep pointer. This suite pins:
#
#   - the sentinel list for each plan kind, from one array here: each sentinel
#     sits once in planner.md, inside a fenced block, in that order; the
#     verbatim-block sentence names each in order and the compared set; and
#     each block carries the command or pointer it exists for;
#   - plan.md holds no sentinel and never names plan-archive.sh, so the
#     blocks have one home;
#   - nothing in planner.md archives the plan folder or removes SPEC.md before
#     the post-merge close, and lifecycle.md's close confirms MERGED first;
#   - the blocks, assembled the way a planner copies them (indentation
#     kept) into a plan with a closing flow-test phase, pass plan-verify.sh;
#   - the shared pre-flight sweep runs its reconcile scan before the reap that
#     reads what it stamps, and the post-merge close passes the PR number;
#   - the new PROGRESS.md blocks never move plan-resume-point.sh's answer;
#   - the adopter form of planner.md and lifecycle.md (every maintainer-only
#     pair stripped) names no verify-harness, every changed page keeps its
#     markers balanced, and no block holds the release manifest mechanics;
#   - the post-clearance block commits no SUMMARY.md, the wiki promotion block
#     sits above the code audit block, and the final summary names the
#     worthiness blocks the late pass feeds;
#   - lifecycle.md says which pass writes the wiki promotion record;
#   - a plan-time directive constrains the code or a flow test's assertions,
#     never a test layer, and spec/audit.md writes a directive as a property
#     or a code constraint.
#
# Every check is a function taking the file(s) it reads, so each red twin
# runs the same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The orchestrator step blocks of a spec-derived plan, in order. A spec-less
# plan carries the same list without flow-checks. Every step but
# post-merge-close is compared verbatim by plan-verify.sh.
SPEC_DERIVED_STEPS=(
  resume-detection
  yield-handling
  gate-retry
  simplify-pass
  flow-checks
  worthiness-step
  overlap-pass
  wiki-promotion
  code-audit
  post-clearance
  post-merge-close
)
SPEC_DERIVED_STEP_COUNT=11
SPEC_ONLY_STEP=flow-checks
UNCOMPARED_STEP=post-merge-close

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  PLANNER_MD="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  WIKI_PROMOTE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/wiki-promote.md"
  AUDIT_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/audit.md"
  SPEC_TEMPLATE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  PLAN_VERIFY="$REPO_ROOT/.gaia/scripts/spec/plan-verify.sh"
  RESUME_POINT="$REPO_ROOT/.gaia/scripts/plan-resume-point.sh"
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
  S_SIMPLIFY='<!-- gaia:orchestrator-step simplify-pass -->'
  S_FLOW='<!-- gaia:orchestrator-step flow-checks -->'
  S_WORTH='<!-- gaia:orchestrator-step worthiness-step -->'
  S_OVERLAP='<!-- gaia:orchestrator-step overlap-pass -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
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

# range_of <file> <start fixed string> <end fixed string>: the lines from the
# first start match up to, not including, the first end match after it.
range_of() {
  awk -v start="$2" -v stop="$3" '
    !inside && index($0, start) { inside = 1; print; next }
    inside && index($0, stop) { exit }
    inside { print }' "$1"
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
# so the flow-checks block falls after the gate retry and before the
# worthiness step.
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

# check_block_has <file> <sentinel> <needle>...
check_block_has() {
  local file="$1" sentinel="$2" block needle
  shift 2
  block="$(fence_with "$file" "$sentinel")"
  [ -n "$block" ] || { printf 'no fenced block holds %s\n' "$sentinel" >&2; return 1; }
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$block" || { printf 'block %s lacks: %s\n' "$sentinel" "$needle" >&2; return 1; }
  done
}

check_block_contents() {
  local file="$1"
  check_block_has "$file" "$S_YIELD" 'gaia_context_yield_limit' 'Yield handoff:' '(YIELD k)' || return 1
  check_block_has "$file" "$S_RETRY" '(GATE RETRY 1)' 'Yield handoff:' 'Stop conditions' || return 1
  check_block_has "$file" "$S_SIMPLIFY" 'simplify-pass.md' '## Simplify pass' || return 1
  check_block_has "$file" "$S_FLOW" 'flow-coverage.sh' '--spec {SPEC_PATH}' '--flow-tests-out' 'flow-tests.tsv' '{PLAN_DIR}/PROGRESS.md' 'before the worthiness step' || return 1
  check_block_has "$file" "$S_WORTH" 'worthiness-step.md' 'flow checks' || return 1
  check_block_has "$file" "$S_OVERLAP" 'overlap-pass.md' '## Overlap pass' || return 1
  check_block_has "$file" "$S_WIKI" 'wiki-promote.md' 'promoted-pages.txt' 'Pass: pre-audit' 'verify-harness.sh branch' || return 1
  check_block_has "$file" "$S_AUDIT" 'resolve-audit-members.sh' 'worthiness-step.md' || return 1
  check_block_has "$file" "$S_CLEAR" 'Pass: refresh' 'post-audit-status.sh' '#### Posting the status last' 'Skipping already-cleared members' 'verify-harness.sh branch' 'Consolidation refresh' || return 1
  check_block_has "$file" "$S_CLOSE" 'plan-archive.sh` runs only after `MERGED` is confirmed' || return 1
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
  printf '# Task\n\n- tests the checkout flow\n- Flow test (FLOW-001): %s\n' "$FIXTURE_FLOW_TEST" >"$FIXTURE_PLAN/task-checkout-flow.md"
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

@test "red twin: a duplicated, unfenced or unlisted sentinel fails the sentinel check" {
  check_sentinels_once_in_fences "$PLANNER_MD"
  copy="$BATS_TEST_TMPDIR/planner.md"
  cp "$PLANNER_MD" "$copy"
  printf '\n%s\n' "$S_FLOW" >>"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
  # Unfenced: drop every fence line, so the sentinel lines sit in prose.
  grep -vE '^[[:space:]]*```' "$PLANNER_MD" >"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
  # A block the list does not name, inside its own fence.
  { cat "$PLANNER_MD"; printf '\n```\n<!-- gaia:orchestrator-step red-split -->\n```\n'; } >"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
}

@test "the sentinels sit in planner.md in the list's order, flow-checks between the gate retry and the worthiness step" {
  check_sentinel_file_order "$PLANNER_MD"
}

@test "red twin: a flow-checks block below the worthiness step fails the order check" {
  check_sentinel_file_order "$PLANNER_MD"
  copy="$BATS_TEST_TMPDIR/planner.md"
  awk -v flow="$S_FLOW" -v worth="$S_WORTH" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == flow { sub(/flow-checks/, "TEMP-SENTINEL") }
    t == worth { sub(/worthiness-step/, "flow-checks") }
    { print }' "$PLANNER_MD" >"$copy"
  sed -i.bak 's/TEMP-SENTINEL/worthiness-step/' "$copy"
  run check_sentinel_file_order "$copy"
  [ "$status" -ne 0 ]
}

@test "the verbatim-block sentence names each step in order, the spec-less omission and the compared set" {
  check_verbatim_sentence "$PLANNER_MD"
}

@test "red twin: a step missing, out of order or wrongly compared in the verbatim-block sentence fails" {
  check_verbatim_sentence "$PLANNER_MD"
  local copy="$BATS_TEST_TMPDIR/planner.md" step
  for step in "${SPEC_DERIVED_STEPS[@]}"; do
    awk -v step="\`$step\`" '/\*\*Verbatim step blocks\.\*\*/ { i = index($0, step); if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(step)) } { print }' "$PLANNER_MD" >"$copy"
    cmp -s "$PLANNER_MD" "$copy" && { echo "\`$step\` is not in the verbatim-block sentence" >&2; return 1; }
    run check_verbatim_sentence "$copy"
    [ "$status" -ne 0 ] || { echo "dropping $step from the order list did not fail" >&2; return 1; }
  done
  # Swap two neighbours in the order list.
  sed '/\*\*Verbatim step blocks\.\*\*/s/`simplify-pass`, `flow-checks`/`flow-checks`, `simplify-pass`/' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "simplify-pass, flow-checks is not in the order list" >&2; return 1; }
  run check_verbatim_sentence "$copy"
  [ "$status" -ne 0 ]
  awk '/\*\*Verbatim step blocks\.\*\*/ { gsub(/[Ss]pec-less/, "other") } { print }' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "the verbatim-block sentence does not mention spec-less plans" >&2; return 1; }
  run check_verbatim_sentence "$copy"
  [ "$status" -ne 0 ]
  sed '/\*\*Verbatim step blocks\.\*\*/s/compares the text of the resume-detection, /compares the text of the /' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "the compared set does not open with resume-detection" >&2; return 1; }
  run check_verbatim_sentence "$copy"
  [ "$status" -ne 0 ]
  sed '/\*\*Verbatim step blocks\.\*\*/s/ and post-clearance blocks/, post-clearance and post-merge-close blocks/' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "the compared set does not end with post-clearance" >&2; return 1; }
  run check_verbatim_sentence "$copy"
  [ "$status" -ne 0 ]
}

@test "each block carries the command or pointer it exists for" {
  check_block_contents "$PLANNER_MD"
}

@test "red twin: a block missing its command fails the contents check" {
  check_block_contents "$PLANNER_MD"
  copy="$BATS_TEST_TMPDIR/planner.md"
  local needle
  for needle in 'flow-coverage.sh' 'flow-tests.tsv' 'gaia_context_yield_limit' 'Yield handoff:' 'YIELD k' 'wiki-promote.md' 'runs only after' 'simplify-pass.md' 'worthiness-step.md' 'overlap-pass.md' 'promoted-pages.txt' 'Pass: pre-audit' 'Pass: refresh' 'post-audit-status.sh' '#### Posting the status last' 'Skipping already-cleared members' 'verify-harness.sh branch' 'Consolidation refresh'; do
    awk -v needle="$needle" '{ gsub(needle, "removed") } { print }' "$PLANNER_MD" >"$copy"
    run check_block_contents "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail the check" >&2; return 1; }
  done
}

# The entry file routes to planner.md and must not carry a second copy of a
# block or the archive call a stale copy would run.
check_entry_file_has_no_blocks() {
  local file="$1" hit
  hit="$(grep -nF -- '<!-- gaia:orchestrator-step' "$file" || true)"
  [ -z "$hit" ] || { printf '%s holds an orchestrator-step sentinel: %s\n' "$file" "$hit" >&2; return 1; }
  hit="$(grep -nF -- 'plan-archive.sh' "$file" || true)"
  [ -z "$hit" ] || { printf '%s names plan-archive.sh: %s\n' "$file" "$hit" >&2; return 1; }
}

@test "plan.md holds no orchestrator-step sentinel and never names plan-archive.sh" {
  check_entry_file_has_no_blocks "$PLAN_MD"
}

@test "red twin: a sentinel or a plan-archive.sh line in plan.md fails the entry-file check" {
  copy="$BATS_TEST_TMPDIR/plan.md"
  { cat "$PLAN_MD"; printf '\n%s\n' "$S_CLOSE"; } >"$copy"
  run check_entry_file_has_no_blocks "$copy"
  [ "$status" -ne 0 ]
  { cat "$PLAN_MD"; printf '\nbash .gaia/scripts/plan-archive.sh {PLAN_DIR}\n'; } >"$copy"
  run check_entry_file_has_no_blocks "$copy"
  [ "$status" -ne 0 ]
}

# ---------- close order: nothing irreversible before MERGED ----------

@test "planner.md archives and removes layers only in or after the post-merge close" {
  check_plan_close_order "$PLANNER_MD"
}

@test "red twin: an archive or a SPEC.md removal above the post-merge close fails" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  { sed -n '1,20p' "$PLANNER_MD"; printf '      bash .gaia/scripts/plan-archive.sh {PLAN_DIR}\n'; sed -n '21,$p' "$PLANNER_MD"; } >"$copy"
  run check_plan_close_order "$copy"
  [ "$status" -ne 0 ]
  { sed -n '1,20p' "$PLANNER_MD"; printf '      On exit 0, rm the folder SPEC.md and AUDIT.md.\n'; sed -n '21,$p' "$PLANNER_MD"; } >"$copy"
  run check_plan_close_order "$copy"
  [ "$status" -ne 0 ]
}

@test "lifecycle.md's post-merge close confirms MERGED before archive and removal" {
  check_lifecycle_close_order "$LIFECYCLE_MD"
}

@test "red twin: an archive above the MERGED confirmation fails the close order" {
  copy="$BATS_TEST_TMPDIR/lifecycle.md"
  awk '{ print } /^## Post-merge close$/ { print ""; print "bash .gaia/scripts/plan-archive.sh <PLAN_DIR>" }' "$LIFECYCLE_MD" >"$copy"
  run check_lifecycle_close_order "$copy"
  [ "$status" -ne 0 ]
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

# ---------- pre-flight sweep call sites and order ----------

@test "the sweep scans before it reaps and the close passes the PR number" {
  check_preflight_sites "$LIFECYCLE_MD"
}

@test "red twin: a reap above the scan, or a close without the PR number, fails" {
  copy="$BATS_TEST_TMPDIR/lifecycle.md"
  # Move the plan reap line to the top of the sweep section.
  awk '
    /^## Pre-flight sweep$/ { print; print ""; print "bash .gaia/scripts/spec/plan-archive-merged.sh \"$PWD\" 2>/dev/null || true"; next }
    { print }' "$LIFECYCLE_MD" >"$copy"
  run check_preflight_sites "$copy"
  [ "$status" -ne 0 ]
  sed 's/"\$PLAN_ID" "<N>"/"$PLAN_ID"/' "$LIFECYCLE_MD" >"$copy"
  run check_preflight_sites "$copy"
  [ "$status" -ne 0 ]
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

@test "red twin: a HALTED phase 2 with no Commit line lowers the resume point" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (HALTED)\nReason: flow test failed in the closing gate\n' "$SHA_ONE" >"$PROGRESS_DIR/PROGRESS.md"
  [ "$(resume_point)" = "2" ]
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

@test "the adopter form of planner.md and lifecycle.md names no verify-harness" {
  check_adopter_form "$PLANNER_MD"
  check_adopter_form "$LIFECYCLE_MD"
}

@test "the marked pair holds the verify-harness mention in planner.md" {
  grep -qF 'verify-harness' "$PLANNER_MD"
}

@test "red twin: an unmarked verify-harness in a block fails the adopter-form check" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  awk -v want="$S_AUDIT" '{ print } { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print "      Run bash .gaia/tests/verify-harness.sh branch first." }' "$PLANNER_MD" >"$copy"
  run check_adopter_form "$copy"
  [ "$status" -ne 0 ]
  copy="$BATS_TEST_TMPDIR/lifecycle.md"
  { cat "$LIFECYCLE_MD"; printf '\nRun verify-harness.sh branch.\n'; } >"$copy"
  run check_adopter_form "$copy"
  [ "$status" -ne 0 ]
}

@test "each changed page keeps its maintainer-only markers balanced" {
  local file
  for file in \
    "$PLANNER_MD" "$LIFECYCLE_MD" "$WIKI_PROMOTE_MD" \
    "$REPO_ROOT/wiki/concepts/Task Orchestration.md" \
    "$REPO_ROOT/wiki/concepts/GAIA Plan.md" \
    "$REPO_ROOT/wiki/concepts/Wiki Consolidate.md" \
    "$REPO_ROOT/.claude/skills/gaia/references/wiki/consolidate.md"; do
    [ -f "$file" ] || { printf 'missing %s\n' "$file" >&2; return 1; }
    check_markers_balanced "$file" || return 1
  done
}

@test "red twin: an unbalanced marker fails the balance check" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  grep -vF -- '<!-- gaia:maintainer-only:end -->' "$PLANNER_MD" >"$copy"
  run check_markers_balanced "$copy"
  [ "$status" -ne 0 ]
}

# check_manifest_placement <planner>: the release manifest mechanics live only in
# wiki-promote.md's maintainer note.
check_manifest_placement() {
  local file="$1" hit
  hit="$(grep -nE -e '--ship|release manifest' "$file" || true)"
  [ -z "$hit" ] || { printf '%s holds manifest mechanics: %s\n' "$file" "$hit" >&2; return 1; }
  check_block_has "$file" "$S_WIKI" 'wiki-promote.md' "maintainer note" || return 1
  check_block_has "$file" "$S_CLEAR" 'wiki-promote.md' "maintainer note" || return 1
}

@test "planner.md holds no manifest mechanics and its blocks point at the maintainer note" {
  check_manifest_placement "$PLANNER_MD"
}

@test "red twin: a seeded --ship or release manifest in planner.md fails" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  { cat "$PLANNER_MD"; printf '\nrun release manifest --ship wiki/concepts/X.md\n'; } >"$copy"
  run check_manifest_placement "$copy"
  [ "$status" -ne 0 ]
  { cat "$PLANNER_MD"; printf '\nrun release manifest\n'; } >"$copy"
  run check_manifest_placement "$copy"
  [ "$status" -ne 0 ]
}

# check_post_clearance_commits_nothing_of_summary <planner>: SUMMARY.md is
# untracked, so the refresh states it stays uncommitted and never stages it.
check_post_clearance_commits_nothing_of_summary() {
  local block
  block="$(fence_with "$1" "$S_CLEAR")"
  [ -n "$block" ] || { printf 'no post-clearance block\n' >&2; return 1; }
  grep -qF 'uncommitted' <<<"$block" || { printf 'post-clearance block does not state SUMMARY.md stays uncommitted\n' >&2; return 1; }
  grep -qiE '(commit|stage|git add)[^.]*SUMMARY\.md' <<<"$(grep -v 'uncommitted' <<<"$block")" && { printf 'post-clearance block instructs committing SUMMARY.md\n' >&2; return 1; }
  true
}

# check_promotion_above_audit <planner>: the wiki promotion block precedes the
# code audit block.
check_promotion_above_audit() {
  local file="$1" wiki audit
  wiki="$(awk -v want="$S_WIKI" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
  audit="$(awk -v want="$S_AUDIT" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
  { [ -n "$wiki" ] && [ -n "$audit" ]; } || { printf 'wiki-promotion (%s) or code-audit (%s) sentinel missing\n' "$wiki" "$audit" >&2; return 1; }
  [ "$wiki" -lt "$audit" ] || { printf 'wiki-promotion (%s) is not above code-audit (%s)\n' "$wiki" "$audit" >&2; return 1; }
}

@test "the post-clearance block commits no SUMMARY.md and the promotion block sits above the audit" {
  check_post_clearance_commits_nothing_of_summary "$PLANNER_MD"
  check_promotion_above_audit "$PLANNER_MD"
}

@test "red twin: a SUMMARY.md commit in post-clearance, or the audit above the promotion, fails" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  awk -v want="$S_CLEAR" '{ print } { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print "      Commit SUMMARY.md with the page fixes." }' "$PLANNER_MD" >"$copy"
  run check_post_clearance_commits_nothing_of_summary "$copy"
  [ "$status" -ne 0 ]
  awk 'BEGIN { RS = "\0" } { gsub(/uncommitted/, "committed"); printf "%s", $0 }' "$PLANNER_MD" >"$copy"
  run check_post_clearance_commits_nothing_of_summary "$copy"
  [ "$status" -ne 0 ]
  awk -v wiki="$S_WIKI" -v audit="$S_AUDIT" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == wiki { sub(/wiki-promotion/, "TEMP-SENTINEL") }
    t == audit { sub(/code-audit/, "wiki-promotion") }
    { print }' "$PLANNER_MD" >"$copy"
  sed -i.bak 's/TEMP-SENTINEL/code-audit/' "$copy"
  run check_promotion_above_audit "$copy"
  [ "$status" -ne 0 ]
}

# check_final_summary_names_worthiness <planner>: the final summary reads the
# worthiness blocks, and the late pass sits in the code audit block above it.
check_final_summary_names_worthiness() {
  local file="$1" summary audit_block summary_line audit_line
  summary="$(range_of "$file" '**Final summary.**' '**Post-clearance')"
  grep -qF '## Worthiness step' <<<"$summary" || { printf 'final summary does not name the ## Worthiness step blocks\n' >&2; return 1; }
  grep -qF '## Overlap pass' <<<"$summary" || { printf 'final summary does not name the ## Overlap pass block\n' >&2; return 1; }
  audit_block="$(fence_with "$file" "$S_AUDIT")"
  grep -qF 'the late pass' <<<"$audit_block" || { printf 'code-audit block does not run the late pass\n' >&2; return 1; }
  summary_line="$(grep -nF -m1 '**Final summary.**' "$file" | cut -d: -f1)"
  audit_line="$(awk -v want="$S_AUDIT" '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) } t == want { print NR; exit }' "$file")"
  [ "$audit_line" -lt "$summary_line" ] || { printf 'the late pass block (%s) is not above the final summary (%s)\n' "$audit_line" "$summary_line" >&2; return 1; }
}

@test "the final summary names the worthiness blocks and the late pass sits above it" {
  check_final_summary_names_worthiness "$PLANNER_MD"
}

@test "red twin: dropping the worthiness mention or the late pass fails" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  sed 's/## Worthiness step` blocks from/removed blocks from/' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "worthiness mention not found" >&2; return 1; }
  run check_final_summary_names_worthiness "$copy"
  [ "$status" -ne 0 ]
  sed 's/the late pass from/the other pass from/' "$PLANNER_MD" >"$copy"
  run check_final_summary_names_worthiness "$copy"
  [ "$status" -ne 0 ]
  sed 's/## Overlap pass` block from/removed block from/' "$PLANNER_MD" >"$copy"
  cmp -s "$PLANNER_MD" "$copy" && { echo "overlap mention not found" >&2; return 1; }
  run check_final_summary_names_worthiness "$copy"
  [ "$status" -ne 0 ]
}

# ---------- lifecycle.md's promotion record ----------

# check_record_arm <lifecycle>: which pass writes the promotion record.
check_record_arm() {
  local file="$1" section needle
  section="$(section_of "$file" '## Consolidation')"
  [ -n "$section" ] || { printf 'no ## Consolidation section\n' >&2; return 1; }
  for needle in \
    'is written only by a pass attempting promotion' \
    'It always attempts promotion' \
    'attempts promotion only when it reaches' \
    '`## Consolidation refresh`' \
    'A plan generated before this order' \
    'Pass: pre-audit'; do
    grep -qF -- "$needle" <<<"$section" || { printf 'consolidation section lacks: %s\n' "$needle" >&2; return 1; }
  done
}

@test "lifecycle.md states which pass writes the promotion record and names the fourth caller" {
  check_record_arm "$LIFECYCLE_MD"
}

@test "red twin: removing any record-arm sentence fails" {
  local needle copy="$BATS_TEST_TMPDIR/lifecycle.md"
  for needle in 'is written only by a pass attempting promotion' 'It always attempts promotion' 'attempts promotion only when it reaches' 'Consolidation refresh' 'A plan generated before this order'; do
    awk -v needle="$needle" '{ while ((i = index($0, needle)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(needle)) } { print }' "$LIFECYCLE_MD" >"$copy"
    cmp -s "$LIFECYCLE_MD" "$copy" && { echo "'$needle' not found" >&2; return 1; }
    run check_record_arm "$copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail the check" >&2; return 1; }
  done
}

# check_old_order_gone <file>...: no statement of promotion after clearance as
# the order, and the maintainer note still names the verify pass and re-audit.
check_old_order_gone() {
  local file
  for file in "$@"; do
    grep -qF -e 'Promotion runs after audit clearance' -e 'Two callers run it' -e 'runs after every dispatched Code Audit Team member has cleared and the human has confirmed' "$file" && {
      printf '%s still states the old promotion order\n' "$file" >&2
      return 1
    }
  done
  return 0
}

check_maintainer_note_costs() {
  local note
  note="$(awk '
    { t = $0; sub(/^[ \t]+/, "", t) }
    t == "<!-- gaia:maintainer-only:start -->" { inside = 1; next }
    t == "<!-- gaia:maintainer-only:end -->" { inside = 0; next }
    inside { print }' "$1")"
  grep -qF 'verify-harness.sh branch' <<<"$note" || { printf 'maintainer note lacks the verify pass\n' >&2; return 1; }
  grep -qF 'shell re-audit' <<<"$note" || { printf 'maintainer note lacks the shell re-audit\n' >&2; return 1; }
}

@test "no owned page states the old promotion order and the maintainer note names its cost" {
  check_old_order_gone "$PLANNER_MD" "$LIFECYCLE_MD" "$WIKI_PROMOTE_MD"
  check_maintainer_note_costs "$WIKI_PROMOTE_MD"
}

@test "red twin: the old order sentence, or a note without the re-audit, fails" {
  copy="$BATS_TEST_TMPDIR/wiki-promote.md"
  { cat "$WIKI_PROMOTE_MD"; printf '\nPromotion runs after audit clearance because it summarizes the audited code.\n'; } >"$copy"
  run check_old_order_gone "$copy"
  [ "$status" -ne 0 ]
  sed 's/shell re-audit/other work/g' "$WIKI_PROMOTE_MD" >"$copy"
  run check_maintainer_note_costs "$copy"
  [ "$status" -ne 0 ]
}

# ---------- plan-time directives never pick a test layer ----------

# check_directive_routing <planner> <audit>: the planner's directive paragraph
# carries no routing-ladder or surface wording, and the SPEC audit writes a
# directive as the property a test proves or the constraint the code meets,
# never the layer, fixture or helper that proves it.
check_directive_routing() {
  local planner="$1" audit="$2" para word
  para="$(grep -F 'Its `## Plan-time directives` section' "$planner")"
  [ -n "$para" ] || { printf 'planner.md has no AUDIT_PATH directive paragraph\n' >&2; return 1; }
  for word in 'ladder' 'surface' 'routes to' 'routed'; do
    grep -qiF -- "$word" <<<"$para" && { printf 'planner AUDIT_PATH paragraph still holds routing wording: %s\n' "$word" >&2; return 1; }
  done
  grep -qF -- 'Write it as the property a test proves or the constraint the code meets, never the test layer, fixture or helper that proves it' "$audit" ||
    { printf 'audit.md 7c lacks the property-not-layer rule\n' >&2; return 1; }
  grep -qF -- 'naming no test layer, fixture or helper' "$audit" ||
    { printf 'audit.md 7d template lacks the no-layer clause\n' >&2; return 1; }
}

@test "a plan-time directive never picks a test layer, in planner.md and the SPEC audit" {
  check_directive_routing "$PLANNER_MD" "$AUDIT_MD"
}

@test "red twin: routing wording in the directive paragraph, or an audit without the no-layer rule, fails" {
  check_directive_routing "$PLANNER_MD" "$AUDIT_MD"
  local needle plan_copy="$BATS_TEST_TMPDIR/planner.md" audit_copy="$BATS_TEST_TMPDIR/audit.md"
  for needle in 'route it by the ladder first' 'honor its intent on the routed surface'; do
    awk -v needle="$needle" '/Its `## Plan-time directives` section/ { $0 = $0 " " needle "." } { print }' "$PLANNER_MD" >"$plan_copy"
    cmp -s "$PLANNER_MD" "$plan_copy" && { echo "the directive paragraph is not in planner.md" >&2; return 1; }
    run check_directive_routing "$plan_copy" "$AUDIT_MD"
    [ "$status" -ne 0 ] || { echo "adding '$needle' did not fail" >&2; return 1; }
  done
  for needle in 'never the test layer, fixture or helper that proves it' 'naming no test layer, fixture or helper'; do
    awk -v needle="$needle" '{ while ((i = index($0, needle)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(needle)) } { print }' "$AUDIT_MD" >"$audit_copy"
    run check_directive_routing "$PLANNER_MD" "$audit_copy"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
}

# ---------- a directive never adds a test file, and a flow is one test ----------

# A directive written as a test demand, or a flow's paths split across files,
# let a plan name tests beyond the one flow test per flow and both-condition
# unit tests, which breaks the trophy's one test per behavior.
DIRECTIVE_NEW_TEST_NEEDLE='It never asks for a new test, a test file, or a rule proven on its own'
UNCOVERED_RULE_NEEDLE='Any other finding that a rule has no flow or success criterion stating it is `spec_defect`, never `plan_directive`'
FOLD_INTO_UAT_NEEDLE='folds into the intent or a success criterion, never into the flow as a branch or case list; a new flow is added only for a critical path no flow names'
HONOR_INSIDE_NEEDLE='or an assertion inside a flow test the plan names'
DIRECTIVE_OTHER_TEST_NEEDLE='any other test'
DIRECTIVE_FOLLOW_UP_NEEDLE='`## Follow-ups`'
FLOW_TEST_PATHS_NEEDLE='covering the happy path and each error path the build has'

# check_directive_test_scope <planner> <audit>
check_directive_test_scope() {
  local planner="$1" audit="$2" para needle
  for needle in "$DIRECTIVE_NEW_TEST_NEEDLE" "$UNCOVERED_RULE_NEEDLE" "$FOLD_INTO_UAT_NEEDLE"; do
    grep -qF -- "$needle" "$audit" || { printf 'audit.md lacks: %s\n' "$needle" >&2; return 1; }
  done
  para="$(grep -F 'Its `## Plan-time directives` section' "$planner")"
  for needle in "$HONOR_INSIDE_NEEDLE" "$DIRECTIVE_OTHER_TEST_NEEDLE" "$DIRECTIVE_FOLLOW_UP_NEEDLE"; do
    grep -qF -- "$needle" <<<"$para" || { printf 'planner AUDIT_PATH paragraph lacks: %s\n' "$needle" >&2; return 1; }
  done
  grep -qF -- "$FLOW_TEST_PATHS_NEEDLE" "$planner" || { printf 'planner.md lacks the one-test-per-flow paths rule\n' >&2; return 1; }
}

@test "a plan-time directive never adds a test file and a flow's paths stay in its one test, in the SPEC audit and planner.md" {
  check_directive_test_scope "$PLANNER_MD" "$AUDIT_MD"
}

@test "red twin: dropping any clause of the directive and flow-test scope fails" {
  check_directive_test_scope "$PLANNER_MD" "$AUDIT_MD"
  local needle file copy mutated
  for needle in "$DIRECTIVE_NEW_TEST_NEEDLE" "$UNCOVERED_RULE_NEEDLE" "$FOLD_INTO_UAT_NEEDLE" \
    "$HONOR_INSIDE_NEEDLE" "$DIRECTIVE_OTHER_TEST_NEEDLE" "$DIRECTIVE_FOLLOW_UP_NEEDLE" "$FLOW_TEST_PATHS_NEEDLE"; do
    mutated=0
    for file in "$PLANNER_MD" "$AUDIT_MD"; do
      grep -qF -- "$needle" "$file" || continue
      copy="$BATS_TEST_TMPDIR/$(basename "$file")"
      awk -v needle="$needle" '{ while ((i = index($0, needle)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(needle)) } { print }' "$file" >"$copy"
      cmp -s "$file" "$copy" && { echo "mutation left $file unchanged: $needle" >&2; return 1; }
      if [ "$file" = "$PLANNER_MD" ]; then
        run check_directive_test_scope "$copy" "$AUDIT_MD"
      else
        run check_directive_test_scope "$PLANNER_MD" "$copy"
      fi
      [ "$status" -ne 0 ] || { echo "removing '$needle' from $file did not fail" >&2; return 1; }
      mutated=1
    done
    [ "$mutated" -eq 1 ] || { echo "no file holds: $needle" >&2; return 1; }
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

@test "red twin: dropping any markup-rule sentence fails" {
  local needle audit_copy="$BATS_TEST_TMPDIR/audit.md" template_copy="$BATS_TEST_TMPDIR/spec-template.md"
  for needle in 'never flow or success-criterion text' 'even when it cites a flow' 'naming the page or component it applies to'; do
    awk -v needle="$needle" '{ while ((i = index($0, needle)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(needle)) } { print }' "$AUDIT_MD" >"$audit_copy"
    run check_markup_rule_placement "$audit_copy" "$SPEC_TEMPLATE_MD"
    [ "$status" -ne 0 ] || { echo "removing '$needle' did not fail" >&2; return 1; }
  done
  sed 's/A page-markup or accessibility structure rule/removed/' "$SPEC_TEMPLATE_MD" >"$template_copy"
  run check_markup_rule_placement "$AUDIT_MD" "$template_copy"
  [ "$status" -ne 0 ]
}
