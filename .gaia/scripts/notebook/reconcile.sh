#!/usr/bin/env bash
# reconcile.sh: compare the notebook catalog with the folders on disk for
# specs, plans and research, and report every mismatch. Run as pass 2 of the
# pre-flight sweep in .claude/skills/gaia/references/spec/lifecycle.md.
#
# Output, one line per mismatch on stdout, sorted by kind then path:
#   reconcile: <kind> <notebook-relative path>: <reason>
# with reason one of:
#   folder without catalog row   a spec or plan folder has no row
#   row without folder           a row with no reap record has no folder
#   loose file                   a regular file sits directly in research
#   registered untagged          a row-less research folder was given an
#                                untagged row (the only change this makes)
#
# Why a row-less spec or plan folder is only reported: its status cannot be
# inferred safely from its contents, so it is named every sweep and every
# reaper skips it. A research folder can be registered because untagged is
# never reaped. A research folder registered this run is reported once, as
# registered, and is silent on the next run.
#
# Ignored: dotfiles and the catalog temp file, rows carrying a reap record
# (the folder is expected to be gone), and plans nested inside a spec folder
# (the parent spec row covers them).
#
# Usage: reconcile.sh [<tree_dir>]
# <tree_dir> names the checkout or worktree to resolve the notebook from;
# without it the notebook is resolved from the current directory.
#
# Exit: 0, 2 usage, 3 the one-time move has not run (the move command on
# stderr, nothing changed), 4 the catalog is unreadable (nothing changed).
set -uo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: reconcile.sh [<tree_dir>]" >&2
  exit 2
fi
if [ "$#" -eq 1 ] && [ -n "$1" ]; then
  GAIA_NOTEBOOK_TREE="$1"
  export GAIA_NOTEBOOK_TREE
fi

_script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./notebook-lib.sh
. "${_script_directory}/notebook-lib.sh" || {
  echo "reconcile: cannot load the notebook library; nothing reconciled" >&2
  exit 1
}

gaia_notebook_require_ready || exit $?

work_directory="$(mktemp -d)" || exit 1
trap 'rm -rf "$work_directory"' EXIT
report_file="${work_directory}/report"
: > "$report_file"

# reconcile_kind <kind> <notebook-relative kind folder>
reconcile_kind() {
  local kind="$1" prefix="$2" rows_json name
  rows_json="$(gaia_notebook_rows "$kind")" || return $?
  printf '%s' "$rows_json" | jq -r '.[].id' | LC_ALL=C sort > "${work_directory}/all-ids"
  printf '%s' "$rows_json" | jq -r '.[] | select(has("reap") | not) | .id' | LC_ALL=C sort > "${work_directory}/live-ids"
  gaia_notebook_folders "$kind" > "${work_directory}/folders" || return $?

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf 'reconcile: %s %s/%s: row without folder\n' "$kind" "$prefix" "$name" >> "$report_file"
  done < <(LC_ALL=C comm -23 "${work_directory}/live-ids" "${work_directory}/folders")

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$kind" = research ] && gaia_notebook_register research "$name" untagged "" >/dev/null; then
      printf 'reconcile: %s %s/%s: registered untagged\n' "$kind" "$prefix" "$name" >> "$report_file"
    else
      printf 'reconcile: %s %s/%s: folder without catalog row\n' "$kind" "$prefix" "$name" >> "$report_file"
    fi
  done < <(LC_ALL=C comm -13 "${work_directory}/all-ids" "${work_directory}/folders")
}

reconcile_kind spec specs || exit $?
reconcile_kind plan plans || exit $?
reconcile_kind research research || exit $?

while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf 'reconcile: research research/%s: loose file\n' "$name" >> "$report_file"
done < <(gaia_notebook_loose_files research)

LC_ALL=C sort "$report_file"
exit 0
