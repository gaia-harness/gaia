#!/usr/bin/env bats

# Tests for .claude/hooks/block-pr-create-without-draft.sh, the PreToolUse guard
# that denies a `gh pr create` for the project's own repository unless it opens
# a draft. Exit 2 = block, 0 = allow.
#
# The hook is copied into a scratch git repository whose `origin` the test
# controls, so the own-repository decision never depends on the remote of the
# checkout running the suite. Every deny is paired with an allow one spelling
# away, so a hook that blocks everything or nothing fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # shellcheck source=../helpers/hook-registration.sh
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  SCRATCH="$BATS_TEST_TMPDIR/project"
  mkdir -p "$SCRATCH/.claude/hooks"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$SCRATCH/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/block-pr-create-without-draft.sh" "$SCRATCH/.claude/hooks/"
  git -C "$SCRATCH" init -q
  git -C "$SCRATCH" remote add origin 'git@github.com:Acme/Widgets.git'
  HOOK="$SCRATCH/.claude/hooks/block-pr-create-without-draft.sh"
  # A gh stub answers the visibility probe from $BATS_TEST_TMPDIR/visibility
  # and exits 1 (a probe error) while that file is absent, so no test reaches
  # the network.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/gh-calls"
[ -f "$BATS_TEST_TMPDIR/visibility" ] || exit 1
cat "$BATS_TEST_TMPDIR/visibility"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

run_hook() {
  local payload
  payload=$(jq -nc --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "${2:-$HOOK}"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
  grep -qF -- 'gh pr create --draft' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the own repository -------------------------------------------------------

# bats test_tags=protected
@test "a create with no --repo and no --draft is blocked and names the draft form" {
  run_hook 'gh pr create --title "feat: x" --body-file f'
  assert_blocked
}

# check_decision LABEL blocked|allowed
# assert_blocked/assert_allowed lean on errexit, which a `||` caller switches
# off, so a case-table row checks with explicit returns and names its label.
check_decision() {
  if [ "$2" = blocked ]; then
    [ "$status" -eq 2 ] || { echo "case $1: status=$status, expected 2: $output"; return 1; }
    grep -qF -- 'BLOCKED' <<<"$output" || { echo "case $1: no BLOCKED: $output"; return 1; }
    grep -qF -- 'gh pr create --draft' <<<"$output" || { echo "case $1: draft form not named: $output"; return 1; }
  else
    [ "$status" -eq 0 ] || { echo "case $1: status=$status, expected 0: $output"; return 1; }
    [ -z "$output" ] || { echo "case $1: unexpected output: $output"; return 1; }
  fi
}

# Each row: label~~decision~~command.
@test "the draft flag spellings decide a create on the origin repository: --draft, -d, --draft=true, --draft=false, --repo with --draft" {
  local row label rest decision cmd
  for row in \
    'draft~~allowed~~gh pr create --draft --title "feat: x" --body-file f' \
    'd~~allowed~~gh pr create -d --title "feat: x" --body-file f' \
    'draft-true~~allowed~~gh pr create --draft=true --title "feat: x"' \
    'draft-false~~blocked~~gh pr create --draft=false --title "feat: x"' \
    'repo-origin-draft~~allowed~~gh pr create --draft --repo acme/widgets --title "feat: x"'; do
    label=${row%%~~*}; rest=${row#*~~}
    decision=${rest%%~~*}; cmd=${rest#*~~}
    run_hook "$cmd"
    check_decision "$label" "$decision"
  done
}

# The origin is git@github.com:Acme/Widgets.git; owner and name compare without
# case, in slug or URL spelling, and the flag is read before or after `pr`.
@test "the repository flag spellings name the origin repository: --repo, -R, --repo=, ahead of the subcommand, URL, shared owner or name" {
  local row label rest decision cmd
  for row in \
    'repo-origin~~blocked~~gh pr create --repo Acme/Widgets --title "feat: x"' \
    'R-lower~~blocked~~gh pr create -R acme/widgets --title "feat: x"' \
    'repo-equals-upper~~blocked~~gh pr create --repo=ACME/WIDGETS --title "feat: x"' \
    'ahead-R~~blocked~~gh -R acme/widgets pr create --title "feat: x"' \
    'ahead-repo-equals~~blocked~~gh --repo=Acme/Widgets pr create --title "feat: x"' \
    'ahead-R-other~~allowed~~gh -R other/repo pr create --title "feat: x"' \
    'ahead-R-draft~~allowed~~gh -R acme/widgets pr create --draft --title "feat: x"' \
    'between-R~~blocked~~gh pr -R acme/widgets create --title "feat: x"' \
    'two-flags-one-origin~~blocked~~gh -R other/repo pr --repo acme/widgets create --title "feat: x"' \
    'between-R-other~~allowed~~gh pr -R other/repo create --title "feat: x"' \
    'url~~blocked~~gh pr create --repo https://github.com/acme/widgets.git --title "feat: x"' \
    'shares-owner~~allowed~~gh pr create --repo acme/gadgets --title "feat: x"' \
    'shares-name~~allowed~~gh pr create --repo other/widgets --title "feat: x"'; do
    label=${row%%~~*}; rest=${row#*~~}
    decision=${rest%%~~*}; cmd=${rest#*~~}
    run_hook "$cmd"
    check_decision "$label" "$decision"
  done
}

# GitHub refuses drafts on a private repository under some plans, so a
# non-draft create there is allowed. Only the exact answer PRIVATE counts;
# any other answer, an empty one, or a probe error (the stub exits 1 when no
# visibility file exists) keeps the block. The probe-target row also asserts the
# probe named the origin repository, normalized from the URL spelling.
# Each row: label~~visibility~~decision~~probe-call-or-dash~~command.
@test "a non-draft create is allowed only on a PRIVATE own repository, blocked on PUBLIC, INTERNAL, private, Private, empty and a probe error" {
  local row label rest visibility decision probe_call cmd
  for row in \
    'private-plain~~PRIVATE~~allowed~~-~~gh pr create --title "feat: x" --body-file f' \
    'private-repo~~PRIVATE~~allowed~~-~~gh pr create --repo Acme/Widgets --title "feat: x"' \
    'private-draft~~PRIVATE~~allowed~~-~~gh pr create --draft --title "feat: x"' \
    'probe-target~~PRIVATE~~allowed~~repo view acme/widgets --json visibility~~gh pr create -R https://github.com/ACME/widgets.git --title "feat: x"' \
    'public~~PUBLIC~~blocked~~-~~gh pr create --title "feat: x"' \
    'internal~~INTERNAL~~blocked~~-~~gh pr create --title "feat: x"' \
    'lowercase-private~~private~~blocked~~-~~gh pr create --title "feat: x"' \
    'titlecase-private~~Private~~blocked~~-~~gh pr create --title "feat: x"' \
    'empty-answer~~empty~~blocked~~-~~gh pr create --title "feat: x"' \
    'probe-error~~absent~~blocked~~-~~gh pr create --title "feat: x"' \
    'probe-error-repo~~absent~~blocked~~-~~gh pr create --repo acme/widgets --title "feat: x"'; do
    label=${row%%~~*}; rest=${row#*~~}
    visibility=${rest%%~~*}; rest=${rest#*~~}
    decision=${rest%%~~*}; rest=${rest#*~~}
    probe_call=${rest%%~~*}; cmd=${rest#*~~}
    rm -f "$BATS_TEST_TMPDIR/visibility" "$BATS_TEST_TMPDIR/gh-calls"
    case "$visibility" in
      absent) ;;
      empty) printf '\n' >"$BATS_TEST_TMPDIR/visibility" ;;
      *) printf '%s\n' "$visibility" >"$BATS_TEST_TMPDIR/visibility" ;;
    esac
    run_hook "$cmd"
    check_decision "$label" "$decision"
    if [ "$probe_call" != - ]; then
      grep -qF -- "$probe_call" "$BATS_TEST_TMPDIR/gh-calls" \
        || { echo "case $label: probe call '$probe_call' not made"; return 1; }
    fi
  done
}

# Another repository is out of scope, including the scaffold repository the
# release command opens a pull request on. The honest limits: a repository the
# shell expands cannot be read, so it is allowed; with no readable origin a
# --repo cannot be matched, so it is allowed, while a plain create still targets
# the own repository and stays blocked.
# Each row: label~~origin(keep|removed)~~decision~~command.
@test "another repository, the scaffold PR, a shell-expanded repository or a --repo with an unreadable origin is not blocked as the own repository" {
  local row label rest origin decision cmd
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  for row in \
    'other-repo~~keep~~allowed~~gh pr create --repo other/repo --title "feat: x" --body-file f' \
    'scaffold~~keep~~allowed~~gh pr create -R gaia-react/create-gaia --base main --head x --title "chore: y" --body-file f' \
    'shell-expanded~~keep~~allowed~~gh pr create --repo "$TARGET_REPO" --title "feat: x"' \
    'no-origin-repo~~removed~~allowed~~gh pr create --repo acme/widgets --title "feat: x"' \
    'no-origin-plain~~removed~~blocked~~gh pr create --title "feat: x"'; do
    label=${row%%~~*}; rest=${row#*~~}
    origin=${rest%%~~*}; rest=${rest#*~~}
    decision=${rest%%~~*}; cmd=${rest#*~~}
    git -C "$SCRATCH" remote remove origin 2>/dev/null || true
    if [ "$origin" = keep ]; then
      git -C "$SCRATCH" remote add origin 'git@github.com:Acme/Widgets.git'
    fi
    run_hook "$cmd"
    check_decision "$label" "$decision"
  done
}

# A create is read in command position: after `&&`, on the line after a
# comment. Data and quoted text are not commands: a heredoc body, a quoted
# mention, a title or body naming the flag, other gh pr verbs. A Monitor call
# stands down.
# Each row: label~~tool~~decision~~command.
@test "a create is read only in command position, not in data or quoted text, and a Monitor call stands down" {
  local row label rest tool decision cmd payload
  for row in \
    'after-push~~Bash~~blocked~~git push -u origin feat/x && gh pr create --title "feat: x" --body-file f' \
    'after-push-draft~~Bash~~allowed~~git push -u origin feat/x && gh pr create --draft --title "feat: x" --body-file f' \
    $'after-comment~~Bash~~blocked~~# open the PR\ngh pr create --title "feat: x"' \
    $'heredoc-body~~Bash~~allowed~~cat > notes.md <<\'EOF\'\ngh pr create --title "feat: x"\nEOF' \
    "quoted-mention~~Bash~~allowed~~echo 'gh pr create --title \"feat: x\"'" \
    'draft-in-title~~Bash~~blocked~~gh pr create --title "feat: --draft" --body "use -d"' \
    'pr-view~~Bash~~allowed~~gh pr view 12 --json title' \
    'pr-ready~~Bash~~allowed~~gh pr ready 12' \
    'monitor~~Monitor~~allowed~~gh pr create --title "feat: x"'; do
    label=${row%%~~*}; rest=${row#*~~}
    tool=${rest%%~~*}; rest=${rest#*~~}
    decision=${rest%%~~*}; cmd=${rest#*~~}
    payload=$(jq -nc --arg tool "$tool" --arg command "$cmd" '{tool_name: $tool, tool_input: {command: $command}}')
    run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
    check_decision "$label" "$decision"
  done
}

# --- registration and fail-loud libraries -------------------------------------

@test "the hook is registered on the PreToolUse Bash|Monitor matcher beside the title guard" {
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-pr-create-without-draft.sh
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-invalid-pr-title.sh
}

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  rm -f "$SCRATCH/.claude/hooks/lib/hook-payload.sh"
  run_hook 'gh pr create --title "feat: x"'
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-pr-create-without-draft.sh cannot load lib/hook-payload.sh' <<<"$output"
}
