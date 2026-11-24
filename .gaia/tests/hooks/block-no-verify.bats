#!/usr/bin/env bats

# Tests for .claude/hooks/block-no-verify.sh.
#
# The hook denies `git commit` / `git push` carrying a hook bypass so the
# Quality Gate floor (typecheck / lint / test, run by the pre-commit hook
# .githooks/pre-commit) cannot be skipped. Bypass tokens: --no-verify, `-n`
# (commit only, `push -n` is --dry-run), and a `-c core.hooksPath=` override. Foreign-repo commands pass via the shared
# repo-scope helper.
#
# Most tests drive the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the tmp repo as the working directory, which is
# where the shared repo-scope helper resolves the home repository's identity
# from: it reads the toplevel and the remote URLs of whatever repo cwd sits in.
# The hook loads that helper from its own on-disk location rather than from cwd,
# so the degrade cases at the end run a copy of the hook from a staged tree
# instead, with that tree as the working directory, which is what puts a library
# the test controls in front of it. The hook always exits 0; allow vs deny is
# carried in stdout: a deny emits `"permissionDecision": "deny"`, an allow emits
# nothing. The deny cases double as a jq/setup canary: a missing jq would exit
# early with no output and those assertions would fail rather than false-pass.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-no-verify.sh"

  REPO=$(mktemp -d -t no-verify-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  git -C "$REPO" checkout --quiet -b feature

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t no-verify-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABSOLUTE_PATH"
}



# --- denied ---

# bats test_tags=protected
@test "git commit --no-verify is denied" {
  run_hook 'git commit --no-verify -m "x"'
  assert_denied_by_json
}

# check_verdict LABEL deny|allow
# The run-hook pair leans on errexit for its status line, which a `||` caller
# switches off, so a case-table row checks the JSON verdict here with explicit
# returns and names its own label when it fails.
check_verdict() {
  [ "$status" -eq 0 ] || { echo "case $1: status=$status output=$output"; return 1; }
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    [ "$2" = deny ] || { echo "case $1: denied, expected allow: $output"; return 1; }
  else
    [ "$2" = allow ] || { echo "case $1: allowed, expected deny: $output"; return 1; }
  fi
}

# Each row: label~~remote~~verdict~~command. `remote` adds an origin to the home
# repo first; the repo-scope helper needs a repository name to compare, and with
# none it fails closed a line earlier, which would pass a deny row without
# exercising it.
#
# A `-R` belonging to another program in the same call was read as gh's
# repository flag, so the helper answered "foreign" for the whole command
# (trailing-R). The repo-scope verdict covers the whole call, so any home
# command in it keeps the guard armed (foreign-*). A substitution in a foreign
# command's own arguments runs in this repository before the foreign command
# does (substitution-*). Only a call whose every command is foreign, or a
# foreign-repo commit, is out of scope.
@test "a foreign command or foreign repo in the call does not exempt or hide a bypass" {
  local row label rest remote verdict cmd
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  for row in \
    'trailing-R~~remote~~deny~~git commit --no-verify -m x && grep -R app/routes .' \
    'foreign-and~~remote~~deny~~gh pr merge 5 -R other/x && git commit --no-verify -m y' \
    'foreign-semicolon~~remote~~deny~~gh pr merge 5 -R other/x; git commit --no-verify -m y' \
    "foreign-newline~~remote~~deny~~gh pr merge 5 -R other/x
git commit --no-verify -m y" \
    "foreign-after~~remote~~deny~~git commit --no-verify -m y && git -C $FOREIGN status" \
    "foreign-cd~~remote~~deny~~cd $FOREIGN && git status && cd - && git commit --no-verify -m y" \
    'substitution-gh~~remote~~deny~~gh pr view 5 -R other/x --jq "$(git commit --no-verify -m y)"' \
    "substitution-git-C~~remote~~deny~~git -C $FOREIGN log --format \"\$(git commit --no-verify -m y)\"" \
    "all-foreign~~remote~~allow~~gh pr merge 5 -R other/x && git -C $FOREIGN commit --no-verify -m y" \
    "foreign-repo-commit~~none~~allow~~git -C $FOREIGN commit --no-verify -m \"x\""; do
    label=${row%%~~*}; rest=${row#*~~}
    remote=${rest%%~~*}; rest=${rest#*~~}
    verdict=${rest%%~~*}; cmd=${rest#*~~}
    git -C "$REPO" remote remove origin 2>/dev/null || true
    if [ "$remote" = remote ]; then
      git -C "$REPO" remote add origin https://github.com/acme/widget.git
    fi
    run_hook "$cmd"
    check_verdict "$label" "$verdict"
  done
}

# `push -n` is --dry-run, so only commit reads -n as a bypass. The
# orphaned-by-pipe row: segment-splitting on the quoted '|' would orphan
# --no-verify from its git segment; the whole-command safety net re-asserts it.
@test "git commit/push hook bypass spellings are denied: -n, -anm, -c core.hooksPath in either case, push --no-verify, env prefix, after a pipe" {
  local row label cmd
  for row in \
    'commit-n~~git commit -n -m "x"' \
    'bundled-anm~~git commit -anm "x"' \
    'hookspath~~git -c core.hooksPath=/dev/null commit -m "x"' \
    'push-no-verify~~git push --no-verify' \
    'hookspath-camel~~git -c core.hooksPath=/dev/null commit -m x' \
    'hookspath-lower-push~~git -c core.hookspath=/dev/null push origin feature' \
    'env-hookspath~~HUSKY=0 git -c core.hooksPath=/dev/null commit -m x' \
    "hookspath-single-quoted~~git -c 'core.hooksPath=/tmp' commit -m x" \
    'hookspath-double-quoted~~git -c "core.hooksPath=/tmp" push origin feature' \
    'hookspath-config-env-joined~~git --config-env=core.hooksPath=HOOKS commit -m x' \
    'hookspath-config-env-separate~~git --config-env core.hooksPath=HOOKS push origin feature' \
    'env-no-verify~~HUSKY=0 git commit --no-verify -m x' \
    'after-pipe~~echo hi | git commit -n -m "x"' \
    'orphaned-by-pipe~~git commit -m "a|b" --no-verify'; do
    label=${row%%~~*}; cmd=${row#*~~}
    run_hook "$cmd"
    check_verdict "$label" deny
  done
}

# Capital -C changes directory; it is not a bypass. Only lowercase
# `-c core.hooksPath=` on a commit or push carries one.
@test "a commit or push with no bypass, a dry-run, a config read or a non-git command is allowed" {
  local row label cmd
  for row in \
    'plain-commit~~git commit -m "x"' \
    'push-n-dry-run~~git push -n origin feature' \
    'push-dry-run~~git push --dry-run origin feature' \
    'plain-push~~git push origin feature' \
    'other-config-override~~git -c user.name=x commit -m x' \
    'other-config-env~~git --config-env=user.name=NAME commit -m x' \
    'config-hookspath~~git config core.hooksPath .githooks' \
    "home-git-C-commit~~git -C $REPO commit -m \"x\"" \
    'hookspath-status~~git -c core.hooksPath=/dev/null status' \
    'non-git~~pnpm run build'; do
    label=${row%%~~*}; cmd=${row#*~~}
    run_hook "$cmd"
    check_verdict "$label" allow
  done
}

# Command-position anchoring: the words appear, but git is not the program, or
# the -n belongs to another program's segment.
@test "command text that merely mentions git commit is not an invocation: grep pattern, echo, grep -n after a commit, tail -n" {
  local row label cmd
  for row in \
    'grep-pattern~~grep -n -e git commit app/foo.ts' \
    'echo-then-grep~~echo git commit && grep -n foo bar' \
    'commit-then-grep-n~~git commit -m "x" && grep -n foo bar' \
    'tail-n~~tail -n 5 git-commit-notes.txt'; do
    label=${row%%~~*}; cmd=${row#*~~}
    run_hook "$cmd"
    check_verdict "$label" allow
  done
}

# A bypass token merely mentioned inside a commit message still denies, by
# design (the hook's header comment); the over-block row drives that case so it
# pins the message that case actually gets. The over-block note applies only to
# commit: push carries no message text a token could be mentioned inside.
@test "deny messages name the pre-commit hook and, on commit only, the commit-message workaround" {
  local row label rest cmd needle presence
  for row in \
    'names-pre-commit~~.githooks/pre-commit~~present~~git commit --no-verify -m x' \
    'over-block-workaround~~documented over-block~~present~~git commit -m "use --no-verify next time"' \
    'push-omits-workaround~~documented over-block~~absent~~git push --no-verify'; do
    label=${row%%~~*}; rest=${row#*~~}
    needle=${rest%%~~*}; rest=${rest#*~~}
    presence=${rest%%~~*}; cmd=${rest#*~~}
    run_hook "$cmd"
    check_verdict "$label" deny
    if grep -qF -- "$needle" <<<"$output"; then
      [ "$presence" = present ] || { echo "case $label: '$needle' present: $output"; return 1; }
    else
      [ "$presence" = absent ] || { echo "case $label: '$needle' missing: $output"; return 1; }
    fi
  done
}

# --- command-word derivation: prefixes that hid `git` from the segment walk ---
#
# `NAME+=value` is a command prefix the shell accepts exactly as `NAME=value`
# (`bash -c 'zz+=1 env'` prints `zz=1`), so a strip reading only the `=`
# spelling leaves the command word unexposed (plus-*).
#
# A reserved word or grouping token stands in command position with no
# `| & ; ( )` between it and the command word (reserved-*). The set is
# hand-written, because bash's reserved words are not derivable from anything
# in this repository, so it carries its non-members with reasons
# (`.claude/rules/bats-assertions.md`). Every member is driven immediately
# before git except `while`, whose row puts git after `do`. Deliberately not members, each
# because it precedes something other than a command: `function` and `for` and
# `select` precede a NAME, `case` precedes a WORD, `[[` precedes a conditional
# expression, and `in`, `esac`, `fi`, `done`, `}` and `]]` close a construct
# rather than opening one. A command WRAPPER (`env`, `command`, `timeout`) is
# not a reserved word and is not a member either; the derivation's own comment
# states that limit.
#
# An assignment's value may be quoted and carry whitespace; a value read as an
# unquoted run stops at the opening quote (quoted-*).
#
# A redirection may lead a simple command and occupy the command-word slot
# (redirect-*). Deliberately not a member: a redirection whose target is another
# descriptor (`2>&1`, `>&2`); the walk cuts segments at `&` before the strip
# sees them, which the second honest limit in lib/git-segments.sh states.
#
# A word merely beginning with a reserved word is an ordinary command name, so
# the strip requires the whitespace that makes the reserved word a word
# (name-*, allowed).
@test "a prefix before the git command word does not hide it: NAME+=value, reserved words, quoted assignments, redirections" {
  local row label rest verdict cmd
  for row in \
    'plus-assign~~deny~~zz+=1 git commit -n -m x' \
    'plus-assign-subshell~~deny~~(name+=v git commit -n -m x)' \
    'plus-assign-push~~deny~~zz+=1 git push --no-verify' \
    'plus-assign-mixed~~deny~~a=1 b+=2 git commit --no-verify -m x' \
    'reserved-then~~deny~~if true; then git commit -n -m y; fi' \
    'reserved-brace~~deny~~{ git commit -n -m y; }' \
    'reserved-bang~~deny~~! git commit -n -m y' \
    'reserved-time~~deny~~time git commit -n -m y' \
    'reserved-time-p~~deny~~time -p git commit -n -m y' \
    'reserved-time-dashdash~~deny~~time -- git commit -n -m y' \
    'reserved-coproc~~deny~~coproc git commit -n -m y' \
    'reserved-do~~deny~~for f in x; do git commit -n -m y; done' \
    'reserved-while-do~~deny~~while :; do git push --no-verify; done' \
    'reserved-if~~deny~~if git commit -n -m y; then echo ok; fi' \
    'reserved-until~~deny~~until git push --no-verify; do echo retry; done' \
    'reserved-else~~deny~~if false; then echo no; else git commit -n -m y; fi' \
    'reserved-elif~~deny~~if false; then echo no; elif git commit -n -m y; then echo ok; fi' \
    'quoted-double~~deny~~GIT_EDITOR="code --wait" git commit --no-verify -m x' \
    'quoted-date~~deny~~GIT_AUTHOR_DATE="2024-01-01 12:00" git commit -n -m x' \
    "quoted-single~~deny~~GIT_AUTHOR_DATE='2024-01-01 12:00' git commit -n -m x" \
    'quoted-push~~deny~~GIT_EDITOR="code --wait" git push --no-verify' \
    'redirect-out~~deny~~>/tmp/gaia-probe git commit --no-verify -m x' \
    'redirect-stderr~~deny~~2>/dev/null git commit -n -m x' \
    'redirect-append-push~~deny~~>>/tmp/gaia-probe git push --no-verify' \
    'name-iffy~~allow~~iffy git commit -n -m y' \
    'name-dotimes~~allow~~dotimes git commit -n -m y'; do
    label=${row%%~~*}; rest=${row#*~~}
    verdict=${rest%%~~*}; cmd=${rest#*~~}
    run_hook "$cmd"
    check_verdict "$label" "$verdict"
  done
}

# A `$( )` inside git's OWN arguments cuts the segment at its parens, so no one
# segment carries both the command word and the bypass flag (orphan-*).
# Collapsing the span must not put the substitution's own text back in the
# reader's way: a word produced INSIDE one is not the outer segment's
# subcommand, and the body still reaches the walk as its own segment (inner-*).
@test "a command substitution does not orphan the flag or arm the outer segment" {
  local row label rest verdict cmd
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  for row in \
    'orphan-message-n~~deny~~git commit -m "$(cat f)" -n' \
    'orphan-message-no-verify~~deny~~git commit -m "$(cat f)" --no-verify' \
    'orphan-git-C~~deny~~git -C "$(pwd)" commit -n -m y' \
    'orphan-git-C-message~~deny~~git -C "$(pwd)" commit -m "$(cat f)" --no-verify' \
    'orphan-nested~~deny~~git commit -m "$(echo "$(date)")" -n' \
    'inner-commit-word~~allow~~git log $(echo commit) -n 1' \
    'inner-git-log~~allow~~echo "$(git log)" --no-verify'; do
    label=${row%%~~*}; rest=${row#*~~}
    verdict=${rest%%~~*}; cmd=${rest#*~~}
    run_hook "$cmd"
    check_verdict "$label" "$verdict"
  done
}

# --- the staged-tree harness the degrade table below uses ---
#
# The library loads resolve off BASH_SOURCE, never off the process working
# directory, so expressing a degraded library needs a COPY of the hook in a tree
# the test controls: running the real $HOOK_ABSOLUTE_PATH leaves it resolving the real
# checkout's library beside itself, whatever a fixture does to a copy anywhere
# else.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

stage_hook_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  mkdir -p "$STAGED_ROOT/.claude"
  # The whole hooks directory, lib/ included, rather than the libraries this
  # hook happens to load today: an enumeration goes short the moment the hook
  # gains a load, and the cases below would then drive a hook degraded in a way
  # none of them names while still reporting green. Each case removes or
  # corrupts only the library it is named for. Staging the directory wholesale
  # also keeps the jq-availability arm present, which runs ahead of the load
  # under test and refuses when it cannot find its own library, answering every
  # case with that refusal instead of with the decision under test.
  cp -R "$HOOKS_SOURCE_DIRECTORY" "$STAGED_ROOT/.claude/hooks"
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-no-verify.sh"
}

# Run the staged copy of the hook, from inside the staged tree.
run_staged() {
  local json
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook_in "$STAGED_ROOT" "$json" "$STAGED_HOOK"
}

# --- a degraded library: repo-scope degrades, the others refuse loudly ---
#
# repo-scope.sh: its load sits under this hook's `set -euo pipefail`, so without
# the bracket suspending errexit an unparseable copy abandons the shell ahead of
# the `type command_targets_foreign_repo` check on the next line. That exits 2,
# the PreToolUse deny code, refusing every git command the hook matches --
# including the very edit that would repair the library. This one denies on
# bash 5 as well as on 3.2, so neither conflict-marker row needs a /bin/bash pin.
# Each allow/deny pair is what discriminates: the allow row alone is satisfied
# by a hook that stopped enforcing, so the deny twin proves the degrade kept the
# floor (without command_targets_foreign_repo the foreign-repo carve-out simply
# does not fire, the fail-closed direction the hook's repo-scope comment
# documents). For the absent library an unbracketed load alone cannot red it:
# the `[ -f ]` guard ahead of the source short-circuits, and errexit exempts a
# non-final command in an `&&` list. Dropping that guard along with the bracket
# reds it, and the shell is then abandoned on a status PreToolUse does not read
# as a deny, so both rows red on the missing verdict.
#
# git-segments.sh and hook-payload.sh: an unloadable copy refuses with exit 2
# naming the library, never failing open. git-segments.sh loads after the git
# fast path, so without it a non-git call still passes silently; hook-payload.sh
# loads before it and refuses every call.
#
# Each row: label~~library~~damage~~expect~~command. expect is allow or deny
# (the JSON verdict), refuse (exit 2 with the BLOCKED line naming the library),
# or silent (exit 0, no output).
@test "repo-scope, git-segments or hook-payload library absent or conflicted: bypass still denied or refused, non-bypass still allowed" {
  local row label rest library damage expect cmd library_path
  for row in \
    'repo-scope-conflicted-allow~~repo-scope.sh~~conflict~~allow~~git status' \
    'repo-scope-conflicted-deny~~repo-scope.sh~~conflict~~deny~~git commit --no-verify -m x' \
    'repo-scope-absent-allow~~repo-scope.sh~~absent~~allow~~git status' \
    'repo-scope-absent-deny~~repo-scope.sh~~absent~~deny~~git commit --no-verify -m x' \
    'git-segments-absent-refuse~~git-segments.sh~~absent~~refuse~~git commit --no-verify -m x' \
    'git-segments-conflicted-refuse~~git-segments.sh~~conflict~~refuse~~git commit --no-verify -m x' \
    'git-segments-absent-non-git~~git-segments.sh~~absent~~silent~~ls' \
    'hook-payload-absent-refuse~~hook-payload.sh~~absent~~refuse~~git commit --no-verify -m x' \
    'parse-absent-refuse~~main-git-guard-parse.sh~~absent~~refuse~~git commit -m x' \
    'command-config-conflicted-refuse~~git-command-config.sh~~conflict~~refuse~~git commit -m x'; do
    label=${row%%~~*}; rest=${row#*~~}
    library=${rest%%~~*}; rest=${rest#*~~}
    damage=${rest%%~~*}; rest=${rest#*~~}
    expect=${rest%%~~*}; cmd=${rest#*~~}
    stage_hook_tree
    library_path="$STAGED_ROOT/.claude/hooks/lib/$library"
    if [ "$damage" = conflict ]; then
      write_conflicted_library "$library_path"
    else
      rm -f "$library_path"
    fi
    run_staged "$cmd"
    case "$expect" in
      allow|deny) check_verdict "$label" "$expect" ;;
      refuse)
        [ "$status" -eq 2 ] || { echo "case $label: status=$status output=$output"; return 1; }
        grep -qF "BLOCKED: block-no-verify.sh cannot load lib/$library" <<<"$output" \
          || { echo "case $label: missing BLOCKED line: $output"; return 1; } ;;
      silent)
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ -z "$output" ] || { echo "case $label: unexpected output: $output"; return 1; } ;;
    esac
  done
}

# block-no-verify.sh and block-main-destructive-git.sh each derive a segment's
# command word with their own copy of one expression, so a widening applied to
# one and not the other reopens the gap in whichever copy was missed. Pinned on
# the construct, not only on sameness: a copy that agrees with the other at the
# narrow spelling fails here too.
# Both git deny guards read the segment command word and the substitution
# collapse from lib/git-segments.sh. An inline copy returning to either one
# would let a widening reach one guard and miss the other, which is the gap the
# shared library closes; the behavior itself is pinned in git-segments-lib.bats.
@test "neither git deny guard carries its own substitution collapse or command-word strip" {
  local hook_file_name
  for hook_file_name in block-no-verify.sh block-main-destructive-git.sh; do
    grep -q '^collapsed_substitutions()' "$HOOKS_SOURCE_DIRECTORY/$hook_file_name" && return 1
    grep -qF 'sed -E '"'"'s/^[[:space:]]*((' "$HOOKS_SOURCE_DIRECTORY/$hook_file_name" && return 1
    grep -qF 'gaia_collapsed_substitutions' "$HOOKS_SOURCE_DIRECTORY/$hook_file_name"
    grep -qF 'gaia_segment_command_word' "$HOOKS_SOURCE_DIRECTORY/$hook_file_name"
  done
  true
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
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-no-verify.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}
