#!/usr/bin/env bats
#
# The merge gate (.claude/hooks/pr-merge-audit-check.sh) denies `gh pr merge`
# while the pull request's PR review record is missing, undecided, unfixed, not
# run or stale, on every path that would otherwise allow, and posts no bypass
# stamp for a pull request it denied.
#
# Every case drives the real hook with the logging gh stub
# (helpers/merge-gate-fixture.sh); the record is written the way the record
# script lays it out, and the body section is rendered by the verdict library.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-review-merge-deny.bats < /dev/null
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
}

# row_fixture <label>: a case-table row gets its own sandbox; the first row
# takes the one setup() built.
row_fixture() {
  unset GH_STUB_FAIL_BRANCHES GH_STUB_BASE_TIP
  if [ "$row_fixture_used" -eq 1 ]; then
    mkdir -p "$BATS_TEST_TMPDIR/row-$1"
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/row-$1" mgf_init || return 1
    write_builtin_descriptor "$REPO"
  fi
  row_fixture_used=1
}

# finding_json <disposition> <fix_state>: one complete reviewer finding;
# `none` for either argument reads as null.
finding_json() {
  jq -n -c --arg disposition "$1" --arg fix_state "$2" '{
    id: "pr-1", file: "wiki/page.md", line: 3, severity: "Major", security: false,
    summary: "a problem", failure_scenario: "it breaks", verified: true,
    disposition: (if $disposition == "none" then null else $disposition end),
    reason: null, issue: null, basis: null, fix_route: null,
    fix_state: (if $fix_state == "none" then null else $fix_state end),
    dropped_by: null, fix_commits: []}'
}

# plant_review <outcome> <findings-json-array> [<body-section-from-another-record>]:
# write the record for pull request 12 at the sandbox HEAD, and give the pull
# request a body carrying the stamp for HEAD plus the section rendered from the
# record (or, when a third argument is given, from that other findings array).
plant_review() {
  local outcome="$1" findings="$2" section_findings="${3:-$2}" head record record_file section body
  head="$(git -C "$REPO" rev-parse HEAD)"
  record="$(jq -n -c --arg head "$head" --arg outcome "$outcome" --argjson findings "$findings" '{
    version: 1, pr: 12, reviewed_head: $head, spec: "present",
    spec_author_not_collaborator: false, changelog_present: true, attempts: [],
    outcome: $outcome,
    not_run_reason: (if $outcome == "not-run" then "reviewer silent twice" else null end),
    findings: $findings, findings_sha256: "", review_fix_commits: []}')"
  record="$(bash -c '. "$1"; jq -c --arg digest "$(pr_review_findings_digest "$2")" ".findings_sha256 = \$digest" <<<"$2"' _ "$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh" "$record")"
  record_file="$(bash -c '. "$1"; pr_review_record_path "$2" feature' _ "$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh" "$REPO")"
  mkdir -p "$(dirname "$record_file")"
  printf '%s\n' "$record" > "$record_file"
  section="$(bash -c '. "$1"; pr_review_render_section "$(jq -c --argjson findings "$3" ".findings = \$findings" <<<"$2")"' _ "$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh" "$record" "$section_findings")"
  body="Summary.

<!-- gaia-pr-body-head: ${head} -->

${section}"
  jq -c --arg body "$body" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

# strip_review_section: the pull request body with no PR review section.
strip_review_section() {
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  jq -c --arg body "Summary.

<!-- gaia-pr-body-head: ${head} -->" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

out_of_scope_pull_request() {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
}

chore_deps_pull_request() {
  cp "$MGF_REPO_ROOT/.gaia/scripts/chore-deps-skip.sh" "$REPO/.gaia/scripts/chore-deps-skip.sh"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$MGF_REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/gaia-packages.sh"
  mgf_commit "package.json" '{"name":"x","version":"1.0.1"}'
  mgf_record 12 false "chore(deps): bump x from 1.0.0 to 1.0.1" "package.json"
}

# assert_review_denied <text>: the merge is denied with <text> as the PR review
# reason, and no GAIA-Audit status was posted.
assert_review_denied() {
  assert_denied_by_json || return 1
  grep -qF -- "$1" <<<"$output" || { printf 'expected the reason [%s], got: %s\n' "$1" "$output" >&2; return 1; }
  [ "$(mgf_post_count)" -eq 0 ] || { printf 'a status was posted on a denied merge:\n%s\n' "$(mgf_post_lines)" >&2; return 1; }
}

@test "the merge is denied while the review record is missing, undecided, unfixed, not run or stale" {
  local missing_text="BLOCKED: PR review: no review record for PR #12. Run the PR review (wiki/concepts/PR Merge Workflow.md, #### PR review), dispose every finding, and re-post GAIA-Audit if a fix moved HEAD."
  local label

  # Row: an in-scope pull request with every member marker current and no
  # review record is denied; with a complete record and section it is allowed.
  row_fixture in-scope-missing || return 1
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null
  strip_review_section
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "$missing_text" || { echo "row in-scope missing: wrong decision"; return 1; }
  plant_review ran '[]'
  mgf_run_merge "gh pr merge 12 --squash"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "row in-scope complete: not allowed: $output"; return 1; }

  # Row: an out-of-scope pull request with one undecided finding is denied and
  # posts no stamp.
  row_fixture out-of-scope-undecided || return 1
  out_of_scope_pull_request
  plant_review ran "[$(finding_json none none)]"
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: 1 finding has no disposition on PR #12." || { echo "row undecided: wrong decision"; return 1; }

  # Row: an out-of-scope pull request whose head already carries a GAIA-Audit
  # success and has no record is still denied for the missing record.
  row_fixture out-of-scope-status-no-record || return 1
  out_of_scope_pull_request
  strip_review_section
  mgf_status_success
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "$missing_text" || { echo "row status without record: wrong decision"; return 1; }

  # Row: a fix finding not yet fixed is denied.
  row_fixture out-of-scope-unfixed || return 1
  out_of_scope_pull_request
  plant_review ran "[$(finding_json fix routed)]"
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: 1 fix finding not yet fixed on PR #12." || { echo "row unfixed: wrong decision"; return 1; }

  # Row: a record saying not run is denied for a human to decide.
  row_fixture out-of-scope-not-run || return 1
  out_of_scope_pull_request
  plant_review not-run '[]'
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: not run on PR #12 (reviewer silent twice); a human decides." || { echo "row not run: wrong decision"; return 1; }

  # Row: a body section that differs from the record's is stale.
  row_fixture out-of-scope-stale-section || return 1
  out_of_scope_pull_request
  plant_review ran "[$(finding_json dismiss none)]" '[]'
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: PR body section missing or stale on PR #12." || { echo "row stale section: wrong decision"; return 1; }

  # Row: a chore(deps) manifest-only pull request with no record is denied
  # and stamped with nothing.
  row_fixture chore-deps-missing || return 1
  chore_deps_pull_request
  strip_review_section
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "$missing_text" || { echo "row chore(deps) missing: wrong decision"; return 1; }

  # Row: a chore(deps) pull request with a complete record and a commit after
  # the reviewed head the review did not make is denied for that commit.
  row_fixture chore-deps-commit-after-review || return 1
  chore_deps_pull_request
  plant_review ran '[]'
  mgf_commit "package.json" '{"name":"x","version":"1.0.2"}'
  mgf_record 12 false "chore(deps): bump x from 1.0.0 to 1.0.2" "package.json"
  # Keep the review's own section (for the earlier head) in the new record.
  label="$(git -C "$REPO" rev-parse --short=7 HEAD)"
  jq -c --arg body "Summary.

<!-- gaia-pr-body-head: $(git -C "$REPO" rev-parse HEAD) -->

$(bash -c '. "$1"; pr_review_render_section "$(cat "$2")"' _ "$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh" "$(bash -c '. "$1"; pr_review_record_path "$2" feature' _ "$MGF_LIBRARY_DIRECTORY/pr-review-verdict.sh" "$REPO")")" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: commits after the review on PR #12: ${label}" || { echo "row commit after review: wrong decision"; return 1; }
}

# release_pull_request [<extra-path>]: a release commit on the feature branch
# over a base that already holds the bookkeeping files, with the real
# bookkeeping predicate installed beside them. An extra path adds one more
# commit that is not bookkeeping.
release_pull_request() {
  . "$MGF_REPO_ROOT/.gaia/tests/helpers/release-bookkeeping-fixture.sh"
  git -C "$REPO" checkout -q main
  release_bookkeeping_seed_base "$REPO"
  git -C "$REPO" push -q origin main
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q feature
  git -C "$REPO" merge -q --ff-only main
  release_bookkeeping_install_predicate "$REPO"
  cp "$MGF_LIBRARY_DIRECTORY/audit-scope-release.sh" "$REPO/.claude/hooks/lib/audit-scope-release.sh"
  release_bookkeeping_apply "$REPO"
  [ -z "${1:-}" ] || mgf_commit "$1" "doc"
  mgf_record 12 false "chore(release): v9.9.9" .gaia/VERSION .gaia/manifest.json package.json apps/web/package.json CHANGELOG.md ${1:+"$1"}
}

# bats test_tags=protected
@test "a release pull request needs no review record, but the title alone waives nothing" {
  # Row: the title on a pure bookkeeping change, with no review record, is allowed.
  row_fixture release-bookkeeping || return 1
  release_pull_request
  strip_review_section
  mgf_run_merge "gh pr merge 12 --squash"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "row release bookkeeping: not allowed: $output"; return 1; }

  # Row: the same title on a change that is more than bookkeeping, with no
  # review record, is denied for the missing record.
  row_fixture release-title-only || return 1
  release_pull_request wiki/page.md
  mgf_marker code-audit-frontend >/dev/null
  mgf_marker code-audit-maintainer-shell >/dev/null
  strip_review_section
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: no review record for PR #12." || { echo "row release title only: wrong decision"; return 1; }

  # Row: a pure bookkeeping change under another title is denied the same way.
  row_fixture bookkeeping-other-title || return 1
  release_pull_request
  mgf_record 12 false "chore: bump versions" .gaia/VERSION .gaia/manifest.json package.json apps/web/package.json CHANGELOG.md
  mgf_marker code-audit-frontend >/dev/null
  mgf_marker code-audit-maintainer-shell >/dev/null
  strip_review_section
  mgf_run_merge "gh pr merge 12 --squash"
  assert_review_denied "BLOCKED: PR review: no review record for PR #12." || { echo "row other title: wrong decision"; return 1; }
}
