#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-branch-state.sh: classify an existing update branch by its own
# state, and add a worktree for one no worktree holds.
#
#   bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <tag> --latest <version> [--branch <name>] [--build <dev.sha>]
#   bash .gaia/scripts/update-gaia-branch-state.sh add-worktree --branch <name>
#
# classify prints exactly one line and exits 0:
#   NONE                                   no local update/<tag>-* branch (or --branch names none)
#   RESUME_IN_WORKTREE <branch> <path>     a worktree holds it, the update not yet recorded
#   RESUME_ADD_WORKTREE <branch>           no worktree holds it, the update not yet recorded
#   APPLIED_UNCOMMITTED <branch> <path>    the holder's working tree records the update, HEAD does not
#   COMMITTED <branch> <path or ->         the branch HEAD already records the update
#
# "Recorded" means .gaia/VERSION equals --latest and the build record agrees:
# with --build (a local run) .gaia/VERSION-dev holds that build id, written
# last; without it (a release run) .gaia/VERSION-dev is absent, removed last. A
# local sync can keep the same .gaia/VERSION, so the version alone cannot tell
# an untouched branch from a finished one. A project that never had
# .gaia/VERSION-dev classifies on the version alone.
#
# Without --branch, a release --tag skips local-sync branches
# (update/<tag>-dev.<sha>-*), which the release tag's glob would also match.
#
# add-worktree prints `ADDED <absolute path>` and exits 0, or exits 1 with a
# one-line reason when the target path exists or a worktree already holds the
# branch.
#
# Exit 2 for both: a usage error, or a working directory outside a git
# repository.
#
# The main checkout's own .gaia/VERSION is never read: once an update runs in
# its own worktree, the bump and the merge live on the update branch, so the
# main checkout's version says nothing about the update's progress.
#
# It is a literal-path script because the classification also runs from inside
# an update worktree, where the runtime refuses captured substitutions in a
# command's text; and adding the worktree here keeps `git worktree add` out of
# any instruction fence.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$script_directory/main-root-lib.sh"
# shellcheck source=/dev/null
. "$script_directory/update-gaia-local-lib.sh"

usage() {
  echo "usage: update-gaia-branch-state.sh classify --tag <tag> --latest <version> [--branch <name>] [--build <dev.sha>]" >&2
  echo "       update-gaia-branch-state.sh add-worktree --branch <name>" >&2
  exit 2
}

# The path of the worktree whose checked-out branch is $1, or nothing. Reads
# the porcelain list, so a path containing spaces survives.
holder_of_branch() {
  local wanted_ref="refs/heads/$1" line current_path=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) current_path="${line#worktree }" ;;
      "branch $wanted_ref")
        printf '%s\n' "$current_path"
        return 0
        ;;
      '') current_path='' ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 0
}

# A version file's content with all whitespace removed; empty when unreadable.
trimmed_file() {
  # The stderr redirect comes first so a missing file's open error is silenced too.
  tr -d '[:space:]' 2>/dev/null < "$1"
}

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

# The newest local update/<tag>-* branch. A release tag's glob also matches the
# local-sync branches of that version, so those are skipped; a dev tag's glob
# cannot match another build's branch.
newest_branch_for_tag() {
  local tag="$1" name
  if gaia_local_is_dev_tag "$tag"; then
    git for-each-ref --count=1 --sort=-committerdate --format='%(refname:short)' "refs/heads/update/${tag}-*"
    return 0
  fi
  while IFS= read -r name; do
    case "$name" in
      "update/${tag}-dev."*) ;;
      *)
        printf '%s\n' "$name"
        return 0
        ;;
    esac
  done < <(git for-each-ref --sort=-committerdate --format='%(refname:short)' "refs/heads/update/${tag}-*")
  return 0
}

# Succeeds when the trimmed .gaia/VERSION-dev content `$1` (empty when the file
# is absent) is the record a run for build `$2` leaves: the build id on a local
# run, nothing on a release run.
build_record_matches() {
  if [ -n "$2" ]; then
    [ "$1" = "$2" ]
  else
    [ -z "$1" ]
  fi
}

classify() {
  local tag='' latest='' branch='' build='' have_tag=0 have_latest=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag) [ "$#" -ge 2 ] || usage; tag="$2"; have_tag=1; shift 2 ;;
      --latest) [ "$#" -ge 2 ] || usage; latest="$2"; have_latest=1; shift 2 ;;
      --branch) [ "$#" -ge 2 ] || usage; branch="$2"; shift 2 ;;
      --build) [ "$#" -ge 2 ] || usage; build="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$have_tag" -eq 1 ] && [ "$have_latest" -eq 1 ] && [ -n "$tag" ] && [ -n "$latest" ] || usage
  if [ -n "$build" ]; then
    gaia_local_is_build_id "$build" || usage
  fi

  if [ -z "$branch" ]; then
    branch="$(newest_branch_for_tag "$tag")"
  elif ! branch_exists "$branch"; then
    branch=''
  fi
  if [ -z "$branch" ]; then
    echo "NONE"
    return 0
  fi

  local holder committed_version committed_build working_version working_build
  holder="$(holder_of_branch "$branch")"
  committed_version="$(git show "$branch:.gaia/VERSION" 2>/dev/null | tr -d '[:space:]')"
  committed_build="$(git show "$branch:.gaia/VERSION-dev" 2>/dev/null | tr -d '[:space:]')"

  if [ "$committed_version" = "$latest" ] && build_record_matches "$committed_build" "$build"; then
    echo "COMMITTED $branch ${holder:--}"
    return 0
  fi
  if [ -z "$holder" ]; then
    echo "RESUME_ADD_WORKTREE $branch"
    return 0
  fi
  working_version="$(trimmed_file "$holder/.gaia/VERSION")"
  working_build="$(trimmed_file "$holder/.gaia/VERSION-dev")"
  if [ "$working_version" = "$latest" ] && build_record_matches "$working_build" "$build"; then
    echo "APPLIED_UNCOMMITTED $branch $holder"
  else
    echo "RESUME_IN_WORKTREE $branch $holder"
  fi
  return 0
}

add_worktree() {
  local branch=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) [ "$#" -ge 2 ] || usage; branch="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$branch" ] || usage

  if ! branch_exists "$branch"; then
    echo "add-worktree: no local branch $branch" >&2
    return 1
  fi
  local holder
  holder="$(holder_of_branch "$branch")"
  if [ -n "$holder" ]; then
    echo "add-worktree: $branch is already held by the worktree at $holder"
    return 1
  fi

  local main_root
  main_root="$(gaia_resolve_main_root)" || {
    echo "add-worktree: cannot resolve the main checkout root" >&2
    return 1
  }
  local target="$main_root/.claude/worktrees/${branch//\//+}"
  if [ -e "$target" ]; then
    echo "add-worktree: $target already exists"
    return 1
  fi
  if ! git worktree add "$target" "$branch" >/dev/null 2>&1; then
    echo "add-worktree: git worktree add failed for $target"
    return 1
  fi
  echo "ADDED $target"
  return 0
}

[ "$#" -ge 1 ] || usage
subcommand="$1"
shift
case "$subcommand" in
  classify | add-worktree) ;;
  *) usage ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "update-gaia-branch-state.sh: not inside a git repository" >&2
  exit 2
fi

case "$subcommand" in
  classify) classify "$@" ;;
  add-worktree) add_worktree "$@" ;;
esac
