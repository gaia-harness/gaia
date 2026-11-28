#!/usr/bin/env bash
# shellcheck shell=bash
#
# state-cleanup.sh: the post-merge verb that removes a merged branch's own
# local state (audit, run and PR-cache entries under .gaia/local) in the same
# pass as the worktree and branch removal. Run it by any path that resolves:
#   bash .gaia/scripts/state-cleanup.sh --branch <branch-name>
#
# The main checkout is resolved from this script's own location, never from
# the working directory, so a cleanup run from inside a linked worktree (or
# from anywhere else) prunes the one real .gaia/local.
#
# The verb is registry-driven. For every branch-spent row outside protected/,
# it maps the branch through that row's key function and hands the key to
# gaia_reaper_reap_key, which owns entry-key parsing, the live-key and nesting
# checks and the symlink-safe removal. It parses no entry key itself and
# applies no age check, because the branch has just merged. protected/ is the
# backstop reaper's alone: Claude never deletes there. It then drops the
# branch's entries from the shared stash stack (stash-reap-lib.sh).
#
# Fail closed. The verb refuses, and removes nothing, when the name cannot
# key a state entry, when the branch still has a local ref or is checked out
# in a listed worktree, or when the ref or worktree read fails (an unread
# live set would otherwise make every key look gone). A refused or stopped
# cleanup is not an error: the backstop reaper removes the state once spent.
#
# Output: one `removed <path>` line per removal, one `dropped <hash> <branch>`
# line per dropped stash entry, one `refused` or `skipped`
# line per refusal, and a `kept state` line when the whole call is refused.
# Always exits 0: cleanup trails a merge that already landed.

script_directory="${BASH_SOURCE[0]%/*}"
[ "$script_directory" = "${BASH_SOURCE[0]}" ] && script_directory="."
script_directory="$(cd "$script_directory" && pwd -P)" || exit 0

# shellcheck source=/dev/null
. "$script_directory/state-reaper-classes.sh"
# shellcheck source=/dev/null
. "$script_directory/stash-reap-lib.sh"

branch_name=""
branch_given=0
if [ "${1-}" = "--branch" ] && [ "$#" -eq 2 ]; then
  branch_name="$2"
  branch_given=1
fi
if [ "$branch_given" -eq 0 ]; then
  printf 'usage: state-cleanup.sh --branch <branch-name>\n' >&2
  exit 0
fi

keep_state() {
  printf 'state-cleanup: kept state for %s: %s; the backstop reaper removes it once spent\n' "$branch_name" "$1"
  exit 0
}

[ -n "$branch_name" ] || keep_state "no branch name was given"
case "$branch_name" in
  worktree-*) keep_state "a worktree- name is a session directory, not a branch" ;;
esac
normalized_name="$(gaia_branch_normalize "$branch_name")"
_gaia_loop_keyable "$normalized_name" || keep_state "the name cannot key a state entry"

main_root="$(gaia_resolve_main_root "$script_directory" 2>/dev/null)" || keep_state "the main checkout cannot be resolved"
[ -n "$main_root" ] || keep_state "the main checkout cannot be resolved"
gaia_reaper_load_registry "$main_root/.gaia/state-registry.json" || keep_state "the state registry cannot be read"

gaia_reaper_snapshot "$main_root"
if [ -z "${GAIA_REAPER_BRANCHES_OK-}" ] || [ -z "${GAIA_REAPER_TREES_OK-}" ]; then
  keep_state "the branch refs or the worktree list cannot be read"
fi
case "
$GAIA_REAPER_LIVE_BRANCHES
" in
  *"
$branch_name
"*) keep_state "the branch still exists locally or is checked out in a worktree" ;;
esac

slug_key=""
for row_json in "${GAIA_REAPER_ROW_JSONS[@]}"; do
  row_fields="$(jq -r '[.retention.class // "", .path // "", .retention.key // ""] | @tsv' <<<"$row_json" 2>/dev/null)" || continue
  IFS=$'\t' read -r row_class row_path row_key <<<"$row_fields"
  [ "$row_class" = branch-spent ] || continue
  case "$row_path" in protected/*) continue ;; esac
  if gaia_reaper_key_is_slug "$row_key"; then
    [ -n "$slug_key" ] || slug_key="$(gaia_key_slug "$branch_name")" || continue
    entry_key="$slug_key"
  else
    entry_key="$normalized_name"
  fi
  [ -n "$entry_key" ] || continue
  gaia_reaper_reap_key "$main_root" "$row_json" "$entry_key"
done
gaia_stash_reap "$main_root" "$GAIA_REAPER_LIVE_BRANCHES" "$branch_name"
exit 0
