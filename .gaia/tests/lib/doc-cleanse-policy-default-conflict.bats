#!/usr/bin/env bats
# doc-grep coverage for how /gaia-cleanse catches a memory entry that
# contradicts a default the wiki states, stated only as prose read by the
# Stage 1 classifier and by the classification-verification round's CF lens.
#
# The pins are key terms, not sentences, so a rewrap or rewording that keeps
# the instruction stays green:
#   - research.md's CONFLICT bullet tells Stage 1 to search the wiki for the
#     default an action-prescribing entry touches ("prescribes or forbids" plus
#     "default"). Without it, an entry sharing no phrase with the wiki's
#     settings row classifies KEEP-LOCAL.
#   - verification-round.md's CF lens walks the KEEP-LOCAL and NO-MATCH
#     entries. Every lens otherwise iterates actions, and an entry classified
#     KEEP-LOCAL has none, so without it the round stamps a report hardened
#     over entries it never read.
#
# Assertion style: .claude/rules/bats-assertions.md.

# section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> up to, excluding, the next
# line matching <terminator_ERE>, newlines collapsed to spaces so a rewrapped
# phrase still matches. Fails when the start anchor matches nothing, so a
# renamed bullet reads as red rather than as a vacuous pass.
section() {
  local extracted_section
  extracted_section="$(awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1")"
  [ -n "$extracted_section" ] || {
    echo "anchor '${2}' matched nothing in ${1}" >&2
    return 1
  }
  printf '%s\n' "$extracted_section" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'
}

# conflict_bullet_searches_defaults <research.md>
conflict_bullet_searches_defaults() {
  local bullet
  bullet="$(section "$1" '^- [*][*]CONFLICT[*][*]' '^$')" || return 1
  grep -qF -- 'prescribes or forbids' <<<"$bullet" || { echo "CONFLICT bullet lacks 'prescribes or forbids'" >&2; return 1; }
  grep -qF -- 'default' <<<"$bullet" || { echo "CONFLICT bullet lacks 'default'" >&2; return 1; }
}

# cf_lens_walks_unacted_entries <verification-round.md>
cf_lens_walks_unacted_entries() {
  local lens
  lens="$(section "$1" '^- [*][*]CF, conflict adjudication' '^- [*][*]ES,')" || return 1
  grep -qF -- 'KEEP-LOCAL' <<<"$lens" || { echo "CF lens lacks 'KEEP-LOCAL'" >&2; return 1; }
  grep -qF -- 'NO-MATCH' <<<"$lens" || { echo "CF lens lacks 'NO-MATCH'" >&2; return 1; }
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESEARCH="$ROOT/.claude/skills/gaia/references/cleanse/research.md"
  ROUND="$ROOT/.claude/skills/gaia/references/cleanse/verification-round.md"
  [ -s "$RESEARCH" ] || { echo "missing or empty $RESEARCH" >&2; return 1; }
  [ -s "$ROUND" ] || { echo "missing or empty $ROUND" >&2; return 1; }
}

@test "Stage 1's CONFLICT bullet searches the wiki for the default an action-prescribing entry touches" {
  run conflict_bullet_searches_defaults "$RESEARCH"
  [ "$status" -eq 0 ]
}

@test "red twin: a CONFLICT bullet without the action-prescribing search fails the pin" {
  local scratch="$BATS_TEST_TMPDIR/research.md"
  sed 's/prescribes or forbids//g' "$RESEARCH" >"$scratch"
  run conflict_bullet_searches_defaults "$scratch"
  [ "$status" -eq 1 ]
  grep -qF -- "lacks 'prescribes or forbids'" <<<"$output"
}

@test "the verification round's CF lens walks the KEEP-LOCAL and NO-MATCH entries" {
  run cf_lens_walks_unacted_entries "$ROUND"
  [ "$status" -eq 0 ]
}

@test "red twin: a CF lens that skips NO-MATCH entries fails the pin" {
  local scratch="$BATS_TEST_TMPDIR/verification-round.md"
  sed 's/NO-MATCH//g' "$ROUND" >"$scratch"
  run cf_lens_walks_unacted_entries "$scratch"
  [ "$status" -eq 1 ]
  grep -qF -- "lacks 'NO-MATCH'" <<<"$output"
}
