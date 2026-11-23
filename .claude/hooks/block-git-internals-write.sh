#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook: deny a write anywhere in git's own
# directory (`.git/`, including its `config`, `hooks/` and each linked
# worktree's `worktrees/<name>/`) and to a linked worktree's `.git` file.
#
# Why. Git runs commands named in its config (an alias with `!`, core.sshCommand,
# core.pager) and the scripts in its hook directory, and classify-git-command.sh
# approves ordinary git calls without a prompt. A write here would plant a
# command the next approved git call runs. The pointer files count too: a
# worktree's `.git` file, or a `commondir` or `gitdir` under
# `.git/worktrees/<name>/`, decides which repository git reads, and pointing one
# at a planted repository hands git that repository's config while every
# same-repository check reads the planted one as home.
# block-main-destructive-git.sh denies the `git config` route to the command
# keys; this hook closes the file-edit route. GAIA's own hooks live in the
# tracked `.githooks/`, which this does not touch.
#
# Matched case-insensitively, because the default macOS filesystem is, so
# `.GIT/config` names the same file. Honest limit: a path reaching the file
# through a symlink, or a write from Bash (`cp`, `>`), is not an edit-tool call;
# a Bash write is not a git command, so the classifier never approves it and the
# permission prompt meets it.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. The contract lives in
# .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-git-internals-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the git config and hooks write guard' "$payload" tool_input

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || file_path=""

# Herestring, not a pipe: a `grep -q` that exits early on a long payload value
# would SIGPIPE its writer, and pipefail would turn the match into an allow.
grep -Eqi '(^|/)\.git(/.*)?$' <<<"$file_path" || exit 0

jq -n --arg reason "Writing inside git's own directory ('$file_path') is denied: git runs commands named in its config and hook scripts on later git calls, its pointer files decide which repository git reads, and ordinary git calls run without a prompt here (wiki/concepts/Git Workflow.md). Change a repository setting with 'git config <key> <value>', which the git guard checks, or edit GAIA's tracked hooks under .githooks/. If this file truly needs a hand edit, ask the user to make it." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
