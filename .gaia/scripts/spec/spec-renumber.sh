#!/usr/bin/env bash
# spec-renumber.sh: Renumber a SPEC. Renames the SPEC folder in the notebook,
# updates the inner SPEC.md frontmatter, re-keys the SPEC's catalog row, and
# best-effort re-keys the gate1/draft/session/lock/audit caches under
# .gaia/local/cache/. The inner SPEC.md keeps its name; any sibling artifacts in
# the folder move with it.
# Does NOT touch external state (branch names, GH issue titles, commit-message
# history), those are reported as next steps for the caller to handle consciously.
#
# Usage:
#   spec-renumber.sh <repo_root> <old_id> <new_id>
#
# Refuses if:
#   - repo_root is not a git working tree
#   - old/new id is not in SPEC-NNN form
#   - the one-time move to the notebook has not run (exit 3, the move command
#     on stderr; no folder and no row changes)
#   - old SPEC folder is missing
#   - new id is already taken (a catalog row, a plan branch or a folder)
#
# The folder move, the frontmatter rewrite and the row re-key run as one block
# under the catalog write lock, so a concurrent register waits and neither
# write is lost.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: spec-renumber.sh <repo_root> <old_id> <new_id>" >&2
  exit 2
fi

repo_root="$1"
old_id="$2"
new_id="$3"

# Source the shared libs from this script's own directory, never through
# repo_root: repo_root is the value whose trustworthiness is in question here,
# so loading a library by it would decide correctness with the input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# Bracketed against a target that is present but UNPARSEABLE. A bare `.` under
# errexit abandons the shell AT the load, exit 2 with no diagnostic, and a
# trailing `|| true` does not save it on stock macOS /bin/bash 3.2.57, which
# aborts before the arm is ever evaluated: the refusal written below would never
# run. An interrupted update, an unresolved merge conflict, and a truncated
# write all leave exactly that state on disk.
# shellcheck source=../notebook/notebook-lib.sh
set +e; [ -f "${_library_directory}/../notebook/notebook-lib.sh" ] && . "${_library_directory}/../notebook/notebook-lib.sh" 2>/dev/null; set -e
type gaia_notebook_rename >/dev/null 2>&1 || {
  echo "spec-renumber: the notebook library is unusable; refuse to renumber" >&2
  exit 4
}
# The branch-naming library reads a SPEC number back out of a plan branch in
# every spelling GAIA mints, the worktree one included. Loaded the same
# bracketed way as the notebook library above, for the same reason.
# shellcheck source=../branch-name-lib.sh
set +e; [ -f "${_library_directory}/../branch-name-lib.sh" ] && . "${_library_directory}/../branch-name-lib.sh" 2>/dev/null; set -e
if ! type gaia_branch_spec_number >/dev/null 2>&1; then
  echo "spec-renumber: the branch-naming library is unusable, so SPEC numbers held only on a branch cannot be read; refuse to renumber" >&2
  exit 4
fi

for id in "$old_id" "$new_id"; do
  if [[ ! "$id" =~ ^SPEC-[0-9]+$ ]]; then
    echo "spec-renumber: invalid id '$id' (expected SPEC-NNN)" >&2
    exit 2
  fi
done

if [ "$old_id" = "$new_id" ]; then
  echo "spec-renumber: old and new ids are identical ($old_id)" >&2
  exit 2
fi

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "spec-renumber: $repo_root is not a git repository" >&2
  exit 3
fi

# repo_root names the tree this renumber runs in; the catalog and folder it
# rewrites are main's. The library resolves main from the tree selector, so
# the folder and the row land in the same notebook whatever tree the operand
# names. Readiness comes before every other gate: a refusal changes nothing.
export GAIA_NOTEBOOK_TREE="$repo_root"
ready_status=0
gaia_notebook_require_ready || ready_status=$?
if [ "$ready_status" -ne 0 ]; then
  if [ "$ready_status" -eq 1 ]; then
    echo "spec-renumber: cannot resolve the main checkout for '$repo_root'; refuse to renumber (would fork the catalog across worktrees)" >&2
    exit 3
  fi
  exit "$ready_status"
fi

# main_root: the checkout that physically owns the notebook. The git mv and
# ls-files calls below touch paths under it, so they must run against the repo
# that contains them, not the raw repo_root operand, which can be a different
# worktree.
if ! main_root="$(gaia_resolve_main_root "$repo_root" 2>/dev/null)" || [ -z "$main_root" ]; then
  echo "spec-renumber: cannot resolve the main checkout for '$repo_root'; refuse to renumber (would fork the catalog across worktrees)" >&2
  exit 3
fi

if ! old_path="$(gaia_notebook_item_directory spec "$old_id")" || ! new_path="$(gaia_notebook_item_directory spec "$new_id")"; then
  echo "spec-renumber: a SPEC folder path was refused by the notebook library" >&2
  exit 2
fi
old_spec="${old_path}/SPEC.md"
new_spec="${new_path}/SPEC.md"

if [ ! -f "$old_spec" ]; then
  echo "spec-renumber: source SPEC file not found at $old_spec" >&2
  exit 4
fi

if [ -e "$new_path" ]; then
  echo "spec-renumber: target folder $new_path already exists" >&2
  exit 4
fi

# Reject if the new id is already known: a catalog row, a plan branch or a
# folder, minus the row and folder we are about to move.
new_number=$((10#${new_id#SPEC-}))
old_number=$((10#${old_id#SPEC-}))
if ! known_rows="$(gaia_notebook_rows spec)"; then
  echo "spec-renumber: the notebook catalog is unreadable; refuse to renumber" >&2
  exit 4
fi
while IFS= read -r known_number; do
  [ -z "$known_number" ] && continue
  if [ "$((10#$known_number))" -eq "$new_number" ]; then
    echo "spec-renumber: $new_id is already known (catalog/branch/filesystem)" >&2
    exit 4
  fi
done < <(
  printf '%s' "$known_rows" | jq -r --arg drop "$old_id" '.[] | select(.id != $drop) | .id' 2>/dev/null \
    | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
  # The test is a builtin prefilter so a branch that cannot name a
  # SPEC skips the subshells of the library, and a repository carries hundreds
  # of refs.
  gaia_branch_list "$repo_root" | while IFS= read -r branch; do
    if [[ "$branch" == *spec-* ]]; then gaia_branch_spec_number "$branch"; fi
  done
  gaia_notebook_folders spec 2>/dev/null | grep -vx -- "$old_id" \
    | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
)

# 1-3 under the catalog lock: prepare the rewritten SPEC.md, move the folder
# whole, re-key the row, then swap the rewritten SPEC.md in. The row re-key is
# a single library write that refuses a collision; a failure moves the folder
# back, leaving the original SPEC.md untouched.
move_folder() {
  # git mv when the inner SPEC.md is tracked, plain mv otherwise.
  if git -C "$main_root" ls-files --error-unmatch "$1" >/dev/null 2>&1; then
    git -C "$main_root" mv "$2" "$3"
  else
    mv "$2" "$3"
  fi
}

renumber_locked() {
  local temporary_spec_file rename_status=0
  # errexit is off inside a block run as `lock || status=$?`, so each step
  # checks its own result.

  # Rewrite frontmatter spec_id (and stamp renamed_from for traceability).
  # Operates on the YAML frontmatter block between the first two `---` lines.
  temporary_spec_file="$(mktemp)"
  if ! awk -v new_id="$new_id" -v old_id="$old_id" '
    BEGIN { in_frontmatter = 0; frontmatter_delimiter_count = 0; stamped = 0 }
    /^---[[:space:]]*$/ {
      frontmatter_delimiter_count++
      if (frontmatter_delimiter_count == 1) { in_frontmatter = 1; print; next }
      if (frontmatter_delimiter_count == 2) {
        if (in_frontmatter && !stamped) { print "renamed_from: " old_id; stamped = 1 }
        in_frontmatter = 0; print; next
      }
    }
    in_frontmatter && /^spec_id:[[:space:]]/ { print "spec_id: " new_id; next }
    { print }
  ' "$old_spec" > "$temporary_spec_file"; then
    rm -f "$temporary_spec_file"
    echo "spec-renumber: failed to prepare the SPEC frontmatter; nothing renumbered" >&2
    return 1
  fi

  if ! move_folder "$old_spec" "$old_path" "$new_path"; then
    rm -f "$temporary_spec_file"
    return 1
  fi

  gaia_notebook_rename spec "$old_id" "$new_id" || rename_status=$?
  case "$rename_status" in
    0) ;;
    6)
      # A folder with no catalog row: nothing to re-key, the folder move stands.
      echo "spec-renumber: no catalog row for $old_id; renamed the folder only" >&2
      ;;
    *)
      echo "spec-renumber: failed to re-key the catalog row; reverting folder move" >&2
      rm -f "$temporary_spec_file"
      move_folder "$new_spec" "$new_path" "$old_path" || true
      return 5
      ;;
  esac

  if ! mv "$temporary_spec_file" "$new_spec"; then
    rm -f "$temporary_spec_file"
    echo "spec-renumber: the row and folder moved but the SPEC frontmatter could not be rewritten" >&2
  fi
}

lock_status=0
gaia_notebook_with_catalog_lock renumber_locked || lock_status=$?
if [ "$lock_status" -ne 0 ]; then
  if [ "$lock_status" -eq 75 ]; then
    echo "spec-renumber: could not acquire the catalog lock; nothing renumbered" >&2
  fi
  exit "$lock_status"
fi

# 4. Best-effort re-key of the id-bearing per-spec caches under
#    .gaia/local/cache/ (draft checkpoint, session-shape cache, liveness lock,
#    audit-findings directory). A missing cache is a normal no-op. A
#    cache-move failure is logged to stderr and does not revert the
#    folder/row move above; that move already succeeded and remains the
#    source of truth.
cache_directory="${repo_root%/}/.gaia/local/cache"

old_gate1="${cache_directory}/gate1-${old_id}.json"
new_gate1="${cache_directory}/gate1-${new_id}.json"
if [ -e "$old_gate1" ]; then
  if ! mv "$old_gate1" "$new_gate1" 2>/dev/null; then
    echo "spec-renumber: failed to re-key gate1 cache $old_gate1" >&2
  fi
fi

old_draft="${cache_directory}/draft-${old_id}.md"
new_draft="${cache_directory}/draft-${new_id}.md"
if [ -e "$old_draft" ]; then
  if ! mv "$old_draft" "$new_draft" 2>/dev/null; then
    echo "spec-renumber: failed to re-key draft cache $old_draft" >&2
  fi
fi

old_session="${cache_directory}/spec-session-${old_id}.json"
new_session="${cache_directory}/spec-session-${new_id}.json"
if [ -e "$old_session" ]; then
  if mv "$old_session" "$new_session" 2>/dev/null; then
    temporary_session_file="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_session" > "$temporary_session_file" 2>/dev/null; then
      mv "$temporary_session_file" "$new_session"
    else
      rm -f "$temporary_session_file"
      echo "spec-renumber: failed to rewrite spec_id in $new_session" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session cache $old_session" >&2
  fi
fi

old_lock="${cache_directory}/spec-session-${old_id}.lock"
new_lock="${cache_directory}/spec-session-${new_id}.lock"
if [ -e "$old_lock" ]; then
  if mv "$old_lock" "$new_lock" 2>/dev/null; then
    temporary_lock_file="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_lock" > "$temporary_lock_file" 2>/dev/null; then
      mv "$temporary_lock_file" "$new_lock"
    else
      rm -f "$temporary_lock_file"
      echo "spec-renumber: failed to rewrite spec_id in $new_lock" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session lock $old_lock" >&2
  fi
fi

old_audit="${cache_directory}/audit-${old_id}"
new_audit="${cache_directory}/audit-${new_id}"
if [ -e "$old_audit" ]; then
  if ! mv "$old_audit" "$new_audit" 2>/dev/null; then
    echo "spec-renumber: failed to re-key audit cache $old_audit" >&2
  fi
fi

echo "renumbered $old_id → $new_id"
echo
echo "Next steps (external state, not auto-updated):"

# Branch name, flag if the current branch references the old id.
current_branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
if [ -n "$current_branch" ] && [ "$(gaia_branch_spec_number "$current_branch")" = "$old_number" ]; then
  new_branch="${current_branch//spec-$(printf '%03d' "$old_number")/spec-$(printf '%03d' "$new_number")}"
  echo "  - Current branch '$current_branch' references $old_id."
  echo "    Rename:   git -C $repo_root branch -m '$new_branch'"
fi

echo "  - Commit-message history is immutable; past commits keep $old_id refs."
