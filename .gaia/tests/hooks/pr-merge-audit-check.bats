#!/usr/bin/env bats

# Tests for .claude/hooks/pr-merge-audit-check.sh.
#
# The hook denies `gh pr merge` unless a code-review-audit signal exists for
# HEAD. Signal 5 (check_out_of_scope_pr) is a fail-closed allowlist bypass: it
# allows the merge when EVERY file the PR changes (vs its merge base with the
# default branch) lives outside audit scope; wiki/, .claude/,
# .gaia/, docs/, and root-level markdown. Any in-scope path (app/, test/,
# configs, .github/workflows/) keeps the marker mandatory.
#
# There is no self-modification bypass: a pull request whose only in-scope
# change re-renders a bundled workflow template verbatim denies without a
# marker like any other in-scope change.
#
# Every gh stub here answers the fork query (`--json isCrossRepository`) with
# `false`, ahead of its record arm, because the gate asks it before anything
# else and denies when gh cannot answer. The fork cases themselves live in
# cross-repo-refusal.bats; the bypass status POST in bypass-audit-stamp.bats.
#
# Every Code Audit Team marker is keyed to a member's own CONTENT DIGEST (a
# sha256 over exactly the files that member owns plus the shared gate
# machinery, folding the in-scope-but-ownerless paths into the default
# member's set), not the whole tree and not the commit. There is no
# carry-forward clearance machinery: a marker either validates for the
# CURRENT digest or it does not.
#
# Each test drives the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the repo as the working directory (the hook uses
# bare `git`, not `git -C`). The hook always exits 0; allow vs deny is carried
# in stdout; a deny emits `"permissionDecision": "deny"`, an allow emits
# nothing. The in-scope (deny) cases double as a jq/setup canary: if jq were
# missing the hook would exit early with no output and those assertions would
# fail rather than false-pass.
#
# Setup models a PR: a base commit on `main`, then a `feature` branch carrying
# the change under test, and a bare `origin` the mocked gh reads the base
# branch tip from (the catch-up fixture). The gate takes the base branch name
# from the PR record and its tip from GitHub, so the stubs below answer
# `gh api repos/.../branches/<base>` from that bare origin.
#
# The real .gaia/scripts/resolve-audit-members.sh is copied into REPO
# (untracked, so it never appears in the diffs under test) so every case below
# exercises the hook exactly as it runs in the real repo, where the resolver
# is always present. The one test that needs the resolver-absent fallback
# removes this copy explicitly.

# The permit-diagnostic case below asserts stdout and stderr independently,
# which needs `run --separate-stderr` (bats >= 1.5.0).
bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/catchup-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  HOOK_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/pr-merge-audit-check.sh
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-text.sh"
  SETTINGS_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude" && pwd)/settings.json
  RESOLVER_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/resolve-audit-members.sh
  LIBRARY_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)
  REPO=$(mktemp -d -t pr-merge-test-XXXXXX)

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  mkdir -p "$REPO/.gaia"
  write_builtin_descriptor "$REPO"
  printf '1.4.0\n' > "$REPO/.gaia/VERSION"
  echo "# readme" > "$REPO/README.md"
  seed_audit_roster "$REPO"
  git -C "$REPO" add .gaia/VERSION .gaia/audit-ci.yml README.md
  git -C "$REPO" commit --quiet -m "init"

  catchup_add_origin "$REPO" main --feature feature || return 1

  mkdir -p "$REPO/.gaia/scripts"
  cp "$RESOLVER_ABSOLUTE_PATH" "$REPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"

  # The copy above resolves its libs relative to ITSELF
  # ($REPO/.claude/hooks/lib/), not the real repo, so the sandbox needs its
  # own copy of the shared ownership classifier + digest engine + clearance
  # reader + base provenance resolver alongside it. The real hook (run by
  # absolute path via $HOOK_ABSOLUTE_PATH, never copied) resolves its own libs to the
  # real repo regardless.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$LIBRARY_DIRECTORY/audit-scope.sh" "$REPO/.claude/hooks/lib/audit-scope.sh"
  cp "$LIBRARY_DIRECTORY/audit-scope-release.sh" "$REPO/.claude/hooks/lib/audit-scope-release.sh"
  cp "$LIBRARY_DIRECTORY/audit-machinery.sh" "$REPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$LIBRARY_DIRECTORY/audit-clearance.sh" "$REPO/.claude/hooks/lib/audit-clearance.sh"
  cp "$LIBRARY_DIRECTORY/audit-digest.sh" "$REPO/.claude/hooks/lib/audit-digest.sh"
  cp "$LIBRARY_DIRECTORY/audit-base-provenance.sh" "$REPO/.claude/hooks/lib/audit-base-provenance.sh"
  cp "$LIBRARY_DIRECTORY/audit-branch-patch.sh" "$REPO/.claude/hooks/lib/audit-branch-patch.sh"
  cp "$BATS_TEST_DIRNAME/../../scripts/audit-key-lib.sh" "$REPO/.gaia/scripts/audit-key-lib.sh"

  # Every permit this gate issues is bound to the pull request the command
  # names, so every case here needs a pull-request record to be bound TO, not
  # only the ones that exercise a record-based bypass. Installing the stub for
  # all of them also makes the suite hermetic: without it the cases that never
  # called it invoked the developer's real `gh`, and passed because it happened
  # to fail in a sandbox with no remote.
  #
  # It is only a floor. A case wanting a different record still calls
  # install_gh_stub_with_title / install_gh_stub_with_status, which overwrite
  # this stub, and the two gh-absence cases scrub or replace it outright.
  install_gh_stub
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Commit one or more files (path=content pairs) on the feature branch.
commit_files() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$REPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$REPO/$path"
    git -C "$REPO" add "$path"
  done
  git -C "$REPO" commit --quiet -m "change"
}

# Seed a bundled workflow template onto the BASE commit (main), out of the
# feature diff, then re-point feature at it, so a feature commit can re-render
# it verbatim: the shape of pull request the removed self-modification bypass
# used to clear.
seed_base_template() {
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/.gaia/cli/templates/workflows"
  printf 'name: Code Review Audit\n' \
    > "$REPO/.gaia/cli/templates/workflows/code-review-audit.yml.tmpl"
  git -C "$REPO" add .gaia/cli/templates/workflows/code-review-audit.yml.tmpl
  git -C "$REPO" commit --quiet -m "seed bundled template on base"
  git -C "$REPO" push --quiet origin main
  git -C "$REPO" checkout --quiet -B feature main
}

# Run the hook with a `gh pr merge` command, against an arbitrary ROOT. The
# root-parameterized twin of run_merge_hook.
run_merge_hook_at() {
  local root="$1" command_line="${2:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg command_line "$command_line" \
    '{tool_name: "Bash", tool_input: {command: $command_line}}')
  invoke_hook_in "$root" "$json" "$HOOK_ABSOLUTE_PATH"
}

# Run the hook with a `gh pr merge` command, from inside the repo.
run_merge_hook() {
  run_merge_hook_at "$REPO" "${1:-gh pr merge 30 --squash --delete-branch}"
}

# Run the hook with a command too large to pass through argv. Linux caps a
# single argument at 128KB (MAX_ARG_STRLEN) while macOS does not, so the sibling
# helpers above, which hand the command to `jq` and the payload to `bash -c` as
# arguments, die with "Argument list too long" on CI and pass locally. Both hops
# go through a file here: `--rawfile` for the command, a stdin redirect for the
# payload.
run_merge_hook_large() {
  local command_line="$1" command_file jsonfile
  command_file="$BATS_TEST_TMPDIR/large-cmd.txt"
  jsonfile="$BATS_TEST_TMPDIR/large-payload.json"
  printf '%s' "$command_line" > "$command_file"
  jq -n --rawfile command_line "$command_file" \
    '{tool_name: "Bash", tool_input: {command: $command_line}}' > "$jsonfile"
  run bash -c 'cd "$1" && bash "$3" < "$2"' _ "$REPO" "$jsonfile" "$HOOK_ABSOLUTE_PATH"
}

# The tip of the base branch as the mocked GitHub reports it: the bare origin's
# branch, which a test advances without fetching to model a tip this checkout
# has not seen.
github_base_tip() {
  git -C "$CATCHUP_ORIGIN" rev-parse "refs/heads/${1:-main}"
}

# Compute MEMBER's real branch-own digest for ROOT's current HEAD, via the real
# digest engine over the merge base with the tip GitHub reports (never
# re-derived by hand), so fixtures stay in lockstep with whatever the hook
# itself would compute.
member_digest_at() {
  local root="$1" member="$2"
  bash -c '. "$1"; merge_base="$(audit_branch_patch_merge_base "$2" "$3")" && audit_branch_member_digest "$2" "$4" "$merge_base"' \
    _ "$LIBRARY_DIRECTORY/audit-digest.sh" "$root" "$(github_base_tip main)" "$member"
}

# The same call pinned to REPO.
member_digest_for() {
  member_digest_at "$REPO" "$1"
}

# Write a Code Audit Team EARNED clearance marker for MEMBER, keyed to
# MEMBER's own content digest at ROOT's current HEAD (schema 3). The
# root-parameterized twin of write_marker, built on member_digest_at.
#   write_marker_at "$LINKED_WORKTREE" "code-audit-frontend"
#   write_marker_at "$ROOT" "code-audit-frontend" light   (optional review field)
write_marker_at() {
  local root="$1" member="$2" review="${3:-}" digest sha tree infix sidecar review_field=""
  [ -z "$review" ] || review_field="$(printf '"review":"%s",' "$review")"
  digest="$(member_digest_at "$root" "$member")"
  sha=$(git -C "$root" rev-parse HEAD)
  tree=$(git -C "$root" rev-parse "HEAD^{tree}")
  if [ "$member" = "code-audit-frontend" ]; then infix=""; sidecar="true"; else infix=".$member"; sidecar="false"; fi
  mkdir -p "$root/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"earned",%s"digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$review_field" "$digest" "$tree" "$sha" "$sidecar" \
    > "$root/.gaia/local/audit/${digest}${infix}.ok"
}

# Write a Code Audit Team EARNED clearance marker for MEMBER, keyed to
# MEMBER's own content digest at REPO's current HEAD (schema 3). A marker
# attests that a member audited exactly the files it owns plus gate
# machinery, so it survives any change outside that set.
#   write_marker "code-audit-frontend"
#   write_marker "code-audit-maintainer-shell"
write_marker() {
  write_marker_at "$REPO" "$1"
}

# Write a REFUSAL artifact for MEMBER, keyed to the SAME digest write_marker
# would use right now (the current-content digest).
write_refused() {
  local member="$1" digest sha tree infix
  digest="$(member_digest_for "$member")"
  sha=$(git -C "$REPO" rev-parse HEAD)
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  if [ "$member" = "code-audit-frontend" ]; then infix=""; else infix=".$member"; fi
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"refused","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:01Z","sidecar":false}\n' \
    "$member" "$digest" "$tree" "$sha" \
    > "$REPO/.gaia/local/audit/${digest}${infix}.refused"
}

# make_no_base_repo_pr <name>
#
# A standalone repo whose branch is not `main`, carries no `origin` remote,
# and has no `main` branch, so the FULL_BASE-style three-level base-resolution
# chain cannot resolve. Seeds .gaia/VERSION so the gate's version read succeeds. Asserts,
# before returning, that neither merge-base arm the derivation tries
# resolves, so the fixture cannot silently degrade into the resolved path
# and green.
make_no_base_repo_pr() {
  local name="$1" repository_directory
  repository_directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$repository_directory/.gaia"
  git -C "$repository_directory" init --quiet --initial-branch=master
  git -C "$repository_directory" config user.email "test@example.com"
  git -C "$repository_directory" config user.name "Test"
  git -C "$repository_directory" config commit.gpgsign false
  printf '1.4.0\n' > "$repository_directory/.gaia/VERSION"
  seed_audit_roster "$repository_directory"
  git -C "$repository_directory" add .gaia/VERSION .gaia/audit-ci.yml
  git -C "$repository_directory" commit --quiet -m "init"
  printf 'second\n' > "$repository_directory/.gaia/second.txt"
  git -C "$repository_directory" add .gaia/second.txt
  git -C "$repository_directory" commit --quiet -m "second"

  if git -C "$repository_directory" merge-base HEAD origin/main >/dev/null 2>&1; then
    echo "make_no_base_repo_pr: origin/main unexpectedly resolved" >&2
    return 1
  fi
  if git -C "$repository_directory" merge-base HEAD main >/dev/null 2>&1; then
    echo "make_no_base_repo_pr: main unexpectedly resolved" >&2
    return 1
  fi
  printf '%s' "$repository_directory"
}

# Print the dispatched member set the resolver resolves for REPO's current diff.
spawn_set() {
  ( cd "$REPO" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null )
}

# Write an earned clearance marker for every name in a spawn-set
# (newline-separated) string.
write_markers_for_spawn_set() {
  local set="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    write_marker "$name"
  done <<<"$set"
}

# Snapshot every file in the audit pool (name + content hash), to prove a run
# mints nothing.
pool_snapshot() {
  local audit_pool_directory="$REPO/.gaia/local/audit"
  [ -d "$audit_pool_directory" ] || { printf '<no-pool>'; return 0; }
  ( cd "$audit_pool_directory" && find . -type f | LC_ALL=C sort | while IFS= read -r pool_file; do printf '%s ' "$pool_file"; shasum "$pool_file" 2>/dev/null; done )
}

# add_base_lookup_to_stub: splice the base-branch tip answer into the gh stub
# just written, ahead of its own arms. GitHub's branches endpoint answers with
# the tip of the bare origin's branch (main when the branch does not exist
# there), GH_STUB_BASE_TIP overrides it, and GH_STUB_FAIL_BRANCHES /
# GH_STUB_HANG_BRANCHES fail or hang only that endpoint, so the fork query and
# the PR record still answer. GH_STUB_LOG receives one line per branches call.
add_base_lookup_to_stub() {
  local stub="$STUB_BINARY_DIRECTORY/gh" patched="$BATS_TEST_TMPDIR/gh-with-base-lookup"
  {
    sed -n '1p' "$stub"
    printf 'origin_directory=%q\n' "$CATCHUP_ORIGIN"
    cat <<'BASE_LOOKUP_ARM'
case "$*" in
  *repos/*/branches/*)
    if [ -n "${GH_STUB_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_STUB_LOG"; fi
    if [ -n "${GH_STUB_HANG_BRANCHES:-}" ]; then sleep 4242; exit 1; fi
    if [ -n "${GH_STUB_FAIL_BRANCHES:-}" ]; then echo 'gh stub: branches lookup failed' >&2; exit 1; fi
    if [ -n "${GH_STUB_BASE_TIP:-}" ]; then printf '%s\n' "$GH_STUB_BASE_TIP"; exit 0; fi
    all_arguments="$*"
    branch_name="${all_arguments##*/branches/}"
    branch_name="${branch_name%% *}"
    git -C "$origin_directory" rev-parse "refs/heads/$branch_name" 2>/dev/null \
      || git -C "$origin_directory" rev-parse refs/heads/main
    exit 0
    ;;
esac
BASE_LOOKUP_ARM
    sed -n '2,$p' "$stub"
  } > "$patched"
  cp "$patched" "$stub"
  chmod +x "$stub"
}

# Install a gh stub on a prepended PATH. `gh issue list` prints $1 (default []).
# GET statuses return null (so the frontend is NOT cleared via a CI status),
# `gh pr view` returns the PR record the hook reads once: an empty title (no
# chore(deps) bypass), an empty base ref (so the base derivation falls back
# to the remote's advertised default), and number 30. Its head is REPO's live
# HEAD, or the sha a case writes to pr-head-override, and its body carries the
# head stamp for that head.
#
# The number is what run_merge_hook's default command names. Every arm that can
# clear a merge binds its clearance to the pull request the COMMAND names, and
# an unconfirmable target denies, so a record carrying no number starves those
# arms rather than exercising them: a bypass test would go green on a deny it
# never meant to assert.
install_gh_stub() {
  local issues="${1:-[]}"
  STUB_BINARY_DIRECTORY="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BINARY_DIRECTORY"
  printf '%s' "$issues" > "$BATS_TEST_TMPDIR/issues.json"
  cat > "$STUB_BINARY_DIRECTORY/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
repo_directory="$REPO"
head_override_file="$BATS_TEST_TMPDIR/pr-head-override"
EOF
  cat >> "$STUB_BINARY_DIRECTORY/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) head="$(cat "$head_override_file" 2>/dev/null || git -C "$repo_directory" rev-parse HEAD 2>/dev/null)"
      jq -n --arg head "$head" '{title:"", baseRefName:"main", number:"30", headRefOid:$head, headRefName:"feature", body:("<!-- gaia-pr-body-head: " + $head + " -->\n<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: " + $head + "\nNo findings.\n<!-- gaia:pr-review:end -->")}'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/gh"
  add_base_lookup_to_stub
  export PATH="$STUB_BINARY_DIRECTORY:$PATH"
}

# Same stub, but the PR record carries $1 as the title and every remaining
# positional as one entry of the record's `files` array, so the chore(deps)
# bypass can actually fire (it requires a manifest-only file list alongside
# the title). $2 is still the issues payload, defaulting to `[]`, exactly as
# install_gh_stub's own. jq builds the record rather than a printf format, so a
# title or path carrying a quote or a backslash stays valid JSON instead of
# silently emptying the field the test is pinning.
install_gh_stub_with_title() {
  local title="$1" issues="${2:-[]}"
  if [ "$#" -gt 0 ]; then shift; fi
  if [ "$#" -gt 0 ]; then shift; fi
  install_gh_stub "$issues"
  printf '%s' "$title" > "$BATS_TEST_TMPDIR/pr-title.txt"
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0)) | map({path: .})' \
    > "$BATS_TEST_TMPDIR/pr-files.json"
  cat > "$STUB_BINARY_DIRECTORY/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
title_file="$BATS_TEST_TMPDIR/pr-title.txt"
files_file="$BATS_TEST_TMPDIR/pr-files.json"
repo_directory="$REPO"
EOF
  cat >> "$STUB_BINARY_DIRECTORY/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) jq -n --arg title "$(cat "$title_file")" --slurpfile files "$files_file" --arg head "$(git -C "$repo_directory" rev-parse HEAD 2>/dev/null)" \
        '{title:$title, baseRefName:"main", number:"30", files: $files[0], headRefOid:$head, headRefName:"feature", body:("<!-- gaia-pr-body-head: " + $head + " -->\n<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: " + $head + "\nNo findings.\n<!-- gaia:pr-review:end -->")}'
      exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/gh"
  add_base_lookup_to_stub
}

# Same stub, but the GAIA-Audit commit status on HEAD is present and matches, so
# check_github_status clears. Call it AFTER the commit under test: the
# description carries the frontend digest for REPO's CURRENT HEAD, computed
# through the real digest engine so it stays in lockstep with the hook.
#
# The hook queries with `gh api ... --jq`, and this stub ignores the filter and
# prints its result directly, which is the same shape every other case here
# uses. `--jq` renders a JSON string unquoted, hence the bare description line.
install_gh_stub_with_status() {
  local digest tree
  install_gh_stub "${1:-[]}"
  digest="$(member_digest_for code-audit-frontend)"
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  printf '1.4.0 %s %s\n' "$digest" "$tree" > "$BATS_TEST_TMPDIR/status-desc.txt"
  cat > "$STUB_BINARY_DIRECTORY/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
status_file="$BATS_TEST_TMPDIR/status-desc.txt"
repo_directory="$REPO"
EOF
  cat >> "$STUB_BINARY_DIRECTORY/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) jq -n --arg head "$(git -C "$repo_directory" rev-parse HEAD 2>/dev/null)" '{title:"", baseRefName:"main", number:"30", headRefOid:$head, headRefName:"feature", body:("<!-- gaia-pr-body-head: " + $head + " -->\n<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: " + $head + "\nNo findings.\n<!-- gaia:pr-review:end -->")}'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) cat "$status_file"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/gh"
  add_base_lookup_to_stub
}

# Put a well-formed GAIA-Audit trailer on HEAD: an empty commit whose message
# carries "GAIA-Audit: <version> <frontend-digest> <tree>" for the current
# frontend digest. The gate no longer reads trailers, so this fixture exists to
# prove a trailer clears nothing.
stamp_trailer() {
  local digest tree
  digest="$(member_digest_for code-audit-frontend)"
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  git -C "$REPO" commit --quiet --allow-empty \
    -m "chore: code review audit passed" \
    -m "GAIA-Audit: 1.4.0 ${digest} ${tree}"
}

# Put the real chore(deps) predicate in the sandbox's ACTING tree, which is
# where the hook resolves it from.
install_chore_deps_predicate() {
  local source_path
  source_path=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/chore-deps-skip.sh
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$source_path" "$REPO/.gaia/scripts/chore-deps-skip.sh"
  # The predicate reads the package registry through this library.
  cp "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/gaia-packages.sh"
  chmod +x "$REPO/.gaia/scripts/chore-deps-skip.sh"
}

# Assert NAME is present as a whole line in NEWLINE-separated SET.
assert_in_set() {
  local name="$1" set="$2"
  grep -qxF -- "$name" <<<"$set" || return 1
  return 0
}

# Assert NAME is absent as a whole line from NEWLINE-separated SET.
assert_not_in_set() {
  local name="$1" set="$2"
  grep -qxF -- "$name" <<<"$set" && return 1
  return 0
}

# run_case_rows <row-function>...: run each row against a fresh copy of the
# fixture setup() built (the repository, its bare origin and the scratch
# directory with the gh stub), so a case table pays setup() once instead of once
# per row. Each row runs in a subshell, so the PATH, exports and working
# directory it changes die with it. A failing assertion exits that subshell
# non-zero, which fails the table under errexit; the row line printed before it
# names the failing row. The subshell is never followed by `||`, which would
# switch errexit off inside it.
run_case_rows() {
  local snapshot="$BATS_TEST_TMPDIR/.case-row-fixture" row entry
  mkdir -p "$snapshot/scratch"
  cp -Rp "$REPO" "$snapshot/repo"
  cp -Rp "$CATCHUP_ORIGIN" "$snapshot/origin"
  for entry in "$BATS_TEST_TMPDIR"/* "$BATS_TEST_TMPDIR"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ "$entry" = "$snapshot" ] && continue
    cp -Rp "$entry" "$snapshot/scratch/"
  done
  for row in "$@"; do
    rm -rf "$REPO" "$CATCHUP_ORIGIN"
    for entry in "$BATS_TEST_TMPDIR"/* "$BATS_TEST_TMPDIR"/.[!.]*; do
      [ -e "$entry" ] || continue
      [ "$entry" = "$snapshot" ] && continue
      rm -rf "$entry"
    done
    cp -Rp "$snapshot/repo" "$REPO"
    cp -Rp "$snapshot/origin" "$CATCHUP_ORIGIN"
    for entry in "$snapshot/scratch"/* "$snapshot/scratch"/.[!.]*; do
      [ -e "$entry" ] || continue
      cp -Rp "$entry" "$BATS_TEST_TMPDIR/"
    done
    printf 'row: %s\n' "$row" >&2
    ( "$row" )
  done
}

# Row of "out-of-scope diffs allow with no marker and spawn nobody": allows a docs/metadata-only PR (wiki + .claude + .gaia)
row_allows_a_docs_metadata_only_pr_wiki_claude_gaia() {
  install_gh_stub
  # The .claude/ witness must be a path no roster member owns. Skill prose is
  # declared in `unowned:` (`.claude/skills/**/*.md`, and the roster carries
  # no prose member), which is what makes it the right witness for the
  # unaudited kind.
  # The .gaia/ file is a README for the same reason: the roster grants
  # .gaia/*.json to the shell member, so the manifest is audited metadata.
  commit_files \
    ".claude/skills/release-notes/SKILL.md" "updated" \
    "wiki/concepts/PR Merge Workflow.md" "updated" \
    ".gaia/templates/README.md" "updated"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# Row of "out-of-scope diffs allow with no marker and spawn nobody": allows a root-level markdown-only PR
row_allows_a_root_level_markdown_only_pr() {
  install_gh_stub
  commit_files "README.md" "# changed"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# Row of "out-of-scope diffs allow with no marker and spawn nobody": allows a docs-only PR under docs/
row_allows_a_docs_only_pr_under_docs() {
  install_gh_stub
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# bats test_tags=protected
@test "denies a PR that changes app/ source" {
  commit_files "apps/web/app/components/Foo/index.tsx" "export const Foo = () => null"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "roster-less or unanswerable resolver denies (case table)": a roster-less config denies with the roster named, even on a docs-only diff
row_a_roster_less_config_denies_with_the_roster_named_even_on_a() {
  # There is no fallback roster. A docs-only diff would otherwise clear on the
  # out-of-scope bypass, so this proves the roster deny runs first and names
  # its own remedy rather than the digest-batch deny's missing sha256 tool.
  install_gh_stub
  printf 'default_mode: local\n' > "$REPO/.gaia/audit-ci.yml"
  git -C "$REPO" commit --quiet -am "drop the roster"
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *'has no auditors: roster'* ]]
  [[ "$output" == *'Restore the auditors: block'* ]]
  [[ "$output" != *'sha256'* ]]
}

# Row of "in-scope diffs deny with no marker (case table)": denies a PR that changes a root config (package.json)
row_denies_a_pr_that_changes_a_root_config_package_json() {
  commit_files "package.json" '{"name":"x"}'
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "in-scope diffs deny with no marker (case table)": denies a PR that changes a root *.config.ts
row_denies_a_pr_that_changes_a_root_config_ts() {
  commit_files "vitest.config.ts" "export default {}"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "in-scope diffs deny with no marker (case table)": denies a PR mixing out-of-scope docs with in-scope source
row_denies_a_pr_mixing_out_of_scope_docs_with_in_scope_source() {
  commit_files \
    "wiki/x.md" "doc" \
    "apps/web/app/y.ts" "export const y = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "in-scope diffs deny with no marker (case table)": denies a PR that changes a CI workflow
row_denies_a_pr_that_changes_a_ci_workflow() {
  commit_files ".github/workflows/tests.yml" "name: t"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "ignores commands that are not gh pr merge" {
  commit_files "apps/web/app/y.ts" "export const y = 1"
  run_merge_hook "git status"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# No self-modification bypass: a verbatim re-render of a bundled workflow
# template is an in-scope change like any other.
# ---------------------------------------------------------------------------

# Row of "in-scope diffs deny with no marker (case table)": denies a workflow re-render whose bytes equal the bundled template
row_denies_a_workflow_re_render_whose_bytes_equal_the_bundled_te() {
  install_gh_stub
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    "wiki/log.md" "entry"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR whose only change renames a file out of app/" {
  # With rename detection on, the diff lists only the new root-level .md path,
  # which the out-of-scope bypass allowlists and no member owns, so the app/
  # source the PR removed would never reach member resolution.
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/apps/web/app"
  printf 'export const moved = "a line long enough to be detected as a rename";\n' > "$REPO/apps/web/app/moved.ts"
  git -C "$REPO" add apps/web/app/moved.ts
  git -C "$REPO" commit --quiet -m "app source on base"
  git -C "$REPO" push --quiet origin main
  git -C "$REPO" checkout --quiet -B feature main
  git -C "$REPO" mv apps/web/app/moved.ts wiki-moved.md
  git -C "$REPO" commit --quiet -m "move app source out of scope"
  run git -C "$REPO" diff --name-only -z main...HEAD
  grep -qF "apps/web/app/moved.ts" <<<"$output" && return 1
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "in-scope diffs deny with no marker (case table)": denies a second workflow alongside the matching audit re-render
row_denies_a_second_workflow_alongside_the_matching_audit_re_ren() {
  # Only the audit workflow is a permitted in-scope path; any other workflow
  # file keeps the marker mandatory.
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".github/workflows/tests.yml" "name: Tests"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "in-scope diffs deny with no marker (case table)" {
  run_case_rows \
    row_denies_a_pr_that_changes_a_root_config_package_json \
    row_denies_a_pr_that_changes_a_root_config_ts \
    row_denies_a_pr_mixing_out_of_scope_docs_with_in_scope_source \
    row_denies_a_pr_that_changes_a_ci_workflow \
    row_denies_a_workflow_re_render_whose_bytes_equal_the_bundled_te \
    row_denies_a_second_workflow_alongside_the_matching_audit_re_ren
}

# ---------------------------------------------------------------------------
# AND-aggregator (FC-5): the dispatched member set drives a per-member
# clearance requirement instead of a single OR'd signal. SEC-001/UAT-002/018:
# one cleared member can never satisfy the gate while a co-dispatched member
# withholds. DP-001/CG-004: a zero-match diff falls through to the legacy
# out-of-scope gate above, NOT an unconditional allow.
# ---------------------------------------------------------------------------

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": AND-aggregator: app-only diff allows once the frontend marker is present (regression)
row_and_aggregator_app_only_diff_allows_once_the_frontend_marker() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# bats test_tags=protected
@test "AND-aggregator: mixed app/ + .gaia .sh diff denies while the maintainer-shell member withholds" {
  commit_files \
    "apps/web/app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": AND-aggregator: mixed app/ + .gaia .sh diff allows once both dispatched members clear
row_and_aggregator_mixed_app_gaia_sh_diff_allows_once_both_dispa() {
  commit_files \
    "apps/web/app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: .gaia .sh-only diff denies without the maintainer-shell marker (sole clearance, no frontend marker needed)" {
  commit_files ".gaia/scripts/example.sh" "#!/bin/bash"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": AND-aggregator: .gaia .sh-only diff allows once the maintainer-shell marker is present
row_and_aggregator_gaia_sh_only_diff_allows_once_the_maintainer() {
  commit_files ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# The witness here must be a root path in scope that NO member claims, or the
# pair below stops exercising the zero-match legacy branch and silently becomes
# two more member-aware cases. `Dockerfile` fails that bar, since it is claimed
# by the default member. A root `Makefile` is not.
# Row of "ownerless in-scope root files deny unmarked and allow on the frontend marker (case table)": AND-aggregator: root Makefile-only diff denies without a marker (zero-match falls through to the legacy gate, not an auto-allow)
row_and_aggregator_root_makefile_only_diff_denies_without_a_mark() {
  commit_files "Makefile" "all:"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# Row of "ownerless in-scope root files deny unmarked and allow on the frontend marker (case table)": AND-aggregator: root Makefile-only diff allows once the legacy marker is present
row_and_aggregator_root_makefile_only_diff_allows_once_the_legac() {
  commit_files "Makefile" "all:"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: resolver script absent falls back to the single-signal path (no crash, same branch as zero-match)" {
  rm -f "$REPO/.gaia/scripts/resolve-audit-members.sh"
  commit_files "apps/web/app/z.ts" "export const z = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1

  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# Row of "roster-less or unanswerable resolver denies (case table)": AND-aggregator: a resolver that CANNOT answer denies instead of falling through to the legacy path
row_and_aggregator_a_resolver_that_cannot_answer_denies_instead() {
  # A non-zero resolver exit means the audited root did not resolve, which is
  # never "nothing owed". The diff below is entirely out of scope, so the
  # legacy single-signal path would ALLOW it: only the unanswerable-query deny
  # can produce a denial here, which is what makes this test discriminating.
  printf '#!/usr/bin/env bash\nexit 2\n' > "$REPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF 'resolve-audit-members.sh' <<< "$output" || return 1
}

# The regression digest keying exists for. Every dispatched member audits its
# own owned-plus-machinery content and writes its marker; code-audit-frontend
# then an EMPTY commit lands -- HEAD advances, every blob stays
# byte-identical. A member's digest is a sha256 over blob shas, so it does not
# rotate either, and no sibling member's marker is orphaned by the commit.
# Row of "digest keying: only the owning change rotates a member's digest (case table)": AND-aggregator: every member's marker survives a content-preserving empty commit (digest is content-keyed)
row_and_aggregator_every_member_s_marker_survives_a_content_pres() {
  commit_files "apps/web/app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"

  before_frontend="$(member_digest_for code-audit-frontend)"
  before_shell="$(member_digest_for code-audit-maintainer-shell)"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(member_digest_for code-audit-frontend)" = "$before_frontend" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$before_shell" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# UAT-001 (flagship): an out-of-glob-only commit rotates no member's digest,
# so every existing marker keeps validating with ZERO new marker minting at
# the merge gate.
# ---------------------------------------------------------------------------

# Row of "digest keying: only the owning change rotates a member's digest (case table)": UAT-001: an out-of-glob commit (CHANGELOG.md) leaves every digest unchanged; zero new marker
row_uat_001_an_out_of_glob_commit_changelog_md_leaves_every_dige() {
  commit_files "apps/web/app/x.ts" "export const x = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  frontend_before="$(member_digest_for code-audit-frontend)"
  shell_before="$(member_digest_for code-audit-maintainer-shell)"

  commit_files "CHANGELOG.md" "## [Unreleased]\n- entry"

  [ "$(member_digest_for code-audit-frontend)" = "$frontend_before" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$shell_before" ]

  before_pool="$(pool_snapshot)"
  run_merge_hook
  assert_allowed_by_json
  after_pool="$(pool_snapshot)"
  [ "$before_pool" = "$after_pool" ]
}

# ---------------------------------------------------------------------------
# UAT-002: a change to a file a single member owns rotates exactly that
# member's digest; every unrelated member keeps its clearance.
# ---------------------------------------------------------------------------

# Row of "digest keying: only the owning change rotates a member's digest (case table)": UAT-002: a maintainer-node-owned change rotates only that member's digest
row_uat_002_a_maintainer_node_owned_change_rotates_only_that_mem() {
  commit_files "apps/web/app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x" ".gaia/cli/src/foo.ts" "export const foo = 1"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_marker "code-audit-maintainer-node"
  frontend_before="$(member_digest_for code-audit-frontend)"
  shell_before="$(member_digest_for code-audit-maintainer-shell)"

  commit_files ".gaia/cli/src/foo.ts" "export const foo = 2"

  [ "$(member_digest_for code-audit-frontend)" = "$frontend_before" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$shell_before" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF "code-audit-frontend: CLEARED" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-shell: CLEARED" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-node: PENDING" <<< "$output" || return 1

  write_marker "code-audit-maintainer-node"
  run_merge_hook
  assert_allowed_by_json
}

# ---------------------------------------------------------------------------
# UAT-003: a gate-machinery change rotates every member's digest, so the
# full team is re-dispatched, not just the owner of the touched file.
# ---------------------------------------------------------------------------

# Row of "digest keying: only the owning change rotates a member's digest (case table)": UAT-003: a machinery-file change rotates every member's digest and re-dispatches the full team
row_uat_003_a_machinery_file_change_rotates_every_member_s_diges() {
  commit_files "apps/web/app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x" ".gaia/cli/src/foo.ts" "export const foo = 1"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_marker "code-audit-maintainer-node"

  # audit-write-clearance.sh is gate machinery, and (unlike audit-scope.sh /
  # audit-machinery.sh / audit-clearance.sh) is NOT one of the fixture copies
  # setup() places under $REPO/.claude/hooks/lib/ for the sandboxed resolver
  # scripts' own dependency resolution, so writing it here cannot clobber
  # those and break the resolver. A change to it rotates EVERY digest.
  commit_files ".gaia/scripts/audit-write-clearance.sh" "# machinery touch"

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF "code-audit-frontend: PENDING" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-shell: PENDING" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-node: PENDING" <<< "$output" || return 1
}

@test "UAT-021: the pending-members deny routes through the audit loop unit and the local-sync note names the wait script" {
  commit_files "apps/web/app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x" ".gaia/cli/src/foo.ts" "export const foo = 1"
  commit_files ".gaia/scripts/audit-write-clearance.sh" "# machinery touch"

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF "code-audit-frontend: PENDING" <<< "$output" || return 1
  grep -qF "audit-loop-unit agent" <<< "$output" || return 1
  grep -qF "pr-wait-merge.sh --pr <N>" <<< "$output" || return 1
  grep -qF "spawn each PENDING member" <<< "$output" && return 1
  grep -qF "gh pr view <N> --json state" <<< "$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# UAT-004 / C6: the gate checks the refused family before the earned family,
# so a live refusal for the current digest denies unconditionally even with a
# same-digest earned marker present.
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "UAT-004: a live refusal for the SAME digest denies even with a valid earned marker present (frontend)" {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_refused "code-audit-frontend"

  run_merge_hook
  assert_denied_by_json
}

# Row of "a live refusal at the current digest denies over any earned marker (case table)": UAT-004: refusal precedence also applies to a specialized member
row_uat_004_refusal_precedence_also_applies_to_a_specialized_mem() {
  commit_files "apps/web/app/x.ts" "export const x = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_refused "code-audit-maintainer-shell"

  run_merge_hook
  assert_denied_by_json
  grep -qF "code-audit-maintainer-shell: REFUSED" <<< "$output" || return 1
}

# ---------------------------------------------------------------------------
# The gate is light-blind: an earned marker carrying `review: light` clears a
# member exactly like a full one, keyed on the same digest, and a refusal still
# outranks it.
# ---------------------------------------------------------------------------

# Row of "light marker clears like a full one only at the current digest (case table)": light marker: an earned review-light marker at the current digest allows the merge
row_light_marker_an_earned_review_light_marker_at_the_current_di() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker_at "$REPO" "code-audit-frontend" light
  grep -qF '"review":"light"' "$REPO"/.gaia/local/audit/*.ok

  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# Row of "light marker clears like a full one only at the current digest (case table)": light marker: a light marker at a stale digest denies the merge
row_light_marker_a_light_marker_at_a_stale_digest_denies_the_mer() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker_at "$REPO" "code-audit-frontend" light
  commit_files "apps/web/app/y.ts" "export const y = 2"

  run_merge_hook
  assert_denied_by_json
}

@test "light marker clears like a full one only at the current digest (case table)" {
  run_case_rows \
    row_light_marker_an_earned_review_light_marker_at_the_current_di \
    row_light_marker_a_light_marker_at_a_stale_digest_denies_the_mer
}

# Row of "a live refusal at the current digest denies over any earned marker (case table)": light marker: a refusal at the same digest as a light earned marker denies
row_light_marker_a_refusal_at_the_same_digest_as_a_light_earned() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker_at "$REPO" "code-audit-frontend" light
  write_refused "code-audit-frontend"

  run_merge_hook
  assert_denied_by_json
}

@test "a live refusal at the current digest denies over any earned marker (case table)" {
  run_case_rows \
    row_uat_004_refusal_precedence_also_applies_to_a_specialized_mem \
    row_light_marker_a_refusal_at_the_same_digest_as_a_light_earned
}

# ---------------------------------------------------------------------------
# UAT-011: the in-scope-but-ownerless band is closed structurally by the
# frontend digest fold, not by a bespoke guard. A stale frontend marker
# (earned before an ownerless in-scope path was added) no longer validates.
# ---------------------------------------------------------------------------

# Row of "digest keying: only the owning change rotates a member's digest (case table)": UAT-011: a stale frontend marker does not clear a merge that adds an in-scope-but-ownerless root Makefile
row_uat_011_a_stale_frontend_marker_does_not_clear_a_merge_that() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "Makefile" "all:"

  run_merge_hook
  assert_denied_by_json
}

# Row of "digest keying: only the owning change rotates a member's digest (case table)": UAT-011: a stale frontend marker does not clear a merge that adds a nested ownerless public asset
row_uat_011_a_stale_frontend_marker_does_not_clear_a_merge_that_2() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "public/logo.svg" "<svg></svg>"

  run_merge_hook
  assert_denied_by_json
}

@test "digest keying: only the owning change rotates a member's digest (case table)" {
  run_case_rows \
    row_and_aggregator_every_member_s_marker_survives_a_content_pres \
    row_uat_001_an_out_of_glob_commit_changelog_md_leaves_every_dige \
    row_uat_002_a_maintainer_node_owned_change_rotates_only_that_mem \
    row_uat_003_a_machinery_file_change_rotates_every_member_s_diges \
    row_uat_011_a_stale_frontend_marker_does_not_clear_a_merge_that \
    row_uat_011_a_stale_frontend_marker_does_not_clear_a_merge_that_2
}

# ---------------------------------------------------------------------------
# FC-4 deadlock-freedom invariant: the dispatch resolver's output and the merge
# gate's clearance requirements derive from the same source of truth.
#
#   No deadlock:     write a marker for every name the resolver prints for a
#                     diff -> the hook must ALLOW. If it denies, the gate
#                     wants a marker the dispatch procedure never produces.
#   No useless spawn: withhold one spawned member's marker (all others
#                     present) -> the hook must DENY. If it allows, that
#                     member was spawned for nothing.
#
# The hazard: a zero-match dispatch does NOT auto-allow. The hook falls
# through to the legacy out-of-scope gate, which still demands the default
# member's clearance unless every changed path is on its allowlist. An
# in-scope-but-ownerless diff (root Makefile, public/**, ...) therefore
# resolves to an EMPTY dispatched set yet still DENIES without that
# clearance; the default member's own digest fold is what covers it, so its
# marker is written directly rather than through the dispatched set.
# ---------------------------------------------------------------------------

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: apps/web/app/x.tsx spawns the default member alone, and its marker allows
row_fc_4_no_deadlock_apps_web_app_x_tsx_spawns_the_default_membe() {
  commit_files "apps/web/app/x.tsx" "export const X = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: frontend tsconfig.json spawns the default member alone, and its marker allows
row_fc_4_no_deadlock_frontend_tsconfig_json_spawns_the_default_m() {
  commit_files "apps/web/tsconfig.json" '{"compilerOptions":{}}'
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: a CI workflow spawns the workflows member only (not the default), and its marker allows
row_fc_4_no_deadlock_a_ci_workflow_spawns_the_workflows_member_o() {
  commit_files ".github/workflows/ci.yml" "name: CI"
  set=$(spawn_set)
  [ "$set" = "code-audit-github-workflows" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: framework shell spawns the shell member only (not the default), and its marker allows
row_fc_4_no_deadlock_framework_shell_spawns_the_shell_member_onl() {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: framework CLI TypeScript spawns the node member only (not the default), and its marker allows
row_fc_4_no_deadlock_framework_cli_typescript_spawns_the_node_me() {
  commit_files ".gaia/cli/src/foo.ts" "export const foo = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-node" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "out-of-scope diffs allow with no marker and spawn nobody": FC-4 no-deadlock: skills prose spawns nobody (not the default), and no markers still allows
row_fc_4_no_deadlock_skills_prose_spawns_nobody_not_the_default() {
  # The prose-legibility member that used to own `.claude/skills/**/*.md` is
  # deleted (harness triage P3-09); nothing replaces its lens, so skills
  # prose is ownerless like the rest of GAIA's former prose-member territory.
  commit_files ".claude/skills/foo/SKILL.md" "# Foo skill"
  set=$(spawn_set)
  [ -z "$set" ]
  run_merge_hook
  assert_allowed_by_json
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: mixed app/ + framework shell spawns both, sorted, and their markers allow
row_fc_4_no_deadlock_mixed_app_framework_shell_spawns_both_sorte() {
  commit_files "apps/web/app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  expected=$'code-audit-frontend\ncode-audit-maintainer-shell'
  [ "$set" = "$expected" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "out-of-scope diffs allow with no marker and spawn nobody": FC-4 no-deadlock: wiki + .claude + root markdown spawns nobody, and no markers still allows
row_fc_4_no_deadlock_wiki_claude_root_markdown_spawns_nobody_and() {
  install_gh_stub
  # The .claude/ witness has to keep the spawn set EMPTY, which is what this
  # case is about, so it must be a path no roster member owns. `.claude/rules/**`
  # and `.claude/agents/code-audit-*.md` are owned by the shell member; skill
  # prose is declared in `unowned:` (`.claude/skills/**/*.md`), so a skill
  # file is the witness.
  commit_files \
    "wiki/x.md" "doc" \
    ".claude/skills/release-notes/SKILL.md" "updated" \
    "README.md" "# changed again"
  set=$(spawn_set)
  [ -z "$set" ]
  run_merge_hook
  assert_allowed_by_json
}

@test "out-of-scope diffs allow with no marker and spawn nobody" {
  run_case_rows \
    row_allows_a_docs_metadata_only_pr_wiki_claude_gaia \
    row_allows_a_root_level_markdown_only_pr \
    row_allows_a_docs_only_pr_under_docs \
    row_fc_4_no_deadlock_skills_prose_spawns_nobody_not_the_default \
    row_fc_4_no_deadlock_wiki_claude_root_markdown_spawns_nobody_and
}

# Row of "ownerless in-scope root files deny unmarked and allow on the frontend marker (case table)": FC-4 no-deadlock: a root in-scope ownerless file denies unmarked and allows once its marker is written
row_fc_4_no_deadlock_a_root_in_scope_ownerless_file_denies_unmar() {
  commit_files "Makefile" "all:"
  set=$(spawn_set)
  [ -z "$set" ]

  # The hazard, made concrete: the dispatched set is empty (nothing OWNS a root
  # Makefile), but the legacy out-of-scope gate still denies, because a root
  # file that is not *.md is in scope.
  # Writing no markers must still deny.
  #
  # Dockerfile cannot be the witness: the default member claims it, so its deny
  # would come from the member-aware branch instead.
  run_merge_hook
  assert_denied_by_json

  # An in-scope-but-ownerless path folds into the default member's own digest
  # input set, so its marker clears the gate even though the resolver never
  # named it.
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "ownerless in-scope root files deny unmarked and allow on the frontend marker (case table)": FC-4 no-deadlock: nested public/** (in-scope, ownerless) denies unmarked and allows once its marker is written
row_fc_4_no_deadlock_nested_public_in_scope_ownerless_denies_unm() {
  commit_files "public/logo.svg" "<svg></svg>"
  set=$(spawn_set)
  [ -z "$set" ]

  run_merge_hook
  assert_denied_by_json

  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
}

@test "ownerless in-scope root files deny unmarked and allow on the frontend marker (case table)" {
  run_case_rows \
    row_fc_4_no_deadlock_a_root_in_scope_ownerless_file_denies_unmar \
    row_fc_4_no_deadlock_nested_public_in_scope_ownerless_denies_unm \
    row_and_aggregator_root_makefile_only_diff_denies_without_a_mark \
    row_and_aggregator_root_makefile_only_diff_allows_once_the_legac
}

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": FC-4 no-deadlock: an ownerless in-scope file riding with a specialized member spawns the specialized member only
row_fc_4_no_deadlock_an_ownerless_in_scope_file_riding_with_a_sp() {
  # The dispatched set here is non-empty (the shell member owns y.sh), so the
  # hook takes the member-aware path and never reaches its legacy out-of-scope
  # gate: the Makefile is audited by nobody. This is the gate's own
  # documented behavior (FC-4's ownerless-plus-specialized row), not a defect.
  # Do not add the default member to the resolved set here: that would spawn
  # a member the gate does not require, breaking the no-useless-spawn half of
  # the invariant.
  #
  # The witness must be BOTH ownerless and in-scope, which is a narrow set: the
  # legacy gate allowlists wiki/, .claude/, .gaia/, docs/,
  # root *.md and three root literals outright, so none of those reaches this
  # path. A root Makefile qualifies -- no roster glob claims it and no arm of
  # the allowlist admits it.
  commit_files "Makefile" "all:" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# --- No useless spawn: withholding a spawned member's marker must deny -----

# Row of "a missing member marker denies (case table)": FC-4 no-useless-spawn: mixed diff denies while only the default member's marker is present
row_fc_4_no_useless_spawn_mixed_diff_denies_while_only_the_defau() {
  commit_files "apps/web/app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied_by_json
}

# Row of "a missing member marker denies (case table)": FC-4 no-useless-spawn: mixed diff denies with only the shell marker, then allows once both are present
row_fc_4_no_useless_spawn_mixed_diff_denies_with_only_the_shell() {
  commit_files "apps/web/app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  assert_denied_by_json

  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
}

# Row of "a missing member marker denies (case table)": FC-4 no-useless-spawn: framework-shell-only diff denies with a frontend marker instead of the shell one
row_fc_4_no_useless_spawn_framework_shell_only_diff_denies_with() {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied_by_json
}

@test "a missing member marker denies (case table)" {
  run_case_rows \
    row_fc_4_no_useless_spawn_mixed_diff_denies_while_only_the_defau \
    row_fc_4_no_useless_spawn_mixed_diff_denies_with_only_the_shell \
    row_fc_4_no_useless_spawn_framework_shell_only_diff_denies_with
}

# --- Linked-worktree anchoring (regression) ---------------------------------
#
# The gate spans two roots that are the SAME path in a plain checkout and
# DIFFERENT paths in a linked worktree, which is why a single-root derivation
# passes every test above and still deadlocks a real worktree merge:
#
#   store root  WHERE a clearance lives -- main-anchored (state registry
#               `audit-clearance-markers`, scope shared; provisioning
#               symlinks <worktree>/.gaia/local at main's).
#   tree root   WHAT the clearance attests to -- the ACTING tree, because the
#               content being merged is the worktree's HEAD, not main's.
#
# Every clearance writer keys on the acting tree (the agent definitions pass
# `--root "$(git rev-parse --show-toplevel)"`, and resolve-audit-members.sh
# derives the same way). Digesting main's HEAD in the
# gate would compare a marker against content nobody is merging: no marker
# could ever match, and the deny message's own remedy ("re-spawn the agents")
# rewrites the same non-matching marker forever.

# Provision a linked worktree of REPO on its own branch, carrying its own
# in-scope change, so its content digest necessarily differs from main's.
# Mirrors real provisioning: .gaia/local is a SYMLINK to main's, so a marker
# written from the worktree lands in main's shared store.
setup_linked_worktree() {
  LINKED_WORKTREE=$(mktemp -d -t pr-merge-wt-XXXXXX)
  rm -rf "$LINKED_WORKTREE"
  git -C "$REPO" worktree add --quiet -b wt "$LINKED_WORKTREE" main
  mkdir -p "$LINKED_WORKTREE/apps/web/app"
  printf 'export const y = 2\n' > "$LINKED_WORKTREE/apps/web/app/y.ts"
  git -C "$LINKED_WORKTREE" add apps/web/app/y.ts
  git -C "$LINKED_WORKTREE" commit --quiet -m "worktree change"

  # The dispatch resolver is anchored on the ACTING tree, and REPO's copy is
  # untracked so it does not appear in the worktree. Copy it in, as the real
  # repo always has it.
  mkdir -p "$LINKED_WORKTREE/.gaia/scripts"
  cp "$RESOLVER_ABSOLUTE_PATH" "$LINKED_WORKTREE/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$LINKED_WORKTREE/.gaia/scripts/resolve-audit-members.sh"

  mkdir -p "$REPO/.gaia/local"
  rm -rf "$LINKED_WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local" "$LINKED_WORKTREE/.gaia/local"
}

run_merge_hook_in_worktree() {
  local command_line="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg command_line "$command_line" '{tool_name: "Bash", tool_input: {command: $command_line}}')
  invoke_hook_in "$LINKED_WORKTREE" "$json" "$HOOK_ABSOLUTE_PATH"
}

teardown_linked_worktree() {
  [ -n "${LINKED_WORKTREE:-}" ] && git -C "$REPO" worktree remove --force "$LINKED_WORKTREE" 2>/dev/null
  return 0
}

# Row of "linked worktree digest keys on the acting tree (case table)": linked worktree: a marker keyed to the WORKTREE's own content allows the merge
row_linked_worktree_a_marker_keyed_to_the_worktree_s_own_content() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  setup_linked_worktree

  local digest
  digest="$(member_digest_at "$LINKED_WORKTREE" code-audit-frontend)"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":4,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$digest" "$(git -C "$LINKED_WORKTREE" rev-parse 'HEAD^{tree}')" "$(git -C "$LINKED_WORKTREE" rev-parse HEAD)" \
    > "$REPO/.gaia/local/audit/${digest}.ok"

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# Row of "linked worktree digest keys on the acting tree (case table)": linked worktree: a marker keyed to MAIN's content does NOT clear the worktree's merge
row_linked_worktree_a_marker_keyed_to_main_s_content_does_not_cl() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  setup_linked_worktree

  # Deliberately key the marker to the MAIN checkout's digest, the shape a
  # main-anchored gate would compute. The two digests must genuinely differ,
  # or this test would pass for the wrong reason.
  local main_digest worktree_digest
  main_digest="$(member_digest_at "$REPO" code-audit-frontend)"
  worktree_digest="$(member_digest_at "$LINKED_WORKTREE" code-audit-frontend)"
  [ "$main_digest" != "$worktree_digest" ]

  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":4,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$main_digest" "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$(git -C "$REPO" rev-parse HEAD)" \
    > "$REPO/.gaia/local/audit/${main_digest}.ok"

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "linked worktree digest keys on the acting tree (case table)" {
  run_case_rows \
    row_linked_worktree_a_marker_keyed_to_the_worktree_s_own_content \
    row_linked_worktree_a_marker_keyed_to_main_s_content_does_not_cl
}

# A `--repo` naming this repository is this repository wherever the merge runs
# from. Neither the worktree's directory nor REPO's is named `gaia`, so a
# comparison against a checkout's directory name reads both merges below as
# foreign and exits before any audit check.
# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": linked worktree: --repo naming this repository is still gated
row_linked_worktree_repo_naming_this_repository_is_still_gated() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git
  setup_linked_worktree

  run_merge_hook_in_worktree "gh pr merge 30 --repo gaia-react/gaia --squash --delete-branch"
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": linked worktree: a quoted --repo naming this repository is still gated
row_linked_worktree_a_quoted_repo_naming_this_repository_is_stil() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git
  setup_linked_worktree

  run_merge_hook_in_worktree 'gh pr merge 30 --repo "gaia-react/gaia" --squash --delete-branch'
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": linked worktree: a brace-expanded --repo naming this repository is still gated
row_linked_worktree_a_brace_expanded_repo_naming_this_repository() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git
  setup_linked_worktree

  run_merge_hook_in_worktree 'gh pr merge 30 --repo {gaia-react/gaia,} --squash --delete-branch'
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": linked worktree: --repo naming another repository exits before the gate
row_linked_worktree_repo_naming_another_repository_exits_before() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git
  setup_linked_worktree

  run_merge_hook_in_worktree "gh pr merge 30 --repo other-org/other-repo --squash --delete-branch"
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# gh takes its repository flag ahead of the subcommand too, and that spelling
# has to reach the gate rather than fail open past it.
# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": a repository flag ahead of the subcommand naming this repository is still gated
row_a_repository_flag_ahead_of_the_subcommand_naming_this_reposi() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git

  run_merge_hook "gh -R gaia-react/gaia pr merge 30 --squash --delete-branch"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  run_merge_hook "gh --repo=gaia-react/gaia pr merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  run_merge_hook "gh pr -R gaia-react/gaia merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  run_merge_hook "gh pr --repo gaia-react/gaia merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": a repository flag ahead of the subcommand naming another repository exits before the gate
row_a_repository_flag_ahead_of_the_subcommand_naming_another_rep() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git

  run_merge_hook "gh -R other-org/other-repo pr merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# The repo-scope verdict covers the whole tool call, so a foreign `gh` ahead of
# a home merge, even a read-only one, does not carry the merge past the gate
# (gaia-react/gaia#2081).
# Row of "a foreign command or cd in the same call never exempts a home merge (case table)": a foreign gh in the same call does not exempt a home merge
row_a_foreign_gh_in_the_same_call_does_not_exempt_a_home_merge() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git

  run_merge_hook "gh pr merge 5 -R other-org/other-repo && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  run_merge_hook "gh pr merge 5 -R other-org/other-repo; gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  run_merge_hook "gh pr view 5 -R other-org/other-repo && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# A `cd` inside a subshell moves nothing for the merge after it, so it cannot
# carry that merge past the gate as foreign.
# Row of "a foreign command or cd in the same call never exempts a home merge (case table)": a cd into another repository inside a subshell does not exempt a later home merge
row_a_cd_into_another_repository_inside_a_subshell_does_not_exem() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  local other
  other=$(mktemp -d -t merge-other-XXXXXX)
  git -C "$other" init --quiet --initial-branch=main

  run_merge_hook "(
cd $other
)
gh pr merge 30 --squash"
  rm -rf "$other"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# A comment line after `&&` does not end the list, so the `cd` after it may
# never run and the merge after that is this repository's.
# Row of "a foreign command or cd in the same call never exempts a home merge (case table)": a cd continued past a comment line after && does not exempt a later home merge
row_a_cd_continued_past_a_comment_line_after_does_not_exempt_a_l() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  local other
  other=$(mktemp -d -t merge-other-XXXXXX)
  git -C "$other" init --quiet --initial-branch=main

  run_merge_hook "false && # c
cd $other
gh pr merge 30 --squash"
  rm -rf "$other"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

@test "a foreign command or cd in the same call never exempts a home merge (case table)" {
  run_case_rows \
    row_a_foreign_gh_in_the_same_call_does_not_exempt_a_home_merge \
    row_a_cd_into_another_repository_inside_a_subshell_does_not_exem \
    row_a_cd_continued_past_a_comment_line_after_does_not_exempt_a_l
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": a call whose every command is foreign exits before the gate
row_a_call_whose_every_command_is_foreign_exits_before_the_gate() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git

  run_merge_hook "gh pr merge 5 -R other-org/other-repo && gh pr checks 5 -R other-org/other-repo"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# Row of "a --repo or -R naming this repository is still gated, another repository exits (case table)": checkout not named for the repository: --repo naming this repository is still gated
row_checkout_not_named_for_the_repository_repo_naming_this_repos() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  git -C "$REPO" remote set-url origin https://github.com/gaia-react/gaia.git

  run_merge_hook "gh pr merge 30 --repo gaia-react/gaia --squash --delete-branch"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

@test "a --repo or -R naming this repository is still gated, another repository exits (case table)" {
  run_case_rows \
    row_linked_worktree_repo_naming_this_repository_is_still_gated \
    row_linked_worktree_a_quoted_repo_naming_this_repository_is_stil \
    row_linked_worktree_a_brace_expanded_repo_naming_this_repository \
    row_linked_worktree_repo_naming_another_repository_exits_before \
    row_a_repository_flag_ahead_of_the_subcommand_naming_this_reposi \
    row_a_repository_flag_ahead_of_the_subcommand_naming_another_rep \
    row_checkout_not_named_for_the_repository_repo_naming_this_repos \
    row_a_call_whose_every_command_is_foreign_exits_before_the_gate
}

# ---------------------------------------------------------------------------
# chore(deps) bypass, allow path
#
# Every case above stubs `gh pr view` to an empty title, so the bypass never
# fires and its allow path went untested. These cover it, and the linked-
# worktree case is the reason for the third: the predicate is executable code,
# so it must be resolved from the ACTING tree. Resolving it from the main
# checkout instead looks correct in an ordinary clone, where the two are the
# same directory, and silently denies every chore(deps) merge from a linked
# worktree.
#
# The bypass requires the PR record's file list to be manifest-only alongside
# the title, so every case below states its file list explicitly.
# ---------------------------------------------------------------------------

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): a dep-bump PR with a manifest-only file list is allowed with no marker at all
row_chore_deps_a_dep_bump_pr_with_a_manifest_only_file_list_is_a() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json" "pnpm-lock.yaml"
  install_chore_deps_predicate
  commit_files "package.json" "{}"

  run_merge_hook
  assert_allowed_by_json
}

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): a dep-bump title whose PR changes app/ still requires a marker
row_chore_deps_a_dep_bump_title_whose_pr_changes_app_still_requi() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json" "apps/web/app/x.ts"
  install_chore_deps_predicate
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook
  assert_denied_by_json
}

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): a record with no files keeps the marker mandatory
row_chore_deps_a_record_with_no_files_keeps_the_marker_mandatory() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group"
  install_chore_deps_predicate
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook
  assert_denied_by_json
}

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): an ordinary PR title still requires a marker
row_chore_deps_an_ordinary_pr_title_still_requires_a_marker() {
  install_gh_stub_with_title "feat: add a thing" "[]" "package.json"
  install_chore_deps_predicate
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook
  assert_denied_by_json
}

@test "chore(deps): the bypass fires from a linked worktree, where main lacks the predicate" {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json"
  commit_files "package.json" "{}"
  setup_linked_worktree

  # The predicate lands in the WORKTREE only. REPO stands in for a main
  # checkout whose branch does not carry it, which is what origin/main looks
  # like before this change merges. A gate resolving the script from the main
  # checkout finds nothing here and denies.
  mkdir -p "$LINKED_WORKTREE/.gaia/scripts"
  cp "$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/chore-deps-skip.sh" \
    "$LINKED_WORKTREE/.gaia/scripts/chore-deps-skip.sh"
  chmod +x "$LINKED_WORKTREE/.gaia/scripts/chore-deps-skip.sh"
  mkdir -p "$LINKED_WORKTREE/.claude/hooks/lib"
  cp "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib/gaia-packages.sh" "$LINKED_WORKTREE/.claude/hooks/lib/gaia-packages.sh"
  write_builtin_descriptor "$LINKED_WORKTREE"
  [ ! -f "$REPO/.gaia/scripts/chore-deps-skip.sh" ]

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# Provenance-keyed base resolution
#
# The gate resolves its diff base through the shared provenance resolver
# (.claude/hooks/lib/audit-base-provenance.sh), which answers with a trust
# token alongside the base. An EMPTY base-to-HEAD range clears the
# out-of-scope bypass only when that trust is one this checkout could not have
# invented AND the base was taken against the pull request's own recorded base
# branch AND local HEAD is the pull request's recorded head AND the command
# being gated names that same pull request. Anything less denies. The first
# three conjuncts alone would not be enough: the gate scopes its range to local
# HEAD, and a synced default-branch checkout has an empty range against every
# pull request in the repository at once, while the record itself is read for
# the CURRENT BRANCH and so describes a pull request the gated command need
# never have named.
# ---------------------------------------------------------------------------

# Advertise refs/remotes/origin/main as the default and point it at REV, so
# the ladder's remote-minting arm resolves. Remote-tracking refs are written
# directly: they only ever need to resolve, never to fetch.
set_origin_main_at() {
  git -C "$REPO" update-ref refs/remotes/origin/main "$1"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# The gh stub with a POPULATED pull-request record: $1 is baseRefName, $2 is
# headRefOid, $3 is the pull-request number, $4 the issue list. jq builds the
# record rather than a printf format, so a value carrying a quote stays valid
# JSON instead of silently emptying a field a test is pinning, the same
# reasoning install_gh_stub_with_title gives.
#
# The number defaults to the one the default command under test merges, so a
# test that does not care about the number gets a record the gate's number
# conjunct accepts. A test that DOES care states both halves at its call site.
# The stub answers `pr` the same way whatever arguments it is handed, which is
# the point: the gate is what must tell the record's pull request from the one
# the command names.
install_gh_stub_with_record() {
  local base_reference="$1" head_oid="$2" number="${3:-30}"
  install_gh_stub "${4:-[]}"
  printf '%s' "$base_reference" > "$BATS_TEST_TMPDIR/pr-base.txt"
  printf '%s' "$head_oid" > "$BATS_TEST_TMPDIR/pr-head.txt"
  printf '%s' "$number" > "$BATS_TEST_TMPDIR/pr-number.txt"
  cat > "$STUB_BINARY_DIRECTORY/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
base_file="$BATS_TEST_TMPDIR/pr-base.txt"
head_file="$BATS_TEST_TMPDIR/pr-head.txt"
number_file="$BATS_TEST_TMPDIR/pr-number.txt"
EOF
  cat >> "$STUB_BINARY_DIRECTORY/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) jq -n --arg base "$(cat "$base_file")" --arg head "$(cat "$head_file")" \
        --arg number "$(cat "$number_file")" \
        '{title:"", baseRefName:$base, headRefOid:$head, number:$number, headRefName:"feature", body:("<!-- gaia-pr-body-head: " + $head + " -->\n<!-- gaia:pr-review:start -->\n## PR review\n\nReviewed head: " + $head + "\nNo findings.\n<!-- gaia:pr-review:end -->")}'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/gh"
  add_base_lookup_to_stub
}

# A `git` earlier on PATH than the real one that fails every `git diff` and
# forwards everything else. The failure mode under test is a diff that never
# RAN: it writes nothing to stdout, which a bare read cannot tell apart from a
# diff that ran and found nothing.
install_failing_diff_git() {
  local real
  real="$(command -v git)"
  cat > "$STUB_BINARY_DIRECTORY/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$real"
EOF
  cat >> "$STUB_BINARY_DIRECTORY/git" <<'EOF'
# Walk past git's own global options to find the subcommand: every call in the
# gate's chain spells the tree as `git -C <root> <subcommand>`, so a check on
# $1 alone would never see a diff at all. The scan runs inside a command
# substitution, which inherits the positional parameters and discards its own
# shifts, so the exec below still forwards the original argv.
subcommand="$(
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C | -c | --git-dir | --work-tree) shift 2 || break ;;
      -*) shift ;;
      *) printf '%s' "$1"; break ;;
    esac
  done
)"
if [ "$subcommand" = "diff" ]; then exit 1; fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/git"
}

# Drop `gh` from PATH entirely, taking the mirroring rebuild rather than the
# dropping one: filtering the directory out wholesale would take jq and git
# with it on a Homebrew host, where all three share a prefix
# (.gaia/tests/helpers/path.sh).
scrub_gh_from_path() {
  local rebuilt
  rebuilt="$(path_shim_without gh)"
  export PATH="$rebuilt"
}

# Run the hook with stdout and stderr kept apart, so a permit's silence on
# stdout can be asserted independently of its diagnostic line on stderr.
# invoke_hook_in merges the two.
run_merge_hook_split() {
  local command_line="${1:-gh pr merge 30 --squash --delete-branch}" json
  json=$(jq -n --arg command_line "$command_line" '{tool_name: "Bash", tool_input: {command: $command_line}}')
  run --separate-stderr bash -c 'cd "$1" && printf %s "$2" | bash "$3"' \
    _ "$REPO" "$json" "$HOOK_ABSOLUTE_PATH"
}

# A copy of the gate in the sandbox whose provenance library records the argv
# of every audit_resolve_base_provenance call before delegating to the real
# one. The copy is what makes the interception possible at all: the real hook
# resolves its libraries from its OWN on-disk location, so nothing a test puts
# in the sandbox can reach them.
install_recording_hook_copy() {
  RECORD_FILE="$BATS_TEST_TMPDIR/arbp-argv.txt"
  : > "$RECORD_FILE"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOK_ABSOLUTE_PATH" "${HOOK_ABSOLUTE_PATH%.sh}"-*.sh "$REPO/.claude/hooks/"
  cp "$LIBRARY_DIRECTORY"/*.sh "$REPO/.claude/hooks/lib/"
  # The copied gate loads the autonomy library from its own tree's .gaia/scripts
  # and denies without it, before the provenance call this copy records.
  cp "$BATS_TEST_DIRNAME/../../scripts/autonomy-lib.sh" "$BATS_TEST_DIRNAME/../../scripts/main-root-lib.sh" "$REPO/.gaia/scripts/"
  copy_review_verdict_libraries "$REPO"
  cat > "$REPO/.claude/hooks/lib/audit-base-provenance.sh" <<EOF
#!/usr/bin/env bash
. "$LIBRARY_DIRECTORY/audit-base-provenance.sh"
_base_provenance_call_record="$RECORD_FILE"
EOF
  cat >> "$REPO/.claude/hooks/lib/audit-base-provenance.sh" <<'EOF'
eval "_original_audit_resolve_base_provenance() $(declare -f audit_resolve_base_provenance | tail -n +2)"
audit_resolve_base_provenance() {
  printf 'supplied=[%s]\n' "${3-}" >> "$_base_provenance_call_record"
  _original_audit_resolve_base_provenance "$@"
}
EOF
}

run_recording_hook() {
  local json
  json=$(jq -n --arg command_line "gh pr merge 30 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $command_line}}')
  invoke_hook_in "$REPO" "$json" "$REPO/.claude/hooks/pr-merge-audit-check.sh"
}

@test "an empty range on a remote-verified record base at the recorded head permits silently, with the reason on stderr" {
  # setup() leaves feature at main's tip, so the base-to-HEAD range is empty
  # by construction rather than by an emptied diff.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head"

  run_merge_hook_split
  [ "$status" -eq 0 ]
  # No JSON at all. The permit keeps the shape every other permit in this hook
  # has: a silent zero exit, never a permissionDecision emission.
  [ -z "$output" ]
  # The reason is one stderr line. The other is the bypass status attempt,
  # which this stub cannot complete (its record carries no head for the stamp
  # to read back); bypass-audit-stamp.bats owns that POST.
  [ "$(printf '%s\n' "$stderr" | grep -c 'range is empty')" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -vc -e 'range is empty' -e 'GAIA-Audit bypass status not posted')" -eq 0 ]
  grep -qF 'remote provenance' <<<"$stderr" || return 1
  grep -qF 'anchor pr-record' <<<"$stderr" || return 1
}

@test "the gate emits no permissionDecision allow at all" {
  merge_gate_text "$HOOK_ABSOLUTE_PATH" | grep -qF 'permissionDecision: "allow"' && return 1
  true
}

@test "an empty range on a locally-derived base denies, and the reason names the local provenance" {
  # No remote-tracking refs at all, so the record's branch cannot verify and
  # the ladder falls to the bare local branch name.
  git -C "$REPO" update-ref -d refs/remotes/origin/main
  git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"

  run_merge_hook
  assert_denied_by_json
  grep -qF 'Diff base:' <<<"$output" || return 1
  grep -qF 'local provenance' <<<"$output" || return 1
  grep -qF 'anchor default-branch' <<<"$output" || return 1
}

# Row of "a cached audit base differing from the record's denies, equal does not (case table)": a cached audit base that differs from the record's base denies, naming the git config --unset recovery
row_a_cached_audit_base_that_differs_from_the_record_s_base_deni() {
  install_gh_stub
  # A recorded head other than local HEAD keeps the empty-range permit from
  # clearing the merge ahead of the stale-cache check.
  printf '%040d' 0 > "$BATS_TEST_TMPDIR/pr-head-override"
  git -C "$REPO" config branch.feature.gaia-audit-base release

  run_merge_hook
  assert_denied_by_json
  grep -qF 'git config --unset branch.feature.gaia-audit-base' <<<"$output" || return 1
}

# Row of "a cached audit base differing from the record's denies, equal does not (case table)": a cached audit base equal to the record's base does not trigger the stale-cache deny
row_a_cached_audit_base_equal_to_the_record_s_base_does_not_trig() {
  install_gh_stub
  git -C "$REPO" config branch.feature.gaia-audit-base main

  run_merge_hook
  grep -qF 'gaia-audit-base' <<<"$output" && return 1
  true
}

@test "a cached audit base differing from the record's denies, equal does not (case table)" {
  run_case_rows \
    row_a_cached_audit_base_that_differs_from_the_record_s_base_deni \
    row_a_cached_audit_base_equal_to_the_record_s_base_does_not_trig
}

@test "an unresolvable base denies, and the reason names it as unresolvable" {
  local repo
  repo="$(make_no_base_repo_pr provenance-no-base)"
  install_gh_stub
  # The base ladder cannot resolve in this repository, but the tip GitHub
  # reports is a commit it holds, so the digests derive and the legacy deny
  # (which prints the ladder's answer) is the one reached.
  export GH_STUB_BASE_TIP
  GH_STUB_BASE_TIP="$(git -C "$repo" rev-parse HEAD)"

  run_merge_hook_at "$repo"
  assert_denied_by_json
  grep -qF 'unresolvable provenance' <<<"$output" || return 1
  grep -qF 'base unresolved' <<<"$output" || return 1
}

# Row of "empty range permits only when every conjunct holds (case table)": a synced default-branch checkout denies gh pr merge for a pull request it is not on (no record)
row_a_synced_default_branch_checkout_denies_gh_pr_merge_for_a_pu() {
  # The reproduced hole: on a synced default branch merge-base(HEAD,
  # refs/remotes/origin/main) IS HEAD, so the range holds zero files on remote
  # provenance. Nothing in the command being gated says which pull request 999
  # is, so a range-only rule would clear an arbitrary unaudited one.
  git -C "$REPO" checkout --quiet main
  set_origin_main_at refs/heads/main
  install_gh_stub

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": a synced default-branch checkout denies even when the record answers with this checkout's own head sha
row_a_synced_default_branch_checkout_denies_even_when_the_record() {
  # Isolates the anchor conjunct: trust is remote and the recorded head sha
  # matches local HEAD, so only "the base was taken against the pull request's
  # own recorded base branch" stands between this and a permit.
  git -C "$REPO" checkout --quiet main
  set_origin_main_at refs/heads/main
  install_gh_stub_with_record "" "$(git -C "$REPO" rev-parse HEAD)" 999

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range on a record base denies when the recorded head sha is not local HEAD
row_an_empty_range_on_a_record_base_denies_when_the_recorded_hea() {
  # Isolates the head-sha conjunct: anchor and trust both qualify, and the
  # checkout is simply not on the pull request being merged.
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "0000000000000000000000000000000000000001" 999

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies when the command names a pull request other than the record's
row_an_empty_range_denies_when_the_command_names_a_pull_request() {
  # Isolates the number conjunct: trust, anchor and head sha all qualify, so
  # the ONLY thing between this and the permit its sibling above earns is that
  # the record describes pull request 30 and the command merges 999. The
  # record is read for the current branch, so nothing but this conjunct ever
  # looks at the number the command names.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies when the command names a target the gate cannot confirm
row_an_empty_range_denies_when_the_command_names_a_target_the_ga() {
  # `gh pr merge` also accepts a branch and a URL. Both resolve to a number
  # only through a network read this gate does not make, so an unconfirmable
  # target takes the deny rather than the relaxation. A separated option value
  # reads as the positional for the same reason and lands in the same place.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge feature --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge https://github.com/gaia-react/gaia/pull/30"
  assert_denied_by_json

  # A single-dash cluster is a shape the shared scanner declines to model,
  # because pflag reads it letter by letter and the first value-taking
  # shorthand in it swallows the rest. An unmodelled shape denies.
  run_merge_hook "gh pr merge -sd 30"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies when a separated option value is the record's own number
row_an_empty_range_denies_when_a_separated_option_value_is_the_r() {
  # The defect this pins: skipping options by their leading dash alone reads a
  # value-taking flag's SEPARATED value as the positional. Every spelling below
  # hands the record's number to a flag and merges 999, so a scanner that does
  # not model the flag set compares the flag's value equal to the record and
  # permits a merge of an entirely unaudited pull request.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge --body 30 999 --squash"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range still permits when a separated option value sits beside the record's own number
row_an_empty_range_still_permits_when_a_separated_option_value_s() {
  # The complement of the test above, and what keeps its deny from being
  # trivially satisfied by "any command carrying a flag value denies": the same
  # flag shapes with the RECORD's number as the real positional still permit,
  # so the scanner is reading the positional rather than refusing the shape.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge --body 999 30 --squash"
  assert_allowed_by_json

  run_merge_hook "gh pr merge --subject=999 30 --squash"
  assert_allowed_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies anything at all following the merge in the same command
row_an_empty_range_denies_anything_at_all_following_the_merge_in() {
  # One tool call, two merges: the first names the record's pull request and
  # the second an arbitrary one. Reading the first reference and permitting
  # would clear both, so the relaxation requires the merge to be the whole
  # command.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge 30 --squash; gh pr merge 999 --squash"
  assert_denied_by_json

  # Not a second merge at all, and it still denies: the relaxation cannot
  # account for what runs beside it, so it refuses rather than read the rest
  # approximately.
  run_merge_hook "gh pr merge 30 --squash && echo done"
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies a second merge smuggled in through an expansion
row_an_empty_range_denies_a_second_merge_smuggled_in_through_an() {
  # The class a word-level tokenizer cannot report. An expansion is ordinary
  # word text to a scan that models words, so the scan reaches the end of the
  # string having found no separator at all while the shell runs the payload
  # FIRST: the piggybacked merge lands before the permitted one. Every spelling
  # below names the record's own pull request as the real positional, so the
  # four conjuncts above are satisfied and only this guard stands between them
  # and a permit.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook 'gh pr merge --body "$(gh pr merge 999 --squash)" 30 --squash'
  assert_denied_by_json
}

# Row of "empty range permits only when every conjunct holds (case table)": an empty range denies when the merge is not the first command in the tool call
row_an_empty_range_denies_when_the_merge_is_not_the_first_comman() {
  # The shared scanner reads the FIRST command and abstains otherwise, because
  # whatever sits ahead of a merge decides which repository and which checkout
  # it lands in. An abstention denies here rather than being read approximately.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "echo ready && gh pr merge 30 --squash"
  assert_denied_by_json
}

@test "empty range permits only when every conjunct holds (case table)" {
  run_case_rows \
    row_a_synced_default_branch_checkout_denies_gh_pr_merge_for_a_pu \
    row_a_synced_default_branch_checkout_denies_even_when_the_record \
    row_an_empty_range_on_a_record_base_denies_when_the_recorded_hea \
    row_an_empty_range_denies_when_the_command_names_a_pull_request \
    row_an_empty_range_denies_when_the_command_names_a_target_the_ga \
    row_an_empty_range_denies_when_a_separated_option_value_is_the_r \
    row_an_empty_range_still_permits_when_a_separated_option_value_s \
    row_an_empty_range_denies_anything_at_all_following_the_merge_in \
    row_an_empty_range_denies_a_second_merge_smuggled_in_through_an \
    row_an_empty_range_denies_when_the_merge_is_not_the_first_comman
}

@test "a non-empty dispatched member set still denies while a member withholds, on remote provenance at the recorded head" {
  commit_files \
    "apps/web/app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  set_origin_main_at refs/heads/main
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"
  write_marker "code-audit-frontend"

  run_merge_hook
  assert_denied_by_json
  grep -qF "code-audit-maintainer-shell: PENDING" <<<"$output" || return 1
}

@test "a diff that never ran never reaches the permit arm" {
  # The resolver copy is removed so the legacy path runs: a failing git would
  # otherwise make the member query unanswerable, and that deny would mask the
  # one under test.
  rm -f "$REPO/.gaia/scripts/resolve-audit-members.sh"
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head"

  # Positive control: with a working git this exact fixture permits, so the
  # denial below is the failed diff and nothing else.
  run_merge_hook
  assert_allowed_by_json

  install_failing_diff_git
  run_merge_hook
  assert_denied_by_json
}

@test "every audit_resolve_base_provenance invocation at run time passes an empty supplied base" {
  install_recording_hook_copy
  commit_files "apps/web/app/x.ts" "export const x = 1"
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"

  run_recording_hook
  assert_denied_by_json
  [ -s "$RECORD_FILE" ]
  grep -v -x 'supplied=\[\]' "$RECORD_FILE" > "$BATS_TEST_TMPDIR/arbp-bad.txt" || true
  [ ! -s "$BATS_TEST_TMPDIR/arbp-bad.txt" ]
}

@test "the base comes from the remote-tracking ref, not a local branch literally named origin/main" {
  # git resolves the bare revspec origin/main through refs/heads/ before
  # refs/remotes/, so a local branch of that name would supply the base while
  # refs/remotes/origin/main still verifies -- remote trust minted for a purely
  # local base. The fully-qualified spelling is what forecloses it, and this
  # checkout is where the two spellings answer differently.
  local remote_base shadow_tip
  remote_base="$(git -C "$REPO" rev-parse HEAD)"
  commit_files "docs/note.md" "a commit only the shadowing local branch carries"
  shadow_tip="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" branch "origin/main" "$shadow_tip"
  commit_files "Makefile" "all:"
  set_origin_main_at "$remote_base"
  install_gh_stub

  run_merge_hook
  assert_denied_by_json
  grep -qF "base ${remote_base:0:12}" <<<"$output" || return 1
  grep -qF "base ${shadow_tip:0:12}" <<<"$output" && return 1
  true
}

# Row of "the gate denies with JSON when gh is absent or has no record (case table)": the gate denies with well-formed JSON when gh is absent from PATH entirely
row_the_gate_denies_with_well_formed_json_when_gh_is_absent_from() {
  # resolve_pr_record returns at its `command -v gh` guard, before any field
  # assignment. Every reader of a record field must survive that under set -u,
  # or the hook dies and emits nothing at all where it owes a deny.
  set_origin_main_at refs/heads/feature
  scrub_gh_from_path
  [ -z "$(command -v gh)" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
}

# Row of "the gate denies with JSON when gh is absent or has no record (case table)": the gate denies with well-formed JSON when gh answers with no record at all
row_the_gate_denies_with_well_formed_json_when_gh_answers_with_n() {
  # The other early return: gh exists, and there is no pull request for this
  # branch. Same obligation, reached one line later.
  set_origin_main_at refs/heads/feature
  install_gh_stub
  cat > "$STUB_BINARY_DIRECTORY/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  pr) exit 1 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BINARY_DIRECTORY/gh"

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
}

@test "the gate denies with JSON when gh is absent or has no record (case table)" {
  run_case_rows \
    row_the_gate_denies_with_well_formed_json_when_gh_is_absent_from \
    row_the_gate_denies_with_well_formed_json_when_gh_answers_with_n
}

# ---------------------------------------------------------------------------
# Arming: which command shapes reach the gate at all
#
# The gate arms on the UNION of a literal text match and a tokenizer read of the
# tool call's first command, because each arm reaches a spelling the other
# cannot. Every case below is an in-scope diff with no marker, so ARMED means
# denied and NOT ARMED means a silent exit 0. The inversion is the point: a case
# here asserting a deny is asserting that the gate ran at all.
# ---------------------------------------------------------------------------

# Row of "arming: which command shapes reach the gate (case table)": arming: a merge that is not the first command still reaches the gate
row_arming_a_merge_that_is_not_the_first_command_still_reaches_t() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  # Invisible to the tokenizer arm, which reads the first command and stops.
  # Swapping the text arm out for the tokenizer, rather than unioning the two,
  # would turn this deny into a silent permit.
  run_merge_hook "echo hi && gh pr merge 30 --squash"
  assert_denied_by_json
}

# Row of "arming: which command shapes reach the gate (case table)": arming: a non-merge command carrying the word merge does not arm the gate
row_arming_a_non_merge_command_carrying_the_word_merge_does_not() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  # A command whose first word cannot reach `gh` must not arm the gate, and the
  # pre-filter is what turns this one away before the scan ever runs. For the
  # case that does reach the scan and abstains there, see the large-payload test
  # below, whose fixture is a real `gh` whose word 1 is not `pr`.
  run_merge_hook "git merge --no-ff main"
  assert_allowed_by_json
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Every clearing arm binds to the pull request the command names
#
# Three arms can clear a merge off a record `gh pr view` reads for the CURRENT
# BRANCH: chore(deps), out-of-scope, and the empty range. The empty range's
# binding is covered above; these cover the other two.
#
# Each is a PAIR, and the pairing is load-bearing. A mismatch case alone goes
# green on a conjunct that denies unconditionally, which is a bypass that no
# longer exists rather than one that binds; the no-positional case is what
# proves the arm still clears the pull request it is meant to.
# ---------------------------------------------------------------------------

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): the bypass denies a merge naming a pull request other than the record's
row_chore_deps_the_bypass_denies_a_merge_naming_a_pull_request_o() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json"
  install_chore_deps_predicate
  commit_files "package.json" "{}"

  # The record describes pull request 30. A dep-bump title on THIS branch says
  # nothing about 999, which no local quality gate pre-verified. The record's
  # file list is manifest-only, so this denies on the naming mismatch alone,
  # not vacuously on an empty or non-manifest list.
  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)": chore(deps): the bypass still fires when the command names no pull request
row_chore_deps_the_bypass_still_fires_when_the_command_names_no() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json"
  install_chore_deps_predicate
  commit_files "package.json" "{}"

  # gh resolves an absent positional to the current branch, which is the very
  # pull request the record was read for, so the turnkey spelling keeps clearing.
  run_merge_hook "gh pr merge --squash --delete-branch"
  assert_allowed_by_json
}

@test "chore(deps) bypass allows only a manifest-only record bound to the named pull request (case table)" {
  run_case_rows \
    row_chore_deps_a_dep_bump_pr_with_a_manifest_only_file_list_is_a \
    row_chore_deps_a_dep_bump_title_whose_pr_changes_app_still_requi \
    row_chore_deps_a_record_with_no_files_keeps_the_marker_mandatory \
    row_chore_deps_an_ordinary_pr_title_still_requires_a_marker \
    row_chore_deps_the_bypass_denies_a_merge_naming_a_pull_request_o \
    row_chore_deps_the_bypass_still_fires_when_the_command_names_no
}

# bats test_tags=protected
@test "out-of-scope: the bypass denies a merge naming a pull request other than the record's" {
  install_gh_stub
  commit_files "wiki/x.md" "doc"

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": out-of-scope: the bypass still fires when the command names no pull request
row_out_of_scope_the_bypass_still_fires_when_the_command_names_n() {
  install_gh_stub
  commit_files "wiki/x.md" "doc"

  run_merge_hook "gh pr merge --squash --delete-branch"
  assert_allowed_by_json
}

# ---------------------------------------------------------------------------
# A bypass whose content qualifies but whose command does not bind
#
# When every path qualifies for a bypass and only the command binding fails,
# the merge still denies, but the reason must say so and name the spelling that
# binds. The generic marker deny claims the pull request "changes at least one
# in-scope path", which is false here, and its
# remedy (run the audit loop) spends a verification run and an audit round on
# a diff that owes no marker.
# ---------------------------------------------------------------------------

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: a lone merge of a .gaia-only pull request bypasses
row_unbound_bypass_a_lone_merge_of_a_gaia_only_pull_request_bypa() {
  install_gh_stub
  commit_files ".gaia/audit-residual-dismissals.jsonl" "{}"

  run_merge_hook "gh pr merge 30 --squash --delete-branch --auto"
  assert_allowed_by_json
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: a compound merge of a .gaia-only pull request names the binding and the lone spelling
row_unbound_bypass_a_compound_merge_of_a_gaia_only_pull_request() {
  install_gh_stub
  commit_files ".gaia/audit-residual-dismissals.jsonl" "{}"

  run_merge_hook "cd /tmp; gh pr merge 30 --squash --delete-branch --auto; echo done"
  assert_denied_by_json
  grep -qF -- "could not bind the merge command" <<<"$output" || return 1
  grep -qF -- "gh pr merge 30 --squash --delete-branch" <<<"$output" || return 1
  grep -qF -- "at least one in-scope path" <<<"$output" && return 1
  return 0
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: a piped merge of a .gaia-only pull request names the binding and the lone spelling
row_unbound_bypass_a_piped_merge_of_a_gaia_only_pull_request_nam() {
  install_gh_stub
  commit_files ".gaia/audit-residual-dismissals.jsonl" "{}"

  run_merge_hook "gh pr merge 30 --squash --delete-branch | tail -5"
  assert_denied_by_json
  grep -qF -- "could not bind the merge command" <<<"$output" || return 1
  grep -qF -- "at least one in-scope path" <<<"$output" && return 1
  return 0
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: a compound merge of a mixed diff keeps the marker deny
row_unbound_bypass_a_compound_merge_of_a_mixed_diff_keeps_the_ma() {
  install_gh_stub
  commit_files \
    "wiki/x.md" "doc" \
    "apps/web/app/y.ts" "export const y = 1"

  run_merge_hook "cd /tmp; gh pr merge 30 --squash"
  assert_denied_by_json
  grep -qF -- "could not bind the merge command" <<<"$output" && return 1
  return 0
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: a compound merge of a chore(deps) manifest-only pull request names the binding
row_unbound_bypass_a_compound_merge_of_a_chore_deps_manifest_onl() {
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json"
  install_chore_deps_predicate
  commit_files "package.json" "{}"

  run_merge_hook "cd /tmp; gh pr merge 30 --squash"
  assert_denied_by_json
  grep -qF -- "could not bind the merge command" <<<"$output" || return 1
  grep -qF -- "chore(deps)" <<<"$output" || return 1
  grep -qF -- "PR title does not match" <<<"$output" && return 1
  return 0
}

# Row of "out-of-scope bypass binds to the named pull request (case table)": unbound bypass: the chore(deps) binding deny also holds on the single-signal path
row_unbound_bypass_the_chore_deps_binding_deny_also_holds_on_the() {
  # With the member resolver absent the gate takes the single-signal path, which
  # carries its own copy of the deny; the case above drives the member-aware one.
  rm -f "$REPO/.gaia/scripts/resolve-audit-members.sh"
  install_gh_stub_with_title "chore(deps): bump the github-actions group" "[]" "package.json"
  install_chore_deps_predicate
  commit_files "package.json" "{}"

  run_merge_hook "cd /tmp; gh pr merge 30 --squash"
  assert_denied_by_json
  grep -qF -- "could not bind the merge command" <<<"$output" || return 1
  grep -qF -- "PR title does not match" <<<"$output" && return 1
  return 0
}

@test "out-of-scope bypass binds to the named pull request (case table)" {
  run_case_rows \
    row_out_of_scope_the_bypass_still_fires_when_the_command_names_n \
    row_unbound_bypass_a_lone_merge_of_a_gaia_only_pull_request_bypa \
    row_unbound_bypass_a_compound_merge_of_a_gaia_only_pull_request \
    row_unbound_bypass_a_piped_merge_of_a_gaia_only_pull_request_nam \
    row_unbound_bypass_a_compound_merge_of_a_mixed_diff_keeps_the_ma \
    row_unbound_bypass_a_compound_merge_of_a_chore_deps_manifest_onl \
    row_unbound_bypass_the_chore_deps_binding_deny_also_holds_on_the
}

# --- Clearance binding: the merge names the pull request the clearance is for
#
# A clearance signal proves a property of THIS CHECKOUT's content: a member's
# own content-digest marker and a GAIA-Audit commit
# status on HEAD's sha. Neither of them reads the pull-request reference the gated
# `gh pr merge` carries, so on a branch whose dispatched members have all
# cleared, `gh pr merge <other-number>` used to be permitted and merged a pull
# request nothing here audited (gaia-react/gaia#1544). The three record-based
# bypasses above already asked that question at their own sites; these cases pin
# it at the two permit sites, which is where a clearance becomes a merge.
#
# Each case pins one signal independently. The permit-site guard covers all of
# them with one call today, but a future change that pushes the question back
# down into the individual signals must not reopen one of them silently.

# bats test_tags=protected
@test "clearance: a frontend marker denies a merge naming a pull request other than the record's" {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # The marker proves a member read THIS content. It says nothing about 999.
  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a frontend marker still clears a merge naming the record's own number
row_clearance_a_frontend_marker_still_clears_a_merge_naming_the() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  run_merge_hook "gh pr merge 30 --squash --delete-branch"
  assert_allowed_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a frontend marker still clears when the command names no pull request
row_clearance_a_frontend_marker_still_clears_when_the_command_na() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # gh resolves an absent positional to the current branch, which is the very
  # pull request the record was read for.
  run_merge_hook "gh pr merge --squash --delete-branch"
  assert_allowed_by_json
}

# A trailer on HEAD is not a clearance signal. With a well-formed trailer for the
# current digest and no marker, status or clearance, the gate denies with its
# ordinary no-signal text, which names no trailer.
@test "clearance: a GAIA-Audit trailer on HEAD alone denies a merge, even naming the record's own number" {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  stamp_trailer
  [ -n "$(git -C "$REPO" log -1 --format=%B | git -C "$REPO" interpret-trailers --parse | grep '^GAIA-Audit:')" ]

  run_merge_hook "gh pr merge 30 --squash"
  assert_denied_by_json
  grep -qi 'trailer' <<<"$output" && return 1
  grep -qF "pr-wait-merge.sh --pr <N>" <<<"$output" || return 1
  grep -qF "gh pr view <N> --json state" <<<"$output" && return 1
  return 0
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a GAIA-Audit CI status denies a merge naming a pull request other than the record's
row_clearance_a_gaia_audit_ci_status_denies_a_merge_naming_a_pul() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  install_gh_stub_with_status

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a GAIA-Audit CI status still clears a merge naming the record's own number
row_clearance_a_gaia_audit_ci_status_still_clears_a_merge_naming() {
  commit_files "apps/web/app/x.ts" "export const x = 1"
  install_gh_stub_with_status

  run_merge_hook "gh pr merge 30 --squash"
  assert_allowed_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a specialized member's marker denies a merge naming a pull request other than the record's
row_clearance_a_specialized_member_s_marker_denies_a_merge_namin() {
  install_gh_stub
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  write_markers_for_spawn_set "$set"

  # The specialized-member path clears through its own marker rather than
  # frontend_cleared, so it is a distinct permit route to the same exit 0.
  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a specialized member's marker still clears when the command names no pull request
row_clearance_a_specialized_member_s_marker_still_clears_when_th() {
  install_gh_stub
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  write_markers_for_spawn_set "$(spawn_set)"

  run_merge_hook "gh pr merge --squash --delete-branch"
  assert_allowed_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: a merge naming an unconfirmable target denies even with every marker present
row_clearance_a_merge_naming_an_unconfirmable_target_denies_even() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # A branch name is not a number, and resolving one costs a second network
  # read, so the gate denies rather than confirm it. Same rule the record-based
  # bypasses already apply.
  run_merge_hook "gh pr merge my-branch --squash"
  assert_denied_by_json
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: the legacy permit site binds when the dispatched set is empty
row_clearance_the_legacy_permit_site_binds_when_the_dispatched_s() {
  install_gh_stub
  # Every other case here commits an owned path, so the dispatched set is
  # non-empty and they all exit through the AND-aggregator. The legacy
  # single-signal gate is reached only on an EMPTY dispatched set, and it is a
  # second permit site with its own call: without this case, deleting that call
  # left the whole suite green.
  commit_files "wiki/x.md" "# x"
  [ -z "$(spawn_set)" ]
  write_marker "code-audit-frontend"

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
  grep -qF -- "does not name the pull request" <<<"$output"
}

# Row of "clearance permits bind to the pull request the merge names (case table)": clearance: the legacy permit site still clears the record's own number
row_clearance_the_legacy_permit_site_still_clears_the_record_s_o() {
  install_gh_stub
  commit_files "wiki/x.md" "# x"
  [ -z "$(spawn_set)" ]
  write_marker "code-audit-frontend"

  run_merge_hook "gh pr merge 30 --squash"
  assert_allowed_by_json
}

@test "clearance permits bind to the pull request the merge names (case table)" {
  run_case_rows \
    row_clearance_a_frontend_marker_still_clears_a_merge_naming_the \
    row_clearance_a_frontend_marker_still_clears_when_the_command_na \
    row_clearance_a_gaia_audit_ci_status_denies_a_merge_naming_a_pul \
    row_clearance_a_gaia_audit_ci_status_still_clears_a_merge_naming \
    row_clearance_a_specialized_member_s_marker_denies_a_merge_namin \
    row_clearance_a_specialized_member_s_marker_still_clears_when_th \
    row_clearance_a_merge_naming_an_unconfirmable_target_denies_even \
    row_clearance_the_legacy_permit_site_binds_when_the_dispatched_s \
    row_clearance_the_legacy_permit_site_still_clears_the_record_s_o
}

# Row of "binding deny reason names the right cause (case table)": clearance: the deny reads the record rather than reporting it unread
row_clearance_the_deny_reads_the_record_rather_than_reporting_it() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # A quoted flag value is outside the byte allowlist, so the predicate abstains
  # ABOVE its own record read. The reason must still name the pull request this
  # checkout is on, or it sends the operator after gh auth for a record that is
  # perfectly healthy.
  run_merge_hook 'gh pr merge 30 --squash --subject "chore: x"'
  assert_denied_by_json
  grep -qF -- "names the right pull request (30)" <<<"$output"
  grep -qF -- "no pull-request record" <<<"$output" && return 1
  return 0
}

# Row of "binding deny reason names the right cause (case table)": clearance: a readable command naming the right number blames the spelling, not the target
row_clearance_a_readable_command_naming_the_right_number_blames() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # The reference IS the record's, so the target was never the problem: the
  # gate abstained at the byte allowlist, above the comparison that would have
  # passed. The mismatch headline would be false here, and its remedy would
  # prescribe the very command that just denied.
  run_merge_hook 'gh pr merge 30 --squash --subject "chore: x"'
  assert_denied_by_json
  grep -qF -- "how the command is spelled, not what it targets" <<<"$output"
  grep -qF -- "naming 30 again is the one repair that" <<<"$output"
  grep -qF -- "does not name the pull request that clearance is for" <<<"$output" && return 1
  return 0
}

# Row of "binding deny reason names the right cause (case table)": clearance: an unreadable command with no number blames the spelling, not the target
row_clearance_an_unreadable_command_with_no_number_blames_the_sp() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # No positional AND unreadable: the gate established no target at all, so the
  # mismatch headline would point at a target the operator probably got right,
  # and its remedy would offer the very no-number spelling they just used. The
  # `<unreadable>` sentinel never equals a record, so a split keyed on the
  # comparison alone routes this to the wrong arm.
  run_merge_hook 'gh pr merge --squash --subject "chore: x"'
  assert_denied_by_json
  grep -qF -- "cannot read the merge command well enough" <<<"$output"
  grep -qF -- "no target this gate could read" <<<"$output"
  grep -qF -- "does not name the pull request that clearance is for" <<<"$output" && return 1
  return 0
}

# Row of "binding deny reason names the right cause (case table)": clearance: a genuine mismatch still gets the mismatch headline, not the spelling one
row_clearance_a_genuine_mismatch_still_gets_the_mismatch_headlin() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # The counterpart control: the two arms must not collapse into one.
  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
  grep -qF -- "does not name the pull request that clearance is for" <<<"$output"
  grep -qF -- "how the command is spelled, not what it targets" <<<"$output" && return 1
  return 0
}

# Row of "binding deny reason names the right cause (case table)": clearance: the deny says a clearance does not lift it, rather than sending the operator back to the audit
row_clearance_the_deny_says_a_clearance_does_not_lift_it_rather() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
  # "keeps the marker mandatory" is true where the binding is a relaxation
  # conjunct on a bypass; here the marker is already present and re-earning it
  # changes nothing, so that wording would loop the operator forever.
  grep -qF -- "UNCONDITIONAL" <<<"$output"
  grep -qF -- "keep the marker mandatory" <<<"$output" && return 1
  return 0
}

# Row of "binding deny reason names the right cause (case table)": clearance: the deny names the binding rather than reporting the signal missing
row_clearance_the_deny_names_the_binding_rather_than_reporting_t() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
  # The marker IS present, so a "no signal for HEAD" reason would send the
  # operator to re-spawn the audit forever. The reason must name the mismatch.
  grep -qF -- '999' <<<"$output"
}

@test "binding deny reason names the right cause (case table)" {
  run_case_rows \
    row_clearance_the_deny_reads_the_record_rather_than_reporting_it \
    row_clearance_a_readable_command_naming_the_right_number_blames \
    row_clearance_an_unreadable_command_with_no_number_blames_the_sp \
    row_clearance_a_genuine_mismatch_still_gets_the_mismatch_headlin \
    row_clearance_the_deny_says_a_clearance_does_not_lift_it_rather \
    row_clearance_the_deny_names_the_binding_rather_than_reporting_t
}

@test "arming: a large non-merge command does not pay an unbounded scan" {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  # Pins the CLASS of regression, not a constant. The arming scan walks bytes and
  # slices per block, so its cost grows faster than its input, and every `gh`
  # invocation reaches it, so an unbounded scan put a synchronous stall on
  # ordinary Bash tool calls: 3s at 32KB and ~40s at the 128KB used here, against
  # ~60ms for the same size starting with another letter. A bounded prefix
  # flattens it to ~100ms at any size. The ceiling below sits far above the bounded cost and far below the
  # unbounded one, so it separates the two robustly without pinning either
  # machine's timing; a shared runner being slow cannot red it, and only losing
  # the bound can.
  # The fixture must start `gh `, not just `g`: the pre-filter admits only a
  # command whose first word can tokenize to `gh`, so a `gx...` string is turned
  # away before the scan and the case would pass no matter what the bound does.
  # It still never arms, since word 1 is not `pr`, which is the point: this is
  # the near-miss that pays the full scan.
  local big start elapsed
  big="gh $(head -c 131072 < /dev/zero | tr '\0' 'x')"

  start=$SECONDS
  run_merge_hook_large "$big"
  elapsed=$(( SECONDS - start ))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 10 ]
}

# ---------------------------------------------------------------------------
# Arming: the shared data-proof (heredoc masking) and its abstentions
#
# gaia_verb_armed's raw match (the union above) is unchanged; these cases
# exercise the SAME-LENGTH VIEW it builds on a raw hit, which suppresses a
# heredoc body proven to be data before re-testing the raw patterns, and the
# conditions under which that suppression does NOT happen. Every fixture is
# an in-scope diff (apps/web/app/x.ts) with no marker, so ARMED means denied and NOT
# ARMED means a silent allow.
# ---------------------------------------------------------------------------

# Build a heredoc-body merge payload of an exact total character length: a
# `cat`-to-file opener, TOTAL-minus-overhead bytes of body padding, the real
# merge line, and the delimiter with no trailing newline (so no downstream
# `$( )` can trim a character off the length this test pins). Sets
# $PADDED_COMMAND rather than echoing, so the caller sees exactly TOTAL
# characters with no command-substitution trailing-newline strip in the way.
padded_heredoc_command() {
  local total="$1" prefix suffix fixed padding_length padding
  prefix=$'cat > f.txt <<EOF\n'
  suffix=$'\ngh pr merge 30 --squash\nEOF'
  fixed=$(( ${#prefix} + ${#suffix} ))
  padding_length=$(( total - fixed ))
  [ "$padding_length" -ge 0 ] || padding_length=0
  padding=$(head -c "$padding_length" < /dev/zero | tr '\0' 'x')
  PADDED_COMMAND="${prefix}${padding}${suffix}"
}

# Stage the whole of .claude/hooks, lib/ included, into a fresh tree and
# delete LIBNAME from the staged copy, then run the STAGED hook. Mechanism A
# (README.md "Test-harness mechanics"): the real hook resolves every lib off
# its OWN on-disk location via BASH_SOURCE, so deleting from $REPO's sandbox
# lib/ (used elsewhere in this file for the two resolver-script copies)
# removes nothing this hook itself reads; only a staged copy's absence is.
# copy_review_verdict_libraries <root>: the scripts the PR review verdict
# library sources, which a sandbox that copies the hooks directory must carry
# beside it or the gate denies on the missing library.
copy_review_verdict_libraries() {
  local library_name
  mkdir -p "$1/.gaia/scripts"
  for library_name in audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh exclusive-lock-lib.sh branch-authorship-lib.sh filing-outcomes-lib.sh pr-body-sections-lib.sh; do
    cp "$BATS_TEST_DIRNAME/../../scripts/$library_name" "$1/.gaia/scripts/"
  done
}

# stage_hooks_copy <root>: copy the hooks directory to <root>/.claude/hooks
# beside the autonomy library the copied gate loads from <root>/.gaia/scripts.
stage_hooks_copy() {
  mkdir -p "$1/.claude" "$1/.gaia/scripts"
  cp -R "$(dirname "$HOOK_ABSOLUTE_PATH")" "$1/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../../scripts/autonomy-lib.sh" "$BATS_TEST_DIRNAME/../../scripts/main-root-lib.sh" "$1/.gaia/scripts/"
  copy_review_verdict_libraries "$1"
}

run_merge_hook_library_absent() {
  local library_name="$1" command_line="$2" json stage
  stage="$BATS_TEST_TMPDIR/staged-${library_name}/.claude/hooks"
  if [ ! -d "$stage" ]; then
    stage_hooks_copy "$BATS_TEST_TMPDIR/staged-${library_name}"
    rm -f "$stage/lib/$library_name"
  fi
  json=$(jq -n --arg command_line "$command_line" '{tool_name: "Bash", tool_input: {command: $command_line}}')
  invoke_hook_in "$REPO" "$json" "$stage/pr-merge-audit-check.sh"
}

# Row of "arming: which command shapes reach the gate (case table)": data-proof: a cat-to-file heredoc body carrying the verb does not arm
row_data_proof_a_cat_to_file_heredoc_body_carrying_the_verb_does() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook $'cat > f.txt <<EOF\ngh pr merge 30 --squash\nEOF\n'
  assert_allowed_by_json
  [ -z "$output" ]
}

# Row of "arming: which command shapes reach the gate (case table)": data-proof: removing the heredoc opener line leaves the same body text armed
row_data_proof_removing_the_heredoc_opener_line_leaves_the_same() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  # Byte-identical to the previous case with the `cat > f.txt <<EOF` opener
  # line removed: the merge now sits at the very start of the text.
  run_merge_hook $'gh pr merge 30 --squash\nEOF\n'
  assert_denied_by_json
}

# Row of "arming: which command shapes reach the gate (case table)": arming: a merge cited in a pull-request body passed through a quoted-delimiter heredoc is allowed
row_arming_a_merge_cited_in_a_pull_request_body_passed_through_a() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook $'gh pr create --title t --body "$(cat <<\'EOF\'\nSee `gh pr merge 30 --squash`.\nEOF\n)"'
  assert_allowed_by_json || return 1
  [ -z "$output" ] || return 1
  run_merge_hook $'gh pr comment 5 --body \'see `gh pr merge 30 --squash`\''
  assert_allowed_by_json || return 1
  [ -z "$output" ] || return 1
  # The unquoted-delimiter twin runs the backticked merge inside its body.
  run_merge_hook $'gh pr create --title t --body "$(cat <<EOF\nSee `gh pr merge 30 --squash`.\nEOF\n)"'
  assert_denied_by_json
}

@test "deny text: a separator or opener arm says the merge may only be cited, and a first-word arm does not" {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook 'echo "$(gh pr merge 30 --squash)"'
  assert_denied_by_json || return 1
  grep -qF 'cannot tell a merge the shell runs from one only cited' <<<"$output" || return 1
  run_merge_hook 'echo x; gh pr merge 30 --squash'
  assert_denied_by_json || return 1
  grep -qF 'cannot tell a merge the shell runs from one only cited' <<<"$output" || return 1

  run_merge_hook 'gh pr merge 30 --squash'
  assert_denied_by_json || return 1
  grep -qF 'cannot tell a merge the shell runs from one only cited' <<<"$output" && return 1
  true
}

# Row of "arming: which command shapes reach the gate (case table)": data-proof: the same payload with the quote terminated is proven data and allowed
row_data_proof_the_same_payload_with_the_quote_terminated_is_pro() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook $'cat > f.txt <<EOF\ngh pr merge 30 --squash\nEOF\n'"'x'"
  assert_allowed_by_json
  [ -z "$output" ]
}

# Row of "arming: which command shapes reach the gate (case table)": data-proof: a heredoc-body merge at the character bound is proven data and allowed
row_data_proof_a_heredoc_body_merge_at_the_character_bound_is_pr() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  padded_heredoc_command 16384
  [ "${#PADDED_COMMAND}" -eq 16384 ]
  run_merge_hook "$PADDED_COMMAND"
  assert_allowed_by_json
  [ -z "$output" ]
}

# Row of "arming: which command shapes reach the gate (case table)": no-regression: an unrelated first line with an unquoted merge on the second line still arms
row_no_regression_an_unrelated_first_line_with_an_unquoted_merge() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook $'echo hi\ngh pr merge 30 --squash\n'
  assert_denied_by_json
}

# Row of "arming: which command shapes reach the gate (case table)": no-regression: a merge after a word-initial # comment does not arm
row_no_regression_a_merge_after_a_word_initial_comment_does_not() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook '# gh pr merge 30 --squash'
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "arming: which command shapes reach the gate (case table)" {
  run_case_rows \
    row_arming_a_merge_that_is_not_the_first_command_still_reaches_t \
    row_arming_a_non_merge_command_carrying_the_word_merge_does_not \
    row_data_proof_a_cat_to_file_heredoc_body_carrying_the_verb_does \
    row_data_proof_removing_the_heredoc_opener_line_leaves_the_same \
    row_arming_a_merge_cited_in_a_pull_request_body_passed_through_a \
    row_data_proof_the_same_payload_with_the_quote_terminated_is_pro \
    row_data_proof_a_heredoc_body_merge_at_the_character_bound_is_pr \
    row_no_regression_an_unrelated_first_line_with_an_unquoted_merge \
    row_no_regression_a_merge_after_a_word_initial_comment_does_not
}

# Row of "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)": library-absent: repo-scope.sh missing denies by name, not by blaming the command's spelling
row_library_absent_repo_scope_sh_missing_denies_by_name_not_by_b() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  # Binding every permit to the named pull request made this library's absence
  # a whole-gate block, where it used to mean only that a bypass did not fire.
  # Without a named guard the block surfaces through the binding's spelling arm,
  # which blames the command and then recommends the exact bare merge that just
  # denied, so the operator is told to respell a command no respelling repairs.
  run_merge_hook_library_absent "repo-scope.sh" "gh pr merge --squash --delete-branch"
  assert_denied_by_json
  grep -qF -- 'repo-scope.sh' <<<"$output"
  grep -qF -- 'how the command is spelled' <<<"$output" && return 1
  return 0
}

# Row of "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)": library-absent: audit-scope.sh missing denies through the library guard, naming the ownership classifier
row_library_absent_audit_scope_sh_missing_denies_through_the_lib() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"
  write_markers_for_spawn_set "$(spawn_set)"

  run_merge_hook_library_absent "audit-scope.sh" "gh pr merge --squash --delete-branch"
  assert_denied_by_json
  grep -qF -- 'cannot load the ownership classifier' <<<"$output"
}

# Row of "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)": library-absent: verb-arming.sh missing denies every Bash tool call, naming the file
row_library_absent_verb_arming_sh_missing_denies_every_bash_tool() {
  run_merge_hook_library_absent "verb-arming.sh" "echo hi"
  assert_denied_by_json
  grep -qF 'verb-arming.sh' <<<"$output" || return 1
}

# Row of "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)": walker-absent: verb-arming-walk.sh missing degrades to the raw match, so the heredoc-body payload still arms
row_walker_absent_verb_arming_walk_sh_missing_degrades_to_the_ra() {
  install_gh_stub
  commit_files "apps/web/app/x.ts" "export const x = 1"

  run_merge_hook_library_absent "verb-arming-walk.sh" $'cat > f.txt <<EOF\ngh pr merge 30 --squash\nEOF\n'
  assert_denied_by_json
}

# Every test above invokes the hook by path, so all of them stay green on a
# registration that no longer names the hook at all. This is the only
# assertion that reads the file deciding which tool calls reach the hook.

@test "the hook is registered in settings.json on the Bash|Monitor matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' pr-merge-audit-check.sh
}

# ---- SPEC-092: the apps/web/ roster globs and the merge-layer fail-closed ---

# Row of "dispatched-member spawn set allows once each spawned member's marker is written (case table)": apps/web/ roster: a apps/web/app diff is claimed by the default member, so its marker is demanded and clears
row_apps_web_roster_a_apps_web_app_diff_is_claimed_by_the_defaul() {
  commit_files "apps/web/app/routes/x.tsx" "export const X = 1"
  [ "$(spawn_set)" = "code-audit-frontend" ]
  run_merge_hook
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
}

@test "dispatched-member spawn set allows once each spawned member's marker is written (case table)" {
  run_case_rows \
    row_fc_4_no_deadlock_apps_web_app_x_tsx_spawns_the_default_membe \
    row_fc_4_no_deadlock_frontend_tsconfig_json_spawns_the_default_m \
    row_fc_4_no_deadlock_a_ci_workflow_spawns_the_workflows_member_o \
    row_fc_4_no_deadlock_framework_shell_spawns_the_shell_member_onl \
    row_fc_4_no_deadlock_framework_cli_typescript_spawns_the_node_me \
    row_fc_4_no_deadlock_mixed_app_framework_shell_spawns_both_sorte \
    row_fc_4_no_deadlock_an_ownerless_in_scope_file_riding_with_a_sp \
    row_apps_web_roster_a_apps_web_app_diff_is_claimed_by_the_defaul \
    row_and_aggregator_app_only_diff_allows_once_the_frontend_marker \
    row_and_aggregator_mixed_app_gaia_sh_diff_allows_once_both_dispa \
    row_and_aggregator_gaia_sh_only_diff_allows_once_the_maintainer
}

# Row of "roster-less or unanswerable resolver denies (case table)": apps/web/ roster guard can fail: with the apps/web/ globs removed the resolver is empty and the gate still refuses without a frontend marker
row_apps_web_roster_guard_can_fail_with_the_apps_web_globs_remov() {
  grep -vE '"apps/(web/|\*\*")' "$REPO/.gaia/audit-ci.yml" > "$REPO/.gaia/audit-ci.yml.tmp"
  mv "$REPO/.gaia/audit-ci.yml.tmp" "$REPO/.gaia/audit-ci.yml"
  commit_files "apps/web/app/routes/x.tsx" "export const X = 1"
  [ -z "$(spawn_set)" ]
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *'code-audit-frontend'* ]]
}

@test "roster-less or unanswerable resolver denies (case table)" {
  run_case_rows \
    row_a_roster_less_config_denies_with_the_roster_named_even_on_a \
    row_and_aggregator_a_resolver_that_cannot_answer_denies_instead \
    row_apps_web_roster_guard_can_fail_with_the_apps_web_globs_remov
}

# --- the one-jq payload reader ---

# Row of "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)": lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library
row_lib_hook_payload_sh_absent_a_payload_the_hook_would_deny_exi() {
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'gh pr merge 1' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/pr-merge-audit-check.sh"
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: pr-merge-audit-check.sh cannot load lib/hook-payload.sh' <<<"$output"
}

@test "a missing gate library or payload reader denies, a missing walker degrades to arming (case table)" {
  run_case_rows \
    row_library_absent_repo_scope_sh_missing_denies_by_name_not_by_b \
    row_library_absent_audit_scope_sh_missing_denies_through_the_lib \
    row_library_absent_verb_arming_sh_missing_denies_every_bash_tool \
    row_walker_absent_verb_arming_walk_sh_missing_degrades_to_the_ra \
    row_lib_hook_payload_sh_absent_a_payload_the_hook_would_deny_exi
}

# --- the gate's own siblings ---

# bats test_tags=whole-tree
@test "a missing or cut-short gate sibling denies the merge, never allows it" {
  # The gate's checks live in siblings it sources from its own directory. A
  # copy missing one, or holding one that stops before its end, must deny: a
  # gate that ran without a sibling's checks, or fell off the end of a file,
  # would exit 0 with no decision, which is an allow.
  local hooks_directory scratch_hooks payload sibling_file sibling_name checked=0
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/sibling-root/.claude/hooks"
  commit_files ".claude/skills/release-notes/SKILL.md" "updated"
  payload=$(jq -nc --arg command 'gh pr merge 30 --squash --delete-branch' '{tool_name: "Bash", tool_input: {command: $command}}')
  for sibling_file in "$hooks_directory"/pr-merge-audit-check-*.sh; do
    [ -f "$sibling_file" ] || continue
    sibling_name="${sibling_file##*/}"
    rm -rf "$BATS_TEST_TMPDIR/sibling-root"
    stage_hooks_copy "$BATS_TEST_TMPDIR/sibling-root"
    # Positive control: the full copy allows this out-of-scope diff, so a deny
    # below is the sibling's doing and not the fixture's.
    invoke_hook_in "$REPO" "$payload" "$scratch_hooks/pr-merge-audit-check.sh"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *'"permissionDecision": "deny"'* ]] || { printf 'control denied for %s: %s\n' "$sibling_name" "$output" >&2; return 1; }
    # Cut short to its header: it defines nothing and decides nothing.
    head -n 12 "$sibling_file" > "$scratch_hooks/$sibling_name"
    invoke_hook_in "$REPO" "$payload" "$scratch_hooks/pr-merge-audit-check.sh"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'"permissionDecision": "deny"'* ]] || { printf '%s cut short: no deny: %s\n' "$sibling_name" "$output" >&2; return 1; }
    grep -qF "cannot load the gate sibling" <<<"$output" || return 1
    grep -qF "$sibling_name" <<<"$output" || return 1
    rm -f "$scratch_hooks/$sibling_name"
    invoke_hook_in "$REPO" "$payload" "$scratch_hooks/pr-merge-audit-check.sh"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'"permissionDecision": "deny"'* ]] || { printf '%s missing: no deny: %s\n' "$sibling_name" "$output" >&2; return 1; }
    grep -qF "$sibling_name': it is missing" <<<"$output" || return 1
    checked=$((checked + 1))
  done
  # Non-vacuity: every sibling the loader names, and the unattended sibling
  # sourced before it, was exercised.
  [ "$checked" -gt 0 ]
  [ "$checked" -eq "$(( $(grep -cE '^  [a-z]+:[a-z_]*$' "$hooks_directory/pr-merge-audit-check.sh") + $(grep -cF '/pr-merge-audit-check-unattended.sh"' "$hooks_directory/pr-merge-audit-check.sh") ))" ]
}

@test "a non-arming Bash payload spawns exactly one jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/pr-merge-audit-check.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The release-change skip: the gate owes markers from exactly the members the
# resolver names, and the digests it matches them against arm the same release
# context, on a release-applying branch and on an ordinary one. The fixture is
# .gaia/tests/helpers/release-skip-fixture.sh, whose fixture-shell member is
# keyed skip_gaia_release_changes: true.
# ---------------------------------------------------------------------------

# release_skip_gate_branch <kind>: rebuilds main as the fixture base, publishes
# it to the origin, and re-cuts feature as one <kind> commit on top.
release_skip_gate_branch() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/release-skip-fixture.sh"
  git -C "$REPO" checkout -q main
  release_skip_seed_base "$REPO"
  git -C "$REPO" push -q origin main 2>/dev/null
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q -B feature main
  release_skip_apply "$REPO" "$1"
}

# gate_pending_members: the members the last deny names PENDING, sorted.
gate_pending_members() {
  printf '%s\n' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | sed -n 's/^  - \([^:]*\): PENDING.*/\1/p' | LC_ALL=C sort
}

# release_skip_gate_agrees <kind> <expected-members> [<hook>]: the deny names
# exactly the resolver's members, and their markers then allow the merge.
release_skip_gate_agrees() {
  local hook="${3:-$HOOK_ABSOLUTE_PATH}" set json
  set="$(spawn_set)"
  [ "$set" = "$2" ] || { echo "resolver: $set" >&2; return 1; }
  json="$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 30 --squash --delete-branch"}}')"
  invoke_hook_in "$REPO" "$json" "$hook"
  [ "$(gate_pending_members)" = "$set" ] || { echo "pending: $(gate_pending_members)" >&2; return 1; }
  write_markers_for_spawn_set "$set"
  invoke_hook_in "$REPO" "$json" "$hook"
  assert_allowed_by_json || { echo "markers for the resolver's members did not clear: $output" >&2; return 1; }
}

# Row of "the gate owes markers from exactly the resolver's members across release contexts (case table)": release skip: the gate owes markers from exactly the resolver's members on a release-applying branch
row_release_skip_the_gate_owes_markers_from_exactly_the_resolver() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  release_skip_gate_branch release
  release_skip_gate_agrees release "$(printf 'fixture-default\nfixture-scripts')"
}

# Row of "the gate owes markers from exactly the resolver's members across release contexts (case table)": release skip: the gate owes markers from exactly the resolver's members on an ordinary branch
row_release_skip_the_gate_owes_markers_from_exactly_the_resolver_2() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  release_skip_gate_branch ordinary
  release_skip_gate_agrees ordinary fixture-shell
}

# Row of "the gate owes markers from exactly the resolver's members across release contexts (case table)": release skip: the gate agreement fails when the digest arms against the base tip instead of the merge base
row_release_skip_the_gate_agreement_fails_when_the_digest_arms_a() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  release_skip_gate_branch release
  # The base takes the same update after the branch was cut, so the tip's
  # VERSION matches the branch head while the merge base's does not.
  catchup_base_commit .gaia/VERSION 1.1.0
  local real_root
  real_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  release_skip_gate_agrees release "$(printf 'fixture-default\nfixture-scripts')"

  local scratch="$BATS_TEST_TMPDIR/tip-armed-hook"
  mkdir -p "$scratch/.claude" "$scratch/.gaia/scripts"
  cp -R "$real_root/.claude/hooks" "$scratch/.claude/hooks"
  cp "$real_root"/.gaia/scripts/*.sh "$scratch/.gaia/scripts/"
  sed 's|audit_scope_release_context "\$root" "\$merge_base" "\$target" "\$merge_base"|audit_scope_release_context "$root" refs/remotes/origin/main "$target" "$(git -C "$root" rev-parse refs/remotes/origin/main)"|' \
    "$real_root/.claude/hooks/lib/audit-digest.sh" > "$scratch/.claude/hooks/lib/audit-digest.sh"
  grep -q 'refs/remotes/origin/main "\$target"' "$scratch/.claude/hooks/lib/audit-digest.sh"
  rm -rf "$REPO/.gaia/local/audit"
  run release_skip_gate_agrees release "$(printf 'fixture-default\nfixture-scripts')" "$scratch/.claude/hooks/pr-merge-audit-check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"markers for the resolver's members did not clear"* ]] || return 1
}

@test "the gate owes markers from exactly the resolver's members across release contexts (case table)" {
  run_case_rows \
    row_release_skip_the_gate_owes_markers_from_exactly_the_resolver \
    row_release_skip_the_gate_owes_markers_from_exactly_the_resolver_2 \
    row_release_skip_the_gate_agreement_fails_when_the_digest_arms_a
}

# ---------------------------------------------------------------------------
# The release-bookkeeping arm: a change the release-bookkeeping predicate
# accepts is wholly out of scope, so the out-of-scope bypass clears it with no
# markers. The fixture is .gaia/tests/helpers/release-bookkeeping-fixture.sh.
# ---------------------------------------------------------------------------

# release_bookkeeping_gate_branch: rebuilds main as the fixture base, publishes
# it to the origin, and re-cuts feature as one bookkeeping release on top, with
# the predicate installed where the audit scope looks for it.
release_bookkeeping_gate_branch() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/release-bookkeeping-fixture.sh"
  git -C "$REPO" checkout -q main
  release_bookkeeping_seed_base "$REPO"
  git -C "$REPO" push -q origin main 2>/dev/null
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q -B feature main
  release_bookkeeping_install_predicate "$REPO"
  release_bookkeeping_apply "$REPO"
}

# Row of "release bookkeeping clears only when the release context is armed (case table)": release bookkeeping: the out-of-scope bypass clears a bookkeeping release with no markers
row_release_bookkeeping_the_out_of_scope_bypass_clears_a_bookkee() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  release_bookkeeping_gate_branch
  [ -z "$(spawn_set)" ]
  run_merge_hook
  assert_allowed_by_json
}

# Row of "release bookkeeping clears only when the release context is armed (case table)": release bookkeeping: the clear fails against a bypass that never arms the release context
row_release_bookkeeping_the_clear_fails_against_a_bypass_that_ne() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  release_bookkeeping_gate_branch
  local real_root scratch="$BATS_TEST_TMPDIR/unarmed-bypass" json
  real_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  mkdir -p "$scratch/.claude" "$scratch/.gaia/scripts"
  cp -R "$real_root/.claude/hooks" "$scratch/.claude/hooks"
  cp "$real_root"/.gaia/scripts/*.sh "$scratch/.gaia/scripts/"
  json="$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 30 --squash --delete-branch"}}')"
  # Positive control: the unmodified copy clears, so the deny below is the
  # missing context call and nothing else about the copy.
  invoke_hook_in "$REPO" "$json" "$scratch/.claude/hooks/pr-merge-audit-check.sh"
  assert_allowed_by_json
  grep -v '^  audit_scope_release_context "\$tree_root" "\$gate_base"$' \
    "$real_root/.claude/hooks/pr-merge-audit-check-bypass.sh" > "$scratch/.claude/hooks/pr-merge-audit-check-bypass.sh"
  cmp -s "$real_root/.claude/hooks/pr-merge-audit-check-bypass.sh" "$scratch/.claude/hooks/pr-merge-audit-check-bypass.sh" && return 1
  invoke_hook_in "$REPO" "$json" "$scratch/.claude/hooks/pr-merge-audit-check.sh"
  assert_denied_by_json
}

@test "release bookkeeping clears only when the release context is armed (case table)" {
  run_case_rows \
    row_release_bookkeeping_the_out_of_scope_bypass_clears_a_bookkee \
    row_release_bookkeeping_the_clear_fails_against_a_bypass_that_ne
}

# --- unattended runs: the autonomy switch's may_merge ---------------------------

# write_switch <may_merge> [expires-offset-seconds] [raw-json]: the autonomy
# switch for $REPO; a raw JSON argument replaces the whole file.
write_switch() {
  mkdir -p "$REPO/.gaia/local/protected"
  if [ -n "${3-}" ]; then
    printf '%s\n' "$3" > "$REPO/.gaia/local/protected/autonomy.json"
    return 0
  fi
  jq -n -c --argjson may_merge "$1" --argjson offset "${2:-3600}" \
    '{enabled: true, expires_at: (now + $offset | floor | todate), may_merge: $may_merge}' \
    > "$REPO/.gaia/local/protected/autonomy.json"
}

# merge_log_lines: the decision log's line count, 0 when absent.
merge_log_lines() {
  local log="$REPO/.gaia/local/protected/autonomy-log.jsonl"
  if [ -f "$log" ]; then wc -l < "$log" | tr -d ' '; else printf '0\n'; fi
}

# bats test_tags=protected
@test "unattended: with may_merge false every merge the gate arms on is denied with the park command, cleared or not" {
  local command_line
  commit_files "Makefile" "all:"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
  write_switch false
  for command_line in 'gh pr merge 30 --squash --delete-branch' 'gh pr merge 30 --auto --squash' \
    'gh pr merge --squash --match-head-commit 0123456789abcdef0123456789abcdef01234567 30' 'gh pr merge -R someone/elsewhere 7 --squash'; do
    echo "case: $command_line"
    run_merge_hook "$command_line"
    assert_denied_by_json
    jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'with may_merge false: only a human merges this PR'
    jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- "autonomy-park.sh --reason merge-ready --pr <n> --root"
  done
  [ "$(merge_log_lines)" -eq 0 ]
}

# bats test_tags=protected
@test "unattended: with may_merge true the clearance check decides, an allowed merge is logged first, and a failed log denies" {
  write_switch true
  commit_files "Makefile" "all:"
  run_merge_hook
  assert_denied_by_json
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'only a human merges this PR' && return 1
  [ "$(merge_log_lines)" -eq 0 ]
  write_marker "code-audit-frontend"
  run_merge_hook 'gh pr merge 30 --auto --squash'
  assert_allowed_by_json
  [ "$(merge_log_lines)" -eq 1 ]
  [ "$(jq -r '.header' "$REPO/.gaia/local/protected/autonomy-log.jsonl")" = 'Unattended merge' ]
  jq -r '.option' "$REPO/.gaia/local/protected/autonomy-log.jsonl" | grep -qF -- 'gh pr merge 30 --auto --squash'
  echo "case: a decision log that cannot be appended turns the allow into a deny"
  rm -f "$REPO/.gaia/local/protected/autonomy-log.jsonl"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.jsonl" "$REPO/.gaia/local/protected/autonomy-log.jsonl"
  run_merge_hook
  assert_denied_by_json
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'cannot append it to the decision log'
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere.jsonl" ]
}

# The question gate's merge arm parks only a recommended label whose first word is Merge;
# an "Apply ..." option whose path ends in a merge is taken. The merge gate is
# the enforcement point: with may_merge false the merge that follows parks.
# bats test_tags=protected
@test "unattended: a taken non-Merge option whose path ends in a merge parks at the merge gate with may_merge false" {
  local gate_hook question_payload
  gate_hook="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.claude/hooks/autonomy-gate.sh"
  commit_files "Makefile" "all:"
  write_marker "code-audit-frontend"
  # Positive control: attended, the cleared merge is allowed.
  run_merge_hook 'gh pr merge 30 --squash'
  assert_allowed_by_json
  write_switch false
  question_payload=$(jq -nc --arg cwd "$REPO" '{session_id: "s1", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "AskUserQuestion",
    tool_input: {questions: [{question: "Apply the fixes, then merge the pull request?", header: "Finish", multiSelect: false,
      options: [{label: "Apply and finish (Recommended)", description: "applies the fixes, then runs gh pr merge"}, {label: "Hold", description: "stops"}]}]}}')
  invoke_hook_in "$REPO" "$question_payload" "$gate_hook"
  assert_denied_by_json
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- "Take 'Apply and finish (Recommended)' for 'Finish'"
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'autonomy-park.sh' && return 1
  [ "$(merge_log_lines)" -eq 1 ]
  run_merge_hook 'gh pr merge 30 --squash'
  assert_denied_by_json
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'autonomy-park.sh --reason merge-ready --pr <n> --root'
  [ "$(merge_log_lines)" -eq 1 ]
  [ "$(jq -r '.header' "$REPO/.gaia/local/protected/autonomy-log.jsonl")" = 'Finish' ]
}

@test "unattended: a missing, expired or malformed switch leaves the gate exactly as attended" {
  local row
  commit_files "Makefile" "all:"
  for row in missing expired malformed; do
    echo "case: $row"
    rm -f "$REPO/.gaia/local/protected/autonomy.json" "$REPO/.gaia/local/audit/"*.ok
    case "$row" in
      missing) ;;
      expired) write_switch false -60 ;;
      malformed) write_switch false 3600 '{"enabled":true,"expires_at":"soon","may_merge":false}' ;;
    esac
    run_merge_hook
    assert_denied_by_json
    jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" | grep -qF -- 'only a human merges this PR' && return 1
    write_marker "code-audit-frontend"
    run_merge_hook
    assert_allowed_by_json
  done
  [ "$(merge_log_lines)" -eq 0 ]
}
