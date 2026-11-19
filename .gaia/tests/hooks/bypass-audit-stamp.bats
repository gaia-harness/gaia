#!/usr/bin/env bats
#
# The merge gate's GAIA-Audit bypass stamp (.claude/hooks/pr-merge-audit-check.sh
# with .claude/hooks/lib/audit-bypass-stamp.sh), and the marker path it leaves
# to post-audit-status.sh.
#
# A pull request the gate clears through a bypass (out of scope, or a
# manifest-only chore(deps)) has no member marker, so the gate itself posts the
# GAIA-Audit status branch protection waits on, immediately before the allow.
# The refusal state is the other half and the one that must hold: no POST on a
# deny, and none for a pull request cleared by a marker rather than a bypass.
#
# Every case drives the real hook with a logging gh stub
# (helpers/merge-gate-fixture.sh) and asserts on the stub's log.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/bypass-audit-stamp.bats < /dev/null
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

# row_fixture <label>: give a case-table row its own sandbox. The first row
# takes the one setup() built; each later row builds a fresh one under its own
# directory, because a row commits to the repository and rewrites the stub.
row_fixture() {
  unset GH_STUB_FAIL_BRANCHES GH_STUB_BASE_TIP
  if [ "$row_fixture_used" -eq 1 ]; then
    mkdir -p "$BATS_TEST_TMPDIR/row-$1"
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/row-$1" mgf_init || return 1
    write_builtin_descriptor "$REPO"
  fi
  row_fixture_used=1
}

# assert_one_post <description>: exactly one status POST, to the pull request's
# head, carrying the bypass fields and <description>, followed by the ready flip
# as the last gh call the gate made (the allow follows with nothing on stdout).
assert_one_post() {
  local head posts
  head="$(git -C "$REPO" rev-parse HEAD)"
  posts="$(mgf_post_lines)"
  [ "$(mgf_post_count)" -eq 1 ] || { printf 'expected one POST, log:\n%s\n' "$(cat "$MGF_GH_LOG")" >&2; return 1; }
  grep -qF -- "repos/test-owner/test-repo/statuses/${head}" <<<"$posts" || return 1
  grep -qF -- '-f state=success' <<<"$posts" || return 1
  grep -qF -- '-f context=GAIA-Audit' <<<"$posts" || return 1
  grep -qxF -- "api -X POST repos/test-owner/test-repo/statuses/${head} -f state=success -f context=GAIA-Audit -f description=$1" <<<"$posts" || return 1
  # The status comes first, then the draft-state read, and the draft flip is the
  # last gh call: a reviewer is notified only after the status that justifies it.
  [ "$(tail -n 3 "$MGF_GH_LOG")" = "${posts}
pr view 12 --json isDraft --jq .isDraft
pr ready 12" ] || { printf 'the POST is not followed by the ready flip as the last gh call:\n%s\n' "$(cat "$MGF_GH_LOG")" >&2; return 1; }
}

assert_allowed_silently() {
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf 'expected an allow (empty stdout), got: %s\n' "$output" >&2; return 1; }
}

# The marker-present fixture: a frontend marker that still validates, because a
# wiki change rotates no digest.
wiki_pr_with_stale_marker() {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" checkout --quiet main
  git -C "$REPO" merge --quiet --ff-only feature
  git -C "$REPO" push --quiet origin main
  git -C "$REPO" checkout --quiet feature
  mgf_marker code-audit-frontend >/dev/null
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
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

# --- out of scope and chore(deps): stamped before the allow ----------------------

@test "UAT-011: an out-of-scope or chore(deps) pull request is allowed and stamped before the allow" {
  local label
  for label in wiki-only wiki-only-with-valid-frontend-marker manifest-only-chore-deps; do
    row_fixture "$label" || { echo "case $label: fixture failed"; return 1; }
    case "$label" in
      wiki-only)
        out_of_scope_pull_request
        ;;
      wiki-only-with-valid-frontend-marker)
        wiki_pr_with_stale_marker
        # The marker validates for the unchanged digest: a wiki change rotates none.
        [ -f "$REPO/.gaia/local/audit/$(mgf_member_digest code-audit-frontend).ok" ] \
          || { echo "case $label: the frontend marker does not validate"; return 1; }
        ;;
      manifest-only-chore-deps)
        chore_deps_pull_request
        # Non-vacuity: package.json dispatches a member, so this is the
        # member-aware gate's allow, cleared by the waiver rather than a marker.
        [ -n "$(cd "$REPO" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null)" ] \
          || { echo "case $label: package.json dispatches no member"; return 1; }
        ;;
    esac
    mgf_run_merge "gh pr merge 12 --squash"
    assert_allowed_silently || { echo "case $label: not allowed silently"; return 1; }
    case "$label" in
      manifest-only-chore-deps) assert_one_post 'skipped: chore(deps) manifest-only' ;;
      *) assert_one_post 'skipped: out of scope' ;;
    esac || { echo "case $label: not exactly one stamp before the allow"; return 1; }
  done
}

@test "UAT-011: a wiki-only pull request whose head already carries a cleared GAIA-Audit status is allowed with no POST" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  mgf_status_success

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
  # Non-vacuity: the gate did read the statuses the fixture planted.
  grep -qF -- '/statuses --jq' "$MGF_GH_LOG"
}

# --- a bypass pull request makes no base lookup -----------------------------------
#
# Neither bypass reads a branch-own digest, so the gate decides them before it
# asks GitHub for the base branch tip. Each state below would deny any pull
# request that did need the tip: the branches endpoint fails, or the tip it
# reports is a commit this checkout does not hold.

ABSENT_BASE_TIP=0123456789abcdef0123456789abcdef01234567

# assert_no_branches_call: the stub never saw the base branch lookup.
assert_no_branches_call() {
  if grep -qF -- '/branches/' "$MGF_GH_LOG"; then
    printf 'the gate looked up the base branch:\n%s\n' "$(cat "$MGF_GH_LOG")" >&2
    return 1
  fi
  return 0
}

@test "an out-of-scope or chore(deps) pull request is allowed with a lookup failing and the base never asked" {
  local row label kind lookup description
  for row in \
    "out-of-scope|branches-fail" \
    "out-of-scope|base-tip-absent" \
    "chore-deps|branches-fail" \
    "chore-deps|base-tip-absent"; do
    kind=${row%%|*}; lookup=${row#*|}; label="$kind/$lookup"
    row_fixture "${kind}-${lookup}" || { echo "case $label: fixture failed"; return 1; }
    case "$kind" in
      out-of-scope) out_of_scope_pull_request; description='skipped: out of scope' ;;
      chore-deps) chore_deps_pull_request; description='skipped: chore(deps) manifest-only' ;;
    esac
    case "$lookup" in
      branches-fail) export GH_STUB_FAIL_BRANCHES=1 ;;
      base-tip-absent) export GH_STUB_BASE_TIP="$ABSENT_BASE_TIP" ;;
    esac
    mgf_run_merge "gh pr merge 12 --squash"
    assert_allowed_silently || { echo "case $label: not allowed silently"; return 1; }
    assert_one_post "$description" || { echo "case $label: not exactly one stamp"; return 1; }
    assert_no_branches_call || { echo "case $label: the gate asked for the base"; return 1; }
  done
}

# --- the refusal state ----------------------------------------------------------

@test "UAT-011: an in-scope pull request with no marker is denied and nothing is posted" {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_denied_by_json
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-011: an in-scope pull request cleared by its member marker is allowed with no bypass POST" {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-011: an ownerless in-scope pull request cleared by the legacy marker is allowed with no bypass POST" {
  mgf_commit "Makefile" "all:"
  mgf_record 12 false "build: makefile" "Makefile"
  mgf_marker code-audit-frontend >/dev/null

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "no stamp when the pull request's recorded head is not local HEAD, and the reason names the manual command" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  mgf_commit "wiki/other.md" "unpushed"

  mgf_run_merge "gh pr merge 12 --squash"
  [ "$(mgf_post_count)" -eq 0 ]
  grep -qF -- 'GAIA-Audit bypass status not posted' <<<"$stderr" || return 1
  grep -qF -- 'gh api -X POST' <<<"$stderr" || return 1
}

# The head GitHub reports on a numbered read after the classification is a
# commit nobody classified: the stamp must still land on local HEAD.
moved_head_after_record() {
  jq -c '.headRefOid = "0123456789abcdef0123456789abcdef01234567"' "$MGF_STUB_DIRECTORY/record.json" \
    > "$MGF_STUB_DIRECTORY/numbered-record.json"
}

@test "the stamp posts on the classified local HEAD even when a numbered head read would answer a moved head" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  moved_head_after_record

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  assert_one_post 'skipped: out of scope'
  ! grep -qF -- '0123456789abcdef0123456789abcdef01234567' "$MGF_GH_LOG"
}

# --- the draft flip and a rejected POST -------------------------------------------

@test "a failed ready flip or rejected POST still allows the bypass and names the manual command" {
  local label
  for label in ready-flip-fails not-a-draft unreadable-draft-state rejected-post; do
    row_fixture "$label" || { echo "case $label: fixture failed"; return 1; }
    out_of_scope_pull_request
    case "$label" in
      ready-flip-fails) : > "$MGF_STUB_DIRECTORY/ready-fails" ;;
      not-a-draft) printf 'false\n' > "$MGF_STUB_DIRECTORY/is-draft" ;;
      unreadable-draft-state) printf 'null\n' > "$MGF_STUB_DIRECTORY/is-draft" ;;
      rejected-post)
        sed -i.bak 's/\*" -X POST "\*) exit 0 ;;/*" -X POST "*) exit 1 ;;/' "$MGF_STUB_DIRECTORY/bin/gh"
        grep -qF -- '" -X POST "*) exit 1' "$MGF_STUB_DIRECTORY/bin/gh" \
          || { echo "case $label: the stub still accepts the POST"; return 1; }
        ;;
    esac
    mgf_run_merge "gh pr merge 12 --squash"
    assert_allowed_silently || { echo "case $label: not allowed silently"; return 1; }
    case "$label" in
      ready-flip-fails)
        [ "$(mgf_post_count)" -eq 1 ] || { echo "case $label: the status did not post once"; return 1; }
        grep -qF -- 'gh pr ready 12' <<<"$stderr" || { echo "case $label: stderr names no manual flip"; return 1; }
        ;;
      not-a-draft)
        [ "$(mgf_post_count)" -eq 1 ] || { echo "case $label: the status did not post once"; return 1; }
        grep -qF -- 'pr view 12 --json isDraft' "$MGF_GH_LOG" || { echo "case $label: the draft state was not read"; return 1; }
        grep -qF -- 'pr ready' "$MGF_GH_LOG" && { echo "case $label: a non-draft was flipped"; return 1; }
        grep -qF -- 'draft flip' <<<"$stderr" && { echo "case $label: stderr reports a draft flip"; return 1; }
        ;;
      unreadable-draft-state)
        grep -qF -- 'pr ready 12' "$MGF_GH_LOG" || { echo "case $label: no flip attempted"; return 1; }
        ;;
      rejected-post)
        grep -qF -- 'pr ready' "$MGF_GH_LOG" && { echo "case $label: flipped after a rejected POST"; return 1; }
        [ "$(mgf_post_count)" -eq 1 ] || { echo "case $label: the POST was not attempted once"; return 1; }
        grep -qF -- "description='skipped: out of scope'" <<<"$stderr" || { echo "case $label: stderr names no manual command"; return 1; }
        ;;
    esac
  done
}

# --- the marker path: the gate allows and post-audit-status.sh posts -----------
#
# A stale audit workflow and a legacy audit configuration on the base, the two
# shapes an adopter's tree can carry after the CI lane is gone. Neither may pull
# a same-repo pull request off the local path.

uat_004_fixture() {
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/.github/workflows"
  printf 'name: Code Review Audit\non: pull_request\n' > "$REPO/.github/workflows/code-review-audit.yml"
  [ -z "$1" ] || printf 'default_mode: %s\n' "$1" >> "$REPO/.gaia/audit-ci.yml"
  git -C "$REPO" add .github/workflows/code-review-audit.yml .gaia/audit-ci.yml
  git -C "$REPO" commit --quiet -m "stale audit lane"
  git -C "$REPO" push --quiet origin main
  git -C "$REPO" checkout --quiet -B feature main
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
}

@test "UAT-004: a stale workflow fixture A or B: the marker allows the merge and the status posts" {
  local row label default_mode marker
  # A: stale workflow, no default_mode. B: stale workflow, default_mode: ci.
  for row in "A|" "B|ci"; do
    label=${row%%|*}; default_mode=${row#*|}
    row_fixture "fixture-$label" || { echo "case $label: fixture failed"; return 1; }
    uat_004_fixture "$default_mode"
    if [ -z "$default_mode" ]; then
      grep -q 'default_mode' "$REPO/.gaia/audit-ci.yml" && { echo "case $label: default_mode present"; return 1; }
    else
      grep -qx "default_mode: $default_mode" "$REPO/.gaia/audit-ci.yml" || { echo "case $label: default_mode missing"; return 1; }
    fi
    marker="$(mgf_marker code-audit-frontend)"

    mgf_run_merge "gh pr merge 12 --squash"
    assert_allowed_silently || { echo "case $label: not allowed silently"; return 1; }
    [ "$(mgf_post_count)" -eq 0 ] || { echo "case $label: the gate posted"; return 1; }

    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$REPO" "$MGF_REPO_ROOT/.claude/hooks/post-audit-status.sh" "$marker"
    [ "$status" -eq 0 ] || { echo "case $label: post-audit-status.sh status=$status"; return 1; }
    [ "$(mgf_post_count)" -eq 1 ] || { echo "case $label: post-audit-status.sh did not post once"; return 1; }
    mgf_post_lines | grep -qF -- 'state=success' || { echo "case $label: no success state"; return 1; }
    mgf_post_lines | grep -qF -- 'context=GAIA-Audit' || { echo "case $label: no GAIA-Audit context"; return 1; }
  done
}

@test "UAT-004: the merge gate carries no self-modification bypass" {
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-text.sh"
  merge_gate_text "$MGF_HOOK" | grep -nE 'check_self_mod_only_update_pr|self_mod_only' && return 1
  true
}
