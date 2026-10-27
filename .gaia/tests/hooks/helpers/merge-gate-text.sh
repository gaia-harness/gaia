#!/usr/bin/env bash
# merge-gate-text.sh: the merge gate's own text, for suites that read its
# source rather than run it. The gate is pr-merge-audit-check.sh plus the
# pr-merge-audit-check-<name>.sh siblings it sources, so a structural check
# reads all of them: a check reading the parent alone passes vacuously on code
# that moved into a sibling. The sibling names come from the parent's own
# loader list, never a directory glob; pr-merge-audit-check.bats holds that
# list to the files on disk.

# merge_gate_text_files <hook>: the hook, then each sibling its loader names.
merge_gate_text_files() {
  local hook="$1" name
  printf '%s\n' "$hook"
  while IFS= read -r name; do
    printf '%s\n' "${hook%.sh}-$name.sh"
  done < <(sed -n 's/^  \([a-z][a-z]*\):[a-z_]*$/\1/p' "$hook")
}

# merge_gate_text <hook>: the concatenated text of merge_gate_text_files.
merge_gate_text() {
  local text_file
  while IFS= read -r text_file; do
    cat "$text_file"
  done < <(merge_gate_text_files "$1")
}
