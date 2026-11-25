#!/usr/bin/env bats
#
# The PR review record has one writer, is keyed to one pull request and its
# reviewed head, and its findings are fixed once written. A write outside the
# record script, a record for another pull request, an unearned not-run, a
# merge from another branch's checkout, a commit after the review and a body
# section read as the record are each driven into the guard's failing state.
#
# Every merge case drives the real hook (.claude/hooks/pr-merge-audit-check.sh)
# with the logging gh stub (helpers/merge-gate-fixture.sh). Records are written
# in the C1 layout, the digest computed from its stated definition.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-review-record-integrity.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  mgf_init
  write_builtin_descriptor "$REPO"
  row_fixture_used=0
  RECORD_SCRIPT="$MGF_REPO_ROOT/.gaia/scripts/pr-review-record.sh"
  GATE_SCRIPT="$MGF_REPO_ROOT/.gaia/scripts/pr-review-gate.sh"
  VERDICT_LIBRARY="$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh"
}

row_fixture() {
  unset GH_STUB_FAIL_BRANCHES GH_STUB_BASE_TIP
  if [ "$row_fixture_used" -eq 1 ]; then
    mkdir -p "$BATS_TEST_TMPDIR/row-$1"
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/row-$1" mgf_init || return 1
    write_builtin_descriptor "$REPO"
  fi
  row_fixture_used=1
}

# finding_json <id> <disposition>: one complete reviewer finding; `none` reads
# as an undecided finding.
finding_json() {
  jq -n -c --arg id "$1" --arg disposition "$2" '{
    id: $id, file: "wiki/page.md", line: 3, severity: "Major", security: false,
    summary: ("problem " + $id), failure_scenario: "it breaks", verified: true,
    disposition: (if $disposition == "none" then null else $disposition end),
    reason: (if $disposition == "dismiss" then "not a defect" else null end),
    issue: null, basis: null, fix_route: null, fix_state: null,
    dropped_by: null, fix_commits: []}'
}

# findings_digest <record-json>: the C3 digest, from its stated definition.
findings_digest() {
  jq -cS '[.findings[] | {file, line, severity, security, summary, failure_scenario, verified}]' <<<"$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1
}

# record_json <pr> <head> <outcome-or-null> <findings-json-array> [<review-fix-commits-json>]
record_json() {
  local record
  record="$(jq -n -c --argjson pr "$1" --arg head "$2" --arg outcome "$3" --argjson findings "$4" --argjson fixes "${5:-[]}" '{
    version: 1, pr: $pr, reviewed_head: $head, spec: "present",
    spec_author_not_collaborator: false, changelog_present: true, attempts: [],
    outcome: (if $outcome == "null" then null else $outcome end),
    not_run_reason: null, findings: $findings, findings_sha256: "",
    review_fix_commits: $fixes}')"
  jq -c --arg digest "$(findings_digest "$record")" '.findings_sha256 = $digest' <<<"$record"
}

# record_file [<branch-key>]: where the record lives (C1), under the sandbox root.
record_file() {
  printf '%s/.gaia/local/runs/%s/pr-review.json\n' "$REPO" "${1:-feature}"
}

write_record() {
  mkdir -p "$(dirname "$2")"
  printf '%s\n' "$1" > "$2"
}

# set_body <findings-json-array> [<reviewed-head>]: the pull request body
# carries the head stamp plus the section rendered from <findings> for the
# reviewed head.
set_body() {
  local head section body
  head="$(git -C "$REPO" rev-parse HEAD)"
  section="$(bash -c '. "$1"; pr_review_render_section "$2"' _ "$VERDICT_LIBRARY" "$(record_json 12 "${2:-$head}" ran "$1")")"
  body="Summary.

<!-- gaia-pr-body-head: ${head} -->

${section}"
  jq -c --arg body "$body" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

strip_review_section() {
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  jq -c --arg body "Summary.

<!-- gaia-pr-body-head: ${head} -->" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

set_head_ref() {
  jq -c --arg ref "$1" '.headRefName = $ref' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

out_of_scope_pull_request() {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
}

# fresh_merge: run the merge with an empty gh log, so a status posted by an
# earlier allowed merge in the same sandbox never reads as this one's.
fresh_merge() {
  : > "$MGF_GH_LOG"
  mgf_run_merge "gh pr merge 12 --squash"
}

assert_review_denied() {
  assert_denied_by_json || return 1
  grep -qF -- "$1" <<<"$output" || { printf 'expected the reason [%s], got: %s\n' "$1" "$output" >&2; return 1; }
  [ "$(mgf_post_count)" -eq 0 ] || { printf 'a status was posted on a denied merge:\n%s\n' "$(mgf_post_lines)" >&2; return 1; }
}

assert_allowed() {
  [ "$status" -eq 0 ] && [ -z "$output" ] || { printf 'expected allow, got status %s: %s\n' "$status" "$output" >&2; return 1; }
}

# bats test_tags=protected
@test "the record has one writer, one PR and findings fixed once written, and the merge hook denies a record that breaks any of these" {
  local missing="BLOCKED: PR review: no review record for PR #12. Run the PR review (wiki/concepts/PR Merge Workflow.md, #### PR review), dispose every finding, and re-post GAIA-Audit if a fix moved HEAD."
  local head record file folder second_head label

  # Row: a finding removed by a write outside the record script. The record
  # script refuses its next read, the gate script and the merge hook treat the
  # pull request as undecided.
  row_fixture tampered-findings || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  record="$(record_json 12 "$head" ran "[$(finding_json pr-1 dismiss),$(finding_json pr-2 dismiss)]")"
  file="$(record_file)"
  write_record "$record" "$file"
  set_body "[$(finding_json pr-1 dismiss),$(finding_json pr-2 dismiss)]"
  fresh_merge
  assert_allowed || { echo "row tampered: the untouched record was not allowed"; return 1; }
  jq -c 'del(.findings[1])' <<<"$record" > "$file.next"
  mv "$file.next" "$file"
  run bash "$RECORD_SCRIPT" read --run-folder "$(dirname "$file")"
  [ "$status" -eq 5 ] || { echo "row tampered: record read exited $status, wanted 5: $output"; return 1; }
  grep -qF "record findings changed after outcome" <<<"$output" || { echo "row tampered: record read gave: $output"; return 1; }
  run bash "$GATE_SCRIPT" check --root "$REPO" --pr 12 --out-of-scope
  [ "$status" -eq 1 ] || { echo "row tampered: gate check exited $status: $output"; return 1; }
  grep -qF "record findings changed after outcome" <<<"$output" || { echo "row tampered: gate check gave: $output"; return 1; }
  fresh_merge
  assert_review_denied "BLOCKED: PR review: record findings changed after outcome on PR #12." || { echo "row tampered: merge not denied"; return 1; }

  # Row: the run folder of the head branch holds a record keyed to PR 49; the
  # pull request is 12, so it has no record and the body section is absent.
  row_fixture other-pr-record || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  write_record "$(record_json 49 "$head" ran '[]')" "$(record_file)"
  strip_review_section
  fresh_merge
  assert_review_denied "$missing" || { echo "row other pr: wrong decision"; return 1; }

  # Row: not-run is refused with no dispatch attempt recorded, and with a
  # reason outside the two stated ones; the record is left open both times.
  row_fixture not-run-unearned || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  file="$(record_file)"
  folder="$(dirname "$file")"
  write_record "$(record_json 12 "$head" null '[]')" "$file"
  run bash "$RECORD_SCRIPT" not-run --run-folder "$folder" --reason "reviewer silent twice"
  [ "$status" -eq 1 ] || { echo "row not-run no attempt: exited $status: $output"; return 1; }
  grep -qF "not run needs two closed no-op attempts" <<<"$output" || { echo "row not-run no attempt: gave: $output"; return 1; }
  jq -c '.attempts = [{n: 1, state: "closed", classifier_exit: 1, dispatch_failed: false, refusal: null}, {n: 2, state: "closed", classifier_exit: 1, dispatch_failed: false, refusal: null}]' "$file" > "$file.next"
  mv "$file.next" "$file"
  run bash "$RECORD_SCRIPT" not-run --run-folder "$folder" --reason "I did not feel like it"
  [ "$status" -eq 1 ] || { echo "row not-run unknown reason: exited $status: $output"; return 1; }
  grep -qF "unknown not-run reason" <<<"$output" || { echo "row not-run unknown reason: gave: $output"; return 1; }
  [ "$(jq -r '.outcome' "$file")" = null ] || { echo "row not-run: a refused call still wrote the outcome"; return 1; }

  # Row: the merge runs from a checkout on another branch; the record is found
  # through the pull request's headRefName normalized the way the run folder
  # is (feat/x -> feat+x). Without the record there it is denied.
  row_fixture other-branch-checkout || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_head_ref feat/x
  write_record "$(record_json 12 "$head" ran "[$(finding_json pr-1 dismiss)]")" "$(record_file feat+x)"
  set_body "[$(finding_json pr-1 dismiss)]"
  git -C "$REPO" checkout -q -b unrelated-branch
  fresh_merge
  assert_allowed || { echo "row other branch: record under feat+x not found"; return 1; }
  rm -f "$(record_file feat+x)"
  strip_review_section
  fresh_merge
  assert_review_denied "$missing" || { echo "row other branch: missing record not denied"; return 1; }

  # Row: a commit after the reviewed head that the review did not make and
  # that is not a merge of the base is denied; listed as a review fix commit
  # it is allowed.
  row_fixture commit-after-review || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  write_record "$(record_json 12 "$head" ran '[]')" "$(record_file)"
  mgf_commit "wiki/page.md" "doc two"
  second_head="$(git -C "$REPO" rev-parse HEAD)"
  label="$(git -C "$REPO" rev-parse --short=7 HEAD)"
  mgf_record 12 false "docs: page" "wiki/page.md"
  set_body '[]' "$head"
  fresh_merge
  assert_review_denied "BLOCKED: PR review: commits after the review on PR #12: ${label}" || { echo "row commit after review: wrong decision"; return 1; }
  write_record "$(record_json 12 "$head" ran '[]' "[\"$second_head\"]")" "$(record_file)"
  fresh_merge
  assert_allowed || { echo "row commit after review: a listed review fix commit was denied"; return 1; }

  # Row: the local record is absent and the body section shows every finding
  # disposed at the reviewed head: the section is read as the record. With an
  # undecided finding in the section it is denied.
  row_fixture body-section-as-record || return 1
  out_of_scope_pull_request
  set_body "[$(finding_json pr-1 dismiss)]"
  fresh_merge
  assert_allowed || { echo "row body only: a complete section was not read as the record"; return 1; }
  set_body "[$(finding_json pr-1 none)]"
  fresh_merge
  assert_review_denied "BLOCKED: PR review: 1 finding has no disposition on PR #12." || { echo "row body only undecided: wrong decision"; return 1; }

  # Row: both exist and disagree; the local record wins. It holds an undecided
  # finding while the body section shows none, so a read of the body would
  # allow.
  row_fixture local-record-wins || return 1
  out_of_scope_pull_request
  head="$(git -C "$REPO" rev-parse HEAD)"
  write_record "$(record_json 12 "$head" ran "[$(finding_json pr-1 none)]")" "$(record_file)"
  set_body '[]'
  fresh_merge
  assert_review_denied "BLOCKED: PR review: 1 finding has no disposition on PR #12." || { echo "row local wins: wrong decision"; return 1; }
}
