#!/usr/bin/env bash
# shellcheck shell=bash
#
# The linked worktree an existing local branch runs in. Sourced; defines
# functions and does no other work at source time.
#
# gaia_branch_worktree_holder <branch> [directory]
#   The path of the working tree, the main checkout included, that has local
#   branch `branch` checked out, as `git worktree list --porcelain` names it;
#   prints nothing when no tree holds it or the list cannot be read. Returns 0.
#
# gaia_add_branch_worktree <branch> [directory]
#   Adds a linked worktree for the EXISTING local branch `branch` (it creates
#   no branch) at <main checkout>/.claude/worktrees/<branch with each / as +>,
#   the spelling the harness's EnterWorktree gives its own trees. SUCCESS:
#   prints that path as one line; returns 0. FAILURE (no such branch, a tree
#   already holds it, the path exists, or the add fails): ONE reason line on
#   stderr; returns 1.
#
# `directory` (default: the process working directory) names the repository.

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/main-root-lib.sh"

# Reads the porcelain list line by line, so a path containing spaces survives.
gaia_branch_worktree_holder() {
  local wanted_reference="refs/heads/$1" directory="${2:-}" line current_path=''
  local -a git_command=(_gaia_git)
  [[ -n "$directory" ]] && git_command=(_gaia_git -C "$directory")
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) current_path="${line#worktree }" ;;
      "branch $wanted_reference")
        printf '%s\n' "$current_path"
        return 0
        ;;
      '') current_path='' ;;
    esac
  done < <("${git_command[@]}" worktree list --porcelain 2>/dev/null)
  return 0
}

gaia_add_branch_worktree() {
  local branch="$1" directory="${2:-}" holder main_root target
  local -a git_command=(_gaia_git)
  [[ -n "$directory" ]] && git_command=(_gaia_git -C "$directory")
  if ! "${git_command[@]}" show-ref --verify --quiet "refs/heads/$branch"; then
    printf 'no local branch %s\n' "$branch" >&2
    return 1
  fi
  holder="$(gaia_branch_worktree_holder "$branch" "$directory")"
  if [[ -n "$holder" ]]; then
    printf '%s is already held by the worktree at %s\n' "$branch" "$holder" >&2
    return 1
  fi
  main_root="$(gaia_resolve_main_root "$directory" 2>/dev/null)" || {
    printf 'cannot resolve the main checkout root\n' >&2
    return 1
  }
  target="$main_root/.claude/worktrees/${branch//\//+}"
  if [[ -e "$target" ]]; then
    printf '%s already exists\n' "$target" >&2
    return 1
  fi
  if ! "${git_command[@]}" worktree add "$target" "$branch" >/dev/null 2>&1; then
    printf 'git worktree add failed for %s\n' "$target" >&2
    return 1
  fi
  printf '%s\n' "$target"
  return 0
}
