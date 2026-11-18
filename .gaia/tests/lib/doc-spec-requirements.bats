#!/usr/bin/env bats
#
# Doc-conformance suite: the /gaia-spec playbook runs the clarify loop in every
# mode, writes the requirements file word for word before the draft, drafts the
# one full SPEC with a case-by-value behaviors section, and leaves the audit to
# one route whose fixer writes the audit file. Each check is a function of the
# file it reads, and each test runs it on a temp copy with the wording changed
# to show it can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  SPEC_DIR="$REPO_ROOT/.claude/skills/gaia/references/spec"
  CLARIFY_MD="$SPEC_DIR/clarify-loop.md"
  RESUME_MD="$SPEC_DIR/resume.md"
  TEMPLATE_MD="$SPEC_DIR/spec-template.md"
}

# Whitespace-collapsed text of a file, so a phrase wrapped over lines still matches.
flat() {
  tr '\n' ' ' <"$1" | tr -s ' '
}

# 0 when every needle is present in the flattened file.
has_all() {
  local file="$1" needle flat_text
  shift
  flat_text="$(flat "$file")"
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$flat_text" || { printf 'missing in %s: %s\n' "$file" "$needle" >&2; return 1; }
  done
  true
}

# Number of the first line of <file> holding <literal>, empty when absent.
line_of() {
  grep -nF -- "$2" "$1" | head -1 | cut -d: -f1
}

check_requirements_file() {
  has_all "$SPEC_MD" 'word for word' 'an auto-mode self-answered one included' 'instead of copying them' || return 1
  has_all "$CLARIFY_MD" '## The requirements file' 'Answered by:' 'REQUIREMENTS.md § <heading text>' 'every clarify question and its answer' 'An auto-mode run writes it too'
}

@test "requirements file holds the brief and every answer in every mode" {
  check_requirements_file
  sed 's/An auto-mode run writes it too/An interactive run writes it/' "$CLARIFY_MD" >"$BATS_TEST_TMPDIR/clarify.md"
  CLARIFY_MD="$BATS_TEST_TMPDIR/clarify.md" check_requirements_file 2>/dev/null && return 1
  true
}

check_clarify_every_mode() {
  has_all "$SPEC_MD" 'The clarify loop still runs in auto mode' 'The loop runs in every mode, auto included' \
    'pick the Recommended option' 'Open-ended Socratic questions are answered by the agent' \
    'Answered by: the Recommended option (auto mode)' 'Answered by: the agent (auto mode)'
}

@test "clarify runs in every mode with the auto rules kept" {
  check_clarify_every_mode
  sed 's/Open-ended Socratic questions are answered by the agent/Open-ended questions are skipped/' "$SPEC_MD" >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_clarify_every_mode 2>/dev/null && return 1
  true
}

check_requirements_before_draft() {
  local requirements draft
  requirements="$(line_of "$SPEC_MD" '### 6. Requirements file')"
  draft="$(line_of "$SPEC_MD" '### 7. Draft')"
  [ -n "$requirements" ] && [ -n "$draft" ] && [ "$requirements" -lt "$draft" ]
}

@test "requirements file is written before the draft" {
  check_requirements_before_draft
  sed 's/^### 6\. Requirements file/### 8. Requirements file/' "$SPEC_MD" >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_requirements_before_draft && return 1
  true
}

check_not_settled_to_deferred() {
  has_all "$SPEC_MD" 'Every Not settled item is written to `clarifications.deferred[]` in every mode, auto mode included' \
    'every Not settled item written to `clarifications.deferred[]`'
}

@test "every Not settled item goes to deferred in every mode" {
  check_not_settled_to_deferred
  sed 's/in every mode, auto mode included/in interactive mode/' "$SPEC_MD" >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_not_settled_to_deferred 2>/dev/null && return 1
  true
}

check_no_kept_finding_source() {
  has_all "$SPEC_MD" 'ambiguity assumptions, refused drops, unhandled finding ids' || return 1
  grep -qiF 'against its recommendation' "$SPEC_MD" && return 1
  true
}

@test "gate 2 lists no finding kept against its recommendation" {
  check_no_kept_finding_source
  { cat "$SPEC_MD"; printf '%s\n' 'each audit finding the user kept against its recommendation'; } >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_no_kept_finding_source 2>/dev/null && return 1
  true
}

check_one_route() {
  grep -qE '\bStandard\b|\bDeep\b|gauge|self-review|[Rr]ed-team' "$SPEC_MD" && return 1
  true
}

@test "one route with no audit tier" {
  check_one_route
  { cat "$SPEC_MD"; printf '%s\n' 'the Deep audit tier'; } >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_one_route && return 1
  true
}

check_fixer_writes_audit() {
  has_all "$SPEC_MD" 'writes `AUDIT.md` at the `${SPEC_DIR}` path it was handed' 'no other subagent writes `AUDIT.md`' \
    "the critical refuter's verdicts" || return 1
  grep -qi 'applier' "$SPEC_MD" && return 1
  true
}

@test "spec playbook names the fixer as the author of AUDIT.md" {
  check_fixer_writes_audit
  { cat "$SPEC_MD"; printf '%s\n' 'the applier writes AUDIT.md'; } >"$BATS_TEST_TMPDIR/spec.md"
  SPEC_MD="$BATS_TEST_TMPDIR/spec.md" check_fixer_writes_audit 2>/dev/null && return 1
  true
}

check_by_value_no_tests() {
  local file
  for file in "$SPEC_MD" "$TEMPLATE_MD"; do
    has_all "$file" 'the actor, the state, the input and the outcome by value' 'plans no tests' || return 1
  done
}

@test "the draft and the template state each case by value and plan no tests" {
  check_by_value_no_tests
  sed 's/plans no tests/plans the tests/' "$TEMPLATE_MD" >"$BATS_TEST_TMPDIR/template.md"
  TEMPLATE_MD="$BATS_TEST_TMPDIR/template.md" check_by_value_no_tests 2>/dev/null && return 1
  true
}

check_resume_at_draft() {
  has_all "$RESUME_MD" '`$SPEC_FOLDER/REQUIREMENTS.md` exists' 'clarify is complete: resume at step 7 (the draft)'
}

@test "resume treats an existing requirements file as clarify complete" {
  check_resume_at_draft
  sed 's/clarify is complete: resume at step 7 (the draft)/resume at step 4/' "$RESUME_MD" >"$BATS_TEST_TMPDIR/resume.md"
  RESUME_MD="$BATS_TEST_TMPDIR/resume.md" check_resume_at_draft 2>/dev/null && return 1
  true
}
