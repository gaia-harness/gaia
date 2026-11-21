#!/usr/bin/env bats
#
# The merge gate (.claude/hooks/pr-merge-audit-check.sh) on the GitHub-reported
# base and the branch-own digest.
#
# The gate keys every Code Audit Team marker to the branch's own patch against
# the PR's base branch, and trusts that base only as GitHub reports it: the base
# branch name from the PR record, its tip from `gh api .../branches/<base>`.
# It requires the tip locally and a unique merge base, and denies through its
# JSON decision, naming the one next step, otherwise. A clean catch-up merge of
# the base leaves every digest, and so every marker, valid.
#
# Every case drives the real hook against the merge-gate fixture (a sandbox with
# a bare origin standing in for GitHub, and a logging gh stub that answers the
# branches endpoint from that origin). The fixture's switches fail or hang only
# the branches endpoint, so the fork query and the PR record still answer and
# the denial under test comes from the base lookup itself.
#
# Run: .gaia/scripts/bats5.sh .github/audit/tests/pr-merge-audit-catchup.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT_DIRECTORY/.gaia/tests/hooks/helpers/run-hook.sh"
  . "$REPO_ROOT_DIRECTORY/.gaia/tests/helpers/audit-roster.sh"
  . "$REPO_ROOT_DIRECTORY/.gaia/tests/hooks/helpers/merge-gate-fixture.sh"
  mgf_init
  unset GH_STUB_FAIL_BRANCHES GH_STUB_HANG_BRANCHES GH_STUB_BASE_TIP GAIA_AUDIT_GH_DEADLINE_SECONDS
}

# --- fixtures -------------------------------------------------------------------

# cleared_pull_request: a pull request changing one frontend file, its record
# and the frontend marker for the digest the gate will compute.
cleared_pull_request() {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null
}

# digest_at <member> <merge-base> [<library-directory>]: the member's branch-own
# digest for REPO's HEAD against <merge-base>, through the real digest engine.
digest_at() {
  local library_directory="${3:-$MGF_LIBRARY_DIRECTORY}"
  bash -c '. "$1/audit-digest.sh"; audit_branch_member_digest "$2" "$4" "$3"' \
    _ "$library_directory" "$REPO" "$2" "$1"
}

# digest_against_origin_tip <member>: the digest against the merge base of HEAD
# and the bare origin's current main tip, one merge base picked when there are
# several.
digest_against_origin_tip() {
  local base="${2:-main}" tip merge_base
  tip="$(git -C "$CATCHUP_ORIGIN" rev-parse "refs/heads/$base")"
  merge_base="$(git -C "$REPO" merge-base HEAD "$tip")"
  digest_at "$1" "$merge_base"
}

# advance_origin_without_fetch [<base>]: land a commit on the bare origin's base
# from a separate clone, so the tip GitHub reports is a commit this checkout
# does not hold.
advance_origin_without_fetch() {
  local base="${1:-main}" clone="$BATS_TEST_TMPDIR/other-clone"
  rm -rf "$clone"
  git clone -q "$CATCHUP_ORIGIN" "$clone" 2>/dev/null
  git -C "$clone" config user.email "other@example.com"
  git -C "$clone" config user.name "Other"
  git -C "$clone" config commit.gpgsign false
  printf 'landed elsewhere\n' > "$clone/landed-elsewhere.txt"
  git -C "$clone" add landed-elsewhere.txt
  git -C "$clone" commit -q -m "base: landed elsewhere"
  git -C "$clone" push -q origin "HEAD:refs/heads/$base"
}

# reason_of: the deny reason in $output, empty when the output carries none.
reason_of() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$output"
}

# assert_denied_naming <fragment>: a deny decision whose reason contains
# <fragment>.
assert_denied_naming() {
  assert_denied_by_json || return 1
  if ! reason_of | grep -qF -- "$1"; then
    printf 'the deny reason does not name %s:\n%s\n' "$1" "$(reason_of)" >&2
    return 1
  fi
  return 0
}

assert_allowed() {
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf 'expected an allow (empty stdout), got: %s\n' "$output" >&2; return 1; }
}

# snapshot_fixture / restore_fixture: save the built fixture once and put it
# back before each case of a table, so cases share one build without sharing
# state. The archive sits outside the test directory it restores.
snapshot_fixture() {
  FIXTURE_ARCHIVE="$BATS_FILE_TMPDIR/fixture-$BATS_TEST_NUMBER.tar"
  tar -C "$BATS_TEST_TMPDIR" -cf "$FIXTURE_ARCHIVE" .
}

restore_fixture() {
  find "$BATS_TEST_TMPDIR" -mindepth 1 -delete
  tar -C "$BATS_TEST_TMPDIR" -xf "$FIXTURE_ARCHIVE"
  unset GH_STUB_FAIL_BRANCHES GH_STUB_HANG_BRANCHES GAIA_AUDIT_GH_DEADLINE_SECONDS
}

# criss_cross_pull_request: a pull request whose HEAD has two merge bases with
# the base tip; the marker is earned for the digest the gate would compute
# against one of them.
criss_cross_pull_request() {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  catchup_criss_cross
  [ "$(git -C "$REPO" merge-base --all HEAD "refs/remotes/origin/main" | grep -c .)" -eq 2 ] || return 1
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend "$(digest_against_origin_tip code-audit-frontend)" >/dev/null
}

# bats test_tags=protected
@test "base lookup denials: absent tip, failing lookup, hanging lookup, empty base name, two merge bases each deny naming one next step and clear after the remedy" {
  snapshot_fixture

  echo "case: a base tip that GitHub reports and this checkout lacks denies naming git fetch origin, and the fetch clears it"
  cleared_pull_request
  mgf_run_merge
  assert_allowed || return 1
  advance_origin_without_fetch
  mgf_run_merge
  assert_denied_naming 'git fetch origin' || return 1
  git -C "$REPO" fetch -q origin
  mgf_run_merge
  assert_allowed || return 1

  echo "case: a failing branches lookup denies naming the gh failure and gh auth status, and restoring gh clears it"
  restore_fixture
  cleared_pull_request
  export GH_STUB_FAIL_BRANCHES=1
  mgf_run_merge
  assert_denied_naming 'gh auth status' || return 1
  assert_denied_naming 'branch' || return 1
  unset GH_STUB_FAIL_BRANCHES
  mgf_run_merge
  assert_allowed || return 1

  echo "case: a hanging branches lookup is cut at the deadline and denies naming gh auth status, and restoring gh clears it"
  restore_fixture
  cleared_pull_request
  export GH_STUB_HANG_BRANCHES=1 GAIA_AUDIT_GH_DEADLINE_SECONDS=1
  mgf_run_merge
  assert_denied_naming 'gh auth status' || return 1
  # The fork query ran, so the denial came from the base lookup.
  grep -qF -- '--json isCrossRepository' "$MGF_GH_LOG" || return 1
  unset GH_STUB_HANG_BRANCHES GAIA_AUDIT_GH_DEADLINE_SECONDS
  mgf_run_merge
  assert_allowed || return 1

  echo "case: an empty base branch name in the record denies naming gh auth status"
  restore_fixture
  cleared_pull_request
  jq -c '.baseRefName = ""' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
  mgf_run_merge
  assert_denied_naming 'gh auth status' || return 1

  echo "case: a HEAD with two merge bases denies naming the merge that makes it unique, and that merge clears it"
  restore_fixture
  criss_cross_pull_request || return 1
  mgf_run_merge
  assert_denied_naming 'git merge --no-edit refs/remotes/origin/main' || return 1
  git -C "$REPO" merge -q --no-edit refs/remotes/origin/main >/dev/null
  [ "$(git -C "$REPO" merge-base --all HEAD "refs/remotes/origin/main" | grep -c .)" -eq 1 ] || return 1
  mgf_marker code-audit-frontend "$(digest_against_origin_tip code-audit-frontend)" >/dev/null
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_run_merge
  assert_allowed
}

# --- a base that is not main ---------------------------------------------------------------

# rebase_origin_onto <base-branch>: rename the sandbox's base to <base-branch>
# with a fresh bare origin carrying it, and point the PR record at it.
rebase_origin_onto() {
  local base="$1"
  if [ "$base" != main ]; then
    git -C "$REPO" branch -m main "$base"
  fi
  git -C "$REPO" worktree remove --force "$CATCHUP_BASE_WORKTREE"
  catchup_add_origin "$REPO" "$base" || return 1
  cleared_pull_request
}

# A clean catch-up merge of the base leaves every digest as it was, and the gate
# trusts the base branch GitHub reports.
assert_catch_up_leaves_gate_allowing() {
  local base="$1" before after
  before="$(digest_against_origin_tip code-audit-frontend "$base")"
  mgf_run_merge
  assert_allowed || return 1

  catchup_base_commit "base-landed.txt" "landed on the base"
  catchup_merge_base
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  after="$(digest_against_origin_tip code-audit-frontend "$base")"
  [ "$before" = "$after" ] || return 1
  mgf_run_merge
  assert_allowed
}

@test "a PR based on a non-main base (master, release/2.x) is cleared after a clean merge of that base" {
  snapshot_fixture
  for base in master release/2.x; do
    echo "case: a PR based on $base is cleared after a clean merge of that base"
    restore_fixture
    rebase_origin_onto "$base" || return 1
    assert_catch_up_leaves_gate_allowing "$base" || return 1
  done
}

# --- a marker is bound to its branch -------------------------------------------------------------

# second_branch_from_base: a second branch cut from the same base commit as the
# feature branch, for a byte-identical patch (or none) of its own.
second_branch_from_base() {
  git -C "$REPO" checkout -q -b second main
}

# bats test_tags=protected
@test "a marker earned on one branch is not accepted on another branch (byte-identical patch, equally empty patch)" {
  local initial_tip landed_tip
  snapshot_fixture

  echo "case: a marker earned on one branch is not accepted on another branch with a byte-identical non-empty patch"
  cleared_pull_request
  mgf_run_merge
  assert_allowed || return 1
  second_branch_from_base
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  [ "$(git -C "$REPO" diff --stat main HEAD)" = "$(git -C "$REPO" diff --stat main feature)" ] || return 1
  mgf_run_merge
  assert_denied_naming 'code-audit-frontend' || return 1

  echo "case: a marker earned on one branch is not accepted on another branch with an equally empty patch"
  restore_fixture
  # The base already holds the change and the branch has merged it, so against
  # the tip GitHub reports the branch's own patch is empty. The local base ref
  # lags, which is what still dispatches the member.
  initial_tip="$(git -C "$REPO" rev-parse refs/remotes/origin/main)"
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  catchup_base_commit "apps/web/app/x.ts" "export const x = 1"
  landed_tip="$(git -C "$CATCHUP_ORIGIN" rev-parse refs/heads/main)"
  git -C "$REPO" merge -q --no-edit "$landed_tip" >/dev/null
  git -C "$REPO" update-ref refs/remotes/origin/main "$initial_tip"
  [ -z "$(git -C "$REPO" diff "$landed_tip" HEAD)" ] || return 1
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null
  mgf_run_merge
  assert_allowed || return 1
  second_branch_from_base
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" merge -q --no-edit "$landed_tip" >/dev/null
  git -C "$REPO" update-ref refs/remotes/origin/main "$initial_tip"
  [ -z "$(git -C "$REPO" diff "$landed_tip" HEAD)" ] || return 1
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_run_merge
  assert_denied_naming 'code-audit-frontend'
}

# --- the previous recipe clears nothing -----------------------------------------------------------------

# bats test_tags=protected
@test "a marker and a GAIA-Audit status keyed to the previous content digest do not clear the gate" {
  local previous_digest
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  # A digest of HEAD's whole content, the shape the marker key had before it was
  # bound to the branch's own patch; the gate never recomputes it, it only has to
  # fail to match the current one.
  previous_digest="$({ printf 'previous-recipe\0'; git -C "$REPO" ls-tree -z -r HEAD; } | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print $1 }')"
  [ -n "$previous_digest" ]
  [ "$previous_digest" != "$(mgf_member_digest code-audit-frontend)" ]

  mgf_marker code-audit-frontend "$previous_digest" >/dev/null
  mgf_run_merge
  assert_denied_naming 'code-audit-frontend'

  mgf_status_success "$previous_digest"
  mgf_run_merge
  assert_denied_naming 'code-audit-frontend'

  # Paired: the same marker and status shape keyed to the current digest clear it.
  mgf_marker code-audit-frontend >/dev/null
  mgf_run_merge
  assert_allowed
}

# --- no network on a payload that is not a merge ----------------------------------------------------------

@test "a Bash payload that is not gh pr merge makes no gh call and no base lookup" {
  local real_git real_gh wrapper_directory="$BATS_TEST_TMPDIR/wrappers" command_log="$BATS_TEST_TMPDIR/wrapper-calls.log"
  real_git="$(command -v git)"
  real_gh="$(command -v gh)"
  mkdir -p "$wrapper_directory"
  : > "$command_log"
  printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$command_log" "$real_gh" > "$wrapper_directory/gh"
  printf '#!/usr/bin/env bash\nprintf "git %%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$command_log" "$real_git" > "$wrapper_directory/git"
  chmod +x "$wrapper_directory/gh" "$wrapper_directory/git"
  export PATH="$wrapper_directory:$PATH"
  cleared_pull_request
  : > "$command_log"

  mgf_run_merge "ls -la"
  assert_allowed
  if grep -qE '^gh ' "$command_log"; then
    printf 'the gate called gh:\n%s\n' "$(cat "$command_log")" >&2
    return 1
  fi
  if grep -qF 'branches' "$command_log"; then return 1; fi

  # Paired: the same wrappers do log the merge payload's calls.
  : > "$command_log"
  mgf_run_merge
  assert_allowed
  grep -qE '^gh ' "$command_log"
}

# --- the patch library is a fail-closed load -------------------------------------------------------------------

# bats test_tags=protected
@test "a library directory without the branch-own patch library makes the gate deny naming it" {
  local scratch="$BATS_TEST_TMPDIR/missing-library"
  mkdir -p "$scratch/.claude/hooks"
  cp -R "$MGF_LIBRARY_DIRECTORY" "$scratch/.claude/hooks/lib"
  rm "$scratch/.claude/hooks/lib/audit-branch-patch.sh"
  ln -s "$MGF_REPO_ROOT/.gaia" "$scratch/.gaia"
  cp "$MGF_HOOK" "${MGF_HOOK%.sh}"-*.sh "$scratch/.claude/hooks/"
  cleared_pull_request

  mgf_run_merge "gh pr merge 12 --squash" "$scratch/.claude/hooks/pr-merge-audit-check.sh"
  assert_denied_naming 'audit-branch-patch.sh'

  # Paired: the real library directory loads and the same pull request clears.
  mgf_run_merge
  assert_allowed
}
