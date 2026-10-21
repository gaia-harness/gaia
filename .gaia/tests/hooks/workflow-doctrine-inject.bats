#!/usr/bin/env bats

# .claude/hooks/workflow-doctrine-inject.sh: injects the execution doctrine
# through hookSpecificOutput.additionalContext when a session works on a branch
# (non-default branch in the main checkout, or any linked worktree), at
# SessionStart and mid-session, and never for a session on the default branch
# in the main checkout.
#
# Every fixture repo carries its own copy of the hook, its libraries, and a
# fixture doctrine file, so the suite never reads the real doctrine. HOOK_SOURCE_PATH
# points the suite at another copy of the hook (a mutated scratch copy proves
# the cases can go red); it defaults to the real hook.
#
# Each negative case runs in the same fixture as a positive control that
# differs by one variable. The hook runs under /bin/bash, the shell whose cost
# budget it is held to.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/workflow-doctrine-inject.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset CLAUDE_CODE_SESSION_ID
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/workflow-doctrine-inject.sh}"
  REPO="$TEMPORARY_DIRECTORY/repo"
  HOOK="$REPO/.claude/hooks/workflow-doctrine-inject.sh"
  DOCTRINE_PATH="$REPO/.claude/doctrine/execution.md"
  mkdir -p "$TEMPORARY_DIRECTORY/norepo"
  cd "$TEMPORARY_DIRECTORY/norepo" || return 1
  make_repo
}

make_repo() {
  mkdir -p "$REPO/.claude/hooks" "$REPO/.claude/doctrine" "$REPO/.gaia/scripts"
  cp "$HOOK_SOURCE_PATH" "$HOOK"
  chmod 755 "$HOOK"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  local library_file
  for library_file in usage-lib.sh main-root-lib.sh branch-name-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$REPO/.gaia/scripts/$library_file"
  done
  printf 'Fixture doctrine line one.\nIt says "quoted" and back\\slash and\ttab.\nLast line.\n' >"$DOCTRINE_PATH"
  git -C "$REPO" init -q -b main
  git -C "$REPO" commit -q --allow-empty -m init
}

# Payload builders: <sid> ... <cwd>
session_start_payload() { jq -nc --arg session_id "$1" --arg session_source "$2" --arg working_directory "$3" '{hook_event_name:"SessionStart",session_id:$session_id,source:$session_source,cwd:$working_directory}'; }
post_tool_bash_payload() {
  jq -nc --arg session_id "$1" --arg command_text "$2" --arg working_directory "$3" \
    '{hook_event_name:"PostToolUse",session_id:$session_id,tool_name:"Bash",tool_input:{command:$command_text},tool_response:{},cwd:$working_directory}'
}
post_tool_enter_worktree_payload() {
  jq -nc --arg session_id "$1" --arg working_directory "$2" --arg worktree_path "${3:-}" \
    '{hook_event_name:"PostToolUse",session_id:$session_id,tool_name:"EnterWorktree",tool_input:{},tool_response:(if $worktree_path == "" then {} else {worktreePath:$worktree_path} end),cwd:$working_directory}'
}

run_hook() { run --separate-stderr /bin/bash "$HOOK" <<<"$1"; }

marker() { printf '%s/.gaia/local/cache/doctrine-injected.%s' "$REPO" "$1"; }

# Exit 0, empty stderr, exactly one JSON value, hookEventName echoes the input
# event; leaves the decoded additionalContext bytes in $TEMPORARY_DIRECTORY/ctx.
assert_envelope() {
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -s length <<<"$output")" = 1 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = "$1" ]
  jq -j .hookSpecificOutput.additionalContext <<<"$output" >"$TEMPORARY_DIRECTORY/ctx"
}

# Context is the fixture doctrine byte for byte, with no key line.
assert_injects() {
  assert_envelope "$1"
  cmp "$TEMPORARY_DIRECTORY/ctx" "$DOCTRINE_PATH"
}

# Context is one key line starting with <prefix>, then the doctrine byte for byte.
assert_injects_keyed() {
  assert_envelope "$1"
  local first
  first="$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")"
  case "$first" in "$2"*) ;; *) echo "first line '$first' lacks prefix '$2'" >&2; return 1 ;; esac
  tail -n +2 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"
}

assert_silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "UAT-003: default branch in the main checkout is silent for every SessionStart source, and a feature branch injects" {
  local session_source
  for session_source in startup resume clear compact; do
    run_hook "$(session_start_payload "s-$session_source" "$session_source" "$REPO")"
    assert_silent
  done
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload s-control startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "UAT-004: a feature branch in the main checkout gets the exact branch key line, then the doctrine" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload s4 startup "$REPO")"
  assert_envelope SessionStart
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")" = "Branch key: branch:feat/123-example. Link its initiative once with: bash .gaia/scripts/usage.sh link branch:feat/123-example research:<date>-<topic> (or issue:<n>)" ]
  tail -n +2 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"
}

@test "UAT-005: every linked worktree injects; the key follows the worktree's branch" {
  git -C "$REPO" worktree add -q -b "worktree-debt+42" "$TEMPORARY_DIRECTORY/wt1"
  run_hook "$(session_start_payload s5a startup "$TEMPORARY_DIRECTORY/wt1")"
  assert_injects_keyed SessionStart "Branch key: branch:debt/42. "

  git -C "$TEMPORARY_DIRECTORY/wt1" checkout -q --detach
  run_hook "$(session_start_payload s5b startup "$TEMPORARY_DIRECTORY/wt1")"
  assert_injects_keyed SessionStart "Session key: session:s5b. "
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx" | grep -c 'branch:')" = 0 ]

  git -C "$REPO" worktree add -q -b worktree-agent-abc123 "$TEMPORARY_DIRECTORY/wt2"
  run_hook "$(session_start_payload s5c startup "$TEMPORARY_DIRECTORY/wt2")"
  assert_injects_keyed SessionStart "Session key: session:s5c. "

  git -C "$REPO" checkout -q -b other
  git -C "$REPO" worktree add -q "$TEMPORARY_DIRECTORY/wt3" main
  run_hook "$(session_start_payload s5d startup "$TEMPORARY_DIRECTORY/wt3")"
  assert_injects_keyed SessionStart "Session key: session:s5d. "
}

@test "UAT-006: EnterWorktree decides from worktreePath, then payload cwd, never the process cwd" {
  git -C "$REPO" worktree add -q -b feat/9-x "$TEMPORARY_DIRECTORY/wtb"
  git -C "$REPO" worktree add -q --detach "$TEMPORARY_DIRECTORY/wtd"

  run_hook "$(post_tool_enter_worktree_payload e1 "$REPO" "$TEMPORARY_DIRECTORY/wtb")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "

  run_hook "$(post_tool_enter_worktree_payload e2 "$TEMPORARY_DIRECTORY/wtb")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "

  run_hook "$(post_tool_enter_worktree_payload e3 "$REPO" "$TEMPORARY_DIRECTORY/wtd")"
  assert_injects_keyed PostToolUse "Session key: session:e3. "

  run_hook "$(post_tool_enter_worktree_payload e4 "$REPO" "$REPO")"
  assert_silent
}

@test "EnterWorktree onto the harness's worktree spelling names the exact rename to the canonical branch first" {
  local rename_line
  git -C "$REPO" worktree add -q -b "worktree-fix+foo" "$TEMPORARY_DIRECTORY/wtr"
  rename_line="This branch is the worktree spelling the harness assigns; rename it to its canonical name before the first push: git -C \"$TEMPORARY_DIRECTORY/wtr\" branch -m worktree-fix+foo fix/foo"

  run_hook "$(post_tool_enter_worktree_payload r1 "$REPO" "$TEMPORARY_DIRECTORY/wtr")"
  assert_envelope PostToolUse
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")" = "$rename_line" ]
  tail -n +2 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/keyed"
  case "$(head -n 1 "$TEMPORARY_DIRECTORY/keyed")" in "Branch key: branch:fix/foo. "*) ;; *) return 1 ;; esac
  tail -n +2 "$TEMPORARY_DIRECTORY/keyed" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"

  # The marker does not suppress the rename while the branch still needs it.
  run_hook "$(post_tool_enter_worktree_payload r1 "$REPO" "$TEMPORARY_DIRECTORY/wtr")"
  assert_envelope PostToolUse
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")" = "$rename_line" ]

  # Controls: SessionStart in the same tree, an agent worktree, and the renamed branch carry no rename line.
  run_hook "$(session_start_payload r2 startup "$TEMPORARY_DIRECTORY/wtr")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/foo. "

  git -C "$REPO" worktree add -q -b worktree-agent-abc123 "$TEMPORARY_DIRECTORY/wta"
  run_hook "$(post_tool_enter_worktree_payload r3 "$REPO" "$TEMPORARY_DIRECTORY/wta")"
  assert_injects_keyed PostToolUse "Session key: session:r3. "

  git -C "$TEMPORARY_DIRECTORY/wtr" branch -m worktree-fix+foo fix/foo
  run_hook "$(post_tool_enter_worktree_payload r4 "$REPO" "$TEMPORARY_DIRECTORY/wtr")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/foo. "

  # An off-grammar worktree spelling is never echoed into a rename line.
  git -C "$REPO" worktree add -q -b "$(printf 'worktree-fix+a\140b')" "$TEMPORARY_DIRECTORY/wto"
  run_hook "$(post_tool_enter_worktree_payload r5 "$REPO" "$TEMPORARY_DIRECTORY/wto")"
  assert_envelope PostToolUse
  grep -q 'rename it' "$TEMPORARY_DIRECTORY/ctx" && return 1
  grep -qF '`' "$TEMPORARY_DIRECTORY/ctx" && return 1
  true
}

@test "UAT-006: a non-Bash, non-EnterWorktree PostToolUse tool is silent in a tree that would inject" {
  git -C "$REPO" checkout -q -b feat/9-x
  run_hook "$(jq -nc --arg working_directory "$REPO" '{hook_event_name:"PostToolUse",session_id:"t1",tool_name:"Read",tool_input:{},tool_response:{},cwd:$working_directory}')"
  assert_silent
  run_hook "$(post_tool_enter_worktree_payload t2 "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "
}

@test "EnterWorktree into a tree with no .gaia/local creates nothing there and writes the marker under the main root" {
  git -C "$REPO" worktree add -q -b feat/9-x "$TEMPORARY_DIRECTORY/wtn"
  [ ! -e "$TEMPORARY_DIRECTORY/wtn/.gaia/local" ]
  run_hook "$(post_tool_enter_worktree_payload m1 "$REPO" "$TEMPORARY_DIRECTORY/wtn")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "
  [ ! -e "$TEMPORARY_DIRECTORY/wtn/.gaia/local" ]
  [ -f "$(marker m1)" ]
  [ "$(cat "$(marker m1)")" = "branch:feat/9-x" ]
}

@test "UAT-007: a branch-changing Bash command injects once the checkout happened, and only then" {
  git -C "$REPO" branch feat/12-x

  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(post_tool_bash_payload b1 'git checkout -b fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D fix/7-x

  git -C "$REPO" switch -q -c fix/7-x
  run_hook "$(post_tool_bash_payload b2 'git switch -c fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D fix/7-x

  git -C "$REPO" switch -q -c fix/7-x
  run_hook "$(post_tool_bash_payload b3 "git -C \"$REPO\" switch -c fix/7-x" "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" checkout -q feat/12-x
  run_hook "$(post_tool_bash_payload b4 'git checkout feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" switch -q feat/12-x
  run_hook "$(post_tool_bash_payload b5 'git switch feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" checkout -q -b pr-123
  run_hook "$(post_tool_bash_payload b6 'gh pr checkout 123' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:pr-123. "
  git -C "$REPO" checkout -q main

  # Same fixture, HEAD back on the default branch: nothing to inject.
  run_hook "$(post_tool_bash_payload n1 'git checkout main' "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload n2 'git status' "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload n3 'git switch -c fix/8-y' "$REPO")"
  assert_silent
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = main ]
}

@test "a Bash command that does not arm starts no git process; an armed one does" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEMPORARY_DIRECTORY/shim"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$TEMPORARY_DIRECTORY/git.log" "$real_git" >"$TEMPORARY_DIRECTORY/shim/git"
  chmod 755 "$TEMPORARY_DIRECTORY/shim/git"
  git -C "$REPO" branch feat/12-x
  git -C "$REPO" checkout -q feat/12-x

  local shell_command
  for shell_command in 'ls -la' 'echo checkout' 'git status' 'pnpm test'; do
    run --separate-stderr env PATH="$TEMPORARY_DIRECTORY/shim:$PATH" /bin/bash "$HOOK" <<<"$(post_tool_bash_payload "shim-$RANDOM" "$shell_command" "$REPO")"
    assert_silent
  done
  [ ! -s "$TEMPORARY_DIRECTORY/git.log" ]

  run --separate-stderr env PATH="$TEMPORARY_DIRECTORY/shim:$PATH" /bin/bash "$HOOK" <<<"$(post_tool_bash_payload shim-control 'git switch feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  [ -s "$TEMPORARY_DIRECTORY/git.log" ]
}

@test "UAT-008: the marker dedupes startup and PostToolUse for one key; resume, compact, and clear always inject; a new key injects" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  [ "$(cat "$(marker d1)")" = "branch:fix/7-x" ]

  run_hook "$(post_tool_enter_worktree_payload d1 "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload d1 'git switch fix/7-x' "$REPO")"
  assert_silent
  run_hook "$(session_start_payload d1 startup "$REPO")"
  assert_silent

  run_hook "$(session_start_payload d1 resume "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  run_hook "$(session_start_payload d1 compact "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  run_hook "$(session_start_payload d1 clear "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "

  git -C "$REPO" checkout -q -b fix/9-z
  run_hook "$(post_tool_bash_payload d1 'git switch -c fix/9-z' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/9-z. "
  [ "$(cat "$(marker d1)")" = "branch:fix/9-z" ]
}

@test "UAT-008: a no-injection clear removes the marker so a later return to the branch injects" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  [ -f "$(marker d2)" ]

  git -C "$REPO" checkout -q main
  run_hook "$(session_start_payload d2 clear "$REPO")"
  assert_silent
  [ -e "$(marker d2)" ] && return 1

  git -C "$REPO" checkout -q fix/7-x
  run_hook "$(post_tool_bash_payload d2 'git switch fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
}

@test "UAT-008: a no-injection resume or compact also removes the marker; startup leaves it" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d3 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main

  run_hook "$(session_start_payload d3 startup "$REPO")"
  assert_silent
  [ -f "$(marker d3)" ]

  run_hook "$(session_start_payload d3 resume "$REPO")"
  assert_silent
  [ -e "$(marker d3)" ] && return 1
  true
}

@test "UAT-009: a cwd outside any repository is silent, with a control that injects" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload c2 startup "$TEMPORARY_DIRECTORY/norepo")"
  assert_silent
  run_hook "$(jq -nc '{hook_event_name:"SessionStart",session_id:"c2",source:"startup"}')"
  assert_silent
  run_hook "$(session_start_payload c2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "UAT-009: a missing doctrine file is silent, with a control that injects" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload c3 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  mv "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/execution.md.away"
  run_hook "$(session_start_payload c3b startup "$REPO")"
  assert_silent
}

@test "UAT-009: without jq, SessionStart injects valid JSON from the process cwd and PostToolUse is silent" {
  git -C "$REPO" checkout -q -b feat/123-example
  mkdir -p "$TEMPORARY_DIRECTORY/nojq"
  local tool_name tool_path
  for tool_name in git sed awk cat wc; do
    tool_path="$(command -v "$tool_name")"
    ln -sf "$tool_path" "$TEMPORARY_DIRECTORY/nojq/$tool_name"
  done
  [ ! -e "$TEMPORARY_DIRECTORY/nojq/jq" ]

  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(session_start_payload nj startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  [ ! -e "$(marker nj)" ]

  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(post_tool_bash_payload nj 'git switch feat/123-example' "$REPO")"
  assert_silent

  git -C "$REPO" checkout -q main
  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(session_start_payload nj startup "$REPO")"
  assert_silent
}

@test "UAT-010: an off-grammar branch name is never echoed and carries no key line" {
  local name
  # shellcheck disable=SC2016  # a literal $( is the point
  name="$(printf 'feat/a\140b$(x)%%')"
  git check-ref-format --branch "$name" >/dev/null
  git -C "$REPO" checkout -q -b "$name"
  run_hook "$(session_start_payload g1 startup "$REPO")"
  assert_injects SessionStart
  grep -q 'Branch key' "$TEMPORARY_DIRECTORY/ctx" && return 1
  grep -q 'usage.sh link' "$TEMPORARY_DIRECTORY/ctx" && return 1
  grep -qF '`' "$TEMPORARY_DIRECTORY/ctx" && return 1
  # shellcheck disable=SC2016  # a literal $( is the point
  grep -qF '$(' "$TEMPORARY_DIRECTORY/ctx" && return 1
  # Control: a valid name on the same fixture gets its key line.
  git -C "$REPO" checkout -q -b feat/ok
  run_hook "$(session_start_payload g2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/ok. "
}

@test "UAT-010: a 128-character branch with a maximum-size doctrine stays under the payload cap and keeps its full name" {
  local name base pad
  name="feat/$(head -c 123 /dev/zero | tr '\0' a)"
  [ "${#name}" = 128 ]
  git -C "$REPO" checkout -q -b "$name"
  base="$(wc -c <"$DOCTRINE_PATH")"
  pad=$((3584 - base - 1))
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3584 ]

  run_hook "$(session_start_payload p1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:$name. "
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/ctx")" -le 4096 ]
  head -n 1 "$TEMPORARY_DIRECTORY/ctx" | grep -qF "link branch:$name research:"
}

@test "audit directive 10: a doctrine one byte over the cap is silent, never truncated" {
  local base pad
  git -C "$REPO" checkout -q -b feat/123-example
  base="$(wc -c <"$DOCTRINE_PATH")"
  pad=$((3585 - base - 1))
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3585 ]
  run_hook "$(session_start_payload o1 startup "$REPO")"
  assert_silent

  pad=$((3584 - base - 1))
  printf 'Fixture doctrine line one.\nIt says "quoted" and back\\slash and\ttab.\nLast line.\n' >"$DOCTRINE_PATH"
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3584 ]
  run_hook "$(session_start_payload o2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "a git directory not named .git still anchors the marker at the main root" {
  mv "$REPO/.git" "$TEMPORARY_DIRECTORY/sepgit"
  printf 'gitdir: %s\n' "$TEMPORARY_DIRECTORY/sepgit" >"$REPO/.git"
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload sg startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  [ -f "$(marker sg)" ]
}

@test "a reftable repository decides the same way as a files repository" {
  rm -rf "$REPO/.git"
  git -C "$REPO" init -q -b main --ref-format=reftable 2>/dev/null || skip "git lacks reftable support"
  git -C "$REPO" commit -q --allow-empty -m init
  run_hook "$(session_start_payload rt1 startup "$REPO")"
  assert_silent
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload rt2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "an origin/HEAD that names another branch makes main a non-default branch" {
  git -C "$REPO" branch develop
  git -C "$REPO" update-ref refs/remotes/origin/develop HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  run_hook "$(session_start_payload od1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:main. "
  git -C "$REPO" checkout -q develop
  run_hook "$(session_start_payload od2 startup "$REPO")"
  assert_silent
}

# ---------------------------------------------------------------------------
# Worktree backstop: a Bash `git worktree add` under .claude/worktrees/.
# Each case runs the real command in the fixture repo first, then feeds the hook
# the same command in a PostToolUse payload.
# ---------------------------------------------------------------------------

# The branch validator reads the commit types from the JSON beside the library.
backstop_fixture() {
  cp "$REPO_ROOT/.gaia/conventional-commits.json" "$REPO/.gaia/conventional-commits.json"
}

context_has() { grep -qF -- "$1" "$TEMPORARY_DIRECTORY/ctx"; }

# <path> <branch>: the backstop names the tree, its branch, the entry call, and the reference.
assert_backstop_names() {
  assert_envelope PostToolUse || return 1
  context_has "A git worktree exists at $1 on branch $2." || return 1
  context_has "EnterWorktree({path: \"$1\"})" || return 1
  context_has ".claude/skills/gaia/references/work-lifecycle.md" || return 1
}

assert_rename_instruction() { # <path> <branch>
  context_has 'bash .gaia/scripts/branch-name-lib.sh name adhoc --type <type> --slug "<slug>"' || return 1
  context_has "git -C \"$1\" branch -m $2 <minted name>" || return 1
}

assert_no_rename_instruction() {
  context_has 'name adhoc' && return 1
  context_has 'branch -m' && return 1
  context_has 'switch -c' && return 1
  return 0
}

@test "backstop: an absolute .claude/worktrees path with a hand-made branch names the tree, the entry call, and the rename" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/hand-tree"
  git -C "$REPO" worktree add -q "$tree" -b hand-name
  run_hook "$(post_tool_bash_payload w1 "git worktree add $tree -b hand-name" "$REPO")"
  assert_backstop_names "$tree" hand-name
  assert_rename_instruction "$tree" hand-name
  [ "$(awk 'END { print NR }' "$TEMPORARY_DIRECTORY/ctx")" -eq 2 ]
}

@test "backstop: relative path, -C form, -b before or after the path, -B, and a quoted path each inject the right absolute path" {
  backstop_fixture
  local tree

  git -C "$REPO" worktree add -q .claude/worktrees/rel -b hand-rel
  tree="$REPO/.claude/worktrees/rel"
  run_hook "$(post_tool_bash_payload w2a 'git worktree add .claude/worktrees/rel -b hand-rel' "$REPO")"
  assert_backstop_names "$tree" hand-rel

  git -C "$REPO" worktree add -q .claude/worktrees/dashc -b hand-c
  tree="$REPO/.claude/worktrees/dashc"
  run_hook "$(post_tool_bash_payload w2b "git -C \"$REPO\" worktree add .claude/worktrees/dashc -b hand-c" "$TEMPORARY_DIRECTORY/norepo")"
  assert_backstop_names "$tree" hand-c

  git -C "$REPO" worktree add -q -b hand-before .claude/worktrees/before
  tree="$REPO/.claude/worktrees/before"
  run_hook "$(post_tool_bash_payload w2c 'git worktree add -b hand-before .claude/worktrees/before' "$REPO")"
  assert_backstop_names "$tree" hand-before

  git -C "$REPO" worktree add -q -B hand-force .claude/worktrees/force
  tree="$REPO/.claude/worktrees/force"
  run_hook "$(post_tool_bash_payload w2d 'git worktree add -B hand-force .claude/worktrees/force' "$REPO")"
  assert_backstop_names "$tree" hand-force

  tree="$REPO/.claude/worktrees/quoted"
  git -C "$REPO" worktree add -q --lock --reason "keep it" "$tree" -b hand-quoted
  run_hook "$(post_tool_bash_payload w2e "git worktree add --lock --reason 'keep it' \"$tree\" -b hand-quoted" "$REPO")"
  assert_backstop_names "$tree" hand-quoted
}

@test "backstop: a minted branch carries no rename instruction, and the hand-made control does" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/minted"
  git -C "$REPO" worktree add -q "$tree" -b fix/12-sample
  run_hook "$(post_tool_bash_payload w3 "git worktree add $tree -b fix/12-sample" "$REPO")"
  assert_backstop_names "$tree" fix/12-sample
  assert_no_rename_instruction
  [ "$(awk 'END { print NR }' "$TEMPORARY_DIRECTORY/ctx")" -eq 1 ]

  tree="$REPO/.claude/worktrees/hand"
  git -C "$REPO" worktree add -q "$tree" -b hand-control
  run_hook "$(post_tool_bash_payload w3b "git worktree add $tree -b hand-control" "$REPO")"
  assert_backstop_names "$tree" hand-control
  assert_rename_instruction "$tree" hand-control
}

@test "backstop: --detach says detached and gives the switch -c instruction" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/loose"
  git -C "$REPO" worktree add -q --detach "$tree"
  run_hook "$(post_tool_bash_payload w4 "git worktree add --detach $tree" "$REPO")"
  assert_envelope PostToolUse
  context_has "A git worktree exists at $tree on a detached HEAD."
  context_has "EnterWorktree({path: \"$tree\"})"
  context_has "git -C \"$tree\" switch -c <minted name>"
  context_has 'name adhoc --type <type> --slug "<slug>"'
  context_has 'branch -m' && return 1
  true
}

@test "backstop: a tree outside any .claude/worktrees directory gets nothing, and the same command under it does" {
  backstop_fixture
  git -C "$REPO" worktree add -q "$TEMPORARY_DIRECTORY/side-tree" -b side-branch
  run_hook "$(post_tool_bash_payload w5 "git worktree add $TEMPORARY_DIRECTORY/side-tree -b side-branch" "$REPO")"
  assert_silent

  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/inside" -b inside-branch
  run_hook "$(post_tool_bash_payload w5b "git worktree add $REPO/.claude/worktrees/inside -b inside-branch" "$REPO")"
  assert_backstop_names "$REPO/.claude/worktrees/inside" inside-branch
}

@test "backstop: a failed add gets nothing, for an occupied path and for an invalid ref" {
  backstop_fixture
  local occupied="$REPO/.claude/worktrees/occupied"
  mkdir -p "$occupied"
  printf 'x\n' >"$occupied/file"
  git -C "$REPO" worktree add -q "$occupied" -b occupied-branch 2>/dev/null && return 1
  run_hook "$(post_tool_bash_payload w6a "git worktree add $occupied -b occupied-branch" "$REPO")"
  assert_silent

  local invalid="$REPO/.claude/worktrees/invalid"
  git -C "$REPO" worktree add -q "$invalid" -b 'bad..name' 2>/dev/null && return 1
  run_hook "$(post_tool_bash_payload w6b "git worktree add $invalid -b bad..name" "$REPO")"
  assert_silent

  # Control: the same fixture and command shape, but the add succeeds.
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/ok" -b ok-branch
  run_hook "$(post_tool_bash_payload w6c "git worktree add $REPO/.claude/worktrees/ok -b ok-branch" "$REPO")"
  assert_backstop_names "$REPO/.claude/worktrees/ok" ok-branch
}

@test "backstop: a re-run add of an already-registered target states what exists and makes entry conditional" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/again"
  git -C "$REPO" worktree add -q "$tree" -b again-branch
  git -C "$REPO" worktree add -q "$tree" -b again-branch 2>/dev/null && return 1
  run_hook "$(post_tool_bash_payload w6d "git worktree add $tree -b again-branch" "$REPO")"
  assert_backstop_names "$tree" again-branch
  context_has "was created" && return 1
  context_has "If this session has not entered it" || return 1
  true
}

@test "backstop: two adds in one session each inject, and a checkout between them still dedupes the doctrine" {
  backstop_fixture
  local tree
  # Default-branch session: no doctrine, the backstop alone, both times.
  tree="$REPO/.claude/worktrees/one"
  git -C "$REPO" worktree add -q "$tree" -b hand-one
  run_hook "$(post_tool_bash_payload same "git worktree add $tree -b hand-one" "$REPO")"
  assert_backstop_names "$tree" hand-one
  tree="$REPO/.claude/worktrees/two"
  git -C "$REPO" worktree add -q "$tree" -b hand-two
  run_hook "$(post_tool_bash_payload same "git worktree add $tree -b hand-two" "$REPO")"
  assert_backstop_names "$tree" hand-two

  # Feature-branch session: the first add carries the doctrine, the checkout is
  # deduped, the second add carries the backstop alone.
  git -C "$REPO" checkout -q -b feat/12-x
  tree="$REPO/.claude/worktrees/three"
  git -C "$REPO" worktree add -q "$tree" -b hand-three
  run_hook "$(post_tool_bash_payload seen "git worktree add $tree -b hand-three" "$REPO")"
  assert_backstop_names "$tree" hand-three
  context_has "Fixture doctrine line one."

  run_hook "$(post_tool_bash_payload seen 'git switch feat/12-x' "$REPO")"
  assert_silent

  tree="$REPO/.claude/worktrees/four"
  git -C "$REPO" worktree add -q "$tree" -b hand-four
  run_hook "$(post_tool_bash_payload seen "git worktree add $tree -b hand-four" "$REPO")"
  assert_backstop_names "$tree" hand-four
  context_has "Fixture doctrine line one." && return 1
  true
}

@test "backstop: an add run from inside another linked worktree resolves against that worktree" {
  backstop_fixture
  local outer="$REPO/.claude/worktrees/outer" inner="$REPO/.claude/worktrees/inner"
  git -C "$REPO" worktree add -q "$outer" -b outer-branch
  git -C "$outer" worktree add -q ../inner -b inner-branch
  run_hook "$(post_tool_bash_payload w8 'git worktree add ../inner -b inner-branch' "$outer")"
  assert_backstop_names "$inner" inner-branch
}

@test "backstop: on a feature branch whose doctrine is not injected yet, one value carries the backstop, then the key line, then the doctrine" {
  backstop_fixture
  git -C "$REPO" checkout -q -b feat/12-x
  local tree="$REPO/.claude/worktrees/combined"
  git -C "$REPO" worktree add -q "$tree" -b fix/13-combined
  run_hook "$(post_tool_bash_payload w9 "git worktree add $tree -b fix/13-combined" "$REPO")"
  jq -e . <<<"$output" >/dev/null
  assert_backstop_names "$tree" fix/13-combined
  [ "$(sed -n 2p "$TEMPORARY_DIRECTORY/ctx" | cut -c1-34)" = "Branch key: branch:feat/12-x. Link" ]
  tail -n +3 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"
}

@test "backstop: a worktree add that is only data (a heredoc body or a quoted argument) gets nothing, and the real command does" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/data"
  git -C "$REPO" worktree add -q "$tree" -b data-branch
  local heredoc_command quoted_command
  heredoc_command=$(printf "cat > note.md <<'EOF'\ngit worktree add %s -b data-branch\nEOF" "$tree")
  run_hook "$(post_tool_bash_payload w10a "$heredoc_command" "$REPO")"
  assert_silent
  quoted_command="gh pr create --title t --body \"run git worktree add $tree -b data-branch later\""
  run_hook "$(post_tool_bash_payload w10b "$quoted_command" "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload w10c "git worktree add $tree -b data-branch" "$REPO")"
  assert_backstop_names "$tree" data-branch
}

@test "backstop: without jq PostToolUse prints nothing for a worktree add, and with jq the same command injects" {
  backstop_fixture
  mkdir -p "$TEMPORARY_DIRECTORY/nojq"
  local tool_name tool_path tree="$REPO/.claude/worktrees/nojq"
  for tool_name in git sed awk cat wc; do
    tool_path="$(command -v "$tool_name")"
    ln -sf "$tool_path" "$TEMPORARY_DIRECTORY/nojq/$tool_name"
  done
  git -C "$REPO" worktree add -q "$tree" -b hand-nojq
  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(post_tool_bash_payload nj2 "git worktree add $tree -b hand-nojq" "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload nj3 "git worktree add $tree -b hand-nojq" "$REPO")"
  assert_backstop_names "$tree" hand-nojq
}

@test "backstop: a hook copy without the worktree-add arm is silent where the real hook injects (red twin)" {
  backstop_fixture
  local tree="$REPO/.claude/worktrees/twin"
  git -C "$REPO" worktree add -q "$tree" -b hand-twin
  run_hook "$(post_tool_bash_payload r1 "git worktree add $tree -b hand-twin" "$REPO")"
  assert_backstop_names "$tree" hand-twin

  sed -e 's/|worktree\[\[:space:\]\]+add)/)/' -e 's/git worktree add;//' -e 's/git -C \* worktree add;//' "$HOOK" >"$TEMPORARY_DIRECTORY/no-arm.sh"
  cmp -s "$HOOK" "$TEMPORARY_DIRECTORY/no-arm.sh" && return 1
  cp "$TEMPORARY_DIRECTORY/no-arm.sh" "$HOOK"
  run_hook "$(post_tool_bash_payload r2 "git worktree add $tree -b hand-twin" "$REPO")"
  assert_silent
}

@test "backstop: a hook copy that skips the porcelain confirmation injects for a failed add (red twin)" {
  backstop_fixture
  local occupied="$REPO/.claude/worktrees/occupied"
  mkdir -p "$occupied"
  printf 'x\n' >"$occupied/file"
  git -C "$REPO" worktree add -q "$occupied" -b occupied-branch 2>/dev/null && return 1
  run_hook "$(post_tool_bash_payload r3 "git worktree add $occupied -b occupied-branch" "$REPO")"
  assert_silent

  # shellcheck disable=SC2016  # the pattern matches a literal $ in the hook source
  sed -e 's/^  \[ "\$in_match" = 1 \] || return 0$/  :/' "$HOOK" >"$TEMPORARY_DIRECTORY/no-confirm.sh"
  cmp -s "$HOOK" "$TEMPORARY_DIRECTORY/no-confirm.sh" && return 1
  cp "$TEMPORARY_DIRECTORY/no-confirm.sh" "$HOOK"
  run_hook "$(post_tool_bash_payload r4 "git worktree add $occupied -b occupied-branch" "$REPO")"
  [ -n "$output" ]
}
