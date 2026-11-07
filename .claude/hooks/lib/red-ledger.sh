#!/usr/bin/env bash
# Shared helper for the RED-observation ledger path, sourced by the capture
# hook (.claude/hooks/capture-red-observations.sh) and the commit check
# (.claude/hooks/red-verify-commit-check.sh). The signal helpers those hooks
# also use live in test-signals.sh, sourced below so a caller sourcing this
# file gets both.
#
# Usage (from a hook script, at any working directory):
#   _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
#   [ -n "$_library_directory" ] && [ -f "$_library_directory/red-ledger.sh" ] && . "$_library_directory/red-ledger.sh"
#   ledger=$(red_ledger_path "$tree_root")
#
# No persistent `cd`; all paths are repo-relative or resolved via `git -C`.
# Guarded so double-sourcing is a no-op.

[ -n "${RED_LEDGER_LIBRARY_SOURCED:-}" ] && return 0
RED_LEDGER_LIBRARY_SOURCED=1

_red_ledger_self_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _red_ledger_self_directory=''
# shellcheck disable=SC1091
[ -n "$_red_ledger_self_directory" ] && [ -f "$_red_ledger_self_directory/test-signals.sh" ] && . "$_red_ledger_self_directory/test-signals.sh"
unset _red_ledger_self_directory

# Absolute path to the append-only JSON Lines ledger, rooted at ROOT (the
# per-tree root a caller has already resolved, typically via Pattern T's
# payload-anchored gaia_resolve_tree_root) and keyed to that same ROOT's own
# gaia_tree_key, so the ledger lands under a tree-keyed subpath even once a
# worktree's whole .gaia/local becomes one symlink to main's. Defaults to
# gaia_resolve_tree_root of the process cwd when no ROOT is supplied. The key
# is always derived from ROOT itself, never from the process cwd, so a
# caller's own root resolution and this function's key agree. The resolver
# is sourced here, deferred into this function's own body (never at source
# time) and on EVERY path -- the no-root branch needs it for
# gaia_resolve_tree_root, the explicit-root branch needs it for
# gaia_tree_key -- so this lib's "no side effects at source time" contract
# holds, matching state-registry-lib.sh's own gaia_registry_path.
red_ledger_path() {
  local root="${1:-}"
  local self_directory
  self_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  # shellcheck disable=SC1091
  source "$self_directory/../../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || return 1
  if [ -z "$root" ]; then
    root="$(gaia_resolve_tree_root 2>/dev/null)" || return 1
  fi
  [ -n "$root" ] || return 1
  local key
  key="$(gaia_tree_key "$root" 2>/dev/null)" || return 1
  printf '%s\n' "$root/.gaia/local/red-ledger/$key/observations.jsonl"
}
