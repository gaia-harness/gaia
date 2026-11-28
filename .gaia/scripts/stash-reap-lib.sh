# shellcheck shell=bash
#
# The stash reaper: drops stash entries whose branch is spent. Every linked
# worktree shares one stash stack, so an entry made on a branch that was later
# merged and deleted stays on the stack every tree lists, where a later session
# can take it for its own. Sourced by state-cleanup.sh (after a merge, that
# branch's entries) and state-reaper.sh (the SessionStart backstop, every spent
# branch's entries); defines functions and does no other work at source time.
#
# An entry is spent when the branch its subject names (stash_subject_branch in
# .claude/hooks/lib/main-git-guard-stash.sh) has no local ref and no worktree
# holds it, read from the caller's live-branch set (gaia_reaper_snapshot's
# GAIA_REAPER_LIVE_BRANCHES), unless a keep below applies.
# A branch counts as live under its own name or its normalized one
# (gaia_branch_normalize), so an entry made under a new worktree's
# `worktree-<name>` spelling survives the rename to its canonical branch. An
# entry is kept when its parent commit (the branch's tip when it was made) is
# reachable from a live local branch other than the default one and not from
# the default branch: a branch renamed and committed on since still holds it,
# while a parent the default branch reaches (the parent of every merged branch,
# or of a stash made before the branch's first commit) is shared with every
# sibling lane and would keep the entry forever. The
# default branch is origin's HEAD, else the main checkout's current branch.
# Outside a named-branch cleanup, the backstop also keeps an entry younger than
# _GAIA_STASH_REAP_GRACE_DAYS. An entry naming no branch is never dropped. The caller refuses to call
# this on a failed ref or worktree read: an unread live set would make every
# branch look gone.
#
# Each drop prints `dropped <hash> <branch>`. A dropped entry stays an
# unreachable commit until gc, so `git stash apply <hash>` recovers it.
#
# Entries are dropped by index, and a peer session can push or drop between the
# read and the drop and shift every index, so each drop re-reads the stack, finds
# the entry by hash, and checks the index still resolves to that hash first.

_gaia_stash_reap_directory="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)" || _gaia_stash_reap_directory=""
# A missing parser is reported per call by gaia_stash_reap, never by a failed
# source: state-reaper.sh ends its whole run on a library that fails to source.
if [ -n "$_gaia_stash_reap_directory" ]; then
  # shellcheck source=/dev/null
  . "$_gaia_stash_reap_directory/../../.claude/hooks/lib/main-git-guard-stash.sh" 2>/dev/null || true
fi

_GAIA_STASH_REAP_GRACE_DAYS=7

# _gaia_stash_branch_live <branch> <live-branches>: rc 0 when <branch> is live.
_gaia_stash_branch_live() {
  local branch="$1" live normalized="$1"
  declare -f gaia_branch_normalize >/dev/null 2>&1 && normalized="$(gaia_branch_normalize "$branch")"
  while IFS= read -r live; do
    [ -n "$live" ] || continue
    [ "$live" = "$branch" ] && return 0
    if declare -f gaia_branch_normalize >/dev/null 2>&1 && [ "$(gaia_branch_normalize "$live")" = "$normalized" ]; then
      return 0
    fi
  done <<<"$2"
  return 1
}

# _gaia_stash_branch_key <branch>: the branch's normalized spelling, else as is.
_gaia_stash_branch_key() {
  if declare -f gaia_branch_normalize >/dev/null 2>&1; then gaia_branch_normalize "$1"; else printf '%s\n' "$1"; fi
}

# _gaia_stash_parent_on_default <main-root> <parent> <default-branch>: rc 0 when
# <parent> is reachable from the default branch. Such a parent is a shared
# ancestor, held by every branch cut from it, so it says nothing about whether
# the entry's own branch lives on under another name.
_gaia_stash_parent_on_default() {
  [ -n "$3" ] || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" merge-base --is-ancestor "$2" "refs/heads/$3" 2>/dev/null
}

# _gaia_stash_list <main-root>: one `<index>\t<hash>\t<subject>\t<epoch>` line
# per entry.
_gaia_stash_list() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" rev-parse -q --verify refs/stash >/dev/null 2>&1 || return 0
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$1" log -g --format='%gd%x09%H%x09%s%x09%ct' refs/stash
}

# gaia_stash_reap <main-root> <live-branches> [<branch>]: drop every spent
# entry, or with <branch> only that branch's entries, when that branch is
# spent. rc 0 always; a failed read or drop prints a `skipped <reason>` line and
# drops nothing more.
gaia_stash_reap() {
  local main_root="$1" live_branches="$2" only_branch="${3-}" listing line index hash subject branch
  local targets="" target found epoch now parent default_branch holders
  declare -f stash_subject_branch >/dev/null 2>&1 || {
    printf 'skipped stash: the stash subject parser did not load\n'
    return 0
  }
  listing="$(_gaia_stash_list "$main_root")" || {
    printf 'skipped stash: the stash stack cannot be read\n'
    return 0
  }
  default_branch="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || default_branch=""
  default_branch="${default_branch#origin/}"
  [ -n "$default_branch" ] || default_branch="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" symbolic-ref -q --short HEAD 2>/dev/null)" || default_branch=""
  now="$(date +%s)"
  while IFS=$'\t' read -r index hash subject epoch; do
    [ -n "$hash" ] || continue
    branch="$(stash_subject_branch "$subject")" || continue
    [ -z "$only_branch" ] || [ "$(_gaia_stash_branch_key "$branch")" = "$(_gaia_stash_branch_key "$only_branch")" ] || continue
    _gaia_stash_branch_live "$branch" "$live_branches" && continue
    parent="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" rev-parse -q --verify "$hash^1" 2>/dev/null)" || parent=""
    if [ -n "$parent" ] && ! _gaia_stash_parent_on_default "$main_root" "$parent" "$default_branch"; then
      holders="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" for-each-ref --contains "$parent" --format='%(refname:lstrip=2)' refs/heads/ 2>/dev/null)" || {
        printf 'skipped stash: the branch tips cannot be read\n'
        return 0
      }
      holders="$(printf '%s\n' "$holders" | grep -vxF -e "$default_branch" -e '')" || holders=""
      [ -z "$holders" ] || continue
    fi
    if [ -z "$only_branch" ]; then
      case "$epoch" in '' | *[!0-9]*) continue ;; esac
      [ $((now - epoch)) -ge $((_GAIA_STASH_REAP_GRACE_DAYS * 86400)) ] || continue
    fi
    targets="$targets$hash $branch
"
  done <<<"$listing"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    hash="${target%% *}"
    branch="${target#* }"
    listing="$(_gaia_stash_list "$main_root")" || {
      printf 'skipped stash: the stash stack cannot be read\n'
      return 0
    }
    found=""
    while IFS=$'\t' read -r index line subject epoch; do
      [ "$line" = "$hash" ] && { found="$index"; break; }
    done <<<"$listing"
    [ -n "$found" ] || continue
    if [ "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" rev-parse -q --verify "$found" 2>/dev/null)" != "$hash" ] \
       || ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$main_root" stash drop -q "$found" >/dev/null 2>&1; then
      printf 'skipped stash: could not drop %s (%s)\n' "$hash" "$branch"
      return 0
    fi
    printf 'dropped %s %s\n' "$hash" "$branch"
  done <<<"$targets"
  return 0
}
