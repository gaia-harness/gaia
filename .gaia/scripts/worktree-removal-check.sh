#!/usr/bin/env bash
# shellcheck shell=bash
#
# worktree-removal-check.sh: the stop that runs before a merged worktree is
# removed. The cleanup arms remove with `git worktree remove --force` or
# `ExitWorktree({action: "remove", discard_changes: true})`, and both destroy
# whatever the tree still holds. Run it by any path that resolves; the
# spelling below assumes a shell at the checkout root:
#   bash .gaia/scripts/worktree-removal-check.sh --tree <absolute worktree path>
#
# Exit codes:
#   0   CLEAR   nothing in the tree is lost by removing it
#   1   a block per condition that holds, then the tree path and one
#       `Next step:` line per block:
#         DIRTY     a `git status --porcelain` line (untracked files count,
#                   ignored files never do), and an `Unpushed:` line when HEAD
#                   is ahead of the branch's upstream
#   2   a refusal rather than a verdict: a usage error, or the path is not a
#       git work tree
#
# On exit 1 it also records the tree in the kept-worktree ledger through
# kept-worktrees.sh beside it, whose session-start reminder lists the tree
# until it is removed. The record's status is ignored: a ledger that cannot be
# written never changes the stop, its output, or its exit code.
#
#   bash .gaia/scripts/worktree-removal-check.sh --removal-step --tree <path> --branch <branch>
# prints only the deliberate-removal clause, the one wording of the removal
# commands, for that reminder to reuse.
#
# `.gaia-backup/` is never consulted: it is gitignored, and after the merge its
# pre-image is the worktree's base commit, which git still holds.
#
# The unpushed half runs only while the branch's upstream ref exists. After a
# squash merge that deletes the remote branch, a fetch prune removes the
# upstream ref, and from then on the branch's commits cannot be told from
# unpushed ones; counting them would stop every such cleanup.
#
# A plain literal-path script so a session inside the worktree can run it as
# one command: the runtime refuses a captured substitution on the command
# line there.
#
# Bash 3.2 compatible. Never `cd`.

set -u

usage() {
  printf 'usage: worktree-removal-check.sh --tree <absolute worktree path>\n       worktree-removal-check.sh --removal-step --tree <path> --branch <branch>\n' >&2
}

removal_step() { # <tree> <branch>
  printf "remove the worktree deliberately from the main checkout with \`git worktree remove --force %s\` then \`git branch -D %s\`, knowing --force discards what it holds.\n" "$1" "$2"
}

here=${BASH_SOURCE[0]%/*}
[ "$here" != "${BASH_SOURCE[0]}" ] || here=.

tree=""
branch=""
removal_step_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)
      [ $# -ge 2 ] || { usage; exit 2; }
      tree=$2
      shift 2
      ;;
    --branch)
      [ $# -ge 2 ] || { usage; exit 2; }
      branch=$2
      shift 2
      ;;
    --removal-step)
      removal_step_only=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$tree" ] || { usage; exit 2; }

if [ "$removal_step_only" = true ]; then
  [ -n "$branch" ] || { usage; exit 2; }
  removal_step "$tree" "$branch"
  exit 0
fi

if [ "$(git -C "$tree" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
  printf 'worktree-removal-check: %s is not a git work tree\n' "$tree" >&2
  exit 2
fi

dirty=$(git -C "$tree" status --porcelain)

unpushed_line=""
if upstream=$(git -C "$tree" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
  ahead=$(git -C "$tree" rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf 0)
  if [ "$ahead" -gt 0 ]; then
    unpushed_line="Unpushed: $ahead commit(s) ahead of $upstream"
  fi
fi

if [ -z "$dirty" ] && [ -z "$unpushed_line" ]; then
  printf 'CLEAR\n'
  exit 0
fi

branch=$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '<branch>')

why=""
[ -z "$dirty" ] || why="uncommitted changes"
[ -z "$unpushed_line" ] || why="${why:+$why, }$ahead unpushed commit(s)"
if [ -f "$here/kept-worktrees.sh" ]; then
  bash "$here/kept-worktrees.sh" record --tree "$tree" --branch "$branch" --why "$why" >/dev/null 2>&1 || true
fi

if [ -n "$dirty" ] || [ -n "$unpushed_line" ]; then
  printf 'DIRTY\n'
  [ -z "$dirty" ] || printf '%s\n' "$dirty"
  [ -z "$unpushed_line" ] || printf '%s\n' "$unpushed_line"
fi
printf 'Worktree: %s\n' "$tree"
if [ -n "$dirty" ] || [ -n "$unpushed_line" ]; then
  printf 'Next step: commit and push or discard those changes, then re-run the cleanup, or %s' "$(removal_step "$tree" "$branch")"
  printf '\n'
fi
exit 1
