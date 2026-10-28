#!/usr/bin/env bash
# Shared helpers for the RED-observation ledger, sourced by the capture
# hook (.claude/hooks/capture-red-observations.sh), the commit check
# (.claude/hooks/red-verify-commit-check.sh) and the worthiness presence check
# (.claude/hooks/worthiness-presence-check.sh). Keeping the path, the
# repo-relative normalization, and the signal invocation in one place keeps
# them in sync by construction.
#
# Usage (from a hook script, at any working directory):
#   _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
#   [ -n "$_library_directory" ] && [ -f "$_library_directory/red-ledger.sh" ] && . "$_library_directory/red-ledger.sh"
#   ledger=$(red_ledger_path "$tree_root")
#   relative_path=$(red_ledger_repo_relative_path "$some_path")
#   red_ledger_signals "$relative_path"          # NDJSON on stdout; helper's exit code
#
# No persistent `cd`; all paths are repo-relative or resolved via `git -C`.
# Guarded so double-sourcing is a no-op.

[ -n "${RED_LEDGER_LIBRARY_SOURCED:-}" ] && return 0
RED_LEDGER_LIBRARY_SOURCED=1

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

# Repo-relative path to the Node signal helper.
red_ledger_signal_script() {
  printf '%s\n' '.gaia/scripts/red-ledger/extract-test-signals.mjs'
}

# Normalize an absolute-or-relative path to a repo-relative POSIX path.
# Strips a leading repo-root prefix and any leading `./`. Idempotent: an
# already-repo-relative path returns unchanged. pwd is the repo root, so a
# bare relative path is already repo-relative.
red_ledger_repo_relative_path() {
  local path="$1"
  local root

  # Resolve the repo root; fall back to pwd when not inside a work tree.
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  [ -n "$root" ] || root="$PWD"

  # Strip a leading repo-root prefix (with or without trailing slash).
  case "$path" in
    "$root"/*) path="${path#"$root"/}" ;;
    "$root") path="" ;;
  esac

  # Strip any leading `./` segments.
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done

  printf '%s\n' "$path"
}

# Run the Node signal helper for a repo-relative test path and echo its NDJSON
# output. Propagates the helper's exit code so the caller can apply its own
# fail-open / fail-closed policy. Exits 0 with no output (and a stderr note) if
# Node is unavailable, treating that as "cannot recompute signal".
red_ledger_signals() {
  local relative_path="$1"
  local script
  script=$(red_ledger_signal_script)

  if ! command -v node >/dev/null 2>&1; then
    echo "red-ledger: node not found; cannot compute signals" >&2
    return 0
  fi
  [ -f "$script" ] || {
    echo "red-ledger: signal helper missing at $script" >&2
    return 0
  }

  node "$script" "$relative_path"
}

# Exit 7 is the extractor refusing a story shape it cannot resolve.
# shellcheck disable=SC2034 # read by the hooks that source this library
RED_LEDGER_UNRESOLVABLE_SHAPE_STATUS=7

# Exit 8 is the extractor refusing an old-format story file. Its stderr line
# already names the migration command, so callers carry it verbatim and never
# re-spell it.
RED_LEDGER_OLD_FORMAT_STATUS=8

# Deny text for an extractor refusal (exit 7: a story shape it cannot resolve;
# exit 8: an old-format story file), carrying the extractor's own stderr line.
red_ledger_refusal_reason() {
  local status="$1" relative_path="$2" extractor_line="$3"
  if [ "$status" -eq "$RED_LEDGER_OLD_FORMAT_STATUS" ]; then
    printf 'Worthiness presence gate: %s is an old-format story file, so its tests cannot be checked for a worthiness verdict.\n\n%s\n\nNext step: run .gaia/cli/gaia migrate-csf4, then retry gh pr merge.' \
      "$relative_path" "${extractor_line:-extract-test-signals: ${relative_path} is an old-format story file; migrate it with: .gaia/cli/gaia migrate-csf4}"
    return 0
  fi
  printf 'Worthiness presence gate: the test-identity extractor cannot read %s, so its tests cannot be checked for a worthiness verdict.\n\n%s\n\nNext step: rewrite the story in a supported shape (see wiki Stories as Tests), then retry gh pr merge.' \
    "$relative_path" "${extractor_line:-extract-test-signals: unsupported story shape in ${relative_path}}"
}

# red_ledger_signals for a caller that never blocks: on exit 8 it prints the
# extractor's line to stderr as a warning and emits no signals. Always returns 0.
red_ledger_signals_or_warn() {
  local relative_path="$1" error_file status=0 output
  error_file=$(mktemp "${TMPDIR:-/tmp}/red-ledger-signals-XXXXXX") || error_file=/dev/null
  output=$(red_ledger_signals "$relative_path" 2>"$error_file") || status=$?
  if [ "$status" -eq "$RED_LEDGER_OLD_FORMAT_STATUS" ]; then
    printf 'warning: %s\n' "$(head -n 1 "$error_file" 2>/dev/null)" >&2
    output=''
  fi
  [ "$error_file" = /dev/null ] || rm -f "$error_file"
  [ -z "$output" ] || printf '%s\n' "$output"
  return 0
}
