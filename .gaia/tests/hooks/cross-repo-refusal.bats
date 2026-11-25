#!/usr/bin/env bats
#
# The fork (cross-repository) refusal: .claude/hooks/lib/cross-repo-refusal.sh
# on its own, and the merge gate (.claude/hooks/pr-merge-audit-check.sh)
# refusing a fork pull request before it reads or runs anything the checked-out
# tree carries.
#
# The merge cases check a fork head out as the working tree, with canary
# scripts at the paths the gate would otherwise source or run from it; a canary
# that runs appends to a log, so "the log does not exist" is the proof that no
# fork-supplied code ran. The audit-dispatch side lives in audit-loop-bound.bats and the pre-checkout
# guard in block-fork-pr-checkout.bats.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/cross-repo-refusal.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  export MGF_PLANT_REVIEW=1
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  LIBRARY_FILE="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/cross-repo-refusal.sh"
}

# --- the library ----------------------------------------------------------------

# library_stub <stdout> <stderr> <exit>: a gh answering every call the same way.
library_stub() {
  LIBRARY_STUB_BIN="$BATS_TEST_TMPDIR/lib-stub"
  mkdir -p "$LIBRARY_STUB_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "$BATS_TEST_TMPDIR/lib-gh.log"
    printf 'printf %%s %q\n' "$1"
    printf 'printf %%s %q >&2\n' "$2"
    printf 'exit %s\n' "$3"
  } > "$LIBRARY_STUB_BIN/gh"
  chmod +x "$LIBRARY_STUB_BIN/gh"
}

# ask <pr-argument>: the library's exit status, then its error line, on stdout.
ask() {
  run bash -c '. "$1"; exit_status=0; gaia_pr_is_cross_repository "$2" || exit_status=$?; printf "%s\n%s" "$exit_status" "$GAIA_CROSS_REPO_GH_ERROR"' \
    _ "$LIBRARY_FILE" "$1"
}

ask_with_stub() {
  local saved="$PATH"
  PATH="$LIBRARY_STUB_BIN:$PATH"
  ask "$1"
  PATH="$saved"
}

@test "library exit codes: true 0 and false 1 with the number reaching gh, empty argument asks the current branch, no pull request 1 for the current branch and 2 when numbered, other gh failure 2, neither true nor false 2, gh absent 2, non-numeric 2 without asking gh" {
  local label log="$BATS_TEST_TMPDIR/lib-gh.log" bin="$BATS_TEST_TMPDIR/no-gh-bin"
  for label in true-false empty-argument no-pr-current-branch no-pr-numbered other-gh-failure neither-true-nor-false gh-absent non-numeric; do
    rm -f "$log"
    case "$label" in
      true-false)
        library_stub 'true' '' 0
        ask_with_stub 34
        [ "${lines[0]}" = 0 ] || { echo "case $label: true gave ${lines[0]}"; return 1; }
        grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$log" || { echo "case $label: number did not reach gh"; return 1; }
        library_stub 'false' '' 0
        ask_with_stub 34
        [ "${lines[0]}" = 1 ] || { echo "case $label: false gave ${lines[0]}"; return 1; }
        ;;
      empty-argument)
        library_stub 'false' '' 0
        ask_with_stub ''
        [ "${lines[0]}" = 1 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$log" || { echo "case $label: gh got an empty positional"; return 1; }
        ;;
      no-pr-current-branch)
        library_stub '' 'no pull requests found for branch "feature"' 1
        ask_with_stub ''
        [ "${lines[0]}" = 1 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        ;;
      no-pr-numbered)
        library_stub '' 'no pull requests found for branch "feature"' 1
        ask_with_stub 34
        [ "${lines[0]}" = 2 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        ;;
      other-gh-failure)
        library_stub '' 'HTTP 502: Bad Gateway' 1
        ask_with_stub 34
        [ "${lines[0]}" = 2 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        grep -qF -- 'HTTP 502: Bad Gateway' <<<"${lines[1]}" || { echo "case $label: error does not name the failure: ${lines[1]}"; return 1; }
        grep -qF -- 'exited 1' <<<"${lines[1]}" || { echo "case $label: error does not name the exit: ${lines[1]}"; return 1; }
        ;;
      neither-true-nor-false)
        library_stub '{"isCrossRepository":false}' '' 0
        ask_with_stub 34
        [ "${lines[0]}" = 2 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        grep -qF -- 'neither true nor false' <<<"${lines[1]}" || { echo "case $label: error ${lines[1]}"; return 1; }
        ;;
      gh-absent)
        mkdir -p "$bin"
        ln -sf "$(command -v bash)" "$bin/bash"
        run env PATH="$bin" bash -c '. "$1"; exit_status=0; gaia_pr_is_cross_repository 34 || exit_status=$?; printf "%s\n%s" "$exit_status" "$GAIA_CROSS_REPO_GH_ERROR"' _ "$LIBRARY_FILE"
        [ "${lines[0]}" = 2 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        [ "${lines[1]}" = 'gh is not on PATH' ] || { echo "case $label: error ${lines[1]}"; return 1; }
        ;;
      non-numeric)
        library_stub 'false' '' 0
        ask_with_stub 'feature-branch'
        [ "${lines[0]}" = 2 ] || { echo "case $label: status ${lines[0]}"; return 1; }
        [ ! -s "$log" ] || { echo "case $label: gh was asked"; return 1; }
        ;;
    esac
  done
}

@test "library: a success with a hint on stderr is judged by stdout alone" {
  local hint
  hint="$(printf '%s\n' \
    'hint: if you need to wait for this pull request to be reviewed, merged, or closed before continuing, use this instead of polling:' \
    '    gh event listen --resource https://github.com/owner/repo/pull/34 --event com.github.pull_request.state.changed.v1' \
    '  - It prints the first event as a JSON line on stdout and exits; run it again to wait for the next one.')"
  library_stub 'false' "$hint" 0
  ask_with_stub 34
  [ "${lines[0]}" = 1 ]
  library_stub 'true' "$hint" 0
  ask_with_stub ''
  [ "${lines[0]}" = 0 ]
  library_stub '{"isCrossRepository":false}' "$hint" 0
  ask_with_stub 34
  [ "${lines[0]}" = 2 ]
  grep -qF -- "answered '{\"isCrossRepository\":false}'" <<<"${lines[1]}"
}

# The same guards deny Claude the fetch the manual path starts with, so a
# refusal that reads as Claude's own instruction leaves it no step it can take.
@test "library: the refusal message names the manual path and hands it to the user, sourced once or twice" {
  local label sources needle
  for label in once twice; do
    sources='. "$1";'
    [ "$label" = once ] || sources='. "$1"; . "$1";'
    run bash -c "$sources"' printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$LIBRARY_FILE"
    [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
    for needle in \
      'This pull request comes from a fork (cross-repository).' \
      "would run the fork's own harness code with your credentials" \
      'review the harness diff by hand (.claude/, .gaia/, .github/)' \
      'push the branch to origin so it becomes a same-repo pull request' \
      'run the PR Merge Workflow on that.' \
      "The manual path is the user's to run, not Claude's: ask the user to" \
      'fetch the fork branch without checking it out'; do
      grep -qF -- "$needle" <<<"$output" || { echo "case $label: message lacks: $needle"; return 1; }
    done
  done
}

@test "library: sourcing does no work (no gh call)" {
  library_stub 'true' '' 0
  PATH="$LIBRARY_STUB_BIN:$PATH" bash -c '. "$1"' _ "$LIBRARY_FILE"
  [ ! -s "$BATS_TEST_TMPDIR/lib-gh.log" ]
}

# --- the merge gate -------------------------------------------------------------

# fork_head_fixture: REPO's working tree IS the fork's head, carrying canaries
# where the gate would source or run code from the acting tree.
fork_head_fixture() {
  mgf_init
  CANARY_LOG="$BATS_TEST_TMPDIR/canary.log"
  local canary
  for canary in .gaia/scripts/resolve-audit-members.sh .gaia/scripts/chore-deps-skip.sh \
    .gaia/scripts/main-root-lib.sh \
    .claude/hooks/lib/audit-scope.sh .claude/hooks/lib/audit-digest.sh; do
    mkdir -p "$REPO/$(dirname "$canary")"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >> %q\n' "$canary" "$CANARY_LOG" > "$REPO/$canary"
    chmod +x "$REPO/$canary"
  done
  mgf_commit "wiki/page.md" "doc"
  git -C "$REPO" add -f .gaia/scripts .claude/hooks/lib
  git -C "$REPO" commit --quiet -m "fork harness"
  mgf_record 34 true "docs: from a fork" "wiki/page.md"
}

refusal_message() {
  bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$LIBRARY_FILE"
}

# bats test_tags=protected
@test "UAT-010: a fork pull request's merge is denied with the refusal, and no fork-supplied code runs" {
  local reason
  fork_head_fixture
  mgf_run_merge "gh pr merge 34 --squash"
  assert_denied_by_json
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  grep -qF -- "$(refusal_message)" <<<"$reason"
  grep -qF -- 'review the harness diff by hand' <<<"$reason"
  grep -qF -- 'push the branch to origin' <<<"$reason"
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$MGF_GH_LOG"
  [ ! -e "$CANARY_LOG" ] || { printf 'fork code ran:\n%s\n' "$(cat "$CANARY_LOG")" >&2; return 1; }
  [ "$(mgf_post_count)" -eq 0 ]
}

# One fork-head fixture serves every row: a denied row reads and writes nothing
# in REPO, so each row resets only the gh log and the stub file it planted, and
# the same-repo row, the one the gate lets past the fork check, runs last.
@test "UAT-010: a merge naming no pull request is denied against the current branch's fork, an undecidable one is denied with nothing posted, a same-repo one is not refused as a fork" {
  local row label reason
  fork_head_fixture
  for row in "current-branch|gh pr merge --squash --delete-branch" "undecidable|gh pr merge 34 --squash" "same-repo|gh pr merge 34 --squash"; do
    label=${row%%|*}
    : > "$MGF_GH_LOG"
    rm -f "$MGF_STUB_DIRECTORY/pr-view-fails"
    case "$label" in
      undecidable) printf 'HTTP 502: Bad Gateway (https://api.github.com/graphql)\n' > "$MGF_STUB_DIRECTORY/pr-view-fails" ;;
      same-repo) mgf_record 34 false "docs: same repo" "wiki/page.md" ;;
    esac
    mgf_run_merge "${row#*|}"
    if [ "$label" = same-repo ]; then
      grep -qF -- 'comes from a fork' <<<"$output" && { echo "case $label: refused as a fork"; return 1; }
      # Positive control: the canary paths are paths the gate runs once the fork check passes.
      [ -e "$CANARY_LOG" ] || { echo "case $label: no canary ran, so the absence checks above prove nothing"; return 1; }
      grep -qxF -- '.gaia/scripts/resolve-audit-members.sh' "$CANARY_LOG" || { echo "case $label: resolve-audit-members.sh canary not run: $(cat "$CANARY_LOG")"; return 1; }
      continue
    fi
    [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
    assert_denied_by_json || { echo "case $label: not denied: $output"; return 1; }
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
    if [ "$label" = current-branch ]; then
      grep -qF -- 'comes from a fork (cross-repository)' <<<"$output" || { echo "case $label: no fork refusal"; return 1; }
      grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$MGF_GH_LOG" || { echo "case $label: gh not asked about the current branch"; return 1; }
    else
      grep -qF -- 'cannot tell whether pull request 34 comes from a fork' <<<"$reason" || { echo "case $label: no cannot-tell reason: $reason"; return 1; }
      grep -qF -- 'HTTP 502: Bad Gateway' <<<"$reason" || { echo "case $label: gh error not named"; return 1; }
      grep -qF -- 'push the branch to origin' <<<"$reason" || { echo "case $label: no manual path"; return 1; }
    fi
    [ ! -e "$CANARY_LOG" ] || { echo "case $label: fork code ran: $(cat "$CANARY_LOG")"; return 1; }
    [ "$(mgf_post_count)" -eq 0 ] || { echo "case $label: a status was posted"; return 1; }
  done
}
