#!/usr/bin/env bats
# Every test exports its own FAKE_GH_PR_BODY into the subshell bats creates
# for it, which is the point: the fixture must not leak to the next test, and
# the hook runs as a child of that same subshell, so it does see the value.
# shellcheck disable=SC2030,SC2031
#
# Tests for `.claude/hooks/issue-claim-release.sh`, the PostToolUse Bash hook
# that strips the `in-progress` claim label from every issue a merged pull
# request closes.
#
# Each test runs the hook against a throwaway git repo, with a fake `gh` on
# PATH that answers `pr view` from FAKE_GH_PR_STATE / FAKE_GH_PR_BODY and
# records every `pr view` ref and `issue edit` call under $FAKE_GH_STATE for
# assertions. Nothing is staged for `repo-scope.sh`: the hook resolves that
# lib from its OWN location rather than from cwd, so it reaches the real one
# beside it and a sandbox copy would never be read.
#
# The sandbox repo's toplevel directory is named exactly `gaia`, matching the
# repo-NAME half of the home slug the fake gh reports (`gaia-react/gaia`). The
# hook compares the whole [HOST/]OWNER/REPO against that slug rather than the
# directory basename, so the name decides nothing on its own. It is kept
# because it is what makes the same-named-sibling fixtures adversarial:
# `--repo other-org/gaia` is precisely the value a repo-NAME comparison calls
# home, so those cases red the moment the boundary regresses to one.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABSOLUTE_PATH=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/issue-claim-release.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"

  PARENT=$(mktemp -d -t issue-claim-release-test-XXXXXX)
  REPO="$PARENT/gaia"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  FAKE_GH_STATE="$BATS_TEST_TMPDIR/gh-state"
  mkdir -p "$FAKE_GH_STATE"
  : > "$FAKE_GH_STATE/issue_edits"
  : > "$FAKE_GH_STATE/issue_edit_repos"
  : > "$FAKE_GH_STATE/pr_view_calls"
  write_gh_stub
  export FAKE_GH_STATE
  export FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-MERGED}"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# Fake `gh` answering the calls this hook makes: `repo view` (the home repo),
# `pr view` (both fields at once, and re-read while the state has not settled
# on MERGED) and `issue edit ... --remove-label ...`. State lives under
# $FAKE_GH_STATE so a test can assert on it after run_hook.
#
# `pr view` reproduces real gh's precedence, verified against gh 2.96: a URL
# selector resolves the repository from the URL and OVERRIDES --repo. Without
# that, a stub would answer every URL out of the home repo and the URL cases
# below would pass on a hook that never guards the boundary at all.
write_gh_stub() {
  cat > "$GH_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
STATE="$FAKE_GH_STATE"
HOME_REPO="${FAKE_GH_HOME_REPO:-gaia-react/gaia}"
HOME_HOST="${FAKE_GH_HOME_HOST:-github.com}"
case "$1" in
  repo)
    shift
    case "$1" in
      # gh identifies a repo as [HOST/]OWNER/REPO, so the hook reads the slug
      # and the URL's authority from one call; the stub answers both.
      view)
        jq -n --arg name_with_owner "$HOME_REPO" --arg url "https://$HOME_HOST/$HOME_REPO" \
          '{nameWithOwner: $name_with_owner, url: $url}'
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view)
        shift
        pr_reference=""
        repo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --json|-q|--jq) shift 2 ;;
            -R|--repo) repo="$2"; shift 2 ;;
            -*) shift ;;
            *) pr_reference="$1"; shift ;;
          esac
        done
        case "$pr_reference" in
          *://*)
            stripped="${pr_reference#*://}"
            stripped="${stripped#*/}"
            repo="${stripped%%/pull/*}"
            ;;
        esac
        [ -n "$repo" ] || repo="$HOME_REPO"
        printf '%s' "$pr_reference" > "$STATE/pr_view_ref"
        printf '%s' "$repo" > "$STATE/pr_view_repo"
        echo x >> "$STATE/pr_view_calls"
        calls=$(wc -l < "$STATE/pr_view_calls" | tr -d ' ')
        # FAKE_GH_PR_STATE_SEQUENCE answers successive `pr view` calls from a
        # whitespace-separated list, so a test can put a state that changes
        # between reads in front of the hook. Past the end of the list the
        # last entry repeats, which is what a state that never settles looks
        # like. Unset, every call answers FAKE_GH_PR_STATE, as before.
        state="${FAKE_GH_PR_STATE:-MERGED}"
        if [ -n "${FAKE_GH_PR_STATE_SEQUENCE:-}" ]; then
          i=0
          for sequence_state in $FAKE_GH_PR_STATE_SEQUENCE; do
            i=$((i + 1))
            state="$sequence_state"
            [ "$i" -ge "$calls" ] && break
          done
        fi
        # The same shape for the call itself failing: the first
        # FAKE_GH_PR_VIEW_FAIL_CALLS reads exit non-zero with no output.
        if [ "$calls" -le "${FAKE_GH_PR_VIEW_FAIL_CALLS:-0}" ]; then
          exit 1
        fi
        jq -n --arg state "$state" --arg body "${FAKE_GH_PR_BODY:-}" \
          '{state: $state, body: $body}'
        exit "${FAKE_GH_PR_VIEW_EXIT:-0}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  issue)
    shift
    case "$1" in
      edit)
        shift
        issue_number=""
        repo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -R|--repo) repo="$2"; shift 2 ;;
            --remove-label|--add-label) shift 2 ;;
            -*) shift ;;
            *) issue_number="$1"; shift ;;
          esac
        done
        echo "$issue_number" >> "$STATE/issue_edits"
        echo "$repo" >> "$STATE/issue_edit_repos"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "$GH_BIN/gh"
}

run_hook() {
  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1")
  invoke_hook_in "$REPO" "$input" "$HOOK_ABSOLUTE_PATH"
}

pr_view_calls() { wc -l < "$FAKE_GH_STATE/pr_view_calls" | tr -d ' '; }
released_issues() { cat "$FAKE_GH_STATE/issue_edits" 2>/dev/null; }
assert_released_once() { [ "$(grep -cxF -- "$1" <<<"$(released_issues)")" -eq 1 ]; }
assert_nothing_released() { [ ! -s "$FAKE_GH_STATE/issue_edits" ]; }

# reset_hook_state: a clean slate between the rows of a case table, so one
# row's recorded gh calls and fixture variables never reach the next.
reset_hook_state() {
  : > "$FAKE_GH_STATE/issue_edits"
  : > "$FAKE_GH_STATE/issue_edit_repos"
  : > "$FAKE_GH_STATE/pr_view_calls"
  rm -f "$FAKE_GH_STATE/pr_view_ref" "$FAKE_GH_STATE/pr_view_repo"
  unset FAKE_GH_PR_BODY FAKE_GH_PR_STATE_SEQUENCE FAKE_GH_PR_VIEW_FAIL_CALLS FAKE_GH_HOME_HOST
  export FAKE_GH_PR_STATE=MERGED
}

@test "only a MERGED pull request releases, and the state re-reads are bounded" {
  reset_hook_state
  export FAKE_GH_PR_STATE="OPEN"
  export FAKE_GH_PR_BODY="Closes #9"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 4"; return 1; }
  assert_nothing_released || { echo "case 4"; return 1; }

# 4a-4c: the state read is re-read briefly rather than decided on one
# immediate read. The hook runs microseconds after the merge call returns, and
# GitHub answers the state from a replica, so a merge that landed can still
# read OPEN on the first look. Deciding there is silent and costs the release.
  reset_hook_state
  export FAKE_GH_PR_STATE_SEQUENCE="OPEN MERGED"
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 4a"; return 1; }
  assert_released_once "12" || { echo "case 4a"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_STATE_SEQUENCE="OPEN"
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 4b"; return 1; }
  assert_nothing_released || { echo "case 4b"; return 1; }
  # Both directions: it did re-read, and the re-reading is bounded rather than
  # waiting out a pull request that a rejected merge leaves open indefinitely.
  [ "$(pr_view_calls)" -ge 2 ] || { echo "case 4b"; return 1; }
  [ "$(pr_view_calls)" -le 5 ] || { echo "case 4b"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_VIEW_FAIL_CALLS=1
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 4c"; return 1; }
  assert_released_once "12" || { echo "case 4c"; return 1; }

  reset_hook_state
  # 4b's bound on the other arm into the loop: a state that never settles and a
  # call that never answers are separate ways to stay in it.
  #
  # A red here means the cap grew. A cap that went away produces no red at all:
  # this suite sets no per-test timeout (bats offers BATS_TEST_TIMEOUT, and
  # setup_file is the latest useful place to set one) and run_hook imposes
  # none, so a loop that never terminates emits neither ok nor not ok and the
  # job dies on its own timeout with nothing attributed to this test.
  export FAKE_GH_PR_VIEW_FAIL_CALLS=99
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 4d"; return 1; }
  assert_nothing_released || { echo "case 4d"; return 1; }
  [ "$(pr_view_calls)" -ge 2 ] || { echo "case 4d"; return 1; }
  [ "$(pr_view_calls)" -le 5 ] || { echo "case 4d"; return 1; }
}

@test "closing-keyword spellings in the body decide which issues release, each once" {
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 1"; return 1; }
  assert_released_once "12" || { echo "case 1"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY=$'Fixes #3\nresolved #4\nCLOSES #5'
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 2"; return 1; }
  assert_released_once "3" || { echo "case 2"; return 1; }
  assert_released_once "4" || { echo "case 2"; return 1; }
  assert_released_once "5" || { echo "case 2"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY=$'Closes #7\nCloses #7'
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 3"; return 1; }
  assert_released_once "7" || { echo "case 3"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="See discussion, no keyword here"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5"; return 1; }
  assert_nothing_released || { echo "case 5"; return 1; }

# GitHub requires a closing keyword to stand as its own word, so a keyword
# that is only the tail of a longer one closes nothing and must release
# nothing. This is the one direction in which the hook can strip a claim off
# work still in flight.
  reset_hook_state
  export FAKE_GH_PR_BODY="This leaves the design unresolved #91 for now"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5b"; return 1; }
  assert_nothing_released || { echo "case 5b"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="resolved #4"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5c"; return 1; }
  assert_released_once "4" || { echo "case 5c"; return 1; }

# 5d-5f cover the two spellings GitHub documents beside the bare one. The
# first two are merges that DID close an issue, so failing to match them
# leaves a claim live on finished work; the third is the reason the qualifier
# is compared rather than merely allowed.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes: #5"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5d"; return 1; }
  assert_released_once "5" || { echo "case 5d"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes gaia-react/gaia#12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5e"; return 1; }
  assert_released_once "12" || { echo "case 5e"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes other-org/other-repo#13"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 5f"; return 1; }
  assert_nothing_released || { echo "case 5f"; return 1; }
}

@test "a merge not in command position (string, comment, other command, heredoc, directory change, subshell) releases nothing" {
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'echo "gh pr merge 42"'
  [ "$status" -eq 0 ] || { echo "case 6"; return 1; }
  assert_nothing_released || { echo "case 6"; return 1; }

# Test 6 pins a mention with no real invocation after it. 6b and 6c pin the
# other half: a mention FOLLOWED by one. Both assert the selector rather than
# the release, because that is where the defect shows, the hook reads some
# other pull request's state and body and releases whatever THAT one closed.
# 6b-6g are one contract, not six: the merge has to BE the first command in
# the tool call. The arming match only proves the phrase appears somewhere a
# command could start, and a comment, another command's quoted value, a
# heredoc body line, a directory change and a subshell all satisfy that while
# meaning something else. Each one previously resolved a pull request this
# merge never touched and stripped labels off its issues.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook $'# gh pr merge 5 (old, already done)\ngh pr merge 9'
  [ "$status" -eq 0 ] || { echo "case 6b"; return 1; }
  assert_nothing_released || { echo "case 6b"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr comment 9 --body "ready; gh pr merge 5 landed" && gh pr merge 9'
  [ "$status" -eq 0 ] || { echo "case 6c"; return 1; }
  assert_nothing_released || { echo "case 6c"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'cat <<\'EOF\' > notes.md\ngh pr merge 5\nEOF\ngh pr merge 9'
  [ "$status" -eq 0 ] || { echo "case 6d"; return 1; }
  assert_nothing_released || { echo "case 6d"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'git fetch && cd ../other && gh pr merge 5'
  [ "$status" -eq 0 ] || { echo "case 6e"; return 1; }
  assert_nothing_released || { echo "case 6e"; return 1; }

# The subshell form is the one the shell-cwd rule pushes toward, and it is
# glued to its `cd`, so any guard matching the word `cd` misses it. Under the
# first-command contract the spelling stops mattering.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook '(cd ../other && gh pr merge 5 --squash)'
  [ "$status" -eq 0 ] || { echo "case 6g"; return 1; }
  assert_nothing_released || { echo "case 6g"; return 1; }

# 6f and 6h are the controls that keep the contract from collapsing into
# "release nothing". A command AFTER the merge cannot change which pull
# request merged, so it is still read; and an empty leading piece, from a
# newline or from the second character of `&&`, is not a command at all.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 1508 && git checkout main'
  [ "$status" -eq 0 ] || { echo "case 6f"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 6f"; return 1; }
  assert_released_once "77" || { echo "case 6f"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'\n  gh pr merge 1508'
  [ "$status" -eq 0 ] || { echo "case 6h"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 6h"; return 1; }
  assert_released_once "77" || { echo "case 6h"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia && gh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ] || { echo "case 7s"; return 1; }
  assert_nothing_released || { echo "case 7s"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 -t "subj"; gh issue list --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7u"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7u"; return 1; }
  assert_released_once "77" || { echo "case 7u"; return 1; }

# The merge has to be the first command in the tool call, so an ordinary
# benign prefix costs the release. That is the deliberate price of the
# first-command contract, and it is what the rule's own bullet tells a reader
# to expect, so it is pinned rather than left to drift.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'git fetch && gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 9"; return 1; }
  assert_nothing_released || { echo "case 9"; return 1; }

# The generic past-bound pairing (6d's heredoc, padded past
# GAIA_VERB_ARM_MAXIMUM_CHARACTERS, arms because the walker abstains above the bound)
# cannot discriminate through this hook's own release: the heredoc's first
# command is necessarily `cat`, never `gh`, so the first-command boundary (6d,
# 9) declines here regardless of arming or masking, above the bound or below
# it. The bound's effect on arming is proven once, at the library level, in
# verb-arming-lib.bats; this pins that the boundary decline still holds past
# the bound, so a bigger heredoc never becomes a spurious release.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  local pad
  pad=$(printf 'x%.0s' $(seq 1 16400))
  run_hook $'cat <<\'EOF\' > notes.md\n'"$pad"$'\ngh pr merge 5\nEOF\ngh pr merge 9'
  [ "$status" -eq 0 ] || { echo "case 11"; return 1; }
  assert_nothing_released || { echo "case 11"; return 1; }
}

@test "only a home-repo reference, flag or URL resolves; a foreign, sibling, other-host or cluster form releases nothing" {
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #99"
  run_hook 'gh pr merge --repo other-org/other-repo 1'
  [ "$status" -eq 0 ] || { echo "case 7"; return 1; }
  assert_nothing_released || { echo "case 7"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --repo gaia-react/gaia 12'
  [ "$status" -eq 0 ] || { echo "case 7b"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "12" ] || { echo "case 7b"; return 1; }
  assert_released_once "12" || { echo "case 7b"; return 1; }

# 7f-7h cover the reference form the `--repo` guard cannot reach. gh takes
# `<number> | <url> | <branch>`, and a URL names its own repository, so a
# merged sibling-repo pull request read by URL would otherwise have its
# closing references applied to THIS repository's issues of the same number.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #99"
  run_hook 'gh pr merge https://github.com/other-org/other-repo/pull/1'
  [ "$status" -eq 0 ] || { echo "case 7f"; return 1; }
  assert_nothing_released || { echo "case 7f"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge https://github.com/gaia-react/gaia/pull/1508'
  [ "$status" -eq 0 ] || { echo "case 7g"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7g"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_repo")" = "gaia-react/gaia" ] || { echo "case 7g"; return 1; }
  assert_released_once "12" || { echo "case 7g"; return 1; }

# The sandbox toplevel is named `gaia`, so `--repo other-org/gaia` is exactly
# the value a repo-NAME comparison calls "home". repo-scope.sh's blocking
# guard does compare that way, and for a consumer that ENFORCES the
# over-classification is safe; this hook ACTS, so it compares the whole slug
# and this case has to stay foreign.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo other-org/gaia 5'
  [ "$status" -eq 0 ] || { echo "case 7i"; return 1; }
  assert_nothing_released || { echo "case 7i"; return 1; }

# gh accepts flags in any position, so the boundary check has to survive a
# --repo written after the reference. 7k and 7l are 7i with the argument order
# reversed, which is the spelling a leading-flag-only guard leaves open.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7k"; return 1; }
  assert_nothing_released || { echo "case 7k"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash -R other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7l"; return 1; }
  assert_nothing_released || { echo "case 7l"; return 1; }

# gh takes its repository flag ahead of the subcommand too. The flag still
# decides the boundary there, and the last spelling wins, as gh's own does.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh -R gaia-react/gaia pr merge 12 --squash'
  [ "$status" -eq 0 ] || { echo "case 7bc"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "12" ] || { echo "case 7bc"; return 1; }
  assert_released_once "12" || { echo "case 7bc"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh --repo=gaia-react/gaia pr merge 12'
  [ "$status" -eq 0 ] || { echo "case 7bd"; return 1; }
  assert_released_once "12" || { echo "case 7bd"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh -R other-org/gaia pr merge 5'
  [ "$status" -eq 0 ] || { echo "case 7be"; return 1; }
  assert_nothing_released || { echo "case 7be"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh -R gaia-react/gaia pr merge 5 -R other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7bf"; return 1; }
  assert_nothing_released || { echo "case 7bf"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge 42'
  [ "$status" -eq 0 ] || { echo "case 7h"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_repo")" = "gaia-react/gaia" ] || { echo "case 7h"; return 1; }
  [ "$(grep -cxF -- "gaia-react/gaia" "$FAKE_GH_STATE/issue_edit_repos")" -eq 1 ] || { echo "case 7h"; return 1; }

# Test 6 proves the matcher rejects a mention inside a string. This proves the
# other half: a real invocation after a shell separator DOES arm. Without it,
# separator_regex could silently stop matching and every compound-command merge would
# release nothing with the suite still green.
# gh's flag library accepts a shorthand with its value attached, so this is
# the same invocation as the spaced form two cases up. Read as a bare boolean
# flag it sets no repository at all, and the whole-slug boundary check below
# never arms: the hook then reads THIS repository's pull request 5.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -Rother-org/other-repo 5'
  [ "$status" -eq 0 ] || { echo "case 7ae"; return 1; }
  assert_nothing_released || { echo "case 7ae"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -Rgaia-react/gaia 5'
  [ "$status" -eq 0 ] || { echo "case 7af"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7af"; return 1; }
  assert_released_once "77" || { echo "case 7af"; return 1; }

# 7ak-7an: gh identifies a repository as [HOST/]OWNER/REPO, so the slug alone
# does not name one. An adopter mirroring a repository between github.com and
# an enterprise host carries the SAME owner/repo on both, and the shared guard
# compares only the repo-name half, so nothing upstream separates them. Read
# on the slug alone, a merge on the other host resolves this host's pull
# request of that number and strips labels off issues it never closed. The
# home-host controls are what keep the check from degrading into "reject every
# qualifier".
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo ghe.example.com/gaia-react/gaia 5'
  [ "$status" -eq 0 ] || { echo "case 7ak"; return 1; }
  assert_nothing_released || { echo "case 7ak"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo github.com/gaia-react/gaia 5'
  [ "$status" -eq 0 ] || { echo "case 7al"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7al"; return 1; }
  assert_released_once "77" || { echo "case 7al"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://ghe.example.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ] || { echo "case 7am"; return 1; }
  assert_nothing_released || { echo "case 7am"; return 1; }

# The mirror direction: when the enterprise host IS home, its own URL has to
# resolve and github.com's must not. Without this the check could pass by
# hardcoding github.com rather than by reading the home repository.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  export FAKE_GH_HOME_HOST="ghe.example.com"
  run_hook 'gh pr merge https://github.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ] || { echo "case 7an"; return 1; }
  assert_nothing_released || { echo "case 7an"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  export FAKE_GH_HOME_HOST="ghe.example.com"
  run_hook 'gh pr merge https://ghe.example.com/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ] || { echo "case 7ao"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7ao"; return 1; }
  assert_released_once "77" || { echo "case 7ao"; return 1; }

# 7ap-7aq: gh's own URL matcher is unanchored after the number and its host
# comparison drops a port, so each of these merges home pull request 5 while a
# tighter matcher declines and leaves the claim standing. The shape rules live
# in the lib and `repo-scope-home-pr.bats` covers them exhaustively; these two
# pin that THIS hook reaches them, which is the half a lib-only suite cannot
# see. 7ap is the spelling a human actually produces, by copying the address
# bar off the Files tab.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://github.com/gaia-react/gaia/pull/5/files'
  [ "$status" -eq 0 ] || { echo "case 7ap"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7ap"; return 1; }
  assert_released_once "77" || { echo "case 7ap"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://github.com:443/gaia-react/gaia/pull/5'
  [ "$status" -eq 0 ] || { echo "case 7aq"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7aq"; return 1; }
  assert_released_once "77" || { echo "case 7aq"; return 1; }

  reset_hook_state
  # The relaxation is to the shape, never to the repository comparison.
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://github.com/other-org/other-repo/pull/5/files'
  [ "$status" -eq 0 ] || { echo "case 7ar"; return 1; }
  assert_nothing_released || { echo "case 7ar"; return 1; }

# 7ag-7aj: gh clusters single-dash shorthands, and this parser does not model
# that. The first value-taking letter in a cluster swallows the rest of the
# token or the next word, so `-sR<slug>` leaves the repository check unarmed
# and `-st 1234 5` hands `1234` to the subject. Read as one unknown flag both
# resolve a pull request in THIS repository that the merge never touched, so
# a cluster is refused outright rather than decoded. 7aj is the control: a
# lone shorthand is not a cluster and still works.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sRother-org/other-repo 5'
  [ "$status" -eq 0 ] || { echo "case 7ag"; return 1; }
  assert_nothing_released || { echo "case 7ag"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sR other-org/other-repo 5'
  [ "$status" -eq 0 ] || { echo "case 7ah"; return 1; }
  assert_nothing_released || { echo "case 7ah"; return 1; }

# Refused even when it names the home repo, and even when every letter in it
# is a boolean. The parser cannot tell those apart from the dangerous shape
# without modelling the cluster grammar, and this is the direction to be
# wrong in: `-sd 1508` costs a release that is done by hand.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -sd 1508'
  [ "$status" -eq 0 ] || { echo "case 7ai"; return 1; }
  assert_nothing_released || { echo "case 7ai"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge -s 1508'
  [ "$status" -eq 0 ] || { echo "case 7aj"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7aj"; return 1; }
  assert_released_once "77" || { echo "case 7aj"; return 1; }

# 7at, 7au: GitHub resolves OWNER/REPO case-insensitively, so a merge spelled
# in another case lands on the home repository and a case-sensitive comparison
# would read it as a different one and cost the release. Every half of the
# value is compared case-blind, and the three cases below cover them: the
# owner half here, both halves of a URL in 7au, and the repo-NAME half in 7av.
# 7aw and 7ay pin the direction that keeps case-blindness honest.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo GAIA-React/gaia 5'
  [ "$status" -eq 0 ] || { echo "case 7at"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7at"; return 1; }
  assert_released_once "77" || { echo "case 7at"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge https://github.com/GAIA-React/GAIA/pull/5'
  [ "$status" -eq 0 ] || { echo "case 7au"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7au"; return 1; }
  assert_released_once "77" || { echo "case 7au"; return 1; }

# 7av-7ay: the boundary is read from the SCANNED value rather than from a
# regex over the raw command, which is what makes these four spellings behave.
# The repo-NAME half of a `--repo` value used to be compared case-sensitively
# against the checkout's directory basename by a pre-filter that ran first, so
# 7av's spelling was called foreign and cost the release; and a quoted value
# kept its quotes through that capture, so 7ax's was too. The scan strips the
# quotes and knows which command in the tool call owns the flag.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo gaia-react/GAIA 5'
  [ "$status" -eq 0 ] || { echo "case 7av"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7av"; return 1; }
  assert_released_once "77" || { echo "case 7av"; return 1; }

  reset_hook_state
  # 7av's safety direction: case-blindness must not turn a different
  # repository into the home one.
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo OTHER-ORG/GAIA 5'
  [ "$status" -eq 0 ] || { echo "case 7aw"; return 1; }
  assert_nothing_released || { echo "case 7aw"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo="gaia-react/gaia" 5'
  [ "$status" -eq 0 ] || { echo "case 7ax"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7ax"; return 1; }
  assert_released_once "77" || { echo "case 7ax"; return 1; }

  reset_hook_state
  # 7ax's safety direction, and the one that matters: reading a quoted value
  # at all is only correct if reading it foreign still declines.
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo="other-org/gaia" 5'
  [ "$status" -eq 0 ] || { echo "case 7ay"; return 1; }
  assert_nothing_released || { echo "case 7ay"; return 1; }
}

@test "quoting, separators, newlines, continuations and block boundaries do not change the resolved reference" {
# 7p-7r pin the separator handling in both directions. A separator inside a
# quoted subject or body is ordinary text and must not end the scan, or every
# token after it, a trailing --repo included, drops out of the set the guard
# reads. A real separator must still end it, or a later command's own --repo
# decides this one.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body "fix; ship it" --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7p"; return 1; }
  assert_nothing_released || { echo "case 7p"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body "a | b" -R other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7q"; return 1; }
  assert_nothing_released || { echo "case 7q"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash -t "labels: rename; recolor" --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7r"; return 1; }
  assert_nothing_released || { echo "case 7r"; return 1; }

# 7t-7w pin the boundary between the two, which is where a pattern over the
# raw text keeps getting it wrong: a separator glued to a CLOSING quote is a
# real separator, a separator inside an open quote or behind a backslash is
# text. Each spelling below is ordinary shell, not a crafted string.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --repo other-org/gaia -t "subj"; gh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ] || { echo "case 7t"; return 1; }
  assert_nothing_released || { echo "case 7t"; return 1; }

# A newline separates two commands exactly as `&&` does, and the matcher that
# arms this hook already treats it that way, so the scan has to agree.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge --repo other-org/gaia 5 --squash\ngh issue list --repo gaia-react/gaia'
  [ "$status" -eq 0 ] || { echo "case 7x"; return 1; }
  assert_nothing_released || { echo "case 7x"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge --squash\necho done'
  [ "$status" -eq 0 ] || { echo "case 7y"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "" ] || { echo "case 7y"; return 1; }
  assert_released_once "77" || { echo "case 7y"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --squash --body="fix; ship it" --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7v"; return 1; }
  assert_nothing_released || { echo "case 7v"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --body fix\;ship --repo other-org/gaia'
  [ "$status" -eq 0 ] || { echo "case 7w"; return 1; }
  assert_nothing_released || { echo "case 7w"; return 1; }

# 7z and 7aa are the other half of 7w: a backslash before a newline is a line
# CONTINUATION rather than an escape, so both characters go away instead of
# the newline becoming a word. Treated as an escape it becomes the first
# non-flag word, which is the reference, so a merge written across two lines
# resolves a newline and releases nothing. 7aa pins that the bogus word takes
# the slot even when the real number comes later.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge \\\n  1508 --squash'
  [ "$status" -eq 0 ] || { echo "case 7z"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7z"; return 1; }
  assert_released_once "77" || { echo "case 7z"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'gh pr merge \\\n  --squash 1508'
  [ "$status" -eq 0 ] || { echo "case 7aa"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7aa"; return 1; }
  assert_released_once "77" || { echo "case 7aa"; return 1; }

# The scan reads the command one fixed-size block at a time, so word, quote and
# escape state has to survive a block boundary. Every other case here is short
# enough to fit in one block, which would leave the chaining unexercised. These
# two straddle several boundaries: 7ab carries a word across them, 7ac holds a
# quoted span open across them so a separator inside it stays text and the flag
# after it is still scanned.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  local pad
  pad=$(printf 'x%.0s' $(seq 1 600))
  run_hook "gh pr merge --body \"$pad\" 1508"
  [ "$status" -eq 0 ] || { echo "case 7ab"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7ab"; return 1; }
  assert_released_once "77" || { echo "case 7ab"; return 1; }

# 7ab and 7ac pin quote state across a boundary but not the WORD itself: in
# both, a word truncated at the boundary is a flag value nothing reads back,
# so the reference still resolves. This sweeps the reference across a whole
# block's worth of offsets so at least one run has it straddling, whatever
# the scan's block constant is; a truncated word there resolves the wrong
# pull request outright.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  local padding_length padding
  for padding_length in $(seq 230 262); do
    padding=$(printf 'x%.0s' $(seq 1 "$padding_length"))
    run_hook "gh pr merge --body \"$padding\" 1508"
    [ "$status" -eq 0 ] || { echo "case 7ad"; return 1; }
    [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7ad"; return 1; }
  done

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  local half body
  half=$(printf 'x%.0s' $(seq 1 300))
  body="$half;$half"
  run_hook "gh pr merge 5 --body \"$body\" --repo other-org/gaia"
  [ "$status" -eq 0 ] || { echo "case 7ac"; return 1; }
  assert_nothing_released || { echo "case 7ac"; return 1; }

# 7n and 7o pin the spellings that carry a quote into the parser. Each one
# fails closed when mishandled, releasing nothing on a merge that closed
# issues, which the rule promises needs no manual step.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --squash --body="release notes here" 1508'
  [ "$status" -eq 0 ] || { echo "case 7n"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7n"; return 1; }
  assert_released_once "12" || { echo "case 7n"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge "1508" --squash'
  [ "$status" -eq 0 ] || { echo "case 7o"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7o"; return 1; }
  assert_released_once "12" || { echo "case 7o"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge --squash --body "release notes here" 1508'
  [ "$status" -eq 0 ] || { echo "case 7j"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1508" ] || { echo "case 7j"; return 1; }
  assert_released_once "12" || { echo "case 7j"; return 1; }
}

@test "flag arity: -m is boolean, -F and -A take a value" {
# 7c-7e pin the value-taking flag table against gh's real flag set. Each one
# fails if the table gains or loses the flag it names: a boolean listed as
# value-taking swallows the reference, and a value-taking flag left out makes
# its own value the reference. Both end the same way, a merged pull request
# whose issues keep a live claim forever.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -m 1498'
  [ "$status" -eq 0 ] || { echo "case 7c"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ] || { echo "case 7c"; return 1; }
  assert_released_once "12" || { echo "case 7c"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -F notes.txt 1498'
  [ "$status" -eq 0 ] || { echo "case 7d"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ] || { echo "case 7d"; return 1; }
  assert_released_once "12" || { echo "case 7d"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  run_hook 'gh pr merge -A me@example.com 1498'
  [ "$status" -eq 0 ] || { echo "case 7e"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "1498" ] || { echo "case 7e"; return 1; }
  assert_released_once "12" || { echo "case 7e"; return 1; }
}

@test "a trailing or leading comment never changes the resolved merge" {
# 7az-7bb and 7as: a word-initial unquoted `#` opens a shell COMMENT, so gh
# receives none of it. Read as ordinary text those words reach the flag parser,
# and a `--repo` among them wins over the one the merge carried, because the
# parser keeps the last one it sees and the shared guard captures greedily.
# 7az is the harm that reaches: a merge landing in the SIBLING repository,
# stripping claims here. 7ba and 7bb are the controls that the arm cuts a
# comment rather than every `#`. 7as pins the stop rather than a skip to the
# newline: a comment hiding a leading command must not promote the words after
# it into the first command, which is the one shape a skip would get wrong.
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --repo other-org/other-repo 5 # was --repo gaia-react/gaia'
  [ "$status" -eq 0 ] || { echo "case 7az"; return 1; }
  assert_nothing_released || { echo "case 7az"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge 5 --squash # ship it'
  [ "$status" -eq 0 ] || { echo "case 7ba"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7ba"; return 1; }
  assert_released_once "77" || { echo "case 7ba"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook 'gh pr merge --body fix#77 5'
  [ "$status" -eq 0 ] || { echo "case 7bb"; return 1; }
  [ "$(cat "$FAKE_GH_STATE/pr_view_ref")" = "5" ] || { echo "case 7bb"; return 1; }
  assert_released_once "77" || { echo "case 7bb"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #77"
  run_hook $'# merge it now\ngh pr merge 5'
  [ "$status" -eq 0 ] || { echo "case 7as"; return 1; }
  assert_nothing_released || { echo "case 7as"; return 1; }
}

@test "gh, jq or hook-payload.sh absent releases nothing and exits 0" {
  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  nogh_bin="$(path_allowlist bash jq git grep sort cat)"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh pr merge 42')
  PATH="$nogh_bin" invoke_hook_in "$REPO" "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case 8a"; return 1; }
  assert_nothing_released || { echo "case 8a"; return 1; }

  reset_hook_state
  export FAKE_GH_PR_BODY="Closes #12"
  nojq_bin="$(path_allowlist bash cat)"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh pr merge 42')
  PATH="$nojq_bin" invoke_hook_in "$REPO" "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case 8b"; return 1; }
  assert_nothing_released || { echo "case 8b"; return 1; }

  reset_hook_state
  local scratch="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch/.claude/hooks"
  cp -R "$(dirname "$HOOK_ABSOLUTE_PATH")/lib" "$scratch/.claude/hooks/lib"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch/.claude/hooks/issue-claim-release.sh"
  rm -f "$scratch/.claude/hooks/lib/hook-payload.sh"

  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'gh pr merge 5 --squash')
  cd "$REPO" || return 1
  invoke_hook "$input" "$scratch/.claude/hooks/issue-claim-release.sh"
  [ "$status" -eq 0 ] || { echo "case hook-payload-missing"; return 1; }
  [ -z "$output" ] || { echo "case hook-payload-missing"; return 1; }
  [ ! -s "$FAKE_GH_STATE/issue_edits" ] || { echo "case hook-payload-missing"; return 1; }
  [ ! -s "$FAKE_GH_STATE/pr_view_calls" ] || { echo "case hook-payload-missing"; return 1; }
}

# ---------- Shared arming decision (tokenizer, and the bound past 6d) ----------

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}
