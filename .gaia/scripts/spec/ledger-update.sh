#!/usr/bin/env bash
# ledger-update.sh: Merge a JSON object into the notebook row matching an id.
# Existing fields are overwritten; absent fields are preserved. The one
# status-transition chokepoint for specs and plans: a SPEC-NNN id patches that
# spec's row, a PLAN-NNN id patches that plan's row. It is a thin wrapper over
# gaia_notebook_update in the notebook library; it opens no file itself, and
# the library owns the catalog location, the write lock and the atomic write.
#
# Usage:
#   ledger-update.sh <repo_root> <SPEC-NNN|PLAN-NNN> '<json-object>'
#
# Refuses if the row is missing, callers must allocate via spec-allocator.sh or
# plan-allocator.sh first. A plan's initial status:"ready" is written at row
# creation by plan-allocator.sh (NOT via this chokepoint); every later
# transition goes through here.
#
# repo_root names the tree this write runs in. It is exported as
# GAIA_NOTEBOOK_TREE, so the library resolves the main checkout from it: from a
# linked worktree the update lands in main's catalog, never a forked copy.
#
# Readiness is checked right after the arguments are validated and before
# anything else: while the one-time move is pending the script exits 3 and the
# library's stderr line names the move command.
#
# Canonical status vocabulary (ledger-lib.sh): spec draft|ready|merged|abandoned,
# plan ready|merged|abandoned. A plan's `abandoned` is accepted but no shipped
# code path stamps it. The row's `status` field is distinct in meaning from the
# `source` field (provenance, not lifecycle); this chokepoint never touches
# `source`.
#
# Exit codes: 0 ok, 2 usage (including an id matching neither prefix, once
# ledger-lib.sh has loaded), 3 the notebook library is not ready (the one-time
# move is pending), 4 row missing OR corrupt catalog OR main checkout
# unresolvable OR lock-acquisition timeout OR the notebook library or
# ledger-lib.sh unusable (could not safely apply the write; fails closed for
# both kinds), 5 invalid patch JSON, 6 status not canonical for that kind.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: ledger-update.sh <repo_root> <SPEC-NNN|PLAN-NNN> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
ledger_id="$2"
patch="$3"

_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each load is bracketed against a target that is present but UNPARSEABLE, and
# the probe under it decides the degrade. A bare `.` under errexit abandons the
# shell AT the load, exit 2 with no diagnostic, so none of the refusals written
# below would run; and a trailing `|| true` does not save it on stock macOS
# /bin/bash 3.2.57, which aborts before the arm is ever evaluated. An
# interrupted update, an unresolved merge conflict, and a truncated write all
# leave exactly that state on disk.
# shellcheck source=/dev/null
set +e; [ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null; set -e
type gaia_ledger_kind_for_id >/dev/null 2>&1 || {
  echo "ledger-update: the shared ledger library is unusable; refuse to write (cannot tell which kind the id belongs to)" >&2
  exit 4
}
# The tree selector must be set before the library resolves anything.
export GAIA_NOTEBOOK_TREE="$repo_root"
# shellcheck source=/dev/null
set +e; [ -f "${_library_directory}/../notebook/notebook-lib.sh" ] && . "${_library_directory}/../notebook/notebook-lib.sh" 2>/dev/null; set -e
for _required_function in gaia_notebook_update gaia_notebook_require_ready with_ledger_lock; do
  type "$_required_function" >/dev/null 2>&1 || {
    echo "ledger-update: the notebook library is unusable; refuse to write (an unserialized write can tear the catalog)" >&2
    exit 4
  }
done

if ! ledger_kind="$(gaia_ledger_kind_for_id "$ledger_id")"; then
  echo "ledger-update: '$ledger_id' is neither a SPEC-NNN nor a PLAN-NNN id" >&2
  exit 2
fi

ready_status=0
gaia_notebook_require_ready || ready_status=$?
case "$ready_status" in
  0) ;;
  3) exit 3 ;;
  *)
    echo "ledger-update: cannot resolve the main checkout for '$repo_root'; refuse to write (would fork the catalog across worktrees)" >&2
    exit 4
    ;;
esac

# Canonical status vocabulary guard (wiki/concepts/GAIA Spec.md, "Ledger status
# vocabulary"). This is the single chokepoint for status writes, so rejecting
# an off-vocabulary status here keeps every tool path (allocator finalize,
# spec-reconcile, plan-reconcile) from persisting a stray label. A patch that
# does not set status (e.g. a merged_at-only stamp) passes untouched.
if ! jq -e 'type == "object"' <<<"$patch" >/dev/null 2>&1; then
  echo "ledger-update: invalid patch JSON (the patch must be a JSON object)" >&2
  exit 5
fi
patch_status="$(jq -r 'if has("status") then (.status | tostring) else empty end' <<<"$patch" 2>/dev/null || true)"
if [ -n "$patch_status" ] && ! gaia_ledger_status_allowed "$ledger_kind" "$patch_status"; then
  case "$ledger_kind" in
    spec) allowed_statuses="draft, ready, merged, abandoned" ;;
    *) allowed_statuses="ready, merged, abandoned" ;;
  esac
  echo "ledger-update: non-canonical status '$patch_status' (allowed: $allowed_statuses)" >&2
  exit 6
fi

update_status=0
gaia_notebook_update "$ledger_kind" "$ledger_id" "$patch" || update_status=$?
case "$update_status" in
  0) exit 0 ;;
  6)
    echo "ledger-update: $ledger_kind $ledger_id not in the catalog" >&2
    exit 4
    ;;
  75)
    echo "ledger-update: could not acquire the catalog lock; patch not applied" >&2
    exit 4
    ;;
  2) exit 2 ;;
  3) exit 3 ;;
  *)
    echo "ledger-update: the catalog write was refused (library exit $update_status); patch not applied" >&2
    exit 4
    ;;
esac
