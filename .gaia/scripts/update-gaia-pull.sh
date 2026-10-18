#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-pull.sh: fast-forward the main checkout's default branch to what
# origin already has, so a teammate whose checkout lags a release someone else
# merged can catch up without a merge of their own.
#
#   bash .gaia/scripts/update-gaia-pull.sh check --tree <main checkout path>
#   bash .gaia/scripts/update-gaia-pull.sh pull  --tree <main checkout path>
#
# `check` never touches the network. It prints `PULL_READY <default branch>`
# (exit 0), or exits 1 with `PULL_REFUSED <code>`, a `Reason:` line and a
# `Next step:` line. Codes: worktree, not-default-branch, uncommitted-changes
# (tracked files only: an untracked file never blocks a fast-forward).
#
# `pull` runs the same guards, fetches `origin <default branch>` only, refuses
# `diverged` when the checkout has commits origin lacks, fast-forwards, and
# prints `PULLED <old version> <new version>` then `LOCKFILE_CHANGED yes|no`.
# A fetch or merge that fails prints `PULL_FAILED <reason>` (exit 1). Exit 2 is
# a usage error.
#
# It never stashes, resets, forces or checks out another branch: every guard
# refuses and leaves the tree as it found it. The default branch is read the
# way every GAIA reader reads it: origin/HEAD, else origin/main, else
# origin/master, else main.
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

PROGRAM_NAME="update-gaia-pull.sh"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=main-root-lib.sh disable=SC1091
. "$SCRIPT_DIRECTORY/main-root-lib.sh"

usage() {
  cat <<EOF
Usage: bash .gaia/scripts/$PROGRAM_NAME check --tree <main checkout path>
       bash .gaia/scripts/$PROGRAM_NAME pull --tree <main checkout path>
EOF
}

SUBCOMMAND="${1:-}"
[ "$#" -gt 0 ] && shift
TREE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree)
      [ "$#" -ge 2 ] || { printf '%s: --tree needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      TREE="$2"
      shift 2
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$PROGRAM_NAME" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SUBCOMMAND" in
  check | pull) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [ -z "$TREE" ]; then
  printf '%s: --tree is required\n' "$PROGRAM_NAME" >&2
  usage >&2
  exit 2
fi

refuse() {
  printf 'PULL_REFUSED %s\nReason: %s\nNext step: %s\n' "$1" "$2" "$3"
  exit 1
}

fail() {
  printf 'PULL_FAILED %s\n' "$1"
  exit 1
}

if [ ! -d "$TREE" ] || ! git -C "$TREE" rev-parse --git-dir >/dev/null 2>&1; then
  fail "$TREE is not a git checkout"
fi

if gaia_is_linked_worktree "$TREE"; then
  refuse worktree "$TREE is a linked worktree, and a pull moves the default branch of the main checkout." \
    "Run /update-gaia from the main checkout, not from a worktree."
fi

if default_ref="$(git -C "$TREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$default_ref" ]; then
  default_branch="${default_ref#origin/}"
elif git -C "$TREE" show-ref --verify --quiet refs/remotes/origin/main; then
  default_branch="main"
elif git -C "$TREE" show-ref --verify --quiet refs/remotes/origin/master; then
  default_branch="master"
else
  default_branch="main"
fi

current_branch="$(git -C "$TREE" symbolic-ref --quiet --short HEAD 2>/dev/null)" || current_branch=""
if [ "$current_branch" != "$default_branch" ]; then
  refuse not-default-branch "the main checkout is on ${current_branch:-a detached HEAD}, not $default_branch." \
    "Switch the main checkout to $default_branch yourself, then run /update-gaia again."
fi

tracked_changes="$(git -C "$TREE" status --porcelain --untracked-files=no 2>/dev/null)"
if [ -n "$tracked_changes" ]; then
  refuse uncommitted-changes "tracked files in $TREE have uncommitted changes." \
    "Commit or discard those changes yourself, then run /update-gaia again."
fi

if [ "$SUBCOMMAND" = check ]; then
  printf 'PULL_READY %s\n' "$default_branch"
  exit 0
fi

read_version() {
  local version=""
  [ -f "$TREE/.gaia/VERSION" ] && version="$(tr -d '[:space:]' <"$TREE/.gaia/VERSION")"
  printf '%s' "${version:-unknown}"
}

old_head="$(git -C "$TREE" rev-parse HEAD 2>/dev/null)" || fail "cannot read HEAD"
old_version="$(read_version)"

if ! fetch_output="$(git -C "$TREE" fetch origin "$default_branch" 2>&1)"; then
  fail "git fetch origin $default_branch failed: $(printf '%s' "$fetch_output" | head -n 1)"
fi
target="$(git -C "$TREE" rev-parse FETCH_HEAD 2>/dev/null)" || fail "cannot read the fetched $default_branch"

if ! git -C "$TREE" merge-base --is-ancestor "$old_head" "$target" 2>/dev/null; then
  if git -C "$TREE" merge-base --is-ancestor "$target" "$old_head" 2>/dev/null; then
    target="$old_head"
  else
    refuse diverged "$default_branch has commits origin/$default_branch lacks, and origin has commits it lacks." \
      "Reconcile $default_branch with origin/$default_branch yourself, then run /update-gaia again."
  fi
fi

if [ "$target" != "$old_head" ]; then
  if ! merge_output="$(git -C "$TREE" merge --ff-only "$target" 2>&1)"; then
    fail "git merge --ff-only failed: $(printf '%s' "$merge_output" | head -n 1)"
  fi
fi

new_head="$(git -C "$TREE" rev-parse HEAD 2>/dev/null)" || fail "cannot read HEAD after the merge"
old_lockfile="$(git -C "$TREE" rev-parse "$old_head:pnpm-lock.yaml" 2>/dev/null)" || old_lockfile=""
new_lockfile="$(git -C "$TREE" rev-parse "$new_head:pnpm-lock.yaml" 2>/dev/null)" || new_lockfile=""

printf 'PULLED %s %s\n' "$old_version" "$(read_version)"
if [ "$old_lockfile" != "$new_lockfile" ]; then
  printf 'LOCKFILE_CHANGED yes\n'
else
  printf 'LOCKFILE_CHANGED no\n'
fi
exit 0
