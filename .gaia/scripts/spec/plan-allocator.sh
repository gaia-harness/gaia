#!/usr/bin/env bash
# plan-allocator.sh: Allocate PLAN-NNN ids for spec-less one-off plans, one
# catalog row per plan. Local-only: no remote tag reservation, no network.
# Plans are gitignored and ephemeral, so the notebook catalog (plus the plan
# folders on disk) is the collision authority. Next id is max+1 over the union
# of catalog plan rows and plan folders on disk. A reaped plan keeps its row,
# so its number is never reused.
#
# Usage:
#   plan-allocator.sh next <repo_root> [<subject>]  # print next PLAN-NNN, register its row
#
# The row is written through the notebook library with status "ready", a
# created_at, a status_changed_at, source "allocated" and the normalized
# subject; every later transition goes through the guarded ledger-update.sh
# chokepoint.
#
# Concurrency: numbering and the row write run under the library's plan mint
# lock, which a spec allocation never holds, so a plan allocation never queues
# behind one. A lock-acquisition timeout maps to exit 4.
#
# Exit: 0 printed an id; 2 usage; 3 the one-time notebook move is pending (the
# move command is on stderr, nothing is minted); 4 the main checkout or the
# lock could not be resolved, or the catalog write failed.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: plan-allocator.sh next <repo_root> [<subject>]" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
subject_argument="${3:-}"

# The libraries are sourced from this script's own directory so they resolve
# identically from the real repo and from test copies. repo_root is the value
# whose trustworthiness is in question, so loading a library through it would
# decide correctness with the input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_library_directory}/title-normalize.sh"
# shellcheck source=SCRIPTDIR/../notebook/notebook-lib.sh
. "${_library_directory}/../notebook/notebook-lib.sh"

# repo_root names the tree this allocation runs in; the catalog it feeds is
# main's. From a linked worktree the operand is that worktree's own root, and
# the library resolves main from it rather than forking a catalog per tree.
export GAIA_NOTEBOOK_TREE="$repo_root"

case "$mode" in
  next) ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

readiness_status=0
gaia_notebook_require_ready || readiness_status=$?
if [ "$readiness_status" -eq 3 ]; then
  exit 3
elif [ "$readiness_status" -ne 0 ]; then
  echo "plan-allocator: cannot resolve the main checkout for '$repo_root'; refuse to allocate (would risk duplicate PLAN ids across worktrees)" >&2
  exit 4
fi

# One bare integer per known PLAN number, one per line, unsorted: the catalog
# rows and the plan folders on disk.
known_plan_numbers() {
  gaia_notebook_rows plan | jq -r '.[].id // empty' | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p'
  gaia_notebook_folders plan | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p'
}

highest_number() {
  local maximum_number=0 known_number numbers
  numbers="$(known_plan_numbers)" || return $?
  while IFS= read -r known_number; do
    [ -z "$known_number" ] && continue
    known_number=$((10#$known_number))
    [ "$known_number" -gt "$maximum_number" ] && maximum_number="$known_number"
  done < <(printf '%s\n' "$numbers" | sort -un)
  echo "$maximum_number"
}

# The critical section run under the mint lock: compute the next id,
# normalize the subject, register the row, print the id. Returns (not exits)
# so the lock releases on failure.
allocate_next() {
  local requested_subject="${1:-}"
  local highest_known next_number new_id subject
  highest_known="$(highest_number)" || return $?
  next_number=$((highest_known + 1))
  new_id="$(printf 'PLAN-%03d' "$next_number")"
  subject="$(gaia_normalize_title "$requested_subject")"
  [ -z "$subject" ] && subject="$new_id"
  gaia_notebook_register plan "$new_id" ready "$subject" "" '{"source":"allocated"}' || return $?
  printf '%s\n' "$new_id"
}

exit_status=0
gaia_notebook_with_mint_lock plan allocate_next "$subject_argument" || exit_status=$?
if [ "$exit_status" -ne 0 ]; then
  if [ "$exit_status" -eq 75 ]; then
    echo "plan-allocator: could not acquire the plan mint lock; refuse to allocate (would risk duplicate PLAN ids)" >&2
    exit 4
  fi
  exit "$exit_status"
fi
