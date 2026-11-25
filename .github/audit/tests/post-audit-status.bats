#!/usr/bin/env bats

# Tests for .claude/hooks/post-audit-status.sh, the local audit producer's
# GAIA-Audit success status POST. It runs on the Claude-driven merge path after
# the audit marker is written; the marker file is its literal precondition.
#
# The fixture sits here in .github/audit/tests/ so it runs in the same
# audit-ci-tests.yml suite as the other GAIA-Audit readers/producers.
#
# Ownership. Two suites guard this one hook, run by two separate legs of
# .github/workflows/audit-ci-tests.yml's shard matrix (the `audit` shard and
# whichever `hooks-*` shard the sharder assigns its sibling, both armed by that
# job's shared `code` path filter). This suite owns the member-aware gate arms
# and the status-target arms, because only its fixture installs the real
# resolver (install_resolver)
# and only its gh mock rejects a status posted to a sha the bare remote does
# not carry. .gaia/tests/hooks/post-audit-status.bats owns the usage and
# marker-shape preconditions, the divergence guards enumerated as decline
# lines, and the head_sha fallback paths (no PR / no upstream, detached HEAD).
# Add a new arm to whichever suite already owns its family instead of
# duplicating it in both.
#
# `gh` is mocked on a prepended PATH. The mock answers `gh auth status` (ok or
# fail per the test), `gh repo view --json nameWithOwner` (a fixed slug),
# `gh pr view --json headRefOid,title,files` (the pushed head sha captured by
# push_branch, plus the PR title and, one per line, the PR's changed paths,
# when a test writes them), `gh pr view --json baseRefName` (`main`),
# `gh api repos/.../branches/main` (the bare remote's main tip, the trusted
# base the success arm measures against), and `gh api .../statuses ... --method POST`
# (records the invocation only when the target sha exists on a bare remote,
# proving it is genuinely fetchable, not just that the mock accepted it
# unconditionally).
#
# SANDBOX pushes to a bare remote (origin) so `gh pr view`'s resolution has a
# real pushed head to target, and so the mock can reject a status posted to a
# sha the remote doesn't carry -- the same 422 an unpushed target sha gets from
# the real GitHub API.
#
# Coverage:
#   1. Marker present  → posts state=success context=GAIA-Audit
#      "<version> <frontend-digest> <tree>" (three positional fields; field 2
#      is the digest, UAT-008 field-position proof)
#      Marker absent   → no POST (declines)
#   2. gh unauthenticated → marker untouched, no POST (fail-safe asymmetry)
#   3. Member-aware gate (blocker COV-001): a mixed app/ + .gaia/**/*.sh diff
#      declines ("members pending ...") while the maintainer-shell member's
#      marker is absent, declines the same way while that member holds a live
#      refusal BESIDE its earned marker (refusal-first precedence, so a
#      sibling's success can never retract the failure a refusal posted),
#      posts success once both markers are present and neither is refused
#      (each member keyed to its OWN content digest, not the tree), and
#      (resolver absent) falls back to the single-marker POST unchanged. There is no
#      carried provenance, so the description never carries a trailing
#      "carried" suffix.
#   4. Status target: the POST only ever lands on a sha the remote carries, so
#      an un-pushed content-preserving commit produces no POST at all and
#      pushing it first lands the status on the pushed head (#726);
#      declines "audited tree not on pushed head" when local HEAD's tree
#      genuinely isn't on the pushed head. The surfaced "status: posted" line's
#      short sha re-resolves to the sha the POST actually targeted (#794).
#   5. Frontend digest unavailable (masked sha256 tool) → declines fail-closed,
#      never posts a status with a missing or empty digest field.
#   7. Trusted base: the success arm declines, naming the one next step, when
#      the base tip is not present locally, when gh cannot answer for the base
#      (failing and hanging), and when the branch has more than one merge base,
#      each with a scratch-copy disable case under which a success posts. The
#      refusal arm posts failure for the same states. After each remedy, and
#      after a clean catch-up merge, one success posts whose frontend digest is
#      the branch-own one. One identities listing serves a whole success run.
#   6. chore(deps) waiver: a dep-bump PR title with a manifest-only file list
#      waives an unmarked code-audit-frontend and no other member; a
#      non-matching or unreadable title, an empty or non-manifest file list,
#      leaves it pending, and a frontend refusal still outranks the waiver.

setup() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../../../.claude/hooks/post-audit-status.sh"
  [ -x "$SCRIPT" ]
  DIGEST_LIBRARY="$THIS_DIRECTORY/../../../.claude/hooks/lib/audit-digest.sh"
  . "$THIS_DIRECTORY/../../../.gaia/tests/helpers/gh-base-stub.sh"
  . "$THIS_DIRECTORY/../../../.gaia/tests/helpers/catchup-fixture.sh"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  . "$THIS_DIRECTORY/../../../.gaia/tests/hooks/helpers/package-fixture.sh"
  write_builtin_descriptor "$SANDBOX"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  echo "# readme" > "$SANDBOX/README.md"
  seed_audit_roster "$SANDBOX"
  git -C "$SANDBOX" add .gaia/audit-ci.yml .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  # A bare remote makes the pushed head sha fetchable, so the gh mock's `api`
  # case can prove a POST targets a sha the remote actually carries instead of
  # accepting anything unconditionally (the gap that let #726 hide).
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  PUSHED_HEAD_FILE="$BATS_TEST_TMPDIR/pushed-head"
  git init --quiet --bare "$REMOTE"
  git -C "$SANDBOX" remote add origin "$REMOTE"
  push_branch

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
}

# Push SANDBOX's current branch to origin and record the pushed head sha (both
# in $PUSHED_HEAD and in $PUSHED_HEAD_FILE, which the gh mock's `pr` case reads
# at run time) -- the sha the POST must land on. Callable more than once per
# test: a later call re-points the mock at the new head, which is how a test
# pushes a content-preserving commit before asserting the POST.
push_branch() {
  local branch
  branch="$(git -C "$SANDBOX" rev-parse --abbrev-ref HEAD)"
  git -C "$SANDBOX" push --quiet --set-upstream origin "$branch"
  PUSHED_HEAD="$(git -C "$SANDBOX" rev-parse HEAD)"
  printf '%s' "$PUSHED_HEAD" > "$PUSHED_HEAD_FILE"
}

# Install a fake `gh` on a prepended PATH.
#   auth   → exit 0 (ok) or 1 (fail) per $1
#   repo   → print the fixed slug for `gh repo view --json nameWithOwner --jq`
#   pr     → print the pushed head sha (from PUSHED_HEAD_FILE, written by
#            push_branch) for `gh pr view --json headRefOid,title,files`, then
#            the title on a second line when PR_TITLE_FILE holds one (the
#            shape the script's `--jq` joins the fields into), then each
#            changed path on its own line when PR_FILES_FILE holds any; no
#            title file prints the sha alone, which reads as an unreadable
#            title
#   api    → `branches/<name>` prints the bare REMOTE's tip of that branch
#            and records nothing. A `statuses/<sha>` target is verified to
#            exist on the bare REMOTE before accepting: append the full argv
#            to POST_LOG and exit 0 only when the sha is a fetchable commit
#            there, else exit 1 and record nothing (the same 422 a real
#            unpushed target sha gets), so a regression to the local unpushed
#            sha fails the test.
#   pr view --json baseRefName → `main`.
#   pr view --json body → a body stamped for the pushed head.
install_gh_mock() {
  local auth_ok="$1"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
auth_ok="$auth_ok"
record="$POST_LOG"
remote="$REMOTE"
pushed_head_file="$PUSHED_HEAD_FILE"
pr_title_file="$BATS_TEST_TMPDIR/pr-title"
pr_files_file="$BATS_TEST_TMPDIR/pr-files"
pr_body_file="$BATS_TEST_TMPDIR/pr-body"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth)
    [ "$auth_ok" = "ok" ] && exit 0 || exit 1
    ;;
  repo)
    printf 'gaia-react/gaia\n'
    ;;
  pr)
    case " $* " in
      *" baseRefName "*)
        printf 'main\n'
        exit 0
        ;;
      *" number,headRefName,body "*)
        [ -f "$pushed_head_file" ] || exit 1
        printf '7\nfeat/review-fixture\n'
        if [ -f "$pr_body_file" ]; then
          cat "$pr_body_file"
        else
          printf '<!-- gaia-pr-body-head: %s -->\n' "$(cat "$pushed_head_file")"
          printf '<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: %s\nNo findings.\n<!-- gaia:pr-review:end -->\n' "$(cat "$pushed_head_file")"
        fi
        exit 0
        ;;
      *" body "*)
        [ -f "$pushed_head_file" ] || exit 1
        printf '<!-- gaia-pr-body-head: %s -->\n' "$(cat "$pushed_head_file")"
        exit 0
        ;;
    esac
    [ -f "$pushed_head_file" ] || exit 1
    cat "$pushed_head_file"
    if [ -s "$pr_title_file" ]; then
      printf '\n'
      cat "$pr_title_file"
      printf '\n'
      [ -s "$pr_files_file" ] && cat "$pr_files_file"
    else
      printf '\n'
    fi
    ;;
  api)
    case "$2" in
      repos/*/branches/*)
        git -C "$remote" rev-parse "refs/heads/${2##*/branches/}"
        exit $?
        ;;
    esac
    sha="${2##*statuses/}"
    sha="${sha%% *}"
    if [ -n "$sha" ] && git -C "$remote" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      printf '%s\n' "$*" >> "$record"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

run_helper() {
  ( cd "$SANDBOX" && "$SCRIPT" "$1" )
}

current_tree() {
  git -C "$SANDBOX" rev-parse "HEAD^{tree}"
}

# The real branch-own digest, sourced fresh in a subshell, so assertions compute
# the SAME digest the script itself derives rather than hardcoding one. The
# merge base is taken against the sandbox's origin/main, the base the gh mock
# reports.
digest_of() {
  local root="$1" member="$2" target="${3:-HEAD}"
  bash -c '. "$1"; merge_base=$(audit_branch_patch_merge_base "$2" refs/remotes/origin/main HEAD) || exit 1; audit_branch_member_digest "$2" "$3" "$merge_base" "$4"' \
    _ "$DIGEST_LIBRARY" "$root" "$member" "$target"
}

# Write a writer-shaped schema-3 EARNED clearance for MEMBER at PATH (an
# absolute path under SANDBOX), keyed to MEMBER's OWN content digest (owned
# files + machinery), NOT the tree. The precondition now accepts only such
# bodies, not a bare `{}`: `digest` equals the filename key and `member`
# matches. `tree` stays in the body as a plain data field.
write_body() {
  local path="$1" member="$2" digest tree sha sidecar
  digest=$(digest_of "$SANDBOX" "$member")
  tree=$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")
  sha=$(git -C "$SANDBOX" rev-parse HEAD)
  if [ "$member" = "code-audit-frontend" ]; then sidecar="true"; else sidecar="false"; fi
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" > "$path"
}

# Write a writer-shaped REFUSAL for MEMBER at PATH, keyed to the same
# current-HEAD digest write_body uses. The refusal twin of write_body: the real
# writer publishes a refusal BESIDE any same-digest earned marker rather than
# replacing it, so a test calls both to reproduce the two-artifact state the
# gate has to resolve by precedence.
write_refusal_body() {
  local path="$1" member="$2" digest tree sha
  digest=$(digest_of "$SANDBOX" "$member")
  tree=$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")
  sha=$(git -C "$SANDBOX" rev-parse HEAD)
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"%s","provenance":"refused","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$member" "$digest" "$tree" "$sha" > "$path"
}

# Copy the real resolver script into SANDBOX so a test can exercise the
# member-aware gate. Untracked, so it never appears in a git diff itself.
install_resolver() {
  local resolver_absolute_path library_directory
  resolver_absolute_path="$THIS_DIRECTORY/../../../.gaia/scripts/resolve-audit-members.sh"
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$resolver_absolute_path" "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"

  # The resolver copy resolves its libs relative to ITSELF
  # ($SANDBOX/.claude/hooks/lib/), so provision the shared ownership
  # classifier alongside it.
  library_directory="$THIS_DIRECTORY/../../../.claude/hooks/lib"
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$library_directory/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$library_directory/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"
  cp "$library_directory/audit-clearance.sh" "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"
  cp "$library_directory/audit-base-provenance.sh" "$SANDBOX/.claude/hooks/lib/audit-base-provenance.sh"
}

# Commit a mixed app/ + .gaia/**/*.sh change on a new `feature` branch off
# SANDBOX's init commit, so the resolver's merge-base(HEAD, main) diff is
# non-empty and dispatches both code-audit-frontend (app/) and
# code-audit-maintainer-shell (.gaia/**/*.sh) against the seeded roster.
commit_mixed_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/apps/web/app" "$SANDBOX/.gaia/scripts"
  echo "export const x = 1;" > "$SANDBOX/apps/web/app/x.ts"
  echo "#!/bin/bash" > "$SANDBOX/.gaia/scripts/example.sh"
  git -C "$SANDBOX" add apps/web/app/x.ts .gaia/scripts/example.sh
  git -C "$SANDBOX" commit --quiet -m "mixed change"
  # Push before any later local-only commit, so the pushed head sha this
  # captures is the one post-audit-status.sh must target (not local HEAD).
  push_branch
}

# -----------------------------------------------------------------------------
# 1. Marker-gated POST: posts on marker present, skips on marker absent
# -----------------------------------------------------------------------------

# bats test_tags=protected
@test "local producer: posts GAIA-Audit success only after marker exists" {
  install_gh_mock ok
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The marker is keyed to the member's own content digest; the status POST
  # still targets the COMMIT (a GitHub commit status has nowhere else to land).
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  # The recorded POST carries state=success, the GAIA-Audit context, and the
  # three-field "<version> <frontend-digest> <tree>" description every
  # state-aware reader accepts as cleared.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${head_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "context=GAIA-Audit" "$POST_LOG"
  grep -q "description=1.2.3 ${digest} ${tree}" "$POST_LOG"

  # Marker absent → no POST, declines.
  rm -f "$POST_LOG"
  run run_helper ".gaia/local/audit/does-not-exist.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker absent" ]
  [ ! -f "$POST_LOG" ]
}

# bats test_tags=protected
@test "local producer: gh unauthenticated → marker stays, no status post (fail-safe asymmetry)" {
  install_gh_mock fail
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: gh unauthenticated" ]

  # The marker the caller wrote is untouched; only the POST is skipped.
  [ -f "$SANDBOX/$marker" ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# 3. Member-aware POST gate (Interface contract 2, blocker COV-001): a mixed
#    diff requires every dispatched member's marker, not just the caller's own.
# -----------------------------------------------------------------------------

# Clear the member markers and the POST log between cases of one fixture.
reset_case() {
  rm -rf "$SANDBOX/.gaia/local/audit" "$BATS_TEST_TMPDIR/pr-title" "$BATS_TEST_TMPDIR/pr-files" "$BATS_TEST_TMPDIR/pr-body"
  rm -f "$POST_LOG"
  mkdir -p "$SANDBOX/.gaia/local/audit"
}

# A refused member inside the gate. The writer publishes a refusal beside the
# same-digest earned marker rather than replacing it, so a member that cleared
# a digest in one wave and refused it in a later one holds both. Read cleared
# alone and that member counts as cleared, so the next member's earned
# handshake posts success on the same head and latest-status-wins retracts the
# failure the refusal writer just posted, while the merge hook goes on denying.
# The gate has to read the refusal family first, exactly as the merge hook does.
# bats test_tags=protected
@test "member-aware POST gate: declines while a member withholds or holds a refusal, posts three-field success with no carried suffix once all clear" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  marker=".gaia/local/audit/${frontend_digest}.ok"
  shell_marker=".gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok"

  echo "case: declines while a co-dispatched maintainer-shell member withholds"
  reset_case
  write_body "$SANDBOX/$marker" code-audit-frontend
  run run_helper "$marker"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "status: declined: members pending code-audit-maintainer-shell" ] || return 1
  # A decline never posts, and the caller's own marker is untouched.
  [ ! -f "$POST_LOG" ] || return 1
  [ -f "$SANDBOX/$marker" ] || return 1

  echo "case: declines while a dispatched member holds a refusal beside its earned marker"
  reset_case
  write_body "$SANDBOX/$marker" code-audit-frontend
  write_body "$SANDBOX/$shell_marker" code-audit-maintainer-shell
  write_refusal_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.refused" code-audit-maintainer-shell
  run run_helper "$marker"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "status: declined: members pending code-audit-maintainer-shell" ] || return 1
  # Nothing is posted, so a standing failure is never overwritten.
  [ ! -f "$POST_LOG" ] || return 1

  echo "case: posts success once every dispatched member has cleared, three-field description, no carried suffix"
  reset_case
  write_body "$SANDBOX/$marker" code-audit-frontend
  write_body "$SANDBOX/$shell_marker" code-audit-maintainer-shell
  run run_helper "$marker"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == "status: posted GAIA-Audit success "* ]] || return 1
  [ -f "$POST_LOG" ] || return 1
  grep -q "statuses/${head_sha}" "$POST_LOG" || return 1
  grep -q "state=success" "$POST_LOG" || return 1
  grep -q "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG" || return 1
  # No carried token appended, and never can be (there is no carried family).
  grep -qF -- "carried" "$POST_LOG" && return 1
  true
}

# The chore(deps) waiver. A dep-bump pull request waives code-audit-frontend
# through the same title-plus-file-list predicate the merge hook and CI
# already read, so a member co-dispatched on a dep-bump diff completes the
# handshake with its own earned marker. Fail-closed on a non-matching or
# unreadable title, an empty or non-manifest file list, and refusal-first: a
# frontend refusal still keeps frontend pending under a dep-bump title.
install_chore_deps_predicate() {
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$THIS_DIRECTORY/../../../.gaia/scripts/chore-deps-skip.sh" "$SANDBOX/.gaia/scripts/chore-deps-skip.sh"
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$THIS_DIRECTORY/../../../.claude/hooks/lib/gaia-packages.sh" "$SANDBOX/.claude/hooks/lib/gaia-packages.sh"
}

# Write $@ as the PR's changed-path list the mock's `pr` case reads back, one
# path per line.
install_pr_files() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/pr-files"
}

# Run the shell member's handshake with frontend unmarked, the title (if any)
# already written to the mock's title file.
run_shell_member_handshake() {
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok"
  write_body "$SANDBOX/$marker" code-audit-maintainer-shell
  run run_helper "$marker"
}

# Each case: label, PR title ("" for an unreadable title), the PR's changed
# paths ("" for none), the member whose handshake runs (shell, or frontend for
# the shell-unmarked case), whether a frontend refusal stands, and the expected
# output ("posted" for a success).
CHORE_DEPS_CASES='a dep-bump title with a manifest-only file list waives frontend, so the co-dispatched member'"'"'s marker posts success|chore(deps): bump vite to 8.3.0|package.json pnpm-lock.yaml|shell|no|posted
a non-dep-bump title leaves frontend pending|fix(cli): raise shared pins|package.json|shell|no|status: declined: members pending code-audit-frontend
a dep-bump title whose PR changes apps/web/app/x.ts leaves frontend pending|chore(deps): bump vite to 8.3.0|package.json apps/web/app/x.ts|shell|no|status: declined: members pending code-audit-frontend
an empty file list leaves frontend pending|chore(deps): bump vite to 8.3.0||shell|no|status: declined: members pending code-audit-frontend
waives frontend only, so an unmarked co-dispatched member stays pending|chore(deps): bump vite to 8.3.0|package.json pnpm-lock.yaml|frontend|no|status: declined: members pending code-audit-maintainer-shell
an unreadable PR title fails closed and leaves frontend pending|||shell|no|status: declined: members pending code-audit-frontend
a files line does not fold into the title (pr_title is line 2 only)|fix(cli): raise shared pins|package.json pnpm-lock.yaml|shell|no|status: declined: members pending code-audit-frontend
a frontend refusal keeps frontend pending under a dep-bump title|chore(deps): bump vite to 8.3.0|package.json pnpm-lock.yaml|shell|yes|status: declined: members pending code-audit-frontend'

# bats test_tags=protected
@test "chore(deps) waiver: case table of dep-bump title and file-list outcomes (waived, non-dep-bump, non-manifest path, empty files, unreadable title, files-line fold, other member unmarked, frontend refusal)" {
  install_gh_mock ok
  install_resolver
  install_chore_deps_predicate
  commit_mixed_diff
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  cases=0

  while IFS='|' read -r label title files member refused expected; do
    echo "case: $label"
    cases=$((cases + 1))
    reset_case
    [ -z "$title" ] || printf '%s' "$title" > "$BATS_TEST_TMPDIR/pr-title"
    # A waived PR records its review before its merge, so its body carries the
    # head stamp and no PR review section.
    printf '<!-- gaia-pr-body-head: %s -->\n' "$PUSHED_HEAD" > "$BATS_TEST_TMPDIR/pr-body"
    # shellcheck disable=SC2086 # the paths column is a space-separated list
    [ -z "$files" ] || install_pr_files $files
    [ "$refused" = no ] || write_refusal_body "$SANDBOX/.gaia/local/audit/${frontend_digest}.refused" code-audit-frontend
    if [ "$member" = shell ]; then
      run_shell_member_handshake
    else
      # Frontend holds its own marker and shell holds none. Only a waiver
      # widened past frontend would clear shell here.
      caller=".gaia/local/audit/${frontend_digest}.ok"
      write_body "$SANDBOX/$caller" code-audit-frontend
      run run_helper "$caller"
    fi
    [ "$status" -eq 0 ] || return 1
    if [ "$expected" = posted ]; then
      [ "$output" = "status: posted GAIA-Audit success $(git -C "$SANDBOX" rev-parse --short HEAD)" ] || return 1
      grep -qF -- "statuses/${head_sha}" "$POST_LOG" || return 1
      grep -qF -- "state=success" "$POST_LOG" || return 1
      grep -qF -- "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG" || return 1
    else
      [ "$output" = "$expected" ] || return 1
      [ ! -f "$POST_LOG" ] || return 1
    fi
  done <<<"$CHORE_DEPS_CASES"
  [ "$cases" -eq 8 ]
}

# The order-independence the helper's header promises, and that a commit key
# cannot actually deliver. A specialized member clears the content and writes
# its marker; an empty commit then advances HEAD and code-audit-frontend
# writes its own. Keyed to HEAD, the empty commit orphans the sibling's marker
# and the POST declines "members pending" even though both members audited
# identical content. Keyed to the content digest (blobs unchanged by an empty
# commit), the POST goes through. The commit is pushed before the POST, per the
# push-then-post ordering the sha guard requires; the marker-survival question
# this pins is orthogonal to the push state.
@test "member-aware POST: a sibling's marker survives a content-preserving empty commit" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  older_head="$PUSHED_HEAD"
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The specialized member clears the content first, before the empty commit.
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell

  # An empty commit: identical blobs, a fresh sha. Pushed before the POST, so
  # the new head is the fetchable sha the status must land on.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  push_branch
  pushed_empty_sha="$PUSHED_HEAD"
  [ "$pushed_empty_sha" != "$older_head" ]

  # The fixture's discriminating property: the commit advanced HEAD but rotated
  # no member's digest, so the sibling's earlier marker is still the
  # clearance the member gate reads.
  [ "$(digest_of "$SANDBOX" code-audit-maintainer-shell)" = "$shell_digest" ]

  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1
  # The sibling's marker cleared the gate rather than being orphaned by the
  # empty commit; an orphaned marker declines "members pending" here instead.
  grep -qF -- "members pending" <<<"$output" && return 1

  # The status lands on the pushed head, not the older head it replaced,
  # carrying the unchanged content.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${pushed_empty_sha}" "$POST_LOG"
  grep -qF -- "statuses/${older_head}" "$POST_LOG" && return 1
  grep -q "state=success" "$POST_LOG"
  grep -q "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG"
}

@test "member-aware POST: resolver absent falls back to the single-marker POST on a mixed diff" {
  install_gh_mock ok
  commit_mixed_diff

  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  # No resolver copied into SANDBOX: the member-aware gate is skipped and the
  # frontend marker alone clears the POST, same as today.
  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]
}

# -----------------------------------------------------------------------------
# 4. Status target (#726): the POST only ever lands on a sha the remote
#    carries, and declines when the audited tree genuinely isn't on the pushed
#    head.
# -----------------------------------------------------------------------------

# bats test_tags=protected
@test "local producer: declines when the audited tree is not on the pushed head (unpushed tree-changing work)" {
  install_gh_mock ok

  # Unpushed tree-changing work: local HEAD's tree now differs from the pushed head's tree (still the init commit's).
  echo "changed" >> "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "unpushed tree change"

  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: audited tree not on pushed head" ]
  [ ! -f "$POST_LOG" ]
}

# #726's surviving invariant: a GAIA-Audit status never lands on a sha the
# remote has never seen. The hook enforces it by DECLINING an un-pushed
# content-preserving commit rather than by retargeting to the older head, so
# the un-pushed half of the fixture must produce no POST at all. Pushing the
# commit first is the other half of the contract, and this fixture is where it is
# worth pinning: the gh mock accepts a `statuses/<sha>` target only when the sha
# is a fetchable commit on the bare remote, the same 422 boundary the real API
# draws and the gap that let #726 hide.
# bats test_tags=protected
@test "#726: an un-pushed empty commit produces no POST; the pushed commit gets the status" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend
  older_head="$PUSHED_HEAD"

  # An empty commit: a local, un-pushed commit, tree identical to
  # the pushed head's, so the tree guard is blind to it by construction.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  empty_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  [ "$empty_sha" != "$older_head" ]
  # The fixture's discriminating property: the remote genuinely lacks this sha,
  # so a status posted there would 422 exactly as #726 did.
  git -C "$REMOTE" cat-file -e "${empty_sha}^{commit}" 2>/dev/null && return 1

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: stamp not pushed" ]
  # No POST on either sha: not the un-pushed commit, and not the older head
  # it is about to replace.
  [ ! -f "$POST_LOG" ]

  # Push the commit, then post: the same marker set now clears, and the status
  # lands on the sha the remote carries.
  push_branch
  run run_helper "$marker"
  [ "$status" -eq 0 ]
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1

  [ -f "$POST_LOG" ]
  grep -q "statuses/${empty_sha}" "$POST_LOG"
  grep -qF -- "statuses/${older_head}" "$POST_LOG" && return 1
  return 0
}

# The surfaced short sha is an identifier a maintainer reads back
# against the PR, so it must re-resolve to the sha the POST actually targeted,
# and it must stay abbreviated: the hook falls back to printing the full sha
# when its own re-resolution check fails, so a 40-hex value on this line means
# the degraded branch fired. The divergence the test originally drew this
# distinction against -- local HEAD ahead of the pushed head -- is unreachable,
# because the sha guard now requires the two to be the same commit before any
# POST happens. What is left is the round trip, asserted against the sha read
# back out of the POST log rather than one the test computed for itself.
@test "#794: the posted-status line's short sha resolves to the sha actually POSTed" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  # Commit empty and push it, so the sha on the surfaced line is a real pushed PR
  # head rather than the branch tip the fixture started on.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  push_branch

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  surfaced="${output##* }"
  # Single line, expected prefix, and the trailing field is what `surfaced` holds.
  [ "$output" = "status: posted GAIA-Audit success ${surfaced}" ]
  # Abbreviated, not the full-sha degraded fallback.
  [ "${#surfaced}" -lt 40 ]

  # Read the POSTed sha back out of the recorded invocation, then re-resolve the
  # surfaced short form against it.
  posted_field=$(grep -oE 'statuses/[0-9a-f]{40}' "$POST_LOG" | head -1)
  posted_sha="${posted_field#statuses/}"
  [ -n "$posted_sha" ]
  [ "$(git -C "$SANDBOX" rev-parse "$surfaced")" = "$posted_sha" ]
}

# bats test_tags=protected
@test "frontend digest unavailable (sha256 tool masked): declines fail-closed, no POST" {
  install_gh_mock ok
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  # Shadow sha256sum with a stub that always fails, on a prepended PATH: the
  # digest engine's own fail-closed posture (never a partial/empty digest, per
  # audit-digest-lib.bats UAT-013) must surface here as a clean decline, never
  # a posted status with a missing or empty digest field.
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$FAKEBIN/sha256sum"

  PATH="$FAKEBIN:$PATH" run run_helper "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: frontend digest unavailable" ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# 7. Trusted base: the success arm measures against the base tip GitHub reports
#    and declines, naming one next step, when it cannot. The refusal arm never
#    verifies the base. These cases use the shared gh stub and a real bare origin
#    with a base branch that moves, instead of the mock above.
# -----------------------------------------------------------------------------

# A forty-hex id no repository carries.
ABSENT_TIP=0123456789abcdef0123456789abcdef01234567

# Point the gh stub's PR record at the sandbox's current HEAD and its base tip at
# $1 (default: the sandbox's origin/main). Call again after HEAD or the base moves.
refresh_stub() {
  GH_STUB_BASE_TIP="${1:-$(git -C "$SANDBOX" rev-parse refs/remotes/origin/main)}"
  GH_STUB_PR_JSON="$(jq -n --arg head "$(git -C "$SANDBOX" rev-parse HEAD)" '{headRefOid: $head, number: 7, headRefName: "feat/review-fixture", title: "", files: [], body: "<!-- gaia-pr-body-head: \($head) -->\n<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: \($head)\nNo findings.\n<!-- gaia:pr-review:end -->"}')"
  export GH_STUB_BASE_TIP GH_STUB_PR_JSON
}

install_base_stub() {
  gh_base_stub_install "$BATS_TEST_TMPDIR/base-bin"
  export PATH="$BATS_TEST_TMPDIR/base-bin:$PATH"
  export GH_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export GH_STUB_REPOSITORY=gaia-react/gaia
  export GH_STUB_BASE_BRANCH=main
  : > "$GH_STUB_LOG"
}

# Lines of the stub's call log containing the fixed string $1.
logged_calls() {
  local count
  count=$(grep -cF -- "$1" "$GH_STUB_LOG") || count=0
  printf '%s' "$count"
}

# Write both members' earned markers for the current branch-own digests and set
# FRONTEND_MARKER and SHELL_MARKER (sandbox-relative paths).
write_both_markers() {
  local frontend_digest shell_digest
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend) || return 1
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell) || return 1
  mkdir -p "$SANDBOX/.gaia/local/audit"
  FRONTEND_MARKER=".gaia/local/audit/${frontend_digest}.ok"
  SHELL_MARKER=".gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok"
  write_body "$SANDBOX/$FRONTEND_MARKER" code-audit-frontend
  write_body "$SANDBOX/$SHELL_MARKER" code-audit-maintainer-shell
}

# A feature branch with a bare origin whose base branch is `main`, a mixed
# frontend + shell change (so two members are dispatched), the gh stub installed
# and pointed at the sandbox, and both members' markers written.
build_audited_branch() {
  install_resolver
  catchup_add_origin "$SANDBOX" main --feature feat/catchup || return 1
  catchup_branch_commit apps/web/app/x.ts "export const x = 1;" || return 1
  catchup_branch_commit .gaia/scripts/example.sh "#!/bin/bash" || return 1
  install_base_stub
  refresh_stub
  write_both_markers
}

# bats test_tags=protected
@test "trusted base: success arm declines per unverifiable-base kind (absent tip, gh failure, multiple merge bases) naming one next step, posting no success" {
  build_audited_branch

  echo "case: a base tip that is not present locally declines naming git fetch origin, and posts no success"
  refresh_stub "$ABSENT_TIP"
  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "status: declined: trusted base unverified, the base tip is not present locally; next step: git fetch origin" ] || return 1
  [ "$(logged_calls 'state=success')" = 0 ] || return 1

  echo "case: gh failing for the base lookup declines naming gh auth status, and posts no success"
  refresh_stub
  : > "$GH_STUB_LOG"
  export GH_STUB_FAIL_BRANCHES=1
  run run_helper "$FRONTEND_MARKER"
  unset GH_STUB_FAIL_BRANCHES
  [ "$status" -eq 0 ] || return 1
  grep -qF -- "status: declined: trusted base unverified, " <<<"$output" || return 1
  grep -qF -- "gh failed reading the base branch tip" <<<"$output" || return 1
  grep -qF -- "next step: gh auth status" <<<"$output" || return 1
  [ "$(logged_calls 'state=success')" = 0 ] || return 1

  # Last, because the criss-cross merge changes the branch for good.
  echo "case: more than one merge base declines naming the merge, and posts no success"
  : > "$GH_STUB_LOG"
  catchup_criss_cross
  refresh_stub
  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "status: declined: trusted base unverified, more than one merge base with the base branch; next step: git merge --no-edit refs/remotes/origin/main" ] || return 1
  [ "$(logged_calls 'state=success')" = 0 ]
}

# bats test_tags=protected
@test "trusted base: gh hanging for the base lookup declines at the deadline, leaves no process behind, and posts no success" {
  build_audited_branch
  export GH_STUB_HANG_BRANCHES=1
  export GAIA_AUDIT_GH_DEADLINE_SECONDS=1
  export GH_STUB_PID_LOG="$BATS_TEST_TMPDIR/pids"

  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ]
  grep -qF -- "status: declined: trusted base unverified, " <<<"$output" || return 1
  grep -qF -- "timed out" <<<"$output" || return 1
  grep -qF -- "next step: gh auth status" <<<"$output" || return 1
  [ "$(logged_calls 'state=success')" = 0 ]

  [ -s "$GH_STUB_PID_LOG" ]
  while read -r stub_pid sleeper_pid; do
    kill -0 "$stub_pid" 2>/dev/null && return 1
    kill -0 "$sleeper_pid" 2>/dev/null && return 1
  done < "$GH_STUB_PID_LOG"
  true
}

# A refusal retracts an earlier success whatever the state of the base: the
# retraction is the one post that must always be able to land.
# bats test_tags=protected
@test "trusted base: a refusal still posts failure on HEAD after an earlier success, per unverifiable-base kind" {
  build_audited_branch
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  refused=".gaia/local/audit/${frontend_digest}.refused"

  for kind in absent-tip criss-cross; do
    echo "case: a refusal posts failure on HEAD after an earlier success, with base state $kind"
    rm -f "$SANDBOX/$refused"
    refresh_stub
    : > "$GH_STUB_LOG"
    # The earlier success lands while the base is healthy, before the refusal.
    run run_helper "$FRONTEND_MARKER"
    [ "$status" -eq 0 ] || return 1
    [ "$(logged_calls 'state=success')" = 1 ] || return 1
    write_refusal_body "$SANDBOX/$refused" code-audit-frontend

    if [ "$kind" = absent-tip ]; then
      refresh_stub "$ABSENT_TIP"
    else
      catchup_criss_cross
      refresh_stub
    fi
    head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
    run run_helper "$refused"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "status: posted GAIA-Audit failure $(git -C "$SANDBOX" rev-parse --short HEAD)" ] || return 1
    grep -F -- "statuses/${head_sha}" "$GH_STUB_LOG" | grep -qF -- "state=failure" || return 1
  done
}

# After a remedy and with every member holding a marker for its current digest,
# exactly one success posts and its description carries the branch-own frontend
# digest in field 2.
assert_one_success_after_remedy() {
  local frontend_digest
  write_both_markers
  refresh_stub
  : > "$GH_STUB_LOG"
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)

  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ] || return 1
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1
  [ "$(logged_calls 'state=success')" = 1 ] || return 1
  grep -qF -- "description=1.2.3 ${frontend_digest} $(current_tree)" "$GH_STUB_LOG" || return 1
}

# bats test_tags=protected
@test "trusted base: after each remedy (fetch, gh recovery, unique merge base) one success posts with the branch-own frontend digest" {
  build_audited_branch

  echo "case: after the base tip is fetched, one success posts with the branch-own frontend digest"
  : > "$GH_STUB_LOG"
  refresh_stub "$ABSENT_TIP"
  run run_helper "$FRONTEND_MARKER"
  [ "$(logged_calls 'state=success')" = 0 ] || return 1
  assert_one_success_after_remedy || return 1

  echo "case: after gh recovers, one success posts with the branch-own frontend digest"
  : > "$GH_STUB_LOG"
  export GH_STUB_FAIL_BRANCHES=1
  run run_helper "$FRONTEND_MARKER"
  [ "$(logged_calls 'state=success')" = 0 ] || return 1
  unset GH_STUB_FAIL_BRANCHES
  assert_one_success_after_remedy || return 1

  # Last, because the criss-cross merge changes the branch for good.
  echo "case: after the base is merged to make the merge base unique, one success posts with the branch-own frontend digest"
  catchup_criss_cross
  refresh_stub
  : > "$GH_STUB_LOG"
  run run_helper "$FRONTEND_MARKER"
  [ "$(logged_calls 'state=success')" = 0 ] || return 1
  catchup_merge_base
  assert_one_success_after_remedy
}

@test "a clean catch-up merge re-posts success on the merge commit with the same frontend digest" {
  build_audited_branch
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ]
  [ "$(logged_calls 'state=success')" = 1 ]
  grep -qF -- "description=1.2.3 ${frontend_digest} " "$GH_STUB_LOG" || return 1
  before_head=$(git -C "$SANDBOX" rev-parse HEAD)

  catchup_base_commit docs/base-note.md "arrived from the base"
  catchup_merge_base
  merge_head=$(git -C "$SANDBOX" rev-parse HEAD)
  [ "$merge_head" != "$before_head" ]
  refresh_stub
  : > "$GH_STUB_LOG"

  # Any existing member marker will do: the shell member's, written before the
  # merge, still names its current digest.
  run run_helper "$SHELL_MARKER"
  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit success $(git -C "$SANDBOX" rev-parse --short HEAD)" ]
  grep -F -- "statuses/${merge_head}" "$GH_STUB_LOG" | grep -qF -- "description=1.2.3 ${frontend_digest} " || return 1
  [ "$(digest_of "$SANDBOX" code-audit-frontend)" = "$frontend_digest" ]
}

# git wrapper that records every invocation's arguments, then runs the real git.
install_git_logger() {
  local real_git
  real_git="$(command -v git)"
  GIT_CALL_LOG="$BATS_TEST_TMPDIR/git-calls.log"
  : > "$GIT_CALL_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/git-logger"
  cat > "$BATS_TEST_TMPDIR/git-logger/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GIT_CALL_LOG"
exec "$real_git" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/git-logger/git"
  export PATH="$BATS_TEST_TMPDIR/git-logger:$PATH"
}

@test "a success run lists the branch's identities once, not once per member" {
  build_audited_branch
  install_git_logger

  run run_helper "$FRONTEND_MARKER"
  [ "$status" -eq 0 ]
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1
  # Both dispatched members' markers were checked.
  [ "$(logged_calls 'state=success')" = 1 ]
  listings=$(grep -c -- 'diff-tree -r --raw -z' "$GIT_CALL_LOG") || listings=0
  [ "$listings" = 1 ]
}
