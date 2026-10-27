#!/usr/bin/env bash
# verify-audit-roster-registration.sh: the remit regions, the unowned and
# light-review reads, the machinery list, and the member-registration and
# remit-region shape invariants.
#
# One contiguous span of the roster check, moved here unchanged.
# verify-audit-roster.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. Its last line tells the parent it was read to the end.
#
# Bash 3.2 compatible (macOS-default bash).

# SC2016: single-quoted awk and printf text is literal, as in the parent.
# shellcheck disable=SC2016,SC2034,SC2154  # the roster globals cross files: the parent and the other siblings set and read them

region_records="$(_verify_roster_read_regions "$root" "$raw_records")"

# The `unowned:` list, read ONCE for the two readers that need it: the dialect
# gate in the awk pass below, and the coverage invariant at the bottom. Not an
# optimization -- both must see the same entries, and a second call is a
# second chance for the two to disagree about which lines the block holds.
unowned_records="$(_audit_scope_parse_unowned < "$config")"

# The light-review keys, read once for the dialect-and-coverage pass below and
# the scalar checks after it.
light_records="$(_audit_scope_parse_light < "$config")"

# The classifier's reading of the release-skip key, as SKIPCLASS records for the
# drift comparison. Absent from a library copy that predates the key, in which
# case there is no second reader to compare against: the SKIPREADER record is
# what arms the comparison, since an empty SKIPCLASS set alone cannot tell "the
# classifier keys no member" from "there is no classifier reading".
skip_class_records=""
if command -v audit_roster_release_skip_members >/dev/null 2>&1; then
  skip_class_records="$(printf 'SKIPREADER\n'; audit_roster_release_skip_members "$config" | awk 'NF { printf "SKIPCLASS\t%s\n", $1 }')"
fi

# --- Invariant: the shared machinery list is readable ------------------------
#
# Read the list as TEXT under --root: that is what makes the invariant
# testable at all, since a fixture can then inject a missing or empty list
# without mutating the repo's real one.

machinery_library="${root}/.claude/hooks/lib/audit-machinery.sh"

_roster_list_lines() {
  # <file> <shell-variable-name>: the heredoc list assigned to that variable.
  [ -f "$1" ] || return 0
  awk -v variable_name="$2" '
    index($0, variable_name "=") == 1 { inlist = 1; next }
    inlist && $0 == "EOF" { inlist = 0; next }
    inlist { print }
  ' "$1"
}

machinery_list="$(_roster_list_lines "$machinery_library" AUDIT_MACHINERY_PATHS)"

_report_unreadable_list() {
  # <file> <variable-name>
  findings=$((findings + 1))
  printf 'verify-audit-roster: FAIL unreadable-machinery-list\n'
  printf '  list: %s\n' "$2"
  printf '  file: %s\n' "$1"
  printf '  The list is empty, or the file does not carry it, so no member can be\n'
  printf '  confirmed as registered. Failing rather than passing every member.\n'
  printf '\n'
}

[ -n "$machinery_list" ] || _report_unreadable_list "$machinery_library" AUDIT_MACHINERY_PATHS

# --- Invariant: every member is registered -----------------------------------
#
# Membership in the list is decided by the matcher the digest itself uses
# (audit_path_is_machinery, from this script's own library copy), fed the list
# read under --root, so this check and the digest cannot disagree about what a
# list entry reaches. An unreadable list is already a finding above, so it
# reports no member a second time.

_self_machinery_library="${_self_library_directory:-}/audit-machinery.sh"
if [ -n "$machinery_list" ] && [ -f "$_self_machinery_library" ]; then
  # shellcheck source=/dev/null
  . "$_self_machinery_library"
  # shellcheck disable=SC2034 # read by audit_path_is_machinery, from the library
  AUDIT_MACHINERY_PATHS="$machinery_list"
fi
if [ -n "$machinery_list" ] && ! command -v audit_path_is_machinery >/dev/null 2>&1; then
  printf 'verify-audit-roster: machinery matcher unavailable in the roster-parsing library\n' >&2
  exit 1
fi

while IFS=$'\t' read -r kind name; do
  [ "$kind" = "MEMBER" ] || continue
  case "$name" in
    code-audit-*) ;;
    *)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL member-name-prefix\n'
      printf '  member: %s\n' "$name"
      printf '  roster: %s\n' "$config"
      printf '  A member name starts with `code-audit-`. The audit loop reads that\n'
      printf '  prefix to tell a Code Audit Team member from any other agent, so a\n'
      printf '  member without it is not held to the member contract. Rename the\n'
      printf '  member and its agent definition together.\n'
      printf '\n'
      continue
      ;;
  esac
  [ -n "$machinery_list" ] || continue
  if ! audit_path_is_machinery ".claude/agents/${name}.md"; then
    findings=$((findings + 1))
    printf 'verify-audit-roster: FAIL unregistered-member-definition\n'
    printf '  member:     %s\n' "$name"
    printf '  agent file: .claude/agents/%s.md\n' "$name"
    printf '  list:       %s\n' "$machinery_library"
    printf '  No AUDIT_MACHINERY_PATHS entry reaches this definition, so an edit\n'
    printf '  to the member'"'"'s own instructions rotates no digest and can merge\n'
    printf '  without that member reviewing it. Restore the list entry that\n'
    printf '  covers every member definition, `.claude/agents/code-audit-*.md`.\n'
    printf '\n'
  fi
done < <(printf '%s\n' "$raw_records" | awk -F'\t' '$1 == "MEMBER" && !seen[$2]++')

# --- Invariant: the remit region's SHAPE -------------------------------------
#
# Rendered here rather than in the awk pass below because these four say the
# region could not be read at all, so there is nothing for the parity comparison
# to compare. The writer refuses to repair a malformed pair, by design: it never
# deletes bytes outside a pair it can identify, so a human deletes the extra,
# unbalanced, or reversed markers first and re-runs it.

while IFS=$'\t' read -r kind name agent_relative_path start_count_or_line end_count_or_line; do
  case "$kind" in
    REGIONMISSING)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL missing-remit-region\n'
      printf '  member:     %s\n' "$name"
      printf '  agent file: %s\n' "$agent_relative_path"
      printf '  This definition carries no remit region, so nothing states which\n'
      printf '  files it owns in a form the roster can be compared against. The\n'
      printf '  region is never optional and deleting the markers is never an\n'
      printf '  escape from the parity it enforces.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONDUP)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL duplicate-remit-region\n'
      printf '  member:        %s\n' "$name"
      printf '  agent file:    %s\n' "$agent_relative_path"
      printf '  start markers: %s\n' "$start_count_or_line"
      printf '  end markers:   %s\n' "$end_count_or_line"
      printf '  More than one remit region appears in this definition, so which\n'
      printf '  pair states the member remit is ambiguous: a reader and the\n'
      printf '  dispatched member could take different ones as authoritative.\n'
      printf '  The writer will not repair this, because collapsing the pairs\n'
      printf '  would delete bytes outside a region it can identify. Delete the\n'
      printf '  extra pair by hand, leaving exactly one, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONUNBALANCED)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL unbalanced-remit-region\n'
      printf '  member:        %s\n' "$name"
      printf '  agent file:    %s\n' "$agent_relative_path"
      printf '  start markers: %s\n' "$start_count_or_line"
      printf '  end markers:   %s\n' "$end_count_or_line"
      printf '  The remit markers do not pair up, so where the region ends is\n'
      printf '  ambiguous: everything from the unclosed marker to the end of the\n'
      printf '  file reads as remit, or no region opens at all. The writer will\n'
      printf '  not repair this, because it never deletes bytes outside a pair it\n'
      printf '  can identify. Restore the missing marker by hand, leaving exactly\n'
      printf '  one balanced pair, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONREVERSED)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL reversed-remit-region\n'
      printf '  member:      %s\n' "$name"
      printf '  agent file:  %s\n' "$agent_relative_path"
      printf '  start line:  %s\n' "$start_count_or_line"
      printf '  end line:    %s\n' "$end_count_or_line"
      printf '  The end marker appears before the start marker, so nothing marks\n'
      printf '  where the region actually begins and ends in file order. The\n'
      printf '  writer will not repair this, because it never deletes bytes\n'
      printf '  outside a pair it can identify. Fix the marker order by hand,\n'
      printf '  leaving the start marker first, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
  esac
done < <(printf '%s\n' "$region_records")

_verify_roster_sibling_loaded=registration
