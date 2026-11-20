#!/usr/bin/env bats
#
# Doc-conformance suite for the shared worthiness step reference.
#
# .claude/skills/gaia/references/worthiness-step.md owns the dispatch and
# verdict routing of the worthiness step. This suite pins:
#
#   - the late pass's one arm per route value, recommending a residual for a
#     fix or delete;
#   - no file under .claude or .gaia/scripts runs the ledger writer with node;
#   - maintainer-only markers balanced, and the verification command named
#     only inside a marked block.
#
# Assertion style: .claude/rules/bats-assertions.md.

# shellcheck disable=SC2016
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES="$REPO_ROOT/.claude/skills/gaia/references"
  REF="$REFERENCES/worthiness-step.md"
  LIFECYCLE="$REFERENCES/work-lifecycle.md"
  DEBT="$REFERENCES/debt.md"
  TDD_SKILL="$REPO_ROOT/.claude/skills/tdd/SKILL.md"
  MERGE_WORKFLOW="$REPO_ROOT/wiki/concepts/PR Merge Workflow.md"
  H_LATE='## The late pass'
}

# ---------- helpers ----------

# section_text <file> <heading prefix>: the heading line and its body, up to
# the next heading of the same or a higher level.
section_text() {
  awk -v h="$2" '
    function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !on && index($0, h) == 1 { on = 1; start = level($0); print; next }
    on && /^#+ / && level($0) <= start { exit }
    on { print }' "$1"
}

LATE_ARMS=(delete file residual evaluate fix)

# late_arm_present <file> <arm>: a late-pass bullet's leading code-span list
# names the route value.
late_arm_present() {
  section_text "$1" "$H_LATE" | grep -qE "^- (\`[a-z]+\`, )*\`$2\`[,:]"
}

# late_repairs_recommend_residual <file>: the late pass's fix and delete arm
# recommends a residual, so a picker that takes the recommendation keeps the
# clean round the last word; only a repair the human picks reaches the unit
# dispatch, and an unattended run settles a residual.
late_repairs_recommend_residual() {
  local late bullet
  late=$(section_text "$1" "$H_LATE")
  [ -n "$late" ] || return 1
  bullet=$(grep -E '^- `fix`, `delete`:' <<<"$late") || return 1
  grep -qF -- '`Accept all as recommended (Recommended)` or `Revise`' <<<"$bullet" || return 1
  grep -qF -- 'the recommendation to record it as a residual' <<<"$bullet" || return 1
  grep -qF -- 'any test in an unattended run, takes `settle --as residual`' <<<"$bullet" || return 1
  grep -qF -- 'the Fix step takes only the tests the human picked to repair' <<<"$bullet" || return 1
  grep -qF -- 'unit dispatch' <<<"$bullet" || return 1
  grep -qF -- 'and those settles run first' <<<"$bullet" || return 1
  grep -qF -- 'takes the File step like a `file` element, never a residual' <<<"$bullet" || return 1
  # Only the accept option may carry the label: strip it, then refuse any other.
  bullet=${bullet//'`Accept all as recommended (Recommended)`'/}
  grep -qF -- '(Recommended)' <<<"$bullet" && return 1
  true
}

# no_node_invocation_of_writer <dir>...: no file outside the writer, the test
# suites and the tests directories runs the ledger writer with node.
no_node_invocation_of_writer() {
  local hits
  hits=$(grep -rnE 'node [^#]*append-worthiness\.mjs' "$@" \
    --exclude='append-worthiness.mjs' --exclude='*.bats' --exclude='*.test.ts' --exclude-dir=tests --exclude-dir=__tests__ --exclude-dir=node_modules 2>/dev/null || true)
  [ -z "$hits" ]
}

# strip_marked <file>: the file without maintainer-only marked blocks.
strip_marked() {
  awk '
    /<!-- gaia:maintainer-only:start -->/ { skip = 1; next }
    /<!-- gaia:maintainer-only:end -->/ { skip = 0; next }
    !skip { print }' "$1"
}

# verification_only_in_marked_block <file>
verification_only_in_marked_block() {
  strip_marked "$1" | grep -q 'verify-harness' && return 1
  grep -qF -- 'verify-harness' "$1"
}

# markers_balanced <file>
markers_balanced() {
  local opened closed
  opened=$(grep -c 'gaia:maintainer-only:start' "$1" || true)
  closed=$(grep -c 'gaia:maintainer-only:end' "$1" || true)
  [ "$opened" -eq "$closed" ]
}

# ---------- late pass ----------

@test "the late pass has one arm per route value and recommends a residual for a fix or delete" {
  local arm
  for arm in "${LATE_ARMS[@]}"; do
    late_arm_present "$REF" "$arm" || return 1
  done
  late_repairs_recommend_residual "$REF"
}

# ---------- one invoker of the writer ----------

@test "nothing under .claude or .gaia/scripts runs the ledger writer with node" {
  no_node_invocation_of_writer "$REPO_ROOT/.claude" "$REPO_ROOT/.gaia/scripts"
}

# ---------- markers ----------

@test "the verification command appears only inside a marked block" {
  verification_only_in_marked_block "$REF"
}

@test "every changed page keeps maintainer-only markers balanced" {
  local file
  for file in "$REF" "$LIFECYCLE" "$DEBT" "$TDD_SKILL" "$MERGE_WORKFLOW" \
    "$REPO_ROOT/.claude/agents/worthiness-evaluator.md" \
    "$REPO_ROOT/wiki/decisions/Worthiness Audit.md" \
    "$REPO_ROOT/wiki/decisions/Worthiness Presence Gate.md" \
    "$REPO_ROOT/wiki/decisions/Quality Gate.md" \
    "$REPO_ROOT/wiki/modules/Claude Integration.md"; do
    markers_balanced "$file"
  done
}
