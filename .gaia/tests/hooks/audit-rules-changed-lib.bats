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
  [ -f "$RULES_LIBRARY" ]
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

# The split this pins: a convention rule still rotates every digest (it is
# machinery) but never throws away a sound anchor. A regression here
# reads as a green suite and a roster that silently re-reads its whole owned
# surface on every rule edit, so each path is asserted by name rather than by
# prefix. The merely-shared machinery rows and the light-review siblings must
# stay out of the global tier too.
@test "a non-global path is not a global rule" {
  local path
  audit_path_is_global_rule ".gaia/scripts/audit-light-route.sh" || return 1
  local rows=(
    .claude/hooks/lib/cross-repo-refusal.sh
    .github/audit/resolve-check-base.sh
    .gaia/scripts/audit-write-findings.sh
    .claude/rules/tailwind.md
    .claude/rules/code-comments.md
    .claude/rules/maintainers/hook-registration.md
    .claude/rules/anything-new.md
    .gaia/scripts/audit-light-route.sh.bak
    .gaia/scripts/audit-light-telemetry.sh
    .claude/hooks/lib/audit-light-route-lib.sh.bak
    .claude/hooks/lib/audit-quick-classify-lib.sh.bak
    .claude/agents/audit-light-reviewer.md.orig
  )
  for path in "${rows[@]}"; do
    echo "case: $path"
    run audit_path_is_global_rule "$path"
    [ "$status" -ne 0 ]
  done
}


@test "the two gate-governing rules under .claude/rules/ are global" {
  run audit_path_is_global_rule ".claude/rules/quality-gate.md"
  [ "$status" -eq 0 ]

  run audit_path_is_global_rule ".claude/rules/pr-merge.md"
  [ "$status" -eq 0 ]
}

@test "audit_path_is_member_rule matches only the member's own file" {
  local row path member expected
  local rows=(
    '.claude/agents/code-audit-frontend.md|code-audit-frontend|match'
    '.claude/agents/code-audit-frontend.md|code-audit-maintainer-shell|none'
    '.claude/agents/code-audit-frontend.md||none'
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r path member expected <<<"$row"
    echo "case: $path for '$member'"
    run audit_path_is_member_rule "$path" "$member"
    if [ "$expected" = match ]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
  done
}


# The shared member protocol is not a member's own definition, so the member
# tier never reaches it: only the global tier makes a change to it reset every
# member's anchor. An empty member evaluates the global tier only. Rows are
# member|comma-separated delta|expected tier (none: exit 1, nothing printed).
@test "audit_rules_reset_for reports each tier" {
  local row member delta tier
  local rows=(
    'code-audit-frontend|.gaia/VERSION|global'
    'code-audit-frontend|.claude/agents/code-audit-frontend.md|member'
    'code-audit-frontend|.claude/hooks/lib/cross-repo-refusal.sh,.gaia/scripts/audit-write-findings.sh|none'
    '|.claude/agents/code-audit-frontend.md|none'
    'code-audit-frontend|.gaia/scripts/audit-light-mark.sh|global'
    'code-audit-frontend|.claude/hooks/lib/audit-member-protocol.md|global'
    'code-audit-github-workflows|.claude/hooks/lib/audit-member-protocol.md|global'
    'code-audit-maintainer-shell|.claude/hooks/lib/audit-member-protocol.md|global'
    'code-audit-maintainer-node|.claude/hooks/lib/audit-member-protocol.md|global'
    '|.claude/hooks/lib/audit-member-protocol.md|global'
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r member delta tier <<<"$row"
    echo "case: '$member' on $delta"
    run audit_rules_reset_for "$member" <<<"$(tr ',' '\n' <<<"$delta")"
    if [ "$tier" = none ]; then
      [ "$status" -ne 0 ]
      [ -z "$output" ]
    else
      [ "$status" -eq 0 ]
      [ "$output" = "$(printf '%s\t%s' "$tier" "$delta")" ]
    fi
  done
}


@test "a #-comment line inside the literal is never matched as a path" {
  run audit_path_is_global_rule "# gaia:maintainer-only:start"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule "# gaia:maintainer-only:end"
  [ "$status" -ne 0 ]
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

# A global script split into siblings keeps its tier only if every sibling is
# listed too: a sibling left out turns an edit to the moved logic into a
# merely-shared change that resets nobody. The siblings are derived from disk by
# the split naming (<parent>-*.sh, or <stem>-*-lib.sh for a -lib.sh parent), so
# a new sibling is checked the moment it exists. The red case drops one derived
# sibling from a scratch copy of the library.
# bats test_tags=whole-tree
@test "every split sibling of a global script is a global rule and is also machinery" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  local entry sibling_pattern sibling relative siblings=""
  while IFS= read -r entry; do
    case "$entry" in "" | "#"*) continue ;; *.sh) ;; *) continue ;; esac
    case "$entry" in
      *-lib.sh) sibling_pattern="${entry%-lib.sh}-*-lib.sh" ;;
      *) sibling_pattern="${entry%.sh}-*.sh" ;;
    esac
    for sibling in "$REPO_ROOT"/$sibling_pattern; do
      [ -f "$sibling" ] || continue
      relative="${sibling#"$REPO_ROOT"/}"
      siblings="$siblings $relative"
      audit_path_is_global_rule "$relative" || { echo "sibling not a global rule: $relative (of $entry)" >&2; return 1; }
      audit_path_is_machinery "$relative" || { echo "sibling global but not machinery: $relative" >&2; return 1; }
    done
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"
  [ -n "$siblings" ]
  local dropped="${siblings# }"
  dropped="${dropped%% *}"
  local scratch_library="$BATS_TEST_TMPDIR/audit-rules-changed-sibling-scratch.sh"
  grep -vxF -- "$dropped" "$RULES_LIBRARY" >"$scratch_library"
  run bash -c '. "$1"; audit_path_is_global_rule "$2"' _ "$scratch_library" "$dropped"
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

# A GLOBAL or companion path that is not machinery resets anchors while
# rotating no digest, so a change to it demands no fresh clearance for the very
# file that resets them. The named rows (the light-review files, the quick-route
# corpus, the member protocol) must also be global rules; the rows derived from
# the real AUDIT_GLOBAL_RULES_PATHS and AUDIT_MEMBER_COMPANION_PATHS literals
# cover a new entry the moment it lands. Rows are checks|path.
# bats test_tags=whole-tree
@test "each global or companion path is also machinery" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  local row checks path entry row_member row_path global_count=0 companion_count=0
  local rows=(
    'global,machinery|.gaia/scripts/audit-light-route.sh'
    'global,machinery|.claude/hooks/lib/audit-light-route-lib.sh'
    'global,machinery|.claude/hooks/lib/audit-quick-classify-lib.sh'
    'global,machinery|.gaia/scripts/audit-light-mark.sh'
    'global,machinery|.claude/agents/audit-light-reviewer.md'
    'global,machinery|.gaia/scripts/tests/fixtures/audit-quick-corpus.json'
    'global,machinery|.claude/hooks/lib/audit-member-protocol.md'
  )
  while IFS= read -r entry; do
    case "$entry" in "" | "#"*) continue ;; esac
    global_count=$((global_count + 1))
    rows+=("machinery|$entry")
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"
  while IFS=' ' read -r row_member row_path; do
    case "$row_member" in "" | "#"*) continue ;; esac
    companion_count=$((companion_count + 1))
    rows+=("machinery|$row_path")
  done <<<"$AUDIT_MEMBER_COMPANION_PATHS"
  [ "$global_count" -gt 0 ]
  [ "$companion_count" -eq "${#COMPANION_PATHS[@]}" ]
  for row in "${rows[@]}"; do
    IFS='|' read -r checks path <<<"$row"
    echo "case: $checks $path"
    case "$checks" in global,*) audit_path_is_global_rule "$path" || return 1 ;; esac
    audit_path_is_machinery "$path" || return 1
  done
  run audit_path_is_global_rule ".gaia/scripts/tests/fixtures/audit-quick-corpus.json.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_member_rule ".claude/hooks/lib/audit-member-protocol.md" "code-audit-frontend"
  [ "$status" -ne 0 ]
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
