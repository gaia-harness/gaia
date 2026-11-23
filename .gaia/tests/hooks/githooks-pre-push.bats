#!/usr/bin/env bats

# Tests for .githooks/pre-push.
#
# The hook holds no check logic. It reads the pushed refs, keeps the non-delete
# branch updates, and hands their shas to the verification runner's `push` mode.
# These tests drive real `git push` commands against a bare remote, with the
# hook installed through core.hooksPath and the runner replaced by a stub that
# logs its argv and exits with the status a control file names. What the
# checks themselves do is the runner suites' business, and the end-to-end suite
# beside this one runs the real distribution checks.

setup() {
  HOOK_SOURCE="$BATS_TEST_DIRNAME/../../../.githooks/pre-push"
  [ -f "$HOOK_SOURCE" ]
  [ -x "$HOOK_SOURCE" ]

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  REPO="$BATS_TEST_TMPDIR/repo"
  HOOKS="$BATS_TEST_TMPDIR/hooks"
  RUNNER_LOG="$BATS_TEST_TMPDIR/runner.log"
  RUNNER_STATUS="$BATS_TEST_TMPDIR/runner.status"

  git init --quiet --bare --initial-branch=main "$REMOTE"
  git init --quiet --initial-branch=main "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$REMOTE"

  mkdir -p "$HOOKS" "$REPO/.gaia/tests"
  cp "$HOOK_SOURCE" "$HOOKS/pre-push"
  chmod +x "$HOOKS/pre-push"
  git -C "$REPO" config core.hooksPath "$HOOKS"

  : > "$RUNNER_LOG"
  printf '0\n' > "$RUNNER_STATUS"
  cat > "$REPO/.gaia/tests/verify-harness.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RUNNER_LOG"
exit "\$(cat "$RUNNER_STATUS")"
STUB

  printf 'base\n' > "$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit --quiet -m "base"
  git -C "$REPO" push --quiet origin main
  : > "$RUNNER_LOG"
}

# commit_on_branch <branch>: a new branch off main with one commit; prints its sha.
commit_on_branch() {
  git -C "$REPO" checkout --quiet -b "$1" main
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add "$1.txt"
  git -C "$REPO" commit --quiet -m "$1"
  git -C "$REPO" rev-parse HEAD
}

# remote_has_branch <branch>
remote_has_branch() {
  git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/$1" > /dev/null
}

NOTE='pre-push: no branch update in this push, nothing to verify'

# The rows share one repository and remote; each pushes refs of its own.
@test "a tag-only push or a branch deletion passes with one note line and never reaches the runner" {
  local label
  for label in "tag-only push" "branch deletion"; do
    case "$label" in
      "tag-only push")
        git -C "$REPO" tag spec/001
        : > "$RUNNER_LOG"
        run git -C "$REPO" push origin refs/tags/spec/001
        ;;
      "branch deletion")
        commit_on_branch doomed > /dev/null
        git -C "$REPO" push --quiet origin doomed
        : > "$RUNNER_LOG"
        printf '1\n' > "$RUNNER_STATUS"
        run git -C "$REPO" push origin --delete doomed
        ;;
    esac
    [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
    [ "$(grep -c '^pre-push:' <<<"$output")" -eq 1 ] || { echo "case $label: not one pre-push line: $output"; return 1; }
    grep -qxF -- "$NOTE" <<<"$output" || { echo "case $label: no note line: $output"; return 1; }
    [ ! -s "$RUNNER_LOG" ] || { echo "case $label: the runner ran: $(cat "$RUNNER_LOG")"; return 1; }
    case "$label" in
      "tag-only push")
        git -C "$REMOTE" rev-parse --verify --quiet refs/tags/spec/001 > /dev/null || { echo "case $label: the tag did not reach the remote"; return 1; }
        ;;
      "branch deletion")
        remote_has_branch doomed && { echo "case $label: the branch is still on the remote"; return 1; }
        ;;
    esac
  done
  true
}

# The rows share one repository and remote; each pushes branches of its own.
@test "the runner is handed each pushed branch sha once: a tag beside a branch, two branches, two branches at one commit" {
  local label branch_sha first_sha second_sha
  for label in "tag beside a branch" "two branches" "two branches at one commit"; do
    : > "$RUNNER_LOG"
    case "$label" in
      "tag beside a branch")
        branch_sha="$(commit_on_branch feat-one)"
        git -C "$REPO" tag spec/002
        run git -C "$REPO" push origin feat-one refs/tags/spec/002
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ "$(cat "$RUNNER_LOG")" = "push $branch_sha" ] || { echo "case $label: runner got [$(cat "$RUNNER_LOG")]"; return 1; }
        remote_has_branch feat-one || { echo "case $label: feat-one did not reach the remote"; return 1; }
        ;;
      "two branches")
        first_sha="$(commit_on_branch feat-a)"
        second_sha="$(commit_on_branch feat-b)"
        [ "$first_sha" != "$second_sha" ] || { echo "case $label: the branches share a sha"; return 1; }
        run git -C "$REPO" push origin feat-a feat-b
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" -eq 1 ] || { echo "case $label: runner ran more than once: $(cat "$RUNNER_LOG")"; return 1; }
        grep -qF -- "$first_sha" "$RUNNER_LOG" || { echo "case $label: first sha missing: $(cat "$RUNNER_LOG")"; return 1; }
        grep -qF -- "$second_sha" "$RUNNER_LOG" || { echo "case $label: second sha missing: $(cat "$RUNNER_LOG")"; return 1; }
        grep -qE -- "^push [0-9a-f]{40} [0-9a-f]{40}$" "$RUNNER_LOG" || { echo "case $label: not push and two shas: $(cat "$RUNNER_LOG")"; return 1; }
        ;;
      "two branches at one commit")
        branch_sha="$(commit_on_branch feat-same)"
        git -C "$REPO" branch feat-twin
        run git -C "$REPO" push origin feat-same feat-twin
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ "$(cat "$RUNNER_LOG")" = "push $branch_sha" ] || { echo "case $label: runner got [$(cat "$RUNNER_LOG")]"; return 1; }
        remote_has_branch feat-twin || { echo "case $label: feat-twin did not reach the remote"; return 1; }
        ;;
    esac
  done
}

# bats test_tags=protected
@test "a runner refusal refuses the push and the ref never reaches the remote" {
  commit_on_branch feat-red > /dev/null
  printf '1\n' > "$RUNNER_STATUS"
  run git -C "$REPO" push origin feat-red
  [ "$status" -ne 0 ]
  [ -s "$RUNNER_LOG" ]
  if remote_has_branch feat-red; then return 1; fi
}

@test "a missing runner fails open with one warning line naming CI" {
  commit_on_branch feat-open > /dev/null
  rm "$REPO/.gaia/tests/verify-harness.sh"
  run git -C "$REPO" push origin feat-open
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pre-push:' <<<"$output")" -eq 1 ]
  grep -qF -- "CI is the remaining check" <<<"$output"
  remote_has_branch feat-open
}

@test "no skip spelling lets a refused push through" {
  commit_on_branch feat-skip > /dev/null
  printf '1\n' > "$RUNNER_STATUS"

  run env SKIP=1 git -C "$REPO" push origin feat-skip
  [ "$status" -ne 0 ]
  if remote_has_branch feat-skip; then return 1; fi

  run env GAIA_SKIP_PREPUSH=1 git -C "$REPO" push origin feat-skip
  [ "$status" -ne 0 ]
  if remote_has_branch feat-skip; then return 1; fi
}
