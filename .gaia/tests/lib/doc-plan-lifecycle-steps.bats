#!/usr/bin/env bats
#
# Doc-conformance suite for the generated orchestrator's lifecycle steps.
#
# .claude/skills/gaia/references/plan/planner.md, the file the planner
# sub-agent reads, holds the verbatim step blocks a planner copies into a
# generated ORCHESTRATOR.md, each opening with a sentinel line plan-verify.sh
# checks: the UAT render, the owning-phase UAT gate, the sub-agent yield
# handling, the pre-audit UAT checks, the worthiness step, the wiki promotion,
# the code audit, the post-clearance step and the post-merge close.
# .claude/skills/gaia/references/spec/lifecycle.md holds the procedures those
# blocks point at, and .claude/skills/gaia/references/plan.md, the
# /gaia-plan entry file, keeps the pre-flight sweep pointer. This suite pins:
#
#   - each sentinel sits once in planner.md, inside a fenced block, and each
#     block carries the command or pointer it exists for;
#   - plan.md holds no sentinel and never names plan-archive.sh, so the
#     blocks have one home;
#   - nothing in planner.md archives the plan folder or removes SPEC.md before
#     the post-merge close, and lifecycle.md's close confirms MERGED first;
#   - the blocks, assembled the way a planner copies them (indentation
#     kept), pass plan-verify.sh;
#   - the render block routes exit 3 and runs on every resume, and the stop
#     conditions name the SPEC reopen;
#   - the shared pre-flight sweep runs its reconcile scan before the reap that
#     reads what it stamps, and the post-merge close passes the PR number;
#   - the new PROGRESS.md blocks never move plan-resume-point.sh's answer;
#   - the adopter form of planner.md and lifecycle.md (every maintainer-only
#     pair stripped) names no verify-harness, every changed page keeps its
#     markers balanced, and no block holds the release manifest mechanics;
#   - the post-clearance block commits no SUMMARY.md, the wiki promotion block
#     sits above the code audit block, and the final summary names the
#     worthiness blocks the late pass feeds;
#   - lifecycle.md says which pass writes the wiki promotion record.
#
# Every check is a function taking the file(s) it reads, so each red twin
# runs the same function against a mutated copy and proves it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  PLANNER_MD="$REPO_ROOT/.claude/skills/gaia/references/plan/planner.md"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  WIKI_PROMOTE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/wiki-promote.md"
  PLAN_VERIFY="$REPO_ROOT/.gaia/scripts/spec/plan-verify.sh"
  RESUME_POINT="$REPO_ROOT/.gaia/scripts/plan-resume-point.sh"
  S_RENDER='<!-- gaia:orchestrator-step uat-render -->'
  S_GATE='<!-- gaia:orchestrator-step uat-gate -->'
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_PRE='<!-- gaia:orchestrator-step uat-pre-audit -->'
  S_WORTH='<!-- gaia:orchestrator-step worthiness-step -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
}

# ---------- helpers ----------

# sentinel_set: the sentinel literals plan-verify.sh requires, in its order.
# plan-verify.sh owns the set, so the suite derives it rather than retyping it.
sentinel_set() {
  grep -oE "'<!-- gaia:orchestrator-step [a-z-]+ -->'" "$PLAN_VERIFY" | tr -d "'" | awk '!seen[$0]++'
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
  local file="$1" sentinel total fenced count=0
  while IFS= read -r sentinel; do
    count=$((count + 1))
    total="$(count_trimmed "$file" "$sentinel")"
    fenced="$(count_in_fences "$file" "$sentinel")"
    if [ "$total" -ne 1 ] || [ "$fenced" -ne 1 ]; then
      printf '%s: %s appears %s times, %s inside a fence (want 1 and 1)\n' "$file" "$sentinel" "$total" "$fenced" >&2
      return 1
    fi
  done < <(sentinel_set)
  [ "$count" -eq 9 ] || { printf 'derived %s sentinels from plan-verify.sh, want 9\n' "$count" >&2; return 1; }
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
  check_block_has "$file" "$S_RENDER" 'uat-write.sh' '{SPEC_PATH}' '--routing' || return 1
  check_block_has "$file" "$S_GATE" 'uat-gate.sh' '--phase' || return 1
  check_block_has "$file" "$S_YIELD" 'gaia_context_yield_limit' 'Yield handoff:' '(YIELD k)' || return 1
  check_block_has "$file" "$S_PRE" '--all' || return 1
  check_block_has "$file" "$S_WORTH" 'worthiness-step.md' || return 1
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

check_pinned_literals() {
  local plan="$1" range block
  range="$(range_of "$plan" '**Stop conditions.**' '**Final summary.**')"
  grep -qiF 'reopen the SPEC' <<<"$range" || { printf 'stop conditions do not name the SPEC reopen\n' >&2; return 1; }
  block="$(fence_with "$plan" "$S_RENDER")"
  grep -qF 'Exit 3' <<<"$block" || { printf 'render block does not route exit 3\n' >&2; return 1; }
  grep -qF 'every resume' <<<"$block" || { printf 'render block does not run on resume\n' >&2; return 1; }
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
  printf '# Orchestrator\n\nResume detection, pre-flight isolation, RUNNING sentinel.\n\n' >"$out"
  for sentinel in "$@"; do
    block="$(fence_with "$source" "$sentinel")"
    [ -n "$block" ] || { printf 'no block for %s\n' "$sentinel" >&2; return 1; }
    block="${block//\{SPEC_PATH\}/$FIXTURE_SPEC}"
    block="${block//\{PLAN_DIR\}/$FIXTURE_PLAN}"
    printf '%s\n\nprose between steps\n\n' "$block" >>"$out"
  done
}

write_plan_fixture() {
  FIXTURE_PLAN="$BATS_TEST_TMPDIR/plan"
  FIXTURE_SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$FIXTURE_PLAN"
  cat >"$FIXTURE_SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
---
EOF
  cat >"$FIXTURE_PLAN/README.md" <<'EOF'
# Plan

## UAT routing

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |
<!-- gaia:uat-routing:end -->
EOF
  printf 'You are the orchestrator.\n' >"$FIXTURE_PLAN/KICKOFF.md"
  printf '# Task\n\n- builds checkout\n' >"$FIXTURE_PLAN/task-checkout.md"
}

# ---------- sentinels and block contents ----------

@test "each orchestrator sentinel sits once in planner.md, inside a fenced block" {
  check_sentinels_once_in_fences "$PLANNER_MD"
}

@test "red twin: a duplicated or unfenced sentinel fails the sentinel check" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  cp "$PLANNER_MD" "$copy"
  printf '\n%s\n' "$S_GATE" >>"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
  # Unfenced: drop every fence line, so the sentinel lines sit in prose.
  grep -vE '^[[:space:]]*```' "$PLANNER_MD" >"$copy"
  run check_sentinels_once_in_fences "$copy"
  [ "$status" -ne 0 ]
}

@test "each block carries the command or pointer it exists for" {
  check_block_contents "$PLANNER_MD"
}

@test "red twin: a block missing its command fails the contents check" {
  copy="$BATS_TEST_TMPDIR/planner.md"
  local needle
  for needle in 'uat-write.sh' '--phase' 'gaia_context_yield_limit' 'Yield handoff:' 'YIELD k' '--all' 'wiki-promote.md' 'runs only after' 'worthiness-step.md' 'promoted-pages.txt' 'Pass: pre-audit' 'Pass: refresh' 'post-audit-status.sh' '#### Posting the status last' 'Skipping already-cleared members' 'verify-harness.sh branch' 'Consolidation refresh'; do
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
  write_plan_fixture
  assemble_orchestrator "$PLANNER_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  # The copy keeps the template's indentation, so the trim rule is exercised.
  grep -qE "^[[:space:]]+<!-- gaia:orchestrator-step uat-render -->$" "$FIXTURE_PLAN/ORCHESTRATOR.md"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN" --spec "$FIXTURE_SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "blocks copied as a planner copies them pass plan-verify.sh without a spec" {
  write_plan_fixture
  assemble_orchestrator "$PLANNER_MD" "$FIXTURE_PLAN/ORCHESTRATOR.md" "$S_YIELD" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  run bash "$PLAN_VERIFY" "$FIXTURE_PLAN"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---------- pinned literals ----------

@test "the render block routes exit 3 and runs on every resume, and stop conditions name the SPEC reopen" {
  check_pinned_literals "$PLANNER_MD"
}

@test "red twin: removing any routing literal fails the literal check" {
  local literal plan_copy="$BATS_TEST_TMPDIR/planner.md"
  for literal in 'Exit 3' 'every resume' 'reopen the SPEC'; do
    awk -v literal="$literal" '{ while ((i = index($0, literal)) > 0) $0 = substr($0, 1, i - 1) "removed" substr($0, i + length(literal)) } { print }' "$PLANNER_MD" >"$plan_copy"
    if cmp -s "$PLANNER_MD" "$plan_copy"; then echo "'$literal' is not in planner.md" >&2; return 1; fi
    run check_pinned_literals "$plan_copy"
    [ "$status" -ne 0 ] || { echo "removing '$literal' did not fail the check" >&2; return 1; }
  done
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

@test "the UAT render, wiki promotion and gate HALTED blocks leave the resume point unchanged" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two\nCommit: %s\n\n_No notes._\n' "$SHA_ONE" "$SHA_TWO" >"$PROGRESS_DIR/PROGRESS.md"
  baseline="$(resume_point)"
  [ "$baseline" = "3" ]
  cat >>"$PROGRESS_DIR/PROGRESS.md" <<'EOF'

## UAT render
Commit: none (nothing changed)
Summary: written 0, rewritten 0, unchanged 1, preserved 0, deleted 0, conflict 0

## UAT render (HALTED)
Reason: UAT render conflict
Spec files: frontend/.playwright/e2e/checkout/a.spec.ts changed-and-edited

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
Reason: UAT gate failed
Spec files: frontend/.playwright/e2e/checkout/a.spec.ts failed
EOF
  [ "$(resume_point)" = "$baseline" ]
}

@test "red twin: a HALTED phase 2 with no Commit line lowers the resume point" {
  resume_fixture
  printf '## Phase 1, One\nCommit: %s\n\n_No notes._\n\n## Phase 2, Two (HALTED)\nReason: UAT gate failed\n' "$SHA_ONE" >"$PROGRESS_DIR/PROGRESS.md"
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
}

# check_record_arm <lifecycle>: which pass writes the promotion record.
check_record_arm() {
  local file="$1" section needle
  section="$(section_of "$file" '## Consolidation')"
  [ -n "$section" ] || { printf 'no ## Consolidation section\n' >&2; return 1; }
  for needle in \
    'is written only by a pass attempting promotion' \
    'The pre-audit pass always attempts' \
    'A refresh attempts only when it reaches' \
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
  for needle in 'is written only by a pass attempting promotion' 'The pre-audit pass always attempts' 'A refresh attempts only when it reaches' 'Consolidation refresh' 'A plan generated before this order'; do
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
