#!/usr/bin/env bats

# Tests for .claude/hooks/block-main-destructive-git.sh. The hook's own header
# states what it blocks. It fires only on a real `git` INVOCATION in command
# position; command text that merely mentions `git commit` / `git push` (a grep
# pattern, an echo string, an argument to another program) does not trip it.
#
# Each test drives the hook as the harness does: a PreToolUse JSON payload on
# stdin, run with the repo as the working directory, which is where the hook
# resolves the current branch when the payload names no cwd. On every case
# here allow and deny both exit 0, with the verdict carried in stdout. The
# exception is a library the hook refuses to run without: its failed load prints
# a BLOCKED: line and exits 2. Every other library load degrades and still exits 0.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-main-destructive-git.sh"

  REPO=$(mktemp -d -t block-main-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t block-main-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  reap_gh_stub_pids
  return 0
}

# A hanging gh stub records its pid (and its sleeping child's) in gh-pids; kill
# any still alive so an orphaned sleep cannot outlive the test.
reap_gh_stub_pids() {
  local pid
  [ -f "${BATS_TEST_TMPDIR:-/nonexistent}/gh-pids" ] || return 0
  for pid in $(cat "$BATS_TEST_TMPDIR/gh-pids"); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  return 0
}

on_main() { git -C "$REPO" checkout --quiet main; }
on_feature() { git -C "$REPO" checkout --quiet -B feature; }

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local command="$1"
  local json
  json=$(jq -n --arg command "$command" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABSOLUTE_PATH"
}

# Same, for a case whose verdict turns on the directory the command runs in:
# the payload carries that directory as its cwd and the hook is invoked there.
run_hook_from() {
  local json
  json=$(jq -n --arg command "$1" --arg directory "$2" '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')
  invoke_hook_in "$2" "$json" "$HOOK_ABSOLUTE_PATH"
}

# Case-table support. A row is 'verdict|branch|process_directory|payload_directory|command':
# verdict is deny or allow; branch is main, feature (a fresh feature branch),
# keep_feature (the existing feature branch) or none; both directories empty
# means the payload carries no cwd and the hook runs in the home repo, and an
# empty payload directory reuses the process directory. The command is last so
# it may carry the separator. Placeholders in the directory and command fields
# name the fixtures.
resolve_row_text() {
  local text="$1"
  text=${text//@MAIN@/$REPO}
  text=${text//@WTA@/$BATS_TEST_TMPDIR/wt-a}
  text=${text//@WTB@/$BATS_TEST_TMPDIR/wt-b}
  text=${text//@WT@/$BATS_TEST_TMPDIR/wt}
  text=${text//@FOREIGN@/$FOREIGN}
  text=${text//@SPACED@/$BATS_TEST_TMPDIR/dir with space}
  text=${text//@TMP@/$BATS_TEST_TMPDIR}
  text=${text//@HEAD@/${HEAD_SHA:-}}
  printf '%s' "$text"
}

run_row() {
  local rest="$1" verdict branch process_directory payload_directory command
  verdict=${rest%%|*}; rest=${rest#*|}
  branch=${rest%%|*}; rest=${rest#*|}
  process_directory=${rest%%|*}; rest=${rest#*|}
  payload_directory=${rest%%|*}; command=${rest#*|}
  process_directory=$(resolve_row_text "$process_directory")
  payload_directory=$(resolve_row_text "${payload_directory:-$process_directory}")
  command=$(resolve_row_text "$command")
  case "$branch" in
    main) on_main ;;
    feature) on_feature ;;
    keep_feature) git -C "$REPO" checkout --quiet feature ;;
    none) ;;
    *) echo "bad branch: $branch"; return 1 ;;
  esac
  if [ -z "$process_directory" ]; then
    run_hook "$command"
  else
    run_hook_split "$command" "$process_directory" "$payload_directory"
  fi
  case "$verdict" in
    deny) assert_denied_by_json ;;
    allow) assert_allowed_by_json ;;
    *) echo "bad verdict: $verdict"; return 1 ;;
  esac
}

add_worktree() {
  git -C "$REPO" worktree add --quiet -b wt-branch "$BATS_TEST_TMPDIR/wt"
}

# --- denied ---

# bats test_tags=protected
@test "git commit on main is denied" {
  on_main
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

# bats test_tags=protected
@test "force-push to main is denied from a feature branch" {
  on_feature
  run_hook 'git push --force origin main'
  assert_denied_by_json
}

@test "a plain push from main, and a refspec push naming main, are denied" {
  local row
  local rows=(
    'deny|main|||git push'
    'deny|feature|||git push origin main'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# Every gate explains itself: each denial says why the action is blocked, not
# only that it is, so the reader can weigh the repair it names. Two independent
# conditions reach the push deny and their repairs differ, so an operator denied
# for the refspec, already on a feature branch, is not told to create one; the
# on-main cause answers first where both hold, because leaving main settles the
# refspec too. Row: branch|command|needle|second needle|text that must be absent.
@test "each denial states its reason and the repair it names" {
  local row branch command present_one present_two absent
  local rows=(
    "main|git commit -m \"x\"|Work reaches 'main' only through a pull request, where the audit gate reviews it before it merges.||"
    'main|git push|It lands local commits on the shared branch without the pull request and audit every change passes through.||'
    'feature|git push --force origin main|Its history is shared, so rewriting it pulls commits out from under every clone and branch built on it.|Fix conflicts with a merge or rebase on the feature branch, then open a PR.|'
    'feature|git push origin HEAD|refspec names main, master or HEAD||Create a feature branch and open a PR'
    'feature|git push origin HEAD|without the pull request and audit every change passes through|git push -u origin <branch-name>|'
    'main|git push|Create a feature branch and open a PR||'
    'main|git push origin main|Create a feature branch and open a PR||refspec names main, master or HEAD'
    'second|git reset --hard HEAD~1|any commit the branch holds after it is dropped|Ask the user to run it themselves|'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r branch command present_one present_two absent <<<"$row"
    case "$branch" in
      main) on_main ;;
      feature) on_feature ;;
      second) on_feature_with_second_commit ;;
    esac
    run_hook "$command"
    assert_denied_by_json
    grep -qF -- "$present_one" <<<"$output"
    [ -z "$present_two" ] || grep -qF -- "$present_two" <<<"$output"
    [ -n "$absent" ] && grep -qF -- "$absent" <<<"$output" && return 1
  done
  true
}

# A spelling of a commit or push that once hid it from the rules: a `-R` or
# `-C` belonging to another program or to commit itself, a global option or a
# quoted option value ahead of the subcommand, an option or several refspecs
# ahead of the operand naming main, and a `-C` path carrying whitespace. The
# remote is required for the trailing `-R` row: with none, the repo-scope
# helper has no repository name to compare and fails closed a line earlier,
# which would pass that row without exercising it. A `-c` value naming main is
# not a refspec, so that row is the allowed control.
@test "a spelling variant of commit or push is still decided on main" {
  local row spaced="$BATS_TEST_TMPDIR/dir with space"
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  mkdir -p "$spaced"
  git -C "$spaced" init --quiet --initial-branch=main
  git -C "$spaced" config user.email "test@example.com"
  git -C "$spaced" config user.name "Test"
  git -C "$spaced" config commit.gpgsign false
  echo "# readme" > "$spaced/README.md"
  git -C "$spaced" add README.md
  git -C "$spaced" commit --quiet -m init
  local rows=(
    'deny|main|||git -C @MAIN@ commit -m "x"'
    'deny|main|||git commit -m x && grep -R app/routes .'
    'deny|main|||git commit --allow-empty -C HEAD'
    'deny|main|||git commit --allow-empty -m x -C HEAD'
    'deny|main|||git -c user.name=x commit -m "y"'
    'deny|main|||git --no-pager commit -m "y"'
    'deny|main|||git -c pack.threads=1 push'
    'deny|main|||git --no-pager push'
    'deny|feature|||git -c pack.threads=1 push origin main'
    'deny|feature|||git --no-pager push origin HEAD:main'
    'allow|feature|||git -c user.name=main push --force origin feature'
    'deny|feature|||git push -f origin main'
    'deny|main|||git -c "user.name=a b" commit -m x'
    "deny|main|||git -c 'user.name=a b' commit -m x"
    'deny|main|||git --namespace "a b" commit -m x'
    'deny|main|||git -c "user.name=a b" push origin main'
    'deny|main|||git -c "user.name=a b" push --force origin main'
    'deny|main|@SPACED@||git -C "@SPACED@" commit -m x'
    'deny|feature|||git push --quiet origin main'
    'deny|feature|||git push -q origin main'
    'deny|feature|||git push --quiet origin HEAD:main'
    'deny|feature|||git push --quiet --no-verify origin master'
    'deny|feature|||git push --quiet origin feature main'
    'deny|feature|||git push origin -- main'
    'deny|feature|||git push --quiet origin +main'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The operand scan must not read an ordinary feature push as a push to main, a
# push option's own value (quoted or not) is not a refspec, and a quoted
# argument carrying a branch name is ordinary text.
@test "feature-branch commits and pushes are allowed, quoted and option text included" {
  local row
  local rows=(
    'allow|feature|||git push --quiet origin feature'
    'allow|feature|||git push -o ci.skip origin feature'
    'allow|feature|||git push --quiet --no-verify origin feature'
    'allow|feature|||git commit -m "touch up main and master"'
    'allow|feature|||git push origin feature -o "ci.skip main"'
    'allow|feature|||git commit -m "x"'
    'allow|feature|||git push origin feature'
    'allow|feature|||git push'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The repo-scope verdict covers the whole tool call, so any home command in it
# keeps the guard armed, including a commit inside a substitution in a foreign
# command's own arguments, which runs in this repository first.
@test "a foreign-repo call does not exempt a home commit" {
  local row
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  local rows=(
    'allow|main|||git -C @FOREIGN@ commit -m "x"'
    'deny|main|||gh pr merge 5 -R other/x && git commit -m y'
    'deny|main|||gh pr merge 5 -R other/x; git commit -m y'
    'deny|main|||'$'gh pr merge 5 -R other/x\ngit commit -m y'
    'deny|main|||git commit -m y && git -C @FOREIGN@ status'
    'deny|main|||gh pr view 5 -R other/x --jq "$(git commit -m y)"'
    'deny|main|||git -C @FOREIGN@ log --format "$(git commit -m y)"'
    'deny|main|||gh pr create -R other/x --body-file =(git commit -m y)'
    'allow|main|||gh pr merge 5 -R other/x && git -C @FOREIGN@ commit -m y'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# A linked worktree is this repository, so a `cd` into one is enforced against
# the branch the command runs on rather than the session's. The payload's cwd
# is the acting agent's directory, so a command with no `cd` and no `-C` is
# judged on the branch there, not on the hook process's own; relative `cd` and
# `-C` words resolve against it; a payload cwd that is not an absolute path
# inside a git tree falls back to the process cwd; and the walk's own reset
# boundary, spelled in command text, must not clear the tracked directory.
@test "cd, -C and the payload cwd pick the checkout a commit or push is read against" {
  local row
  on_main
  add_worktree
  git -C "$BATS_TEST_TMPDIR/wt" commit --quiet --allow-empty -m "worktree only"
  mkdir "$BATS_TEST_TMPDIR/wt/sub" "$REPO/sub"
  local rows=(
    "allow|main|@MAIN@||cd '@WT@' && git commit -m x"
    "allow|main|@MAIN@||cd '@WT@' && git push origin wt-branch"
    "deny|main|@WT@||cd '@MAIN@' && git commit -m x"
    'allow|main|@MAIN@|@WT@|git push'
    'allow|main|@MAIN@|@WT@|git push -u origin wt-branch'
    'allow|main|@MAIN@|@WT@|git commit -m x'
    'deny|main|@WT@|@MAIN@|git push'
    'deny|main|@WT@|@MAIN@|git commit -m x'
    'deny|main|@MAIN@|@WT@|git reset --hard main'
    'allow|main|@MAIN@|@WT@|git reset --hard HEAD'
    'allow|main|@MAIN@|@WT@|cd sub && git push'
    'allow|main|@MAIN@|@WT@|git -C sub commit -m x'
    'deny|main|@WT@|@MAIN@|cd sub && git commit -m x'
    'deny|main|@WT@|@MAIN@|git -C sub commit -m x'
    'deny|main|@MAIN@|relative/dir|git push'
    'deny|main|@MAIN@|@TMP@|git push'
    "deny|main|@WT@||cd '@MAIN@';__gaia_walk_reset__;git commit -m x"
    "deny|main|@WT@||cd '@MAIN@';__gaia_walk_reset__;git push"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# A failed `cd` leaves the real shell where the previous one moved it, so a
# target that does not resolve keeps the tracked directory; a resolvable second
# hop still replaces the first. The other half of an unresolvable `cd` is that
# the hop may have SUCCEEDED into a checkout the scan cannot name (`cd -` lands
# back where the shell started), so a candidate standing on main arms the rule,
# from a main checkout and from a worktree alike. The ambiguity reads
# candidates, not the session: with nothing on main to find it stays allowed.
@test "an unresolvable cd is read against every checkout it could name" {
  local row
  on_main
  add_worktree
  # shellcheck disable=SC2016 # the hook must receive the unexpanded text
  local rows=(
    'deny|main|@MAIN@||cd "$UNSET_VAR" && git commit -m x'
    'deny|main|@MAIN@||cd /nonexistent; git commit -m x'
    'deny|main|@MAIN@||cd ${ROOT}; git push'
    "deny|main|@WT@||cd '@MAIN@'; cd /nonexistent; git commit -m x"
    "deny|main|@WT@||cd '@MAIN@'; cd /nonexistent; git push"
    "deny|main|@WT@||cd '@MAIN@'; cd \"\$UNSET_VAR\"; git commit -m x"
    "allow|main|@WT@||cd '@MAIN@'; cd '@WT@'; git commit -m x"
    "deny|main|@MAIN@||cd '@WT@' && cd - && git commit -m x"
    "deny|main|@MAIN@||cd '@WT@' && cd - && git push"
    "deny|main|@MAIN@||cd '@WT@'; cd \"\$BACK\"; git commit -m x"
    "allow|feature|@MAIN@||cd '@WT@' && cd - && git commit -m x"
    'deny|main|@WT@||cd "$MAIN" && git commit -m x'
    'deny|main|@WT@||cd "$MAIN" && git push'
    'deny|main|@WT@||cd - && git commit -m x'
    'allow|feature|@WT@||cd "$MAIN" && git commit -m x'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# A directory word the scan CAN read settles which checkout the segment acts
# in, whatever repository it names. Reading a readable sibling repository as
# ambiguous denied a commit landing in that sibling against THIS checkout's
# branch. Driven from a linked worktree with the main checkout on main, the
# shape that separates the readings: the worktree's own branch allows, and only
# a candidate found through the ambiguity arm denies.
@test "a readable foreign -C or cd beside a home command is not ambiguous" {
  local row
  on_main
  foreign_on_sidebranch
  add_worktree
  local rows=(
    'allow|main|@WT@||git status && git -C @FOREIGN@ commit -m x'
    'allow|main|@WT@||git status && git -C @FOREIGN@ push'
    'allow|main|@WT@||git status && cd @FOREIGN@ && git commit -m x'
    'allow|main|@WT@||git status && cd @FOREIGN@ && git push'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The arms the directory read adds, each isolated from the ambiguity arm that
# would otherwise answer for them. Three checkouts, with the session's own and
# the main checkout BOTH off main, leave the tracked `cd` target, the `-C`
# fallback and the working-directory probe as the only things that can deny.
@test "a kept cd target, the -C fallback and the cwd candidate each deny with no candidate on main" {
  local row
  three_checkouts
  local rows=(
    "deny|none|@WTA@||cd '@WTB@'; cd /nonexistent; git commit -m x"
    "deny|none|@WTA@||cd '@WTB@'; cd /nonexistent; git push"
    "deny|none|@WTA@||cd '@WTB@'; git -C \"\$UNSET_VAR\" commit -m x"
    "deny|none|@WTB@||cd '@WTA@'; cd /nonexistent; git commit -m x"
    "deny|none|@WTB@||cd '@WTA@'; cd /nonexistent; git push"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# A tilde reaches the directory read as a literal character, since it arrived
# as text inside the tool call rather than through a shell. Both callers route
# their word through the expansion, and the bare `~` and the `~/` prefix are
# each their own case arm, so with no case driving one the arm can be removed
# with nothing going red. Driven from a worktree with every other candidate off
# main, so the deny can only come from the expansion resolving, for a foreign
# word too. Row: home directory|session directory|command.
@test "a literal tilde is expanded before the branch is read" {
  local row home_directory session_directory command
  three_checkouts
  local rows=(
    '@WTB@|@WTA@|git -C ~ commit -m x'
    '@WTB@|@WTA@|git -C ~ push'
    '@WTB@|@WTA@|git -C ~/. commit -m x'
    '@WTB@|@WTA@|cd ~ && git commit -m x'
    '@WTB@|@WTA@|cd ~/. && git commit -m x'
    '@FOREIGN@|@WTA@|git status && git -C ~ commit -m x'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r home_directory session_directory command <<<"$row"
    run_hook_from_home "$command" "$(resolve_row_text "$session_directory")" "$(resolve_row_text "$home_directory")"
    assert_denied_by_json
  done
}

# The `-C` word is read by a scan that models quoting but never expands, so a
# value it cannot resolve names no readable checkout and falls back to the
# directory the command runs in, ambiguous on the same terms an unresolvable
# `cd` is. A later `cd` replaces the leading one, so a command that stepped
# into a worktree and back reads the main checkout, and a `cd` inside a subshell
# stands tracking down; the stand-down reads quoting, so a parenthesis inside a
# commit subject does not.
@test "-C and later cd decide the checkout a commit or push is read against" {
  local row
  on_main
  add_worktree
  # shellcheck disable=SC2016 # the hook must receive the unexpanded text
  local rows=(
    "deny|main|@MAIN@||git -C @WT@ status && git commit -m x"
    'deny|main|@MAIN@||git -C "$UNSET_VAR" commit -m x'
    'deny|main|@MAIN@||git -C "$UNSET_VAR" push'
    'deny|main|@MAIN@||git -C "$(pwd)" commit -m x'
    'deny|main|@MAIN@||git -C /nonexistent commit -m x'
    "deny|main|@MAIN@||cd '@WT@'; git -C \"\$UNSET_VAR\" commit -m x"
    "deny|main|@WT@||cd '@MAIN@'; git -C \"\$UNSET_VAR\" commit -m x"
    "allow|feature|@MAIN@||cd '@WT@'; git -C \"\$UNSET_VAR\" commit -m x"
    "deny|main|@MAIN@||cd '@WT@' && git status && cd '@MAIN@' && git commit -m x"
    "deny|main|@MAIN@||cd '@WT@' && git status && cd '@MAIN@' && git push"
    "allow|main|@MAIN@||cd '@MAIN@' && git status && cd '@WT@' && git commit -m x"
    "deny|main|@MAIN@||(cd '@WT@' && git status) && git commit -m x"
    "allow|main|@MAIN@||cd '@WT@' && git commit -m 'debt(hooks): x'"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The setup sentinel suspends enforcement for the greenfield finalize commit and
# push, then resumes: a total standdown while fresh, restored once removed, and
# self-healing when stale, because a leftover from a setup that crashed before
# cleanup must NOT keep main-branch protection suspended.
@test "the setup sentinel stands the guard down only while it is fresh" {
  local row state command verdict sentinel="$REPO/.gaia/local/setup-in-progress"
  local rows=(
    'fresh|git commit -m "x"|allow'
    'fresh|git push origin main|allow'
    'fresh|git push --force origin main|allow'
    'removed|git commit -m "x"|deny'
    'stale|git commit -m "x"|deny'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r state command verdict <<<"$row"
    on_main
    mkdir -p "$REPO/.gaia/local"
    rm -f "$sentinel"
    touch "$sentinel"
    case "$state" in
      stale) touch -t 200001010000 "$sentinel" ;;
      removed)
        run_hook "$command"
        assert_allowed_by_json
        rm -f "$sentinel"
        ;;
    esac
    run_hook "$command"
    case "$verdict" in
      allow) assert_allowed_by_json ;;
      deny) assert_denied_by_json ;;
    esac
  done
}

# The words appear but git is not the program, so command-position anchoring
# leaves them alone; a real invocation after another command is still caught.
@test "command text that only mentions git is allowed, and a git call after other commands is denied" {
  local row
  local rows=(
    'allow|main|||pnpm run build'
    'allow|main|||grep -n -e git commit app/foo.ts'
    'allow|main|||echo "git push origin main"'
    'allow|main|||echo git commit && grep -n foo bar'
    'deny|main|||echo hi | git commit -m "x"'
    'deny|feature|||true && git push origin main'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The control that keeps the two arms above from reading as a blanket allow:
# with the sibling checkout itself on main, the `-C` read denies, and it
# denies naming the branch the commit actually lands on rather than reporting
# the checkout as unreadable.
@test "a readable foreign -C on main beside a home command denies on its own branch" {
  on_main
  local worktree_directory="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$worktree_directory"
  run_hook_from "git status && git -C $FOREIGN commit -m x" "$worktree_directory"
  assert_denied_by_json
  grep -qF -- 'cannot read' <<<"$output" && return 1
  grep -qF -- "Commits to 'main' are forbidden" <<<"$output"
}

# Rule 3's ambiguity arm answered ahead of its refspec arm, so an operator
# already on a feature branch was told the pushing checkout was unknown and
# offered a repair they had applied: spelling the directory literally only
# surfaces the refspec deny on the next attempt. The refspec verdict does not
# depend on which checkout the push runs from, so it is answered first.
@test "a refspec naming main is reported ahead of an unreadable directory" {
  on_main
  local worktree_directory="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$worktree_directory"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from 'cd "$MAIN" && git push origin main' "$worktree_directory"
  assert_denied_by_json
  grep -qF -- 'refspec names main' <<<"$output"
}

# run_hook_split <command> <process directory> <payload cwd>
run_hook_split() {
  local json
  json=$(jq -n --arg command "$1" --arg directory "$3" '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')
  invoke_hook_in "$2" "$json" "$HOOK_ABSOLUTE_PATH"
}

# A sibling repository on its own branch, for the rows that must not read it
# as ambiguous.
foreign_on_sidebranch() {
  git -C "$FOREIGN" commit --quiet --allow-empty -m init
  git -C "$FOREIGN" checkout --quiet -B sidebranch
}

# Three checkouts, the session's own and the main checkout both off main.
three_checkouts() {
  on_feature
  git -C "$REPO" worktree add --quiet -b feature-a "$BATS_TEST_TMPDIR/wt-a"
  git -C "$REPO" worktree add --quiet -b master "$BATS_TEST_TMPDIR/wt-b"
}

# Same as run_hook_from, with HOME pointed at a named checkout. The directory
# read expands a literal tilde against it, and nothing else in the hook reads
# HOME, so this isolates that one arm.
run_hook_from_home() {
  local json
  json=$(jq -n --arg command "$1" --arg directory "$2" '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | HOME="$4" bash "$3"' _ "$2" "$json" "$HOOK_ABSOLUTE_PATH" "$3"
}

# --- the staged-tree harness the degrade cases below share ---
#
# Each library load in this hook resolves off BASH_SOURCE, never off the process
# working directory, so expressing a degraded library needs a COPY of the hook in
# a tree the test controls: running the real $HOOK_ABSOLUTE_PATH leaves it resolving the
# real checkout's libraries whatever a fixture does to a copy anywhere else.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

stage_hook_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  mkdir -p "$STAGED_ROOT/.claude" "$STAGED_ROOT/.gaia/scripts"
  # The whole hooks directory, lib/ included, rather than the libraries this
  # hook happens to load today: an enumeration goes short the moment the hook
  # gains a load, and the cases below would then drive a hook degraded in a way
  # none of them names while still reporting green. Each case then degrades one
  # named library and nothing else, by corrupting it, by removing it, or by
  # relying on it never having been staged at all. Staging the directory
  # wholesale also keeps the jq-availability arm present, which runs ahead of
  # the loads under test and refuses when it cannot find its own library,
  # answering every case with that refusal instead of with the decision under
  # test.
  cp -R "$HOOKS_SOURCE_DIRECTORY" "$STAGED_ROOT/.claude/hooks"
  # Outside the hooks directory, so the wholesale copy above does not reach it.
  # This line stays a hand-maintained list for that reason: a further
  # .gaia/scripts load the hook's live path gains has to be added here, or it
  # goes short with nothing red.
  cp "${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/.gaia/scripts/main-root-lib.sh" "$STAGED_ROOT/.gaia/scripts/"
  git -C "$STAGED_ROOT" init --quiet --initial-branch=main
  git -C "$STAGED_ROOT" config user.email "test@example.com"
  git -C "$STAGED_ROOT" config user.name "Test"
  git -C "$STAGED_ROOT" config commit.gpgsign false
  echo "# readme" > "$STAGED_ROOT/README.md"
  git -C "$STAGED_ROOT" add README.md
  git -C "$STAGED_ROOT" commit --quiet -m init
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-main-destructive-git.sh"
}

# run_staged <command> [interpreter]
run_staged() {
  local json interpreter="${2:-}"
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | $4 "$3"' _ "$STAGED_ROOT" "$json" "$STAGED_HOOK" "$interpreter"
}

# --- the staged-tree degrade cases ---
#
# The tree is staged once
# per table; each row restores the one library it degrades from the real
# source, then corrupts or removes it. Row for the first table:
# library|kind|branch|interpreter|command|verdict.

# restore_staged_library <path relative to the staged root>
restore_staged_library() {
  [ "$1" = none ] && return 0
  cp "${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/$1" "$STAGED_ROOT/$1"
}

degrade_staged_library() {
  case "$2" in
    absent) rm -f "$STAGED_ROOT/$1" ;;
    conflicted) write_conflicted_library "$STAGED_ROOT/$1" ;;
  esac
  return 0
}

# The repo-scope load sits under the hook's `set -euo pipefail`, so an
# unparseable copy once abandoned the shell ahead of the `type
# command_targets_foreign_repo` check, exiting 2 (the PreToolUse deny code) for
# every git command the hook matches. The conflict-marker pair discriminates:
# the allow case alone is satisfied by a hook that stopped enforcing, so the
# deny twin proves the degrade kept the main-branch floor. An absent library
# is its own case: the `[ -f ]` guard short-circuits, and what reds it is the
# degrade failing open. The main-root-lib rows are pinned to stock /bin/bash,
# since the `|| true` arm they replaced survives on bash 5 and is abandoned
# ahead of on 3.2, so only a /bin/bash run tells the fix apart; the control row
# proves that interpreter still denies on an intact tree.
@test "a conflicted or absent library never opens the guard" {
  local row library kind branch interpreter command verdict
  stage_hook_tree
  local rows=(
    '.claude/hooks/lib/repo-scope.sh|conflicted|feature||git status|allow'
    '.claude/hooks/lib/repo-scope.sh|conflicted|main||git commit -m "x"|deny'
    '.claude/hooks/lib/repo-scope.sh|absent|main||git commit -m "x"|deny'
    'none|none|main|/bin/bash|git commit -m "x"|deny'
    '.gaia/scripts/main-root-lib.sh|conflicted|main|/bin/bash|git commit -m "x"|deny'
    '.gaia/scripts/main-root-lib.sh|conflicted|feature|/bin/bash|git status|allow'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r library kind branch interpreter command verdict <<<"$row"
    [ -z "$interpreter" ] || [ -x "$interpreter" ] || { echo "skipped: no $interpreter"; continue; }
    restore_staged_library "$library"
    git -C "$STAGED_ROOT" checkout --quiet -B "$branch"
    degrade_staged_library "$library" "$kind"
    run_staged "$command" "$interpreter"
    case "$verdict" in
      allow) assert_allowed_by_json ;;
      deny) assert_denied_by_json ;;
    esac
    restore_staged_library "$library"
  done
}

# The parser, the hop guard, the segment splitter and the payload reader hold
# every rule the walk applies, so a hook that loaded none of them would allow
# every commit and push: an unloadable one refuses loudly with exit 2 naming
# the library. Absent and unparseable are separate cases: the `[ -f ]` test
# catches the first, and only the errexit bracket keeps the second from exiting
# 2 before the `type` check can name the library. A call that would not arm
# the hook still passes silently. Row: library|kind|command|verdict.
@test "an unloadable guard library refuses an armed call with exit 2 and never fails open" {
  local row library kind command verdict
  stage_hook_tree
  local rows=(
    '.claude/hooks/lib/git-segments.sh|absent|git commit -m x|blocked'
    '.claude/hooks/lib/git-segments.sh|absent|ls|silent'
    '.claude/hooks/lib/main-git-guard-parse.sh|absent|git commit -m x|blocked'
    '.claude/hooks/lib/main-git-guard-parse.sh|conflicted|git commit -m x|blocked'
    '.claude/hooks/lib/main-checkout-hop-guard.sh|absent|git commit -m x|blocked'
    '.claude/hooks/lib/main-checkout-hop-guard.sh|conflicted|git commit -m x|blocked'
    '.claude/hooks/lib/main-git-guard-history.sh|absent|git commit -m x|blocked'
    '.claude/hooks/lib/main-git-guard-history.sh|conflicted|git clean -fdx|blocked'
    '.claude/hooks/lib/git-command-config.sh|absent|git commit -m x|blocked'
    '.claude/hooks/lib/git-command-config.sh|conflicted|git status|blocked'
    '.claude/hooks/lib/main-git-guard-parse.sh|absent|ls|silent'
    '.claude/hooks/lib/hook-payload.sh|absent|git push --force origin main|blocked'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r library kind command verdict <<<"$row"
    restore_staged_library "$library"
    degrade_staged_library "$library" "$kind"
    run_staged "$command"
    case "$verdict" in
      blocked)
        [ "$status" -eq 2 ]
        grep -qF "BLOCKED: block-main-destructive-git.sh cannot load lib/${library#.claude/hooks/lib/}" <<<"$output"
        ;;
      silent)
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        ;;
    esac
    restore_staged_library "$library"
  done
}

# --- a hard reset that moves HEAD drops commits, whatever the spelling ---

@test "git reset --hard to a target that moves HEAD is denied" {
  local row
  on_feature_with_second_commit
  # shellcheck disable=SC2016 # the hook must receive the unexpanded text
  local rows=(
    'deny|keep_feature|||git reset -q --hard HEAD~1'
    'deny|keep_feature|||git reset --hard --quiet HEAD^'
    'deny|keep_feature|||git -C @MAIN@ reset --hard HEAD~1'
    'deny|keep_feature|||git reset --hard no-such-ref'
    'deny|keep_feature|||cd "$SOMEWHERE" && git reset --hard @HEAD@'
    'deny|main|||git reset --hard @HEAD@'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# A target resolving to HEAD's own commit moves nothing, a reset without
# --hard is not this rule's, command text that only quotes a hard reset is not
# a reset, and after an unreadable directory only a literal HEAD still passes.
@test "git reset --hard that keeps HEAD where it is, and other resets, are allowed" {
  local row
  on_feature_with_second_commit
  # shellcheck disable=SC2016 # the hook must receive the unexpanded text
  local rows=(
    'allow|keep_feature|||git reset --hard'
    'allow|keep_feature|||git reset --hard HEAD'
    'allow|keep_feature|||git reset --hard @'
    'allow|keep_feature|||git reset --hard @HEAD@'
    'allow|keep_feature|||git reset --hard feature'
    'allow|keep_feature|||git reset HEAD~1'
    'allow|keep_feature|||git reset --soft HEAD~1'
    'allow|keep_feature|||echo "git reset --hard HEAD~1"'
    'allow|keep_feature|||cd "$SOMEWHERE" && git reset --hard HEAD'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# --- history rules: main, the remote, the reflog and ignored local state ---

# classify-git-command.sh approves ordinary git calls without a prompt, and a
# deny here is the only guard that holds beside that allow. Every row runs from a feature branch, where rules 1 to 3 allow a push.
# bats test_tags=protected
@test "history rules deny what reaches main, the remote, the reflog or ignored state" {
  local row
  local rows=(
    'deny|feature|||git push origin feature:main'
    'deny|feature|||git push origin +feature:main'
    'deny|feature|||git push origin feature:refs/heads/master'
    'deny|feature|||git push origin :main'
    'deny|feature|||git push origin refs/heads/main'
    'deny|feature|||git push origin --delete refs/heads/main'
    'deny|feature|||git push --mirror origin'
    'deny|feature|||git push --all origin'
    'deny|feature|||git push --all --force origin'
    'deny|feature|||git push --branches origin'
    'deny|feature|||git clean -fdx'
    'deny|feature|||git clean -xdf'
    'deny|feature|||git clean -fX'
    'deny|feature|||git -C @MAIN@ clean -f -x'
    'deny|feature|||git config core.hooksPath /dev/null'
    'deny|feature|||git config --local core.hooksPath .husky'
    'deny|feature|||git config --unset core.hooksPath'
    'deny|feature|||git config set core.HooksPath /tmp/none'
    'deny|feature|||git update-ref -d refs/heads/main'
    'deny|feature|||git update-ref refs/heads/master HEAD'
    'deny|feature|||git update-ref --stdin'
    'deny|feature|||git branch -D main'
    'deny|feature|||git branch --delete --force master'
    'deny|feature|||git branch -f main HEAD'
    'deny|feature|||git branch -M main'
    'deny|feature|||git reflog expire --expire=now --all'
    'deny|feature|||git reflog delete HEAD@{1}'
    'deny|feature|||git gc --prune=now'
    'deny|feature|||git prune'
    'deny|feature|||git filter-branch -f HEAD'
    'deny|feature|||git filter-repo --path secrets --invert-paths'
    'deny|feature|||git status && git clean -fdx'
    'deny|feature|||git push origin feature:heads/main'
    'deny|feature|||git push origin :'
    'deny|feature|||git push origin +:'
    'deny|feature|||git push origin refs/heads/*:refs/heads/*'
    'deny|feature|||git push origin +refs/heads/*'
    'deny|feature|||git push --mirr origin'
    'deny|feature|||git push --al origin'
    'deny|feature|||git push --bra origin'
    'deny|feature|||git config core.hooksPath ""'
    'deny|feature|||git config --unse core.hooksPath'
    'deny|feature|||git config core.hooksPath get'
    'deny|feature|||git config core.hooksPath list'
    'deny|feature|||git config core.hooksPath remove-section'
    'deny|feature|||git config --remove-section core'
    'deny|feature|||git config rename-section core old'
    'deny|feature|||git update-ref --stdi'
    'deny|feature|||git update-ref HEAD HEAD~1'
    'deny|feature|||git update-ref -m reason -d HEAD'
    'deny|feature|||git branch --forc main HEAD'
    'deny|feature|||git branch --mov main old-main'
    'deny|feature|||git checkout -B main origin/main'
    'deny|feature|||git checkout -fB master'
    'deny|feature|||git checkout -Bmain'
    'deny|feature|||git switch -C main'
    'deny|feature|||git switch --force-create=master origin/master'
    'deny|feature|||git switch --force-c main'
    'deny|feature|||git reflog drop --all'
    'deny|feature|||git gc --prun=now'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

@test "history rules allow the everyday forms beside each rule" {
  local row
  local rows=(
    'allow|feature|||git push --force-with-lease origin feature'
    'allow|feature|||git push -u origin feature'
    'allow|feature|||git push origin feature:feature-copy'
    'allow|feature|||git push origin --delete feature-old'
    'allow|feature|||git push origin --tags'
    'allow|feature|||git clean -fd'
    'allow|feature|||git clean -n'
    'allow|feature|||git config --get core.hooksPath'
    'allow|feature|||git config core.hooksPath'
    'allow|feature|||git config core.hooksPath .githooks'
    'allow|feature|||git config user.name Test'
    'allow|feature|||git branch -D feature-old'
    'allow|feature|||git branch -m feature-renamed'
    'allow|feature|||git branch feature-two main'
    'allow|feature|||git branch -u origin/main'
    'allow|feature|||git update-ref refs/heads/feature-two HEAD'
    'allow|feature|||git reflog'
    'allow|feature|||git gc'
    'allow|feature|||git gc --no-prune'
    'allow|feature|||git rebase main'
    'allow|feature|||echo "never run git clean -fdx here"'
    'allow|feature|||git commit -m "do not git push --mirror"'
    'allow|feature|||git push origin feature:feature/main'
    'allow|feature|||git push origin refs/heads/feat/*:refs/heads/feat/*'
    'allow|feature|||git push --atomic origin feature'
    'allow|feature|||git config --get-all core.hooksPath'
    'allow|feature|||git config --remove-section alias'
    'allow|feature|||git update-ref refs/heads/feature-two HEAD~1'
    'allow|feature|||git checkout -B feature-two main'
    'allow|feature|||git checkout -b feature-two'
    'allow|feature|||git switch -C feature-two main'
    'allow|feature|||git switch -c feature-two'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# Each history denial says why and names the repair. Row: command|needle.
@test "each history denial states its reason and the repair it names" {
  local row command needle
  local rows=(
    'git push origin feature:main|git push -u origin <branch-name>'
    'git push --mirror origin|deletes every remote branch this clone lacks'
    'git push --all origin|main included'
    'git clean -fdx|the notebook (specs, plans'
    "git clean -fdx|'git clean -fd'"
    "git config core.hooksPath /dev/null|'git config core.hooksPath .githooks'"
    'git update-ref -d refs/heads/main|Main changes only through a merged pull request'
    'git branch -D main|Ask the user to run it themselves'
    'git reflog expire --expire=now --all|recovers a dropped commit'
    'git gc --prune=now|no prune option'
    'git filter-branch -f HEAD|ask them to run it themselves'
  )
  on_feature
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r command needle <<<"$row"
    run_hook "$command"
    assert_denied_by_json
    grep -qF -- "$needle" <<<"$output"
  done
}

# The history rules are this repository's policy: a foreign -C stands them down
# the way it stands down the commit and push rules.
@test "a history rule aimed at a foreign repository is allowed" {
  on_feature
  run_hook "git -C $FOREIGN clean -fdx"
  assert_allowed_by_json
  run_hook "git -C $FOREIGN branch -D main"
  assert_allowed_by_json
}

# A key git runs as a command turns any prompt-free git approval into an unprompted shell,
# whether set inline, from the environment, or persisted by `git config`.
# bats test_tags=protected
@test "command-running config is denied inline, through --config-env and through git config" {
  local row
  local rows=(
    "deny|feature|||git -c 'alias.zz=!echo ran' zz"
    "deny|feature|||git -c 'alias.lg=-c core.pager=evil log' lg"
    'deny|feature|||git -c core.sshCommand=evil fetch'
    'deny|feature|||git -c CORE.PAGER=cat log'
    'deny|feature|||git -c core.fsmonitor=./evil status'
    'deny|feature|||git -c include.path=/tmp/x status'
    'deny|feature|||git -c includeIf.gitdir:/x/.path=/tmp/x status'
    'deny|feature|||git -c filter.lfs.smudge=evil status'
    'deny|feature|||git -c diff.foo.textconv=evil diff'
    'deny|feature|||git -c core.hooksPath=/tmp/hooks status'
    'deny|feature|||git --config-env=core.editor=EDITOR status'
    'deny|feature|||git --config-env core.pager=PAGER log'
    "deny|feature|||git config alias.x '!echo hi'"
    "deny|feature|||git config alias.x '-c core.sshCommand=evil fetch'"
    "deny|feature|||git config --global core.sshCommand 'ssh -i key'"
    'deny|feature|||git config --file /tmp/c credential.helper store'
    'deny|feature|||git config set core.editor vim'
    'deny|feature|||git config hook.pre.command evil'
    'deny|feature|||git config --rename-section foo alias'
    'deny|feature|||git config rename-section foo core'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

@test "config that runs nothing, reads and unsets pass the command-config rule" {
  local row
  local rows=(
    'allow|feature|||git -c alias.co=checkout co'
    'allow|feature|||git -c pager.log=false log'
    'allow|feature|||git -c core.fsmonitor=true status'
    'allow|feature|||git -c color.ui=always log'
    'allow|feature|||git -c core.hooksPath=.githooks status'
    'allow|feature|||git --config-env=user.name=NAME log'
    'allow|feature|||git config alias.st status'
    'allow|feature|||git config core.pager'
    'allow|feature|||git config --default less core.pager'
    'allow|feature|||git config --get core.sshCommand'
    'allow|feature|||git config --unset alias.x'
    'allow|feature|||git config --rename-section foo bar'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The shell an alias runs does not care which repository it was named in, so
# the foreign-repository skip that stands the other rules down does not apply.
@test "command-running config aimed at a foreign repository is still denied" {
  on_feature
  run_hook "git -C $FOREIGN -c 'alias.zz=!echo ran' zz"
  assert_denied_by_json
  run_hook "git -C $FOREIGN config alias.x '!echo ran'"
  assert_denied_by_json
}

# --- main-checkout hop guard, segment parsing and the -C early exit ---

# A peer's hop is denied in each spelling that moves the main checkout's HEAD:
# a checkout or switch naming another branch, the branch-creating, detaching
# and previous-branch forms, `-C` after `switch` (force-create, not a
# directory), git's own options ahead of the subcommand, a worktree session
# aiming `-C` at the main checkout, and a bare switch name that exists only on
# the remote or nowhere (git would DWIM the first into a new tracking branch;
# denying the second refuses a command git rejects anyway, the safe direction
# for a guard whose escape is the ! prefix). Row: session directory|command.
@test "hop guard: a peer's move of the main checkout's HEAD is denied in every spelling" {
  local row session_directory command
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  add_worktree
  git -C "$REPO" update-ref refs/remotes/origin/remoteonly HEAD
  [ -z "$(git -C "$REPO" rev-parse --verify -q remoteonly 2>/dev/null)" ] || return 1
  local rows=(
    '|git checkout main'
    '|git checkout main 2>/dev/null'
    '|git checkout main > /dev/null'
    '|git checkout -b brand-new'
    '|git checkout -'
    '|git checkout --detach'
    '|git checkout -B brand-new'
    '|git checkout --orphan o2'
    '|git switch -C other'
    '|git switch -C main main'
    '@WT@|git -C @MAIN@ switch -C other'
    '|git -c advice.detachedHead=false switch other'
    '|git --git-dir .git checkout main'
    '@WT@|git -C @MAIN@ checkout main'
    '|git switch remoteonly'
    '|git switch nonexistent'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    session_directory=${row%%|*}
    command=${row#*|}
    run_hop "$(resolve_row_text "$command")" sid-peer "$(resolve_row_text "$session_directory")"
    assert_denied_by_json
  done
}

# Each state below is reset before its row. Allowed: a checkout aimed at a
# different repository, the session that created the pull request, a branch
# whose pull request is merged or closed, a checkout run inside a linked
# worktree, path-restore forms, and hopping off the default branch (named
# main, named by origin/HEAD, or a detached HEAD). The origin/HEAD row is last
# because it leaves that ref behind. Row: state|session|directory|command.
@test "hop guard: a hop is allowed for the owner, a closed pull request, a restore or a default branch" {
  local row state session directory command
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  add_worktree
  git -C "$FOREIGN" commit --quiet --allow-empty -m init
  git -C "$FOREIGN" branch --quiet other
  git -C "$FOREIGN" checkout --quiet -B feature
  local rows=(
    'feature|sid-peer||git -C @FOREIGN@ switch other'
    'feature|sid-owner||git switch other'
    'nopr|sid-peer||git checkout main'
    'feature|sid-peer|@WT@|git switch other'
    'feature|sid-peer||git checkout -- README.md'
    'feature|sid-peer||git checkout main -- README.md'
    'feature|sid-peer||git checkout -p main'
    'feature|sid-peer||git checkout -- main'
    'feature|sid-peer||git checkout main README.md'
    'feature|sid-peer||git checkout README.md'
    'main|sid-peer||git switch other'
    'detached|sid-peer||git switch other'
    'trunk|sid-peer||git switch other'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r state session directory command <<<"$row"
    export GH_STUB="open:42"
    git -C "$REPO" checkout --quiet feature
    case "$state" in
      nopr) export GH_STUB=none ;;
      main) git -C "$REPO" checkout --quiet main ;;
      detached) git -C "$REPO" checkout --quiet --detach ;;
      trunk)
        git -C "$REPO" checkout --quiet -B trunk
        git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
        git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
        ;;
    esac
    run_hop "$(resolve_row_text "$command")" "$session" "$(resolve_row_text "$directory")"
    assert_allowed_by_json
  done
}

# A lookup that fails or answers with something that is not a pull request
# number fails open, with one stderr line naming the cause. Row:
# stub|needle|second needle.
@test "hop guard: a gh failure or a non-number answer fails open naming the cause" {
  local row stub needle_one needle_two
  hold_feature_with_pr 42
  local rows=(
    'fail|could not check|exited 4'
    'garbage|could not check|'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r stub needle_one needle_two <<<"$row"
    export GH_STUB="$stub"
    run_hop 'git checkout main' sid-peer
    assert_allowed_by_json
    grep -qF -- "$needle_one" <<<"$output"
    [ -z "$needle_two" ] || grep -qF -- "$needle_two" <<<"$output"
  done
}

# Parsing must not hide the git command: a command name merely beginning with a
# reserved word is an ordinary name; an assignment's quoted value may carry
# whitespace and must not stand where the command word is read; a `$( )` inside
# git's own arguments cuts the segment at its parens, so the subcommand must be
# read past it; and the collapse must not hand a non-git segment the
# substitution's own text.
@test "segment parsing does not hide the git command" {
  local row
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  local rows=(
    'allow|main|||iffy git commit -m y'
    'allow|main|||dotimes git commit -m y'
    'allow|main|||coprocess git commit -m y'
    'deny|main|||GIT_EDITOR="code --wait" git commit -m x'
    'deny|main|||GIT_AUTHOR_DATE="2024-01-01 12:00" git commit --amend'
    "deny|main|||GIT_AUTHOR_DATE='2024-01-01 12:00' git push"
    'deny|main|||git -c user.name="$(whoami)" commit -m y'
    'deny|main|||git commit -m "$(date)"'
    'deny|feature|||git push "$(echo origin)" main'
    'allow|feature|||echo "$(git log)" main'
    'allow|feature|||grep -R "$(echo commit)" .'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The early exit for subcommands no rule reads must not skip a later commit or
# push that does arm one.
@test "the -C early exit does not skip a later commit or push" {
  local row
  on_main
  add_worktree
  local rows=(
    "deny|main|@WT@||cd '@MAIN@' && git -C '@MAIN@' status && git -C '@MAIN@' commit -m x"
    'deny|main|||git -C @MAIN@ status && git -C @MAIN@ commit -m x'
    'deny|feature|||git -C @MAIN@ push origin main'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# The post-merge cleanup pulls `main` into the main checkout when that checkout
# is on `main` (PR Merge Workflow, worktree arm). The pull moves no HEAD to
# another branch, so the guard must let it through, both from the main checkout
# and from a session whose cwd was a worktree the cleanup just removed.
@test "the post-merge pull into a main checkout on main is allowed" {
  local row
  local rows=(
    'allow|main|||git -C @MAIN@ pull --ff-only origin main'
    'allow|main|@MAIN@|@MAIN@/.claude/worktrees/removed|git -C @MAIN@ pull --ff-only origin main'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_row "$row"
  done
}

# --- a hard reset that moves HEAD drops commits, whatever the spelling ---
#
# The rule reads the target as a commit rather than as text, so every spelling
# of an earlier commit denies and every spelling of HEAD's own commit passes.
# The feature branch carries a second commit, so each earlier target names a
# commit HEAD would leave behind.

on_feature_with_second_commit() {
  on_feature
  echo "second" > "$REPO/second.txt"
  git -C "$REPO" add second.txt
  git -C "$REPO" commit --quiet -m "second"
  FIRST_SHA=$(git -C "$REPO" rev-parse HEAD~1)
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

# bats test_tags=protected
@test "git reset --hard to an earlier commit is denied in every spelling" {
  local target
  on_feature_with_second_commit
  git -C "$REPO" branch older "$FIRST_SHA"
  for target in 'HEAD~1' 'HEAD~' 'HEAD^' '@~1' '@^' "$FIRST_SHA" "${FIRST_SHA:0:8}" older main; do
    run_hook "git reset --hard $target"
    assert_denied_by_json || { echo "allowed: git reset --hard $target"; return 1; }
  done
}

# --- main-checkout hop guard ---
#
# A peer session moving the main checkout's HEAD off a branch another session
# holds there with an open pull request is denied. `gh` is a stub on PATH whose
# answer GH_STUB selects: `open:<n>` lists one open pull request, `none` lists
# nothing (merged, closed, never opened), `fail` exits non-zero, `hang` never
# answers, `hangwrap` never answers from a child the stub does NOT exec (the
# wrapper shape a real `gh` shim takes), `garbage` answers with something that
# is not a number. Every call appends its argv to gh-calls, so a test can prove
# gh was never reached. The hang is 90 s, far above the tests' 60 s wall-clock
# ceilings, so a machine loaded enough to stretch the hook's tick-counted bound
# cannot make a hang look like an answer; the proof the bound fired is the
# hook's own `timed out` line. The sleeps close fd 3 (bats' output) and every
# pid is recorded for teardown. The owner is
# proved by the `gh pr create` breadcrumb, written here through the same lib the
# capture hook writes it with, so the path and shape cannot drift from the
# reader's.

stub_gh() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/gh-calls"
[ "$1 $2" = "pr list" ] || exit 1
case "${GH_STUB:-none}" in
  open:*) printf '%s\n' "${GH_STUB#open:}" ;;
  none) ;;
  fail) echo "gh: authentication required" >&2; exit 4 ;;
  hang) echo "$$" >>"$BATS_TEST_TMPDIR/gh-pids"; exec sleep 90 3>&- ;;
  hangwrap) sleep 90 3>&- & echo "$$ $!" >>"$BATS_TEST_TMPDIR/gh-pids"; wait ;;
  garbage) echo "not-a-number" ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# hold_feature_with_pr <number>: the main checkout sits on `feature`, a second
# branch `other` exists to switch to, and `feature` has an open pull request.
hold_feature_with_pr() {
  stub_gh
  git -C "$REPO" branch --quiet other
  git -C "$REPO" checkout --quiet -B feature
  export GH_STUB="open:$1"
}

write_breadcrumb() {
  local branch="$1" session_id="$2" breadcrumb_path
  # shellcheck source=/dev/null
  . "${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/.gaia/scripts/gh-artifact-lib.sh"
  breadcrumb_path="$(gaia_gh_artifact_path "$REPO/.gaia/local/cache" "$branch")"
  gaia_gh_artifact_write "$breadcrumb_path" 42 example/repo "$branch" "$session_id"
}

# run_hop <command> [session_id] [cwd]
run_hop() {
  local json
  json=$(jq -n --arg command "$1" --arg session_id "${2:-sid-peer}" --arg directory "${3:-$REPO}" \
    '{tool_name: "Bash", session_id: $session_id, cwd: $directory, tool_input: {command: $command}}')
  invoke_hook_in "${3:-$REPO}" "$json" "$HOOK_ABSOLUTE_PATH"
}

@test "hop guard: a peer switching the main checkout off a branch with an open PR is denied" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git switch other' sid-peer
  assert_denied_by_json
  grep -qF -- "'feature'" <<<"$output"
  grep -qF -- '#42' <<<"$output"
  grep -qF -- 'worktree arm' <<<"$output"
  grep -qF -- 'with the ! prefix' <<<"$output"
}

@test "hop guard: the owner is matched before any gh call" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  export GH_STUB=hang
  local start=$SECONDS
  run_hop 'git switch other' sid-owner
  assert_allowed_by_json
  # The owner is decided before gh is reached: the stub saw no call at all.
  [ ! -s "$BATS_TEST_TMPDIR/gh-calls" ] || return 1
  grep -qF -- 'timed out' <<<"$output" && return 1
  [ $((SECONDS - start)) -lt 60 ]
}

@test "hop guard: a missing breadcrumb counts as not the owner" {
  hold_feature_with_pr 42
  run_hop 'git switch other' sid-owner
  assert_denied_by_json
}

# The bound killed the pid it backgrounded, but the output was read through the
# command substitution's pipe, which stays open until every process holding it
# exits. A `gh` that runs the real binary without `exec` leaves that child
# holding the pipe, so the bound did not hold and the diagnostic claimed one
# that had (#2004).
@test "hop guard: a gh wrapper that does not exec is still cut off at the bound" {
  hold_feature_with_pr 42
  export GH_STUB=hangwrap
  local start=$SECONDS
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output"
  [ $((SECONDS - start)) -lt 60 ]
}

@test "hop guard: gh missing from PATH fails open with the named cause" {
  hold_feature_with_pr 42
  # A PATH holding every tool the hook and its libraries call, and no gh.
  local tools="$BATS_TEST_TMPDIR/tools" tool tool_path
  mkdir -p "$tools"
  for tool in bash cat jq git sed tr dirname basename find env mkdir grep head \
      wc date sleep rm shasum sha256sum perl awk; do
    tool_path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$tool_path" "$tools/$tool"
  done
  PATH="$tools" run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'gh is not on PATH' <<<"$output"
}

@test "hop guard: an unloadable breadcrumb library fails open with the named cause" {
  stage_hook_tree
  stub_gh
  export GH_STUB=open:42
  git -C "$STAGED_ROOT" branch --quiet other
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  [ ! -e "$STAGED_ROOT/.gaia/scripts/gh-artifact-lib.sh" ]
  run_staged 'git switch other'
  assert_allowed_by_json
  grep -qF -- 'gh-artifact-lib.sh did not load' <<<"$output"
  # The lookup that failed is whose session opened the pull request, not whether
  # one is open: that answer is already in hand by the time this arm runs (#2007).
  grep -qF -- 'whether this session opened' <<<"$output"
}

# The guard's header promises a stderr line for anything it cannot check, and
# the arm taken when the main-root resolver is missing returned silently, so a
# peer's hop was allowed with no diagnostic anywhere (#2007).
@test "hop guard: an unloadable main-root-lib.sh fails open with the named cause" {
  stage_hook_tree
  stub_gh
  export GH_STUB=open:42
  rm -f "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  git -C "$STAGED_ROOT" branch --quiet other
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  run_staged 'git switch other'
  assert_allowed_by_json
  grep -qF -- 'main-root-lib.sh did not load' <<<"$output"
}

# The switch arm returned before the no-op carve-out ever inspected the operand,
# so a switch to the branch HEAD already holds was denied although it moves
# nothing, which is the same no-op deny the carve-out repairs on the checkout
# arm. The session most likely to hit it is the branch's own owner after a
# restart, whose new session id no longer matches the breadcrumb (#2018).
@test "hop guard: a switch that moves nothing is allowed in a peer-held main checkout" {
  hold_feature_with_pr 42
  run_hop 'git switch feature' sid-peer
  assert_allowed_by_json
  # The controls: a switch that really moves HEAD is still denied, and so is
  # every branch-creating and detaching spelling the arm lists, each of which
  # moves HEAD whatever the operand says. Driven per spelling rather than
  # sampled, because this test is the arm's only coverage and a spelling
  # dropped from the case list is invisible to a suite that drives its siblings.
  run_hop 'git switch other' sid-peer
  assert_denied_by_json
  run_hop 'git switch -c brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git switch -C feature' sid-peer
  assert_denied_by_json
  run_hop 'git switch --create brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git switch --force-create feature' sid-peer
  assert_denied_by_json
  run_hop 'git switch --orphan o2' sid-peer
  assert_denied_by_json
  run_hop 'git switch --detach' sid-peer
  assert_denied_by_json
}

# A checkout naming the branch HEAD already holds, or HEAD itself, moves
# nothing, so denying it refuses a no-op (#2005).
@test "hop guard: a checkout that moves nothing is allowed in a peer-held main checkout" {
  hold_feature_with_pr 42
  run_hop 'git checkout feature' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout HEAD' sid-peer
  assert_allowed_by_json
  # The control: a checkout that really moves HEAD is still denied.
  run_hop 'git checkout other' sid-peer
  assert_denied_by_json
}

# The collapsed line re-emits the WHOLE command, so every intact git segment
# in a command that carries a `$( )` anywhere is walked twice, not only the
# segment the substitution sits in. Every other rule reaches the same verdict
# both times at no cost; the hop arm is the one that can spend a bounded
# pull-request lookup, so without the memo this command's worst-case wait
# doubles and the diagnostic prints twice.
#
# Pinned on the ALLOW path: a deny exits the hook on the first visit, so the
# second one can never be observed there.
@test "hop guard: a target beside a substitution is answered once, not twice" {
  hold_feature_with_pr 42
  export GH_STUB=fail
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hop 'git checkout main && echo "$(date)"' sid-peer
  assert_allowed_by_json
  [ "$(grep -cF -- 'could not check' <<<"$output")" -eq 1 ]
}

# The memo above spans the lookup only. Whether a segment moves HEAD at all is
# a property of that segment's own operands, so a memo covering that question
# answers a later segment with an earlier one's verdict: a pathspec restore and
# a checkout of the branch HEAD already holds both leave HEAD where it is, and
# either one standing in for the branch switch beside it takes the guard off.
@test "hop guard: each checkout segment is judged on its own operands" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git checkout -- README.md && git checkout main' sid-peer
  assert_denied_by_json
  run_hop 'git checkout feature && git checkout main' sid-peer
  assert_denied_by_json
}

# The collapsed line re-emits the whole command, its own `cd` segments
# included, so the walk has to enter it with no tracked directory standing.
# Reading it under the directory the FIRST pass ended in puts a `cd` that
# follows a git segment in front of it on the second pass, and the commit is
# then read against a checkout the command reaches only afterwards.
@test "the collapsed re-emission is not governed by a cd that follows the segment it re-reads" {
  on_feature
  local worktree_directory="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet "$worktree_directory" main
  run_hook_from "git commit -m \"\$(date)\" && cd '$worktree_directory'" "$REPO"
  assert_allowed_by_json
}

# --- the early exit for subcommands no rule reads ---

# A `git` shim first on PATH logs each argv and execs the real git, so the
# number of `--git-common-dir` resolutions a payload costs is countable.
install_git_shim() {
  local real_git
  real_git=$(command -v git)
  SHIM_LOG="$BATS_TEST_TMPDIR/git-shim.log"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$SHIM_LOG"
    printf 'exec "%s" "$@"\n' "$real_git"
  } > "$BATS_TEST_TMPDIR/shim/git"
  chmod +x "$BATS_TEST_TMPDIR/shim/git"
  : > "$SHIM_LOG"
}

common_dir_call_count() {
  grep -cF -- '--git-common-dir' "$SHIM_LOG" || true
}

run_hook_with_shim() {
  local json
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  : > "$SHIM_LOG"
  run bash -c 'cd "$1" && printf %s "$2" | PATH="$4:$PATH" bash "$3"' _ "$REPO" "$json" "$HOOK_ABSOLUTE_PATH" "$BATS_TEST_TMPDIR/shim"
}

@test "a -C status makes strictly fewer --git-common-dir calls than a -C commit on the same path" {
  on_feature
  install_git_shim
  run_hook_with_shim "git -C $REPO status"
  local status_count
  status_count=$(common_dir_call_count)
  run_hook_with_shim "git -C $REPO commit -m x"
  local commit_count
  commit_count=$(common_dir_call_count)
  [ "$commit_count" -gt 0 ]
  [ "$status_count" -lt "$commit_count" ]
}

# --- the one-jq payload reader ---


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
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-main-destructive-git.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}
