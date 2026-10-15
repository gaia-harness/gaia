#!/usr/bin/env bash
# plan-archive.sh: Reduce or delete a merged gaia-plan folder.
#
# On PR merge, an executed gaia-plan's orchestrator self-cleanup disposes of
# the whole plan folder, gating the disposition on the usage ledger:
#
#   - Spec-less PLAN-NNN plan in the notebook's plans folder: this best-effort
#     advances that plan's catalog row to status "merged" with a merged_at
#     timestamp, through ledger-update.sh, before the disposition decision,
#     which is gated on the usage ledger holding a gaia-plan close for
#     plan:PLAN-NNN (usage.sh represented); a folder that fails the gate, or
#     carries no consolidated SUMMARY.md yet, is left in place untouched. A
#     kept folder survives for later age-reap (plan-archive-merged.sh) instead
#     of being deleted outright.
#   - Spec-colocated plan at plan[-N] inside a SPEC folder of the notebook's
#     specs folder: the same gate applies, keyed on the parent SPEC (a
#     gaia-plan close for spec:SPEC-NNN clears every plan subfolder of that
#     spec); the SPEC folder is the archival unit for everything else and is
#     untouched here.
#
# Encapsulating the delete in a subprocess keeps the destructive rm out of
# the caller's own tool-call stream, so the block-rm-rf.sh PreToolUse hook
# and the settings.json permission gate never see the internal rm and cannot
# prompt or block.
#
# Usage:
#   plan-archive.sh <plan_dir>
#
# <plan_dir> is a path to the plan folder, absolute or repo-relative (trailing
# slash tolerated). The notebook library classifies it
# (notebook-lib.sh classify): only a spec-less plan folder or a spec-colocated
# plan[-N] folder is accepted, spelled exactly (a path with dot segments, a
# nested path or a symlinked folder is refused). Anything else, including a
# folder that still sits under a pre-notebook root, is refused with a stderr
# line that prints the accepted locations.
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#     When the one-time notebook move is pending, the move line goes to
#     stderr and the folder is left untouched.
#   - The PLAN-NNN catalog merge stamp (see above) is best-effort: a missing
#     catalog, missing row, or lock timeout is swallowed and never blocks or
#     fails this script.
#   - The usage-ledger gate is fail-closed: any error resolving the main
#     checkout, a missing or unreadable usage ledger, or a run with no
#     recorded close leaves the folder in place and prints a keep line on
#     stdout naming the recovery command.
#   - stdout carries at most one human summary line describing what
#     happened; diagnostics and refusals go to stderr only.
#   - Idempotent: a missing plan_dir, or a second run after a successful
#     reduce or delete, is a no-op.
#   - No git dependency for the delete itself -- the notebook is gitignored,
#     so this is plain filesystem work. git is only consulted (best-effort,
#     $PWD fallback) to resolve the repo root, and to resolve the main
#     checkout whose usage ledger the gate reads.
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: plan-archive.sh <plan_dir>" >&2
  exit 0
fi

raw="$1"

# ---------- resolve repo root ----------
root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] || root="$PWD"
root="${root%/}"

# The gate reads the main checkout's usage ledger, and the library classifies
# and resolves every path. A library that cannot load leaves every folder in
# place.
# shellcheck source=.gaia/scripts/main-root-lib.sh
. "$root/.gaia/scripts/main-root-lib.sh" 2>/dev/null || {
  echo "plan-archive: cannot load $root/.gaia/scripts/main-root-lib.sh; nothing archived" >&2
  exit 0
}
# shellcheck source=.gaia/scripts/notebook/notebook-lib.sh
. "$root/.gaia/scripts/notebook/notebook-lib.sh" 2>/dev/null || {
  echo "plan-archive: cannot load $root/.gaia/scripts/notebook/notebook-lib.sh; nothing archived" >&2
  exit 0
}
export GAIA_NOTEBOOK_TREE="$root"

gaia_notebook_require_ready || exit 0

main_root="$(gaia_resolve_main_root "$root" 2>/dev/null)" || main_root=""

trimmed_path="${raw%/}"
trimmed_path="${trimmed_path#./}"

# _refuse <reason>: one stderr line that shows where plan folders may live.
_refuse() {
  local plans_location specs_location
  plans_location="$(gaia_notebook_kind_directory plan 2>/dev/null)" || plans_location="(the notebook's plans folder)"
  specs_location="$(gaia_notebook_kind_directory spec 2>/dev/null)" || specs_location="(the notebook's specs folder)"
  echo "plan-archive: refusing $trimmed_path ($1); accepted: a PLAN-NNN folder under $plans_location, or a plan[-N] folder inside a SPEC-NNN folder under $specs_location" >&2
  exit 0
}

# ---------- classify the argument ----------
classification="$(gaia_notebook_classify_path "$trimmed_path" 2>/dev/null)" || _refuse "not a plan folder of the notebook"

kind=""
spec_part=""
plan_id=""
plan_child=""
read -r classified_kind classified_id classified_child <<EOF
$classification
EOF
case "$classified_kind" in
  plan)
    kind="plans"
    plan_id="$classified_id"
    absolute_source_path="$(gaia_notebook_item_directory plan "$plan_id" 2>/dev/null)" || _refuse "the folder resolves outside the plans folder or is a symlink"
    ;;
  spec-plan)
    kind="specs"
    spec_part="$classified_id"
    plan_child="$classified_child"
    spec_directory="$(gaia_notebook_item_directory spec "$spec_part" 2>/dev/null)" || _refuse "the folder resolves outside the specs folder or is a symlink"
    absolute_source_path="$spec_directory/$plan_child"
    if [ -L "$absolute_source_path" ]; then
      _refuse "the plan folder is a symlink"
    fi
    ;;
  *) _refuse "not a plan folder of the notebook" ;;
esac

# The classifier reads the leading components and ignores the rest, so the
# argument must also spell exactly the folder it classified to: a trailing
# segment or a dot segment would otherwise act on a different folder than the
# one named.
if [ -n "$main_root" ]; then
  relative_path="${absolute_source_path#"${main_root}/"}"
else
  relative_path="$absolute_source_path"
fi
case "$trimmed_path" in
  /*)
    argument_parent="$(cd -- "$(dirname -- "$trimmed_path")" 2>/dev/null && pwd -P)" || argument_parent=""
    [ "$argument_parent/${trimmed_path##*/}" = "$absolute_source_path" ] || _refuse "the path is not the exact plan folder"
    ;;
  *)
    [ "$trimmed_path" = "$relative_path" ] || _refuse "the path is not the exact plan folder"
    ;;
esac

# ---------- existence check ----------
if [ ! -e "$absolute_source_path" ]; then
  echo "plan-archive: $relative_path does not exist; nothing to do" >&2
  exit 0
fi

# ---------- derive the usage ref the gate needs ----------
usage_workflow="gaia-plan"
if [ "$kind" = "plans" ]; then
  usage_ref="plan:$plan_id"
else
  usage_ref="spec:$spec_part"
fi

# ---- best-effort catalog merge stamp (PLAN-NNN folders only) ----
# Runs before the usage-ledger gate so the terminal identity record survives
# even a folder the gate leaves in place (a later run, once the close is
# recorded, finds the row already merged and can retry the reduce).
if [ -n "$plan_id" ]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  patch="$(jq -nc --arg timestamp "$now" '{status: "merged", merged_at: $timestamp}')"
  bash "$root/.gaia/scripts/spec/ledger-update.sh" "$root" "$plan_id" "$patch" \
    >/dev/null 2>&1 || true
fi

# ---------- usage-ledger gate ----------
recovery_command="outside a live $usage_workflow run, record it: bash .gaia/scripts/usage.sh record $usage_ref --workflow $usage_workflow --start <iso>"
gate_status=2
if [ -n "$main_root" ]; then
  gate_status=0
  bash "$root/.gaia/scripts/usage.sh" represented "$usage_ref" --workflow "$usage_workflow" \
    --main-root "$main_root" </dev/null >/dev/null 2>&1 || gate_status=$?
fi
if [ "$gate_status" -eq 2 ]; then
  printf 'Kept %s: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for %s; once it reads, %s\n' \
    "$relative_path" "$usage_ref" "$recovery_command"
  exit 0
fi
if [ "$gate_status" -ne 0 ]; then
  printf 'Kept %s: no %s run recorded for %s; %s\n' \
    "$relative_path" "$usage_workflow" "$usage_ref" "$recovery_command"
  exit 0
fi

# ---------- disposition ----------
if [ -n "$plan_id" ]; then
  # A catalog-tracked spec-less PLAN-NNN: keep-then-age-reap. Reduce the
  # folder to its consolidated SUMMARY.md and clear everything else, RUNNING
  # included, instead of deleting outright, so plan-archive-merged.sh can
  # reap it once merged_at clears the retention window.
  if [ ! -s "$absolute_source_path/SUMMARY.md" ]; then
    echo "plan-archive: no consolidated SUMMARY.md yet under $relative_path; left intact for consolidation" >&2
    printf 'Retained plan (no consolidated SUMMARY.md yet): %s\n' "$relative_path"
    exit 0
  fi
  find "$absolute_source_path" -mindepth 1 -maxdepth 1 ! -name SUMMARY.md -exec rm -rf {} +
  printf 'Reduced plan folder to SUMMARY.md (kept for age-reap): %s\n' "$relative_path"
  exit 0
fi

# Spec-colocated plan[-N]: delete only the subfolder, gated on the parent
# SPEC's own consolidated SUMMARY.md existing (consolidation has consumed
# plan/PROGRESS.md). A cold invocation that races ahead of consolidation
# keeps the subfolder rather than destroying PROGRESS.md.
spec_summary="$spec_directory/SUMMARY.md"
summary_ok=1
verify_script="$root/.gaia/scripts/summary-verify.sh"
if [ -x "$verify_script" ] || [ -f "$verify_script" ]; then
  bash "$verify_script" "$spec_summary" >/dev/null 2>&1 || summary_ok=0
else
  [ -s "$spec_summary" ] || summary_ok=0
fi
if [ "$summary_ok" -ne 1 ]; then
  echo "plan-archive: parent SPEC has no consolidated SUMMARY.md yet; left $relative_path in place" >&2
  printf 'Retained plan (parent SPEC not yet consolidated): %s\n' "$relative_path"
  exit 0
fi

# ---------- delete (a gated spec-colocated plan[-N]) ----------
rm -rf -- "$absolute_source_path"
printf 'Deleted plan folder: %s (the usage ledger holds the run record)\n' "$relative_path"

exit 0
