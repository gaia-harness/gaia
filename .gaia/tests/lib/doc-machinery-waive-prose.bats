#!/usr/bin/env bats
# The machinery-path waive rule is stated in
# `wiki/concepts/Audit Round Procedure.md`'s `#### Cross-remit findings`
# section. The waive is fail-closed (an empty eligibility set disengages it
# rather than opening it) and files nothing. Both statements guard the audit
# disposition, so they are pinned here.
#
# Assertion style: .claude/rules/bats-assertions.md.

# extract_section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> (inclusive) up to,
# excluding, the next line matching <terminator_ERE>.
extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# extract_section_or_fail <file> <start_ERE> <terminator_ERE>
# extract_section, plus a guard: fails loudly, rather than passing
# vacuously, when the start anchor matches nothing (a renamed or deleted
# heading).
extract_section_or_fail() {
  local extracted_section
  extracted_section="$(extract_section "$1" "$2" "$3")"
  [ -n "$extracted_section" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  printf '%s\n' "$extracted_section"
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WIKI="$ROOT/wiki/concepts/Audit Round Procedure.md"
}

@test "Group 1: cross-remit section states an empty eligibility set disengages rather than opens the waive" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "disengages" || return 1
  printf '%s\n' "$section" | grep -qF -- "rather than opening it" || return 1
}

@test "Group 4: cross-remit section states the waive files nothing" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "no tech-debt issue" || return 1
  printf '%s\n' "$section" | grep -qF -- "no issue number" || return 1
  printf '%s\n' "$section" | grep -qF -- ".gaia/local/debt/refresh-requested" || return 1
}
