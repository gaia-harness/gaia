#!/usr/bin/env bash
# spec-abandon-empty.sh: Guarded sweep that retires a never-authored SPEC
# draft to the terminal `abandoned` status. A ghost draft (a row
# allocated but never touched: no SPEC.md, no draft cache, no gate-1 snapshot)
# would otherwise re-surface on every /gaia-spec resume prompt forever; this
# pass gives it a terminal home once it is unambiguously never-authored.
#
# Double guard, BOTH required:
#   - Emptiness (primary): no SPEC.md, no draft-<id>.md cache, no
#     gate1-<id>.json snapshot. Any one of these present means authored
#     content exists; never sweep it, this is what keeps a paused-but-authored
#     session safe (SPEC never-boundary).
#   - Age (secondary): the row's created_at is older than the guard age (~1
#     day). A session paused moments after allocation is briefly "empty" too;
#     age is what tells that apart from a genuinely abandoned draft. An
#     unparseable or missing created_at is treated as NOT aged, never guessed.
#
# Epoch math is jq-only (`now`, `fromdateiso8601`), never `date -d`/`date -j`,
# because the `date` binary parses no timestamp here, so behavior is identical
# on macOS and Linux CI.
#
# Usage:
#   spec-abandon-empty.sh <repo_root>
#
# Best-effort and fail-open, exactly like spec-reconcile.sh: a missing jq, an
# unparseable timestamp, or a ledger-update failure never blocks a caller.
# Prints one summary line to stdout when it flips any row, silent otherwise;
# diagnostics go to stderr.
#
# Exit: 0 (advisory), except 3 when the one-time move to the notebook has not
# run (the move command on stderr, nothing changed).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-abandon-empty.sh <repo_root>" >&2
  exit 0
fi

repo_root="${1%/}"
cache_directory="${repo_root}/.gaia/local/cache"
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../notebook/notebook-lib.sh
. "${_library_directory}/../notebook/notebook-lib.sh" 2>/dev/null || {
  echo "spec-abandon-empty: cannot load the notebook library; nothing swept" >&2
  exit 0
}

GUARD_AGE_SECONDS=86400

# No jq → nothing to do.
command -v jq >/dev/null 2>&1 || exit 0

# repo_root names the tree this sweep runs in; the catalog it sweeps is
# main's, resolved by the library from the tree selector. Readiness is checked
# before any other gate: a not-ready notebook changes nothing.
export GAIA_NOTEBOOK_TREE="$repo_root"
ready_status=0
gaia_notebook_require_ready || ready_status=$?
if [ "$ready_status" -eq 1 ]; then
  echo "spec-abandon-empty: cannot resolve the main checkout for '$repo_root'; nothing swept" >&2
  exit 0
elif [ "$ready_status" -ne 0 ]; then
  exit "$ready_status"
fi

# Aged draft ids only (local, cheap): status == draft AND created_at parses
# to older than the guard age. An unparseable/missing created_at is
# excluded here rather than guessed at.
aged_ids="$(gaia_notebook_rows spec draft 2>/dev/null | jq -r --argjson guard "$GUARD_AGE_SECONDS" '
  def to_epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  now as $now
  | .[]
  | select(
      (.created_at // "") as $timestamp
      | ($timestamp | try to_epoch catch null) as $epoch
      | $epoch != null and ($now - $epoch) > $guard
    )
  | .id
' 2>/dev/null || true)"
[ -n "$aged_ids" ] || exit 0

now_timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
abandoned_list=""

while IFS= read -r id; do
  [ -n "$id" ] || continue

  # The library validates the id and refuses a symlinked or escaping folder;
  # a refusal skips this row only.
  if ! folder="$(gaia_notebook_item_directory spec "$id" 2>/dev/null)" || [ -z "$folder" ]; then
    echo "spec-abandon-empty: refused the folder for row id '$id' (invalid id or symlink); skipped" >&2
    continue
  fi

  # Emptiness guard: no SPEC.md, no draft cache, no gate-1 snapshot. Any one
  # present means authored content exists; leave the row alone.
  [ -f "${folder}/SPEC.md" ] && continue
  [ -f "${cache_directory}/draft-${id}.md" ] && continue
  [ -f "${cache_directory}/gate1-${id}.json" ] && continue

  patch="$(jq -nc --arg timestamp "$now_timestamp" '{status: "abandoned", abandoned_at: $timestamp}')"
  if bash "${_library_directory}/ledger-update.sh" "$repo_root" "$id" "$patch" >/dev/null 2>&1; then
    # Third-party cleanup of a dormant-or-ghost lock this sweep does not own;
    # it only ever runs on a genuine ghost, so it never acts on a live lock.
    rm -f "${cache_directory}/spec-session-${id}.lock" 2>/dev/null || true
    abandoned_list="${abandoned_list:+$abandoned_list, }${id}"
  fi
done <<EOF
$aged_ids
EOF

[ -n "$abandoned_list" ] || exit 0

count="$(printf '%s' "$abandoned_list" | awk -F', ' '{print NF}')"
printf 'Abandoned %s never-authored draft(s): %s\n' "$count" "$abandoned_list"

exit 0
