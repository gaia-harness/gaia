#!/usr/bin/env bash
# plan-archive-merged.sh: delete a merged spec-less PLAN-NNN folder once the
# usage ledger records its run. The plans-side mirror of
# spec-archive-merged.sh, run by the pre-flight sweep of /gaia-spec and
# /gaia-plan (.claude/skills/gaia/references/spec/lifecycle.md).
#
# Why this exists: the orchestrator's post-merge close reduces a plan folder to
# SUMMARY.md, but a PR can merge out-of-band (the github.com
# button, another session), or the orchestrator can end before its close, so
# the PLAN-NNN folder lingers in the notebook's plans folder with nothing to
# sweep it. This pass is that sweep.
#
# Sweep criteria, per catalog plan row: a row is a delete candidate when ALL
# hold:
#   - the row carries no reap record (a reaped plan is already gone)
#   - the row is a merged row on one of two arms:
#       confirmed arm: a non-empty pr_number (stamped by the orchestrator's
#         post-merge close, or by plan-reconcile.sh's scan, which matches a
#         merged PR by plan number and creation time, not by confirmed
#         identity) and a parseable merged_at that has aged past the
#         retention window
#       legacy arm: no pr_number, status == "merged", and a parseable
#         merged_at that has aged past the same window; rows written before
#         pr_number existed age out here
#     A row whose status is not "merged", or whose merged_at is missing or
#     unparseable, is never a candidate on either arm.
#   - the library resolves the row's id to a plan folder that exists (a
#     malformed id, a symlinked folder or a folder outside the plans folder is
#     refused, never followed; the folder is the deletion unit, siblings go
#     with it)
#   - the folder holds a well-formed SUMMARY.md (the consolidation gate
#     below); a folder with an absent, empty or malformed SUMMARY.md never
#     went through consolidation, so whatever it holds is the sole record and
#     is never destroyed
# A merged row with no active folder (already gone, or never had one) is
# skipped.
#
# Age gate: a merged folder is kept until GAIA_SPEC_RETENTION_DAYS (default
# 30; a non-numeric override falls back to 30) days have passed since the
# row's merged_at, the SAME single knob spec-archive-merged.sh reads, so a
# just-merged plan survives for review instead of vanishing at merge. There
# is no early reap: --close is accepted and ignored. A missing or unparseable
# merged_at keeps the folder rather than reading as infinitely old.
#
# Consolidation gate: a folder with no verified SUMMARY.md has never been
# through consolidation (a plan that was never executed holds only its plan
# files), so its contents are the sole record and reaping them would be
# destructive.
# This delegates to .gaia/scripts/summary-verify.sh when present (exit 0 =
# well-formed); absent that script, a plain non-empty SUMMARY.md is the
# floor.
#
# Usage-ledger gate: once a candidate clears the age gate, this asks
# `usage.sh represented` (against the main checkout's usage ledger) whether a
# gaia-plan close is recorded for plan:<id>. Any non-zero verdict blocks that
# one id: the folder is left in place, one stdout keep line names the missing
# run and the `usage.sh record` recovery command, and the sweep moves on to
# the next candidate.
#
# After a delete the row gets a reap record naming this script; the row's
# merged/merged_at/pr_number stamp is a precondition set upstream (the
# orchestrator's post-merge close, or plan-reconcile.sh's scan), not by this
# sweep, and stays untouched. It is the identity record that survives once the
# folder is gone.
#
# Best-effort and fail-open by contract, exactly like spec-archive-merged.sh:
# a missing jq / catalog or an unrecorded run never blocks a caller. One stdout
# line summarizes what was deleted, and one names each kept folder;
# diagnostics go to stderr.
#
# Usage:
#   plan-archive-merged.sh <repo_root> [<plan_id>] [--close]
# With <plan_id>, only that id is considered. With no id, every merged row is
# swept. --close is accepted and ignored.
#
# Exit: 0 (advisory), except 3 when the one-time notebook move is pending: the
# move command is on stderr and nothing is removed.
set -uo pipefail

args=()
for argument in "$@"; do
  case "$argument" in
    --*) ;; # --close and unknown flags tolerated, ignored
    *) args+=("$argument") ;;
  esac
done

if [ "${#args[@]}" -lt 1 ]; then
  echo "usage: plan-archive-merged.sh <repo_root> [<plan_id>] [--close]" >&2
  exit 0
fi

repo_root="${args[0]%/}"
filter_id="${args[1]:-}"

# Retention knob, read once: a non-numeric override falls back to the default.
# The same GAIA_SPEC_RETENTION_DAYS knob spec-archive-merged.sh reads.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../notebook/notebook-lib.sh
. "${_library_directory}/../notebook/notebook-lib.sh" 2>/dev/null || {
  echo "plan-archive-merged: cannot load ${_library_directory}/../notebook/notebook-lib.sh; skipping sweep" >&2
  exit 0
}
# shellcheck source=SCRIPTDIR/../main-root-lib.sh
. "${_library_directory}/../main-root-lib.sh" 2>/dev/null || {
  echo "plan-archive-merged: cannot load ${_library_directory}/../main-root-lib.sh; skipping sweep" >&2
  exit 0
}

# repo_root names the tree this sweep runs in; the catalog and the plan
# folders it reads are main's. The operand decides the tree, not the caller's
# cwd, so a run against another checkout never touches the cwd's notebook.
export GAIA_NOTEBOOK_TREE="$repo_root"
readiness_status=0
gaia_notebook_require_ready || readiness_status=$?
if [ "$readiness_status" -eq 3 ]; then
  exit 3
elif [ "$readiness_status" -ne 0 ]; then
  echo "plan-archive-merged: cannot resolve the main checkout for '$repo_root'; skipping sweep" >&2
  exit 0
fi

# _consolidation_gate_pass <folder>: 0 iff the folder's SUMMARY.md is present
# and well-formed (consolidation ran). 1 keeps the folder: consolidation never
# produced a SUMMARY.md to replace its contents. Prefers summary-verify.sh when
# present; falls back to a plain non-empty-file check.
_consolidation_gate_pass() {
  local folder="$1"
  local summary="${folder}/SUMMARY.md" verify="${repo_root}/.gaia/scripts/summary-verify.sh"
  if [ -f "$verify" ]; then
    bash "$verify" "$summary" >/dev/null 2>&1
    return $?
  fi
  [ -s "$summary" ]
}

# No jq -> nothing to do (checked first among the gates: cheap, and every other
# gate needs it).
command -v jq >/dev/null 2>&1 || exit 0

# The age test lives in ledger-lib.sh. Loaded bracketed against an unparseable
# copy; without it no age can be judged, and an unknown age must never read as
# past the window, so the sweep reaps nothing.
# shellcheck source=SCRIPTDIR/ledger-lib.sh
[ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null || true
if ! type gaia_ledger_age_past_window >/dev/null 2>&1; then
  echo "plan-archive-merged: ledger-lib.sh is unusable; nothing swept" >&2
  exit 0
fi

# The usage ledger lives under the main checkout, resolved from repo_root's own
# git identity and never the caller's cwd. An unresolved root fails the gate
# closed: every candidate is kept.
main_root="$(gaia_resolve_main_root "$repo_root" 2>/dev/null || true)"

# _usage_gate <relative_folder> <ref> <workflow>: 0 when the usage ledger
# records a <workflow> close for <ref>. Otherwise prints the keep line for the
# folder on stdout and returns 1: the unreadable-ledger form when
# `usage.sh represented` exits 2 or the main checkout is unresolved, the
# no-run-recorded form for any other failure.
_usage_gate() {
  local relative_folder="$1" ref="$2" workflow="$3" gate_status=2 recovery_command
  recovery_command="outside a live ${workflow} run, record it: bash .gaia/scripts/usage.sh record ${ref} --workflow ${workflow} --start <iso>"
  if [ -n "$main_root" ]; then
    gate_status=0
    bash "${repo_root}/.gaia/scripts/usage.sh" represented "$ref" --workflow "$workflow" \
      --main-root "$main_root" </dev/null >/dev/null 2>&1 || gate_status=$?
  fi
  [ "$gate_status" -ne 0 ] || return 0
  if [ "$gate_status" -eq 2 ]; then
    printf 'Kept %s: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for %s; once it reads, %s\n' \
      "$relative_folder" "$ref" "$recovery_command"
  else
    printf 'Kept %s: no %s run recorded for %s; %s\n' \
      "$relative_folder" "$workflow" "$ref" "$recovery_command"
  fi
  return 1
}

# Candidate rows (local, cheap): merged rows with no reap record. The
# confirmed arm (a pr_number) and the legacy arm (none) share every gate and
# differ only in provenance, so one select covers both; the age gate below
# requires a parseable, aged merged_at of each. An optional single-id filter
# narrows the sweep to one row. Each candidate prints as "<id><TAB><merged_at>".
merged_rows="$(gaia_notebook_rows plan merged | jq -r --arg id "$filter_id" \
  '.[] | select(has("reap") | not) | select($id == "" or .id == $id) | "\(.id)\t\(.merged_at // "")"' \
  2>/dev/null || true)"
[ -n "$merged_rows" ] || exit 0

deleted_list=""

while IFS='	' read -r plan_id merged_at; do
  [ -n "$plan_id" ] || continue

  # The library validates the id and refuses a folder that resolves outside
  # the plans folder or is itself a symlink; either is skipped, never followed.
  if ! folder="$(gaia_notebook_item_directory plan "$plan_id")" || [ -z "$folder" ]; then
    echo "plan-archive-merged: refusing the folder for '$plan_id'; kept" >&2
    continue
  fi
  # Skip merged rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue
  relative_folder="${folder#"${main_root}/"}"

  # Consolidation gate: a folder with no consolidated SUMMARY.md is never
  # reaped; its contents are the sole record.
  if ! _consolidation_gate_pass "$folder"; then
    echo "plan-archive-merged: consolidation never ran; kept $plan_id" >&2
    continue
  fi

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # merged_at keeps the folder (fail-closed). No caller bypasses it.
  if ! gaia_ledger_age_past_window "$merged_at" "$now_epoch" "$retention_days"; then
    echo "plan-archive-merged: $plan_id within retention window (or merged_at missing/unparseable); kept" >&2
    continue
  fi

  # Usage-ledger gate: refuse to delete a folder whose gaia-plan run the usage
  # ledger does not record. Any non-zero verdict, including an unresolved main
  # checkout, blocks this id and leaves the folder untouched.
  if ! _usage_gate "$relative_folder" "plan:${plan_id}" gaia-plan; then
    continue
  fi

  if ! rm -rf "${folder:?}" 2>/dev/null; then
    echo "plan-archive-merged: $plan_id folder delete failed; left active folder in place" >&2
    continue
  fi
  gaia_notebook_record_reap plan "$plan_id" plan-archive-merged \
    || echo "plan-archive-merged: $plan_id folder deleted but its reap record was not written" >&2

  deleted_list="${deleted_list:+$deleted_list, }${plan_id}"
done <<EOF
$merged_rows
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s merged plan folder(s): %s\n' "$count" "$deleted_list"

exit 0
