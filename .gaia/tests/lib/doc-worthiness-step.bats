#!/usr/bin/env bats
#
# Doc-conformance suite for the shared worthiness step reference.
#
# .claude/skills/gaia/references/worthiness-step.md owns the dispatch and
# verdict routing of the pre-audit worthiness step. This suite pins:
#
#   - each caller (the work lifecycle, /gaia-debt) holds an imperative line
#     naming the reference before its audit step, and the merge workflow's
#     pre-dispatch section names it;
#   - the reference pins its commands, the no-op HALT and the refused settle;
#   - the repair, judge-again, delete, late-pass and tdd sections never name
#     the filer, and only the File step runs it;
#   - the step order and the maintainer-only verification order;
#   - the File step's one arm per filer word, the late pass's one arm per
#     route value, and the tdd arm's dispatch-and-record-only shape;
#   - the single invoker of the ledger writer;
#   - the merge workflow's `clean` row order;
#   - maintainer-only markers balanced, and the verification command named
#     only inside a marked block.
#
# Every check is a function taking the file(s) it reads, so each red twin runs
# the same function against a mutated copy and proves it can fail.
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
  H_FIX='### 3. Fix'
  H_JUDGE='### 4. Judge again once'
  H_DELETE='### 5. Delete'
  H_FILE='### 6. File'
  H_LATE='## The late pass'
  H_TDD='## The tdd arm'
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

# line_of <file> <literal>: the first line number holding <literal>, or empty.
line_of() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# heading_line <file> <heading prefix>: the line number of the heading.
heading_line() {
  awk -v h="$2" 'index($0, h) == 1 { print NR; exit }' "$1"
}

# caller_names_reference_before <file> <literal>: the file holds an imperative
# line naming the reference that sits above the first line holding <literal>.
caller_names_reference_before() {
  local imperative boundary
  imperative=$(grep -nE '(^Read|Read) `\.claude/skills/gaia/references/worthiness-step\.md` and run it|Run the worthiness step first' "$1" | head -n 1 | cut -d: -f1)
  boundary=$(line_of "$1" "$2")
  [ -n "$imperative" ] || return 1
  [ -n "$boundary" ] || return 1
  [ "$imperative" -lt "$boundary" ]
}

# derived_callers: the reference files under references/ that name the
# reference, excluding the reference itself.
derived_callers() {
  grep -rlF -- 'worthiness-step.md' "$REFERENCES" | grep -v '/worthiness-step\.md$' | sort
}

# literals_present <file> <literal>...: every literal sits in the file.
literals_present() {
  local file="$1" literal
  shift
  for literal in "$@"; do
    grep -qF -- "$literal" "$file" || return 1
  done
}

REFERENCE_LITERALS=(
  'worthiness-step.sh prune'
  'worthiness-step.sh route'
  'worthiness-step.sh record'
  'worthiness-step.sh finding'
  'audit-noop-detect.sh'
  '--expect-count'
  'A second no-op is a HALT'
  'settle --as refused'
  'settle --as fixed'
  'settle --as filed'
  'settle --as residual'
)

# filer_absent_from_repair_sections <file>: no scoped section names the filer.
filer_absent_from_repair_sections() {
  local heading
  for heading in "$H_FIX" "$H_JUDGE" "$H_DELETE" "$H_LATE" "$H_TDD"; do
    section_text "$1" "$heading" | grep -q 'file-tech-debt' && return 1
  done
  return 0
}

# order_holds <file>: the Fix section comes before Judge again, which comes
# before the late pass, and the marked block names a fix commit before the
# verification.
order_holds() {
  local fix judge late commit verify
  fix=$(heading_line "$1" "$H_FIX")
  judge=$(heading_line "$1" "$H_JUDGE")
  late=$(heading_line "$1" "$H_LATE")
  [ -n "$fix" ] && [ -n "$judge" ] && [ -n "$late" ] || return 1
  [ "$fix" -lt "$judge" ] || return 1
  [ "$judge" -lt "$late" ] || return 1
  commit=$(line_of "$1" 'a fix commit')
  verify=$(line_of "$1" 'verify-harness.sh branch')
  [ -n "$commit" ] && [ -n "$verify" ] || return 1
  [ "$commit" -lt "$verify" ]
}

FILE_WORDS=('`refused-authored`' '`diverted`' '`failed`' '`filed`' '`matched`' '`absent`' '`transient`' 'route read after the last fix commit')

# file_step_has <file> <word>: the File step holds <word>.
file_step_has() {
  section_text "$1" "$H_FILE" | grep -qF -- "$2"
}

LATE_ARMS=(delete file residual evaluate fix)

# late_arm_present <file> <arm>: the late pass has a bullet for the route value.
late_arm_present() {
  section_text "$1" "$H_LATE" | grep -qE "^- \`$2\`"
}

# accepted_fix_arm_names_dispatch <file>
accepted_fix_arm_names_dispatch() {
  section_text "$1" "$H_LATE" | grep -E '^- `fix`' | grep -qF 'unit dispatch'
}

# tdd_arm_is_dispatch_and_record_only <file>
tdd_arm_is_dispatch_and_record_only() {
  local arm
  arm=$(section_text "$1" "$H_TDD")
  [ -n "$arm" ] || return 1
  grep -qiE 'settle|fix|commit|AskUserQuestion|file-tech-debt' <<<"$arm" && return 1
  grep -qF -- 'dispatches and records' <<<"$arm" || return 1
  grep -qF -- 'worthiness-step.sh record' <<<"$arm" || return 1
  grep -qF -- '--expect-count' <<<"$arm"
}

# no_node_invocation_of_writer <dir>...: no file outside the writer, the test
# suites and the tests directories runs the ledger writer with node.
no_node_invocation_of_writer() {
  local hits
  hits=$(grep -rnE 'node [^#]*append-worthiness\.mjs' "$@" \
    --exclude='append-worthiness.mjs' --exclude='*.bats' --exclude='*.test.ts' --exclude-dir=tests --exclude-dir=__tests__ --exclude-dir=node_modules 2>/dev/null || true)
  [ -z "$hits" ]
}

# clean_row_order_holds <file>: check-all, the late pass, the status, the merge.
clean_row_order_holds() {
  local row a b c d
  row=$(grep -E '^\| `clean` ' "$1" | head -n 1)
  [ -n "$row" ] || return 1
  a=$(awk -v r="$row" 'BEGIN { print index(r, "check-all") }')
  b=$(awk -v r="$row" 'BEGIN { print index(r, "late worthiness pass") }')
  c=$(awk -v r="$row" 'BEGIN { print index(r, "`GAIA-Audit` status") }')
  d=$(awk -v r="$row" 'BEGIN { print index(r, "and the merge") }')
  [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$c" -gt 0 ] && [ "$d" -gt 0 ] || return 1
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]
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

# ---------- callers name the reference before their audit ----------

@test "the derived caller set holds the work lifecycle and debt" {
  local callers
  callers=$(derived_callers)
  grep -qxF "$LIFECYCLE" <<<"$callers"
  grep -qxF "$DEBT" <<<"$callers"
}

@test "the work lifecycle runs the reference before its audit heading" {
  caller_names_reference_before "$LIFECYCLE" '## 6. Audit'
}

@test "debt runs the reference before getting a marker for HEAD" {
  caller_names_reference_before "$DEBT" 'Get a real marker for HEAD'
}

@test "red twin: the lifecycle line moved below the audit heading fails" {
  local copy="$BATS_TEST_TMPDIR/lifecycle.md"
  awk '
    /^## 5b\. Worthiness step$/ { skip = 3 }
    skip > 0 { held = held $0 "\n"; skip--; next }
    { print }
    /^## 6\. Audit$/ { printf "%s", held }' "$LIFECYCLE" > "$copy"
  run caller_names_reference_before "$copy" '## 6. Audit'
  [ "$status" -ne 0 ]
}

@test "red twin: a bare mention does not pass" {
  local copy="$BATS_TEST_TMPDIR/debt.md"
  sed 's/Run the worthiness step first/Mention worthiness-step.md/; s/`\.claude\/skills\/gaia\/references\/worthiness-step\.md` and run it/the shared reference/' "$DEBT" > "$copy"
  run caller_names_reference_before "$copy" 'Get a real marker for HEAD'
  [ "$status" -ne 0 ]
}

@test "the merge workflow names the reference in its pre-dispatch section" {
  section_text "$MERGE_WORKFLOW" '#### Before the first dispatch' | grep -qF -- 'worthiness-step.md'
}

@test "red twin: a pre-dispatch section without the reference fails" {
  local copy="$BATS_TEST_TMPDIR/merge.md"
  sed 's/worthiness-step\.md/x.md/g' "$MERGE_WORKFLOW" > "$copy"
  run bash -c "$(declare -f section_text); section_text '$copy' '#### Before the first dispatch' | grep -qF -- 'worthiness-step.md'"
  [ "$status" -ne 0 ]
}

# ---------- command pins ----------

@test "the reference pins each command, the no-op HALT and the refused settle" {
  literals_present "$REF" "${REFERENCE_LITERALS[@]}"
}

@test "red twin: dropping any pinned literal fails the check" {
  local literal copy="$BATS_TEST_TMPDIR/ref.md"
  for literal in "${REFERENCE_LITERALS[@]}"; do
    grep -vF -- "$literal" "$REF" > "$copy"
    run literals_present "$copy" "${REFERENCE_LITERALS[@]}"
    [ "$status" -ne 0 ]
  done
}

# ---------- the filer stays in the File step ----------

@test "no repair, judge-again, delete, late-pass or tdd section names the filer" {
  filer_absent_from_repair_sections "$REF"
}

@test "the File step does run the filer" {
  section_text "$REF" "$H_FILE" | grep -qF -- 'file-tech-debt.sh file'
}

@test "red twin: a filer mention seeded in the Fix step fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  awk -v h="$H_FIX" '{ print } index($0, h) == 1 { print "Then run file-tech-debt.sh for the rest." }' "$REF" > "$copy"
  run filer_absent_from_repair_sections "$copy"
  [ "$status" -ne 0 ]
}

# ---------- order ----------

@test "the fix comes before judge-again before the late pass, and a fix commit before the verification" {
  order_holds "$REF"
}

@test "red twin: swapped fix and judge-again headings fail" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  sed -e 's/^### 3\. Fix$/### X/' -e 's/^### 4\. Judge again once$/### 3. Fix/' -e 's/^### X$/### 4. Judge again once/' "$REF" > "$copy"
  run order_holds "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: the verification named before the fix commit fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  awk '
    /^In this repo a fix commit lands first\.$/ { held = $0; next }
    held != "" { print; print held; held = ""; next }
    { print }' "$REF" > "$copy"
  run order_holds "$copy"
  [ "$status" -ne 0 ]
}

# ---------- filing arms ----------

@test "the File step names each filer word and reads a route after the last fix commit" {
  local word
  for word in "${FILE_WORDS[@]}"; do
    file_step_has "$REF" "$word"
  done
}

@test "red twin: removing any one filer word from the File step fails" {
  local word copy="$BATS_TEST_TMPDIR/ref.md"
  for word in "${FILE_WORDS[@]}"; do
    awk -v h="$H_FILE" -v w="$word" '
      index($0, h) == 1 { on = 1 }
      on && /^## / { on = 0 }
      on { gsub(w, "removed") }
      { print }' "$REF" > "$copy"
    run file_step_has "$copy" "$word"
    [ "$status" -ne 0 ]
  done
}

# ---------- late pass ----------

@test "the late pass has one arm per route value and the accepted fix names the unit dispatch" {
  local arm
  for arm in "${LATE_ARMS[@]}"; do
    late_arm_present "$REF" "$arm"
  done
  accepted_fix_arm_names_dispatch "$REF"
}

@test "red twin: a missing late-pass arm, or an accepted fix without the dispatch, fails" {
  local arm copy="$BATS_TEST_TMPDIR/ref.md"
  for arm in "${LATE_ARMS[@]}"; do
    grep -v -E "^- \`$arm\`" "$REF" > "$copy"
    run late_arm_present "$copy" "$arm"
    [ "$status" -ne 0 ]
  done
  sed 's/unit dispatch/x/g' "$REF" > "$copy"
  run accepted_fix_arm_names_dispatch "$copy"
  [ "$status" -ne 0 ]
}

# ---------- tdd arm ----------

@test "the tdd arm dispatches and records only" {
  tdd_arm_is_dispatch_and_record_only "$REF"
}

@test "the tdd skill points at the arm by name" {
  grep -qF -- 'worthiness-step.md' "$TDD_SKILL"
  grep -qF -- '`## The tdd arm`' "$TDD_SKILL"
  grep -qF -- "$H_TDD" "$REF"
}

@test "red twin: a question seeded in the tdd arm fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  awk -v h="$H_TDD" '{ print } index($0, h) == 1 { print "Ask the human with AskUserQuestion." }' "$REF" > "$copy"
  run tdd_arm_is_dispatch_and_record_only "$copy"
  [ "$status" -ne 0 ]
}

# ---------- one invoker of the writer ----------

@test "nothing under .claude or .gaia/scripts runs the ledger writer with node" {
  no_node_invocation_of_writer "$REPO_ROOT/.claude" "$REPO_ROOT/.gaia/scripts"
}

@test "the reference names the recorder as the way to write the ledger" {
  grep -qF -- 'worthiness-step.sh record' "$REF"
}

@test "red twin: a node invocation seeded in a copy fails" {
  local dir="$BATS_TEST_TMPDIR/seeded"
  mkdir -p "$dir"
  printf 'node .gaia/scripts/audit-ledger/append-worthiness.mjs a b keep\n' > "$dir/skill.md"
  run no_node_invocation_of_writer "$dir"
  [ "$status" -ne 0 ]
}

# ---------- the merge workflow's clean row ----------

@test "the clean row runs check-all, the late pass, the status, then the merge" {
  clean_row_order_holds "$MERGE_WORKFLOW"
}

@test "red twin: the late pass moved after the status fails" {
  local copy="$BATS_TEST_TMPDIR/merge.md" row moved
  row=$(grep -E '^\| `clean` ' "$MERGE_WORKFLOW" | head -n 1)
  moved="${row/late worthiness pass/ZZZ}"
  moved="${moved% |} late worthiness pass |"
  # shellcheck disable=SC2001
  printf '%s\n' "$moved" > "$copy"
  run clean_row_order_holds "$copy"
  [ "$status" -ne 0 ]
}

# ---------- markers ----------

@test "the verification command appears only inside a marked block" {
  verification_only_in_marked_block "$REF"
}

@test "red twin: the verification named outside a marked block fails" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  { cat "$REF"; printf 'Then run verify-harness.sh.\n'; } > "$copy"
  run verification_only_in_marked_block "$copy"
  [ "$status" -ne 0 ]
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

@test "red twin: an unclosed marker fails the balance check" {
  local copy="$BATS_TEST_TMPDIR/ref.md"
  { cat "$REF"; printf '<!-- gaia:maintainer-only:start -->\n'; } > "$copy"
  run markers_balanced "$copy"
  [ "$status" -ne 0 ]
}
