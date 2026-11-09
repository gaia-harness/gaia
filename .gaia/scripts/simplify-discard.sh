#!/usr/bin/env bash
# simplify-discard.sh: save a plan run's simplify edits as a patch, prove the
# patch restores them, then restore the working tree to HEAD.
#
# Usage:
#   simplify-discard.sh --root <tree> --patch <file>
#
# The caller checked the tree was clean before the pass ran, so everything
# uncommitted here is the pass's own work. The patch uses --binary and is taken
# from a throwaway index holding every tracked and untracked change. The saved
# file is then applied to a second throwaway index on HEAD, and the two trees
# must match, so a truncated, unwritable or lossy patch refuses the reset. The
# real index and working tree stay untouched until that proof passes.
#
# Limit: gitignored files are neither saved nor removed.
#
# Exit 0: patch saved and proven, tree restored. Exit 1: a refusal reset nothing,
# or the reset itself failed and the patch holds the edits; the reason is on
# stderr. Exit 2: usage.

set -u

refuse() {
  printf 'simplify-discard: %s; nothing was reset\n' "$1" >&2
  exit 1
}

root=""
patch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 || break ;;
    --patch) patch="${2:-}"; shift 2 || break ;;
    *) printf 'simplify-discard: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$root" ] || [ -z "$patch" ]; then
  printf 'usage: simplify-discard.sh --root <tree> --patch <file>\n' >&2
  exit 2
fi

git -C "$root" rev-parse --verify --quiet HEAD >/dev/null || refuse "$root has no HEAD"

work="$(mktemp -d)" || refuse 'no temporary directory'
trap 'rm -rf "$work"' EXIT

# GIT_INDEX_FILE is absolute, so both throwaway indexes stay out of the tree.
saved_index="$work/saved.index"
GIT_INDEX_FILE="$saved_index" git -C "$root" read-tree HEAD || refuse 'could not read HEAD into a throwaway index'
GIT_INDEX_FILE="$saved_index" git -C "$root" add -A || refuse 'could not stage the edits in a throwaway index'
saved_tree="$(GIT_INDEX_FILE="$saved_index" git -C "$root" write-tree)" || refuse 'could not write the edited tree'

mkdir -p "$(dirname "$patch")" || refuse "could not create the folder for $patch"
GIT_INDEX_FILE="$saved_index" git -C "$root" diff --cached --binary HEAD >"$patch" || refuse "could not save $patch"
[ -s "$patch" ] || refuse "$patch is empty"

proof_index="$work/proof.index"
GIT_INDEX_FILE="$proof_index" git -C "$root" read-tree HEAD || refuse 'could not read HEAD into the proof index'
GIT_INDEX_FILE="$proof_index" git -C "$root" apply --cached --binary "$patch" || refuse "$patch does not apply to HEAD"
proof_tree="$(GIT_INDEX_FILE="$proof_index" git -C "$root" write-tree)" || refuse 'could not write the proof tree'
[ "$proof_tree" = "$saved_tree" ] || refuse "$patch does not restore the edits"

git -C "$root" add -A || refuse 'could not stage the edits'
if ! git -C "$root" reset --hard; then
  printf 'simplify-discard: the reset failed; the edits are saved in %s\n' "$patch" >&2
  exit 1
fi
