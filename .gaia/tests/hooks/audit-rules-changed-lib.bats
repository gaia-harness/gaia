#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-rules-changed.sh, the two-tier reset
# predicate for a Code Audit Team member's per-member review base.
#
# The two tiers are asymmetric in blast radius: a GLOBAL match resets every
# member's anchor, a MEMBER match resets only the member whose own agent
# definition changed, and everything else in the shared machinery set resets
# nobody (it still rotates digests, it just does not throw away a sound
# incremental anchor). These tests pin that boundary directly against the
# real AUDIT_GLOBAL_RULES_PATHS literal rather than a restated copy, so the
# suite stays honest if the literal grows.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  RULES_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh"
  [ -f "$RULES_LIBRARY" ] || skip "audit-rules-changed.sh not present"
  # shellcheck source=/dev/null
  . "$RULES_LIBRARY"
}

@test "every path in AUDIT_GLOBAL_RULES_PATHS is matched by audit_path_is_global_rule" {
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in "#"*) continue ;; esac
    case "$entry" in
      *"/**") probe="${entry%\*\*}quality-gate.md" ;;
      *) probe="$entry" ;;
    esac
    audit_path_is_global_rule "$probe" || { echo "not matched: $probe" >&2; return 1; }
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"
}

@test "a merely-shared machinery path is not matched by audit_path_is_global_rule" {
  run audit_path_is_global_rule ".claude/hooks/lib/cross-repo-refusal.sh"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".github/audit/resolve-check-base.sh"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".gaia/scripts/audit-write-findings.sh"
  [ "$status" -ne 0 ]
}

@test "the two gate-governing rules under .claude/rules/ are global" {
  run audit_path_is_global_rule ".claude/rules/quality-gate.md"
  [ "$status" -eq 0 ]

  run audit_path_is_global_rule ".claude/rules/pr-merge.md"
  [ "$status" -eq 0 ]
}

# The split this pins: a convention rule still rotates every digest (it is
# machinery), but it no longer throws away a sound anchor. A regression here
# reads as a green suite and a roster that silently re-reads its whole owned
# surface on every rule edit, so it is asserted by name rather than by prefix.
@test "a coding-convention rule under .claude/rules/ is not global" {
  run audit_path_is_global_rule ".claude/rules/tailwind.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/code-comments.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/maintainers/hook-registration.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/anything-new.md"
  [ "$status" -ne 0 ]
}

@test "audit_path_is_member_rule matches a member's own agent file and no other" {
  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" "code-audit-frontend"
  [ "$status" -eq 0 ]

  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" "code-audit-maintainer-shell"
  [ "$status" -ne 0 ]
}

@test "audit_path_is_member_rule returns 1 for an empty member" {
  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" ""
  [ "$status" -ne 0 ]
}

@test "audit_rules_reset_for reports the global tier on a global-rules path" {
  run audit_rules_reset_for "code-audit-frontend" <<<".gaia/VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.gaia/VERSION')" ]
}

@test "audit_rules_reset_for reports the member tier on the member's own agent file" {
  run audit_rules_reset_for "code-audit-frontend" <<<".claude/agents/code-audit-frontend.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'member\t.claude/agents/code-audit-frontend.md')" ]
}

@test "audit_rules_reset_for returns 1 on a delta of only merely-shared machinery" {
  run audit_rules_reset_for "code-audit-frontend" <<'EOF'
.claude/hooks/lib/cross-repo-refusal.sh
.gaia/scripts/audit-write-findings.sh
EOF
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an empty member evaluates the global tier only" {
  run audit_rules_reset_for "" <<<".claude/agents/code-audit-frontend.md"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a #-comment line inside the literal is never matched as a path" {
  run audit_path_is_global_rule "# gaia:maintainer-only:start"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule "# gaia:maintainer-only:end"
  [ "$status" -ne 0 ]
}

# A GLOBAL path that is not machinery resets every member's anchor while
# rotating no digest, so a change to it demands no fresh clearance for the very
# file that resets everyone. Walks the real literal, so a new entry is covered
# the moment it lands.
@test "every path in AUDIT_GLOBAL_RULES_PATHS is also matched by audit_path_is_machinery" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  checked=0
  unmatched=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in "#"*) continue ;; esac
    checked=$((checked + 1))
    audit_path_is_machinery "$entry" || unmatched="$unmatched $entry"
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"

  [ "$checked" -gt 0 ]
  [ -z "$unmatched" ] || { printf 'global rule not machinery:%s\n' "$unmatched" >&2; return 1; }
}

# The router with its helper library, the light-marker script and the reviewer
# definition decide whether a clearance is believed, so a change to any of them
# resets every member's anchor. Asserted per path, with a sibling that must
# stay out.

@test "each light-review file is a global rule and is also machinery" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  for light_path in \
    .gaia/scripts/audit-light-route.sh \
    .claude/hooks/lib/audit-light-route-lib.sh \
    .claude/hooks/lib/audit-quick-classify-lib.sh \
    .gaia/scripts/audit-light-mark.sh \
    .claude/agents/audit-light-reviewer.md; do
    audit_path_is_global_rule "$light_path" || { echo "not a global rule: $light_path" >&2; return 1; }
    audit_path_is_machinery "$light_path" || { echo "global but not machinery: $light_path" >&2; return 1; }
  done
}

# The classifier library decides whether a quick clearance is believed, so a
# change to it resets every member's anchor. The red case runs the same tier
# check against a scratch copy of the library with that one entry removed, so
# the assertion is shown able to fail.
# bats test_tags=whole-tree
@test "the quick classifier library is a global rule, and the tier check fails on a copy without its entry" {
  local scratch_library="$BATS_TEST_TMPDIR/audit-rules-changed-scratch.sh" classifier=".claude/hooks/lib/audit-quick-classify-lib.sh"
  run audit_rules_reset_for "code-audit-frontend" <<<"$classifier"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t%s' "$classifier")" ]
  grep -vxF -- "$classifier" "$RULES_LIBRARY" >"$scratch_library"
  [ "$(wc -l <"$RULES_LIBRARY" | tr -d ' ')" -eq $(($(wc -l <"$scratch_library" | tr -d ' ') + 1)) ]
  run bash -c '. "$1"; audit_path_is_global_rule "$2"' _ "$scratch_library" "$classifier"
  [ "$status" -ne 0 ]
  run bash -c '. "$1"; audit_path_is_global_rule "$2"' _ "$RULES_LIBRARY" "$classifier"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "the quick-route corpus is a global rule and is also machinery" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  audit_path_is_global_rule ".gaia/scripts/tests/fixtures/audit-quick-corpus.json" || return 1
  audit_path_is_machinery ".gaia/scripts/tests/fixtures/audit-quick-corpus.json" || return 1
  run audit_path_is_global_rule ".gaia/scripts/tests/fixtures/audit-quick-corpus.json.bak"
  [ "$status" -ne 0 ]
}

@test "audit_rules_reset_for reports the global tier for a light-review file" {
  run audit_rules_reset_for "code-audit-frontend" <<<".gaia/scripts/audit-light-mark.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.gaia/scripts/audit-light-mark.sh')" ]
}

@test "a sibling of a light-review file is not a global rule" {
  audit_path_is_global_rule ".gaia/scripts/audit-light-route.sh" || return 1
  run audit_path_is_global_rule ".gaia/scripts/audit-light-route.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".gaia/scripts/audit-light-telemetry.sh"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".claude/hooks/lib/audit-light-route-lib.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".claude/hooks/lib/audit-quick-classify-lib.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".claude/agents/audit-light-reviewer.md.orig"
  [ "$status" -ne 0 ]
}

# The shared member protocol is not a member's own definition, so the member
# tier never reaches it. Only the global tier makes a change to it reset every
# member's anchor, and only machinery membership makes it rotate digests.

@test "the member protocol is a global rule and is also machinery" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  audit_path_is_global_rule ".claude/hooks/lib/audit-member-protocol.md" || return 1
  audit_path_is_machinery ".claude/hooks/lib/audit-member-protocol.md" || return 1
  run audit_path_is_member_rule ".claude/hooks/lib/audit-member-protocol.md" "code-audit-frontend"
  [ "$status" -ne 0 ]
}

@test "a change to the member protocol resets every member's anchor in the global tier" {
  local member
  for member in code-audit-frontend code-audit-github-workflows code-audit-maintainer-shell code-audit-maintainer-node; do
    run audit_rules_reset_for "$member" <<<".claude/hooks/lib/audit-member-protocol.md"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'global\t.claude/hooks/lib/audit-member-protocol.md')" ]
  done
  run audit_rules_reset_for "" <<<".claude/hooks/lib/audit-member-protocol.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.claude/hooks/lib/audit-member-protocol.md')" ]
}

@test "the member-protocol cases can fail: a library without the protocol line answers not-global" {
  local mutant="$BATS_TEST_TMPDIR/rules-without-protocol.sh"
  grep -vF ".claude/hooks/lib/audit-member-protocol.md" "$RULES_LIBRARY" > "$mutant"
  # The mutant really dropped the entry, so the red answers below are the
  # tier mapping's, not an unreadable file's.
  grep -qF "AUDIT_GLOBAL_RULES_PATHS" "$mutant"
  # shellcheck source=/dev/null
  . "$mutant"
  run audit_path_is_global_rule ".claude/hooks/lib/audit-member-protocol.md"
  [ "$status" -ne 0 ]
  run audit_rules_reset_for "code-audit-frontend" <<<".claude/hooks/lib/audit-member-protocol.md"
  [ "$status" -ne 0 ]
}

# The member companion tier: files that decide only what one member reviews
# and how. They reset that member's anchor and nobody else's, and never join
# the global tier.

COMPANION_PATHS=(
  .claude/hooks/lib/audit-frontend-refuter.md
  .claude/agents/audit-rule-specialist.md
  .claude/agents/audit-refuter.md
  .gaia/scripts/audit-frontend-oracles.sh
)

@test "each frontend companion resets only the frontend member and is not a global rule" {
  local companion_path other_member
  [ "${#COMPANION_PATHS[@]}" -eq 4 ]
  for companion_path in "${COMPANION_PATHS[@]}"; do
    run audit_rules_reset_for "code-audit-frontend" <<<"$companion_path"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'member\t%s' "$companion_path")" ]
    for other_member in code-audit-maintainer-shell code-audit-maintainer-node code-audit-github-workflows ""; do
      run audit_rules_reset_for "$other_member" <<<"$companion_path"
      [ "$status" -ne 0 ]
      [ -z "$output" ]
    done
    run audit_path_is_global_rule "$companion_path"
    [ "$status" -ne 0 ]
  done
}

@test "the companion cases can fail: a copy with the companion rows emptied prints nothing for the frontend member" {
  local scratch_library="$BATS_TEST_TMPDIR/rules-without-companions.sh" companion_path
  grep -v '^code-audit-frontend ' "$RULES_LIBRARY" >"$scratch_library"
  grep -qF "AUDIT_MEMBER_COMPANION_PATHS" "$scratch_library"
  for companion_path in "${COMPANION_PATHS[@]}"; do
    run bash -c '. "$1"; audit_rules_reset_for code-audit-frontend <<<"$2"' _ "$scratch_library" "$companion_path"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "a companion row for one member never matches another member or a different path" {
  run audit_path_is_member_rule ".claude/agents/audit-refuter.md" "code-audit-maintainer-shell"
  [ "$status" -ne 0 ]
  run audit_path_is_member_rule ".claude/agents/audit-refuter.md.bak" "code-audit-frontend"
  [ "$status" -ne 0 ]
  run audit_path_is_member_rule ".claude/agents/audit-refuter.md" ""
  [ "$status" -ne 0 ]
  run audit_path_is_member_rule "# The refuter reference, the rule specialist and refuter the frontend member" "code-audit-frontend"
  [ "$status" -ne 0 ]
}

# A companion that is not machinery resets one member's anchor while rotating
# no digest, so a change to it would demand no fresh clearance.
@test "every companion path in AUDIT_MEMBER_COMPANION_PATHS is also matched by audit_path_is_machinery" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  local checked=0 unmatched="" row_member row_path
  while IFS=' ' read -r row_member row_path; do
    case "$row_member" in ""|"#"*) continue ;; esac
    checked=$((checked + 1))
    audit_path_is_machinery "$row_path" || unmatched="$unmatched $row_path"
  done <<<"$AUDIT_MEMBER_COMPANION_PATHS"

  [ "$checked" -eq "${#COMPANION_PATHS[@]}" ]
  [ -z "$unmatched" ] || { printf 'companion not machinery:%s\n' "$unmatched" >&2; return 1; }
}

@test "the machinery check can fail: a scratch companion row for a non-machinery path is reported" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  local scratch_library="$BATS_TEST_TMPDIR/rules-extra-companion.sh" unmatched="" row_member row_path
  awk '{ print } /^code-audit-frontend \.gaia\/scripts\/audit-frontend-oracles\.sh$/ { print "code-audit-frontend frontend/app/not-machinery.ts" }' "$RULES_LIBRARY" >"$scratch_library"
  grep -qF "frontend/app/not-machinery.ts" "$scratch_library"
  # shellcheck source=/dev/null
  . "$scratch_library"
  while IFS=' ' read -r row_member row_path; do
    case "$row_member" in ""|"#"*) continue ;; esac
    audit_path_is_machinery "$row_path" || unmatched="$unmatched $row_path"
  done <<<"$AUDIT_MEMBER_COMPANION_PATHS"
  [ "$unmatched" = " frontend/app/not-machinery.ts" ]
}

# bash 3.2 mis-parses an apostrophe inside a command substitution that wraps a
# heredoc, so the companion literal must hold none.
extract_companion_literal() {
  awk '
    /^AUDIT_MEMBER_COMPANION_PATHS="\$\(cat <<.EOF.\)?$/ { inside = 1; next }
    inside && /^EOF$/ { exit }
    inside { print }
  ' "$1"
}

@test "the companion literal holds no apostrophe and the library parses under bash -n" {
  local literal
  literal="$(extract_companion_literal "$RULES_LIBRARY")"
  [ -n "$literal" ]
  [ "$(printf '%s\n' "$literal" | grep -c '^code-audit-frontend ')" -eq "${#COMPANION_PATHS[@]}" ]
  case "$literal" in *"'"*) echo "apostrophe in companion literal" >&2; return 1 ;; esac
  cp "$RULES_LIBRARY" "$BATS_TEST_TMPDIR/rules-parse-check.sh"
  run bash -n "$BATS_TEST_TMPDIR/rules-parse-check.sh"
  [ "$status" -eq 0 ]
}

@test "the apostrophe check can fail: a scratch copy with an apostrophe in a companion comment is caught" {
  local scratch_library="$BATS_TEST_TMPDIR/rules-apostrophe.sh" literal
  awk '{ print } /^# The refuter reference, the rule specialist/ { print "# the member'"'"'s anchor" }' "$RULES_LIBRARY" >"$scratch_library"
  literal="$(extract_companion_literal "$scratch_library")"
  [ -n "$literal" ]
  case "$literal" in *"'"*) return 0 ;; esac
  echo "apostrophe not detected" >&2
  return 1
}

# The release scrub strips maintainer-only regions from shell files. The
# companion rows and the machinery entries sit outside any fence, so they must
# survive it in the stripped copy.
scrub_scratch_copies() {
  local staging_directory="$1" machinery_source="$2" rules_source="$3"
  mkdir -p "$staging_directory/.claude/hooks/lib"
  cp "$machinery_source" "$staging_directory/.claude/hooks/lib/audit-machinery.sh"
  cp "$rules_source" "$staging_directory/.claude/hooks/lib/audit-rules-changed.sh"
  "$REPO_ROOT/.gaia/cli/gaia-maintainer" release scrub "$staging_directory" --config "$REPO_ROOT/.gaia/release-scrub.yml" --json >"$BATS_TEST_TMPDIR/scrub-report.json"
}

assert_scrubbed_companions_survive() {
  local staging_directory="$1" companion_path
  for companion_path in "${COMPANION_PATHS[@]}"; do
    grep -qF -- "$companion_path" "$staging_directory/.claude/hooks/lib/audit-rules-changed.sh" || { echo "stripped: $companion_path" >&2; return 1; }
  done
  for companion_path in .claude/agents/audit-rule-specialist.md .claude/agents/audit-refuter.md .gaia/scripts/audit-frontend-oracles.sh; do
    grep -qxF -- "$companion_path" "$staging_directory/.claude/hooks/lib/audit-machinery.sh" || { echo "stripped: $companion_path" >&2; return 1; }
  done
  return 0
}

# bats test_tags=whole-tree
@test "the companion rows and machinery entries survive the release scrub" {
  local staging_directory="$BATS_TEST_TMPDIR/staging"
  scrub_scratch_copies "$staging_directory" "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$RULES_LIBRARY"
  # The scrub really ran: the maintainer-only fenced entry is gone.
  grep -qF ".claude/hooks/lib/audit-member-protocol.md" "$staging_directory/.claude/hooks/lib/audit-rules-changed.sh" && return 1
  assert_scrubbed_companions_survive "$staging_directory"
}

# bats test_tags=whole-tree
@test "the scrub check can fail: a companion row moved inside a maintainer-only fence is lost" {
  local staging_directory="$BATS_TEST_TMPDIR/staging-red" scratch_library="$BATS_TEST_TMPDIR/rules-fenced-companion.sh"
  awk -v marker="gaia:""maintainer-only" '
    /^code-audit-frontend \.claude\/agents\/audit-refuter\.md$/ { print "# " marker ":start"; print; print "# " marker ":end"; next }
    { print }
  ' "$RULES_LIBRARY" >"$scratch_library"
  scrub_scratch_copies "$staging_directory" "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$scratch_library"
  run assert_scrubbed_companions_survive "$staging_directory"
  [ "$status" -ne 0 ]
}
