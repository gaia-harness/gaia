#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/capture-gh-artifact.sh, the PostToolUse hook
# that drops a breadcrumb when `gh pr create` succeeds. Every test runs the
# hook with cwd = a tmp git repo, never the real repo root, and points
# GAIA_GH_ARTIFACT_CACHE_DIRECTORY at a per-test tmp dir so no test ever touches the
# real .gaia/local/cache/.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.claude/hooks/capture-gh-artifact.sh"
  LIBRARY_SOURCE="$REPO_ROOT/.gaia/scripts/gh-artifact-lib.sh"
  AUDIT_KEY_LIBRARY_SOURCE="$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"
  export GAIA_GH_ARTIFACT_CACHE_DIRECTORY="$CACHE"
  # This suite runs the REAL hook, so the PR-to-branch edge would be written
  # into the real tree's ledger from every case. The seam keeps the existing
  # breadcrumb cases exactly as they were; the edge cases unset it.
  export GAIA_USAGE_HOOKS_DISABLE=1
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Scaffolds a tmp git repo with the real lib copied in at its repo-relative
# path, so the hook's `source .gaia/scripts/gh-artifact-lib.sh` resolves.
# Also copies audit-key-lib.sh beside it: gaia_gh_artifact_path sources it via
# BASH_SOURCE (the same idiom gaia_gh_artifact_cache_directory uses for
# main-root-lib.sh), so without its sibling present the hook's own internal
# source would fail and no breadcrumb would ever be written, breaking every
# "writes the breadcrumb" test below for a reason unrelated to what they mean
# to exercise. Sets $REPO.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.gaia/scripts"
  cp "$LIBRARY_SOURCE" "$REPO/.gaia/scripts/gh-artifact-lib.sh"
  cp "$AUDIT_KEY_LIBRARY_SOURCE" "$REPO/.gaia/scripts/audit-key-lib.sh"
}

# run_hook <command> [stdout] [session_id]
run_hook() {
  local command="$1" tool_output="${2:-}" session_id="${3:-S1}" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$session_id" Bash "$command" "$tool_output")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
}

# run_hook_raw <json> - for payloads the helper's required-param mock cannot
# express (an empty session_id).
run_hook_raw() {
  local input="$1"
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
}

# breadcrumb_path <branch>: the exact keyed filename the hook (and the real
# gaia_gh_artifact_path) computes for <branch>. Sources the REAL, repo-level
# audit-key-lib.sh (not $REPO's copy) purely to compute the expected value
# with the same gaia_key_slug the production code calls, rather than keeping
# a second, potentially-drifting copy of the encoding rule in this test file.
breadcrumb_path() {
  local branch="$1"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"
  printf '%s/gh-artifact-pr.%s.json' "$CACHE" "$(gaia_key_slug "$branch")"
}

# any_breadcrumb_exists: true iff ANY gh-artifact-pr*.json breadcrumb sits in
# $CACHE, regardless of its branch-slug. The "should not write" tests below
# assert no breadcrumb was written at all, not merely that one specific keyed
# name is absent, so this is a stronger and simpler check than reconstructing
# an exact expected filename for every negative case (several of which never
# check out a named branch at all).
any_breadcrumb_exists() {
  compgen -G "$CACHE/gh-artifact-pr*.json" >/dev/null 2>&1
}

# ---------- It writes the breadcrumb when it should ----------

@test "writes the breadcrumb on a successful gh pr create" {
  build_repo
  cd "$REPO"
  git checkout -b feat/x --quiet

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  breadcrumb_file="$(breadcrumb_path "feat/x")"
  [ -f "$breadcrumb_file" ]
  jq -e '.number | type == "number"' "$breadcrumb_file" >/dev/null
  [ "$(jq -r '.type' "$breadcrumb_file")" = "pr" ]
  [ "$(jq -r '.number' "$breadcrumb_file")" = "712" ]
  [ "$(jq -r '.repo' "$breadcrumb_file")" = "gaia-react/gaia" ]
  [ "$(jq -r '.branch' "$breadcrumb_file")" = "feat/x" ]
  [ "$(jq -r '.session_id' "$breadcrumb_file")" = "S1" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$breadcrumb_file" >/dev/null
  [ "$(jq -r 'keys | @csv' "$breadcrumb_file")" = '"branch","number","repo","session_id","ts","type"' ]
}

@test "a separator form (cd /tmp && gh pr create) also matches and writes" {
  build_repo
  cd "$REPO"
  git checkout -b feat/y --quiet

  run_hook "cd /tmp && gh pr create --title x" "https://github.com/gaia-react/gaia/pull/900"
  [ "$status" -eq 0 ]

  breadcrumb_file="$(breadcrumb_path "feat/y")"
  [ -f "$breadcrumb_file" ]
  [ "$(jq -r '.number' "$breadcrumb_file")" = "900" ]
}

# Case-table checks: each names its row and returns 1 explicitly, so a failing
# row reports its label and fails the test.
check_status_zero() {
  [ "$status" -eq 0 ] || { echo "case $1: status=$status output=$output"; return 1; }
}
check_silent() {
  check_status_zero "$1" || return 1
  [ -z "$output" ] || { echo "case $1: unexpected output: $output"; return 1; }
}
check_no_breadcrumb() {
  any_breadcrumb_exists && { echo "case $1: a breadcrumb was written"; return 1; }
  return 0
}
check_breadcrumb_for() {
  [ -f "$(breadcrumb_path "$2")" ] || { echo "case $1: no breadcrumb for $2"; return 1; }
}
reset_cache() {
  rm -f "$CACHE"/gh-artifact-pr*.json
}

# ---------- It does NOT write when it should not ----------

# The issue row keeps the forensics write-allowlist intact; the prose row has
# no shell separator; the detached-HEAD row is refused by the lib for an empty
# branch, so it runs last on the shared repo.
@test "no breadcrumb is written for gh issue create, a non-Bash call, prose, empty stdout, no URL, an empty session_id or a detached HEAD" {
  local input
  build_repo
  cd "$REPO"

  git checkout -b feat/issue --quiet
  run_hook "gh issue create --repo gaia-react/gaia --label gaia-forensics --title t --body-file f" \
    "https://github.com/gaia-react/gaia/issues/415"
  check_status_zero issue-create
  check_no_breadcrumb issue-create

  reset_cache
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Edit "gh pr create")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  check_status_zero non-bash
  check_no_breadcrumb non-bash

  reset_cache
  run_hook 'git commit -m "run gh pr create next"' ""
  check_status_zero prose-mention
  check_no_breadcrumb prose-mention

  reset_cache
  run_hook "gh pr create --title x --body y" ""
  check_status_zero empty-stdout
  check_no_breadcrumb empty-stdout

  reset_cache
  run_hook "gh pr create --title x --body y" "Creating pull request..."
  check_status_zero no-url
  check_no_breadcrumb no-url

  reset_cache
  git checkout -b feat/nosid --quiet
  input=$(jq -n --arg t "Bash" --arg c "gh pr create --title x --body y" \
    --arg o "https://github.com/gaia-react/gaia/pull/712" \
    '{session_id: "", transcript_path: "/tmp/transcript.jsonl", cwd: ".",
      hook_event_name: "PostToolUse", tool_name: $t, tool_input: {command: $c},
      tool_response: {stdout: $o, stderr: "", interrupted: false}}')
  run_hook_raw "$input"
  check_status_zero empty-session-id
  check_no_breadcrumb empty-session-id

  reset_cache
  git checkout --detach --quiet
  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero detached-head
  check_no_breadcrumb detached-head
}

# ---------- Shared arming decision (data proof, bound, tokenizer) ----------

# A heredoc body is proven data and writes nothing, while the same text outside
# it writes; padded past the arming bound the proof is not attempted and it
# writes; a quoted verb in the first command arms through the tokenizer; a
# multi-statement command still writes.
@test "a create inside a heredoc body writes nothing; outside it, past the arming bound, with a quoted verb or after another statement it writes" {
  local heredoc_command pad
  build_repo
  cd "$REPO"

  git checkout -b feat/heredoc --quiet
  heredoc_command=$'cat > /tmp/notes.txt <<EOF\ngh pr create --title x\nEOF'
  run_hook "$heredoc_command" "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero heredoc-body
  check_no_breadcrumb heredoc-body
  run_hook "gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero heredoc-text-unwrapped
  check_breadcrumb_for heredoc-text-unwrapped feat/heredoc

  git checkout -b feat/overbound --quiet
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr create --title x\nEOF'
  [ "${#heredoc_command}" -gt 16384 ] || { echo "case over-bound: payload not past the bound"; return 1; }
  run_hook "$heredoc_command" "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero over-bound
  check_breadcrumb_for over-bound feat/overbound

  git checkout -b feat/quoted --quiet
  run_hook 'gh pr "create" --title x' "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero quoted-verb
  check_breadcrumb_for quoted-verb feat/quoted

  git checkout -b feat/multi --quiet
  run_hook "echo start && gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  check_status_zero multi-statement
  check_breadcrumb_for multi-statement feat/multi
}

# ---------- A missing dependency degrades silently ----------

# The lib and hook-payload rows each need their own tree: the lib row stages a copy of the hook (it
# resolves gh-artifact-lib.sh off its OWN location, so running
# $HOOK_ABSOLUTE_PATH from a lib-less directory would reach the real checkout's
# lib and record normally; `stage_hook_repo` keeps the verb-arming load
# resolvable so the hook reaches the gh-artifact load), and the hook-payload row
# stages the whole lib directory less that one file.
@test "a missing jq, gh-artifact lib or hook-payload library degrades to exit 0, no output and no breadcrumb, and a missing jq writes no edge" {
  local nojq_bin input

  build_repo
  cd "$REPO"
  git checkout -b feat/nojq --quiet
  nojq_bin="$(path_allowlist bash cat git)"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/712")
  PATH="$nojq_bin" invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  check_silent jq-absent
  check_no_breadcrumb jq-absent

  git checkout -b feat/nojq-edge --quiet
  unset GAIA_USAGE_HOOKS_DISABLE
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/80")
  PATH="$nojq_bin" invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  check_silent jq-absent-edge
  [ ! -e "$(edge_file)" ] || { echo "case jq-absent-edge: an edge was written"; return 1; }
  export GAIA_USAGE_HOOKS_DISABLE=1

  cd "$BATS_TEST_TMPDIR"
  rm -rf "$REPO"
  reset_cache
  stage_hook_repo
  rm -f "$REPO/.gaia/scripts/gh-artifact-lib.sh"
  cd "$REPO"
  git checkout -b feat/nolib --quiet
  run_staged_hook "gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  check_silent lib-absent
  check_no_breadcrumb lib-absent

  cd "$BATS_TEST_TMPDIR"
  rm -rf "$REPO"
  reset_cache
  build_repo
  mkdir -p "$REPO/.claude/hooks"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  rm -f "$REPO/.claude/hooks/lib/hook-payload.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$REPO/.claude/hooks/capture-gh-artifact.sh"
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --fill" "https://github.com/acme/widgets/pull/7")
  invoke_hook "$input" "$REPO/.claude/hooks/capture-gh-artifact.sh"
  check_silent hook-payload-absent
  check_no_breadcrumb hook-payload-absent
}

# ---------- Injection safety ----------

@test "a hostile repo slug (command substitution, shell metacharacter) never executes and writes no breadcrumb" {
  build_repo
  cd "$REPO"

  git checkout -b feat/inject --quiet
  run_hook "gh pr create --title x" 'https://github.com/o$(touch CANARY)/n/pull/1'
  check_status_zero command-substitution
  [ -e "$REPO/CANARY" ] && { echo "case command-substitution: CANARY created in repo"; return 1; }
  check_no_breadcrumb command-substitution
  [ -e "$CACHE/CANARY" ] && { echo "case command-substitution: CANARY created in cache"; return 1; }

  reset_cache
  git checkout -b feat/inject2 --quiet
  run_hook "gh pr create --title x" "https://github.com/o;id/n/pull/1"
  check_status_zero metacharacter
  check_no_breadcrumb metacharacter
}

# ---------- Registration ----------

@test "registered in .claude/settings.json's PostToolUse Bash matcher" {
  hook_registered "$REPO_ROOT/.claude/settings.json" \
    '.hooks.PostToolUse[] | select(.matcher == "Bash")' capture-gh-artifact.sh
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

# The verb-arming load resolves off the hook's own BASH_SOURCE, so corrupting
# it needs a COPY of the hook staged inside the tmp repo. $HOOK_ABSOLUTE_PATH would
# always reach the real checkout's lib, where the case cannot be expressed.
stage_hook_repo() {
  build_repo
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/hook-payload.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-view.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-helpers.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-view.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT"/.claude/hooks/lib/repo-scope*.sh "$REPO/.claude/hooks/lib/"
  STAGED_HOOK="$REPO/.claude/hooks/capture-gh-artifact.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

# run_staged_hook <command> <stdout> [interpreter]
run_staged_hook() {
  local input interpreter="${3:-bash}"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1" "$2")
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$input" "$STAGED_HOOK" "$interpreter"
}

# ---------- The PR-to-branch edge in the usage ledger ----------

edge_file() { printf '%s/.gaia/local/telemetry/links.jsonl' "$REPO"; }

# check_no_pr_edge LABEL: the ledger is absent or holds no pr: edge.
check_no_pr_edge() {
  [ -f "$(edge_file)" ] || return 0
  grep -q '"pr:' "$(edge_file)" && { echo "case $1: a pr: edge was recorded"; return 1; }
  return 0
}

# A repo flag in any spelling, even after a multi-line body, names a repository
# the edge cannot vouch for, so no edge is recorded. The ledger is cleared
# between rows so the recording row asserts its own single edge.
@test "the pr:<N> edge is recorded, normalizing a worktree branch spelling, unless a repo flag in any spelling or after a multi-line body names the repository" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE

  git checkout -b feat/foreign --quiet
  run_hook "gh pr create --repo x/y --title t" "https://github.com/x/y/pull/79"
  check_status_zero repo-long
  run_hook "gh pr create -R x/y --title t" "https://github.com/x/y/pull/80"
  run_hook "gh pr create --title t --repo=x/y" "https://github.com/x/y/pull/81"
  check_no_pr_edge repo-flag-spellings

  rm -f "$(edge_file)"
  git checkout -b feat/foreign-body --quiet
  run_hook $'gh pr create --title t --body "line one\nline two" --repo x/y' "https://github.com/x/y/pull/82"
  check_status_zero multi-line-body
  run_hook $'gh pr create --body "line one\nline two" -Rx/y' "https://github.com/x/y/pull/83"
  check_no_pr_edge multi-line-body

  rm -f "$(edge_file)"
  reset_cache
  git checkout -b worktree-debt+42-fix --quiet
  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/77"
  check_silent records-edge
  [ "$(jq -sc '[.[] | [.kind, .child, .parent, .source]]' "$(edge_file)")" = '[["edge","pr:77","branch:debt/42-fix","gh-pr-create"]]' ] \
    || { echo "case records-edge: ledger is $(cat "$(edge_file)")"; return 1; }
  check_breadcrumb_for records-edge worktree-debt+42-fix
}

# The seam (GAIA_USAGE_HOOKS_DISABLE) keeps the real ledger untouched while the
# breadcrumb still lands; an unwritable breadcrumb cache must not take the edge
# down with it.
@test "an unwritable breadcrumb cache never drops the edge, and the test seam keeps the edge unwritten" {
  build_repo
  cd "$REPO"

  git checkout -b feat/seam --quiet
  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/79"
  check_status_zero seam
  [ ! -e "$(edge_file)" ] || { echo "case seam: an edge was written"; return 1; }
  check_breadcrumb_for seam feat/seam

  reset_cache
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b feat/edge --quiet
  : >"$BATS_TEST_TMPDIR/not-a-dir"
  export GAIA_GH_ARTIFACT_CACHE_DIRECTORY="$BATS_TEST_TMPDIR/not-a-dir/cache"
  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/78"
  check_status_zero unwritable-cache
  [ "$(jq -sc '[.[] | [.child, .parent]]' "$(edge_file)")" = '[["pr:78","branch:feat/edge"]]' ] \
    || { echo "case unwritable-cache: ledger is $(cat "$(edge_file)")"; return 1; }
  check_no_breadcrumb unwritable-cache
}

@test "an allowed gh pr create form still writes the breadcrumb" {
  # shellcheck source=../helpers/gh-allow-list.sh
  . "$REPO_ROOT/.gaia/tests/helpers/gh-allow-list.sh"
  gh_command_is_allowed 'gh pr create --title x --body y'
  build_repo
  cd "$REPO"
  git checkout -b feat/x --quiet
  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -f "$(breadcrumb_path feat/x)" ]
}
