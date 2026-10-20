#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA state-registry lint.
#
# Keeps every `.entries[]` row of the state registry saying how its entry
# dies: each row must carry a valid `retention` object and must not carry the
# legacy `reaped_by` prose field, and row ids must be unique. Validity is
# decided by gaia_reaper_row_check in the sibling state-reaper-lib.sh, the same
# check the reaper applies at run time, so the lint and the reaper can never
# disagree about what a valid row is. The class vocabulary and its semantics
# live in the header of state-reaper-lib.sh; this file does not restate them.
# Residue and report_only rows carry no retention and are out of scope.
#
# Usage: bash .gaia/scripts/state-registry-lint.sh [registry-path]
#
# The default registry is the one in the tree that holds this script,
# resolved physically from the script's own directory. It never asks for the
# main checkout and never reads the working directory, so a run from a linked
# worktree lints that worktree's registry.
#
# Output: one `<row-id>: <reason>` line per violation on stdout.
# Exit codes:
#   0  every row is clean
#   1  one or more violations
#   2  the lint cannot run (jq missing, registry unreadable or not JSON)

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf 'state-registry-lint: cannot resolve the script directory\n' >&2
  exit 2
}
registry_path="${1-$script_directory/../state-registry.json}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'state-registry-lint: jq is not available\n' >&2
  exit 2
fi
if [ ! -f "$registry_path" ] || [ ! -r "$registry_path" ]; then
  printf 'state-registry-lint: cannot read the registry: %s\n' "$registry_path" >&2
  exit 2
fi
if ! jq -e '.entries | type == "array"' "$registry_path" >/dev/null 2>&1; then
  printf 'state-registry-lint: not a registry (invalid JSON or no entries array): %s\n' "$registry_path" >&2
  exit 2
fi

# shellcheck source=.gaia/scripts/state-reaper-lib.sh
source "$script_directory/state-reaper-lib.sh"

violations=0
row_json=""
row_index=0

while IFS= read -r row_json; do
  row_index=$((row_index + 1))
  row_id="$(printf '%s' "$row_json" | jq -r 'if (type == "object") and ((.id | type) == "string") and (.id != "") then .id else empty end')"
  [ -n "$row_id" ] || row_id="entries[$((row_index - 1))]"

  if ! reason="$(gaia_reaper_row_check "$row_json")"; then
    printf '%s: %s\n' "$row_id" "$reason"
    violations=$((violations + 1))
  elif printf '%s' "$row_json" | jq -e 'type == "object" and has("reaped_by")' >/dev/null 2>&1; then
    printf '%s: carries the legacy reaped_by field; retention replaces it\n' "$row_id"
    violations=$((violations + 1))
  fi
done < <(jq -c '.entries[]' "$registry_path")

while IFS= read -r duplicate_id; do
  [ -n "$duplicate_id" ] || continue
  printf '%s: duplicate row id\n' "$duplicate_id"
  violations=$((violations + 1))
done < <(jq -r '[.entries[] | select(type == "object") | .id | select(type == "string")] | group_by(.) | .[] | select(length > 1) | .[0]' "$registry_path")

[ "$violations" -eq 0 ] || exit 1
exit 0
