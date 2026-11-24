#!/usr/bin/env bats
#
# The pre-checkout fork guard, .claude/hooks/block-fork-pr-checkout.sh: a
# PreToolUse Bash hook that denies `gh pr checkout <n>` and a `git fetch` of
# `pull/<n>/head` when gh reports pull request <n> as cross-repository, or
# cannot say. Driven directly with PreToolUse payloads and a logging gh stub
# that answers per pull request number.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/block-fork-pr-checkout.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="$REPO_ROOT/.claude/hooks/block-fork-pr-checkout.sh"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/gh-stub"
  GH_LOG="$STUB_DIRECTORY/gh.log"
  mkdir -p "$STUB_DIRECTORY/bin"
  : >"$GH_LOG"
  # Pull request 34 is a fork and 12 is not; `$STUB_DIRECTORY/fail` makes every
  # `pr view` fail the way an unreachable API does.
  cat >"$STUB_DIRECTORY/bin/gh" <<EOF
#!/usr/bin/env bash
stub_directory="$STUB_DIRECTORY"
EOF
  cat >>"$STUB_DIRECTORY/bin/gh" <<'EOF'
printf '%s\n' "$*" >>"$stub_directory/gh.log"
if [ -f "$stub_directory/fail" ]; then
  echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2
  exit 1
fi
case "$*" in
  "repo view --json nameWithOwner --jq .nameWithOwner") echo o/r ;;
  "pr view 34 --json isCrossRepository --jq .isCrossRepository") echo true ;;
  "pr view 12 --json isCrossRepository --jq .isCrossRepository") echo false ;;
  *) echo "Could not resolve to a PullRequest" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB_DIRECTORY/bin/gh"
  MESSAGE="$(bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$REPO_ROOT/.claude/hooks/lib/cross-repo-refusal.sh")"
}

# run_guard <command> [hook]
run_guard() {
  local payload
  payload="$(jq -n -c --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')"
  run env PATH="$STUB_DIRECTORY/bin:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "${2:-$HOOK}"
}

reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"
}

# assert_reason_has <fragment>: the denial reason carries it; an empty fragment
# asserts nothing.
assert_reason_has() {
  if [ -n "$1" ]; then
    reason | grep -qF -- "$1"
  fi
}

# assert_gh_asked_about <pull request number>: the stub saw the cross-repo
# query for it.
assert_gh_asked_about() {
  grep -qxF -- "pr view $1 --json isCrossRepository --jq .isCrossRepository" "$GH_LOG"
}

# bats test_tags=protected
@test "UAT-010: gh pr checkout of a fork pull request is denied with the refusal" {
  run_guard 'gh pr checkout 34'
  assert_denied_by_json
  reason | grep -qF -- "$MESSAGE"
  reason | grep -qF -- 'review the harness diff by hand'
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$GH_LOG"
}

# Rows: a git fetch of the head ref, the same through `git -C` (the spelling the
# rules prescribe), a pull-request URL target read for its number, and flags
# before the target that must not hide it.
@test "a fork pull request checkout or fetch is denied" {
  local command_text
  local rows=(
    'git fetch origin pull/34/head:pr-34'
    'git -C /tmp/x fetch origin pull/34/head:pr-34'
    'gh pr checkout https://github.com/o/r/pull/34'
    'gh pr checkout --branch local-name 34'
  )
  for command_text in "${rows[@]}"; do
    echo "case: $command_text"
    : >"$GH_LOG"
    run_guard "$command_text"
    assert_denied_by_json
    assert_reason_has "$MESSAGE"
    assert_gh_asked_about 34
  done
}

# A repository flag names a repository the guard cannot ask gh about from the
# working directory, so every placement is refused before gh is called: after
# the target, ahead of the subcommand in every spelling, and on a checkout
# started by a subshell, brace group, negation or keyword.
@test "a repository flag in any placement is denied" {
  local row command_text fragment checkout
  local rows=(
    'gh pr checkout 12 --repo other/repo|names another repository (--repo)'
    'gh pr checkout 12 -R other/repo|names another repository (-R)'
  )
  for command_text in 'gh -R other/repo pr checkout 12' 'gh --repo other/repo pr checkout 12' \
    'gh --repo=other/repo pr checkout 12' 'gh pr -R other/repo checkout 12' \
    'gh pr --repo other/repo checkout 12' 'gh pr checkout 5 && gh -R other/repo pr checkout 12' \
    'gh -R a/b pr -R other/repo checkout 12' \
    'cat <(gh -R other/repo pr checkout 12)' 'cat >(gh -R other/repo pr checkout 12)' \
    'gh -R other/repo pr checkout 12 $( gh pr checkout 12 )' 'gh -R other/repo pr checkout 12 `gh pr checkout 12`'; do
    rows+=("$command_text|a repository flag before the subcommand")
  done
  for checkout in 'gh -R other/repo pr checkout 12' 'gh pr checkout 12 -R other/repo'; do
    for command_text in "($checkout)" "{ $checkout; }" "! $checkout" "if true; then $checkout; fi" \
      "for i in 1; do $checkout; done" "while $checkout; do :; done" "sleep 1 & $checkout" \
      "case x in x) $checkout;; esac" "time $checkout"; do
      rows+=("$command_text|")
    done
  done
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r command_text fragment <<<"$row"
    : >"$GH_LOG"
    run_guard "$command_text"
    assert_denied_by_json
    assert_reason_has "$fragment"
    [ ! -s "$GH_LOG" ]
  done
}

# A foreign URL is refused on the URL alone, never by asking gh about the
# number; a URL naming this repository is refused when gh cannot name it.
@test "a URL naming another or unknown repository is denied" {
  local row command_text unreachable fragment
  local rows=(
    'gh pr checkout https://github.com/other/repo/pull/12|no|other/repo'
    'gh pr checkout https://github.com/o/r/pull/12|yes|could not say which repository'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r command_text unreachable fragment <<<"$row"
    rm -f "$STUB_DIRECTORY/fail"
    if [ "$unreachable" = yes ]; then : >"$STUB_DIRECTORY/fail"; fi
    : >"$GH_LOG"
    run_guard "$command_text"
    assert_denied_by_json
    assert_reason_has "$fragment"
    if [ "$unreachable" = no ]; then
      grep -qF -- 'pr view 12' "$GH_LOG" && return 1
    fi
  done
  true
}

@test "when gh cannot answer or the target cannot be read, deny" {
  local row command_text unreachable fragment_one fragment_two fragment_three
  local rows=(
    'gh pr checkout 34|yes|cannot tell whether pull request 34 comes from a fork|HTTP 502: Bad Gateway|push the branch to origin'
    'gh pr checkout some-branch|no|gh pr checkout <number>||'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r command_text unreachable fragment_one fragment_two fragment_three <<<"$row"
    rm -f "$STUB_DIRECTORY/fail"
    if [ "$unreachable" = yes ]; then : >"$STUB_DIRECTORY/fail"; fi
    : >"$GH_LOG"
    run_guard "$command_text"
    assert_denied_by_json
    assert_reason_has "$fragment_one"
    assert_reason_has "$fragment_two"
    assert_reason_has "$fragment_three"
    if [ "$unreachable" = no ]; then
      [ ! -s "$GH_LOG" ]
    fi
  done
}

@test "same-repo and unrelated calls are allowed" {
  local command_text
  # Calls that ask gh about pull request 12, which is not a fork. A repository
  # flag ahead of another gh subcommand does not deny the home checkout after it.
  local asks_gh_rows=(
    'gh -R other/repo pr view 3 && gh pr checkout 12'
    'gh pr checkout https://github.com/o/r/pull/12'
    'gh pr checkout 12'
  )
  # Calls that never reach gh: unrelated, no pull-request refspec, or a
  # checkout only cited in a heredoc body.
  local no_gh_rows=(
    'git status'
    'git fetch origin main'
    $'cat > notes.txt <<EOF\ngh pr checkout 34\nEOF\n'
  )
  for command_text in "${asks_gh_rows[@]}"; do
    echo "case: asks gh: $command_text"
    : >"$GH_LOG"
    run_guard "$command_text"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    assert_gh_asked_about 12
  done
  for command_text in "${no_gh_rows[@]}"; do
    echo "case: no gh: $command_text"
    : >"$GH_LOG"
    run_guard "$command_text"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$GH_LOG" ]
  done

  echo "case: a non-Bash tool call"
  run env PATH="$STUB_DIRECTORY/bin:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ \
    '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# run_prefilter_probe <command> [hook]: drives the hook with jq and gh stubs
# first on PATH that each touch a sentinel, so a run that spawns either leaves
# it behind.
run_prefilter_probe() {
  local payload probe_bin="$BATS_TEST_TMPDIR/probe-bin"
  payload="$(jq -n -c --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')"
  PROBE_SENTINEL="$BATS_TEST_TMPDIR/probe-spawned"
  mkdir -p "$probe_bin"
  for tool in jq gh; do
    cat >"$probe_bin/$tool" <<EOF
#!/usr/bin/env bash
echo $tool >>"$PROBE_SENTINEL"
EOF
    chmod +x "$probe_bin/$tool"
  done
  run env PATH="$probe_bin:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "${2:-$HOOK}"
}

@test "a command naming neither checkout nor pull exits before spawning jq or gh" {
  run_prefilter_probe 'ls -la'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$PROBE_SENTINEL" ]
}

@test "a missing cross-repo library denies an armed call instead of allowing it" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/no-cross-lib"
  mkdir -p "$hook_copy_directory/lib"
  cp "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/jq-availability.sh" "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" \
    "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$REPO_ROOT/.claude/hooks/lib/verb-arming-view.sh" \
    "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-helpers.sh" "$REPO_ROOT/.claude/hooks/lib/verb-arming-live-view.sh" \
    "$REPO_ROOT/.claude/hooks/lib/hook-payload.sh" \
    "$hook_copy_directory/lib/"
  run_guard 'gh pr checkout 12' "$hook_copy_directory/block-fork-pr-checkout.sh"
  assert_denied_by_json
  reason | grep -qF -- 'cross-repo-refusal.sh'
}

@test "the guard is registered under PreToolUse for Bash in the rooted command form" {
  # Any matcher naming Bash: the merge gate it sits beside is registered under
  # a matcher shared with another tool.
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher | split("|") | index("Bash"))' block-fork-pr-checkout.sh
  # shellcheck disable=SC2016 # the expansion is literal text in settings.json
  jq -e --arg command '"$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.claude/hooks/block-fork-pr-checkout.sh"' \
    '[.hooks.PreToolUse[] | select(.matcher | split("|") | index("Bash")) | .hooks[].command] | index($command) != null' "$SETTINGS"
}

# --- the one-jq payload reader ---

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'gh pr checkout 12' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/block-fork-pr-checkout.sh"
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-fork-pr-checkout.sh cannot load lib/hook-payload.sh' <<<"$output"
}

# The allow list lets this form through without a prompt; the hook still denies it.
@test "an allowed gh pr checkout form is still denied for a fork pull request" {
  . "$REPO_ROOT/.gaia/tests/helpers/gh-allow-list.sh"
  gh_command_is_allowed 'gh pr checkout 34'
  run_guard 'gh pr checkout 34'
  assert_denied_by_json
}
