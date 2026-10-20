#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-machinery.sh, the one machinery-path
# matcher for the Code Audit Team.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  MACHINERY_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  [ -f "$MACHINERY_LIBRARY" ] || skip "audit-machinery.sh not present"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIBRARY"
}

# The gate-machinery lockstep set: files whose change must rotate every
# member's digest. An entry dropped from AUDIT_MACHINERY_PATHS fails open (a
# change to that file merges without forcing any re-audit), so each one is
# asserted by name. Files covered by a `/**` prefix entry are listed too, so
# narrowing that prefix reds here.

@test "every gate-machinery file is matched by audit_path_is_machinery" {
  unmatched=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    audit_path_is_machinery "$f" || unmatched="$unmatched $f"
  done <<'EOF'
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-base-provenance.sh
.claude/hooks/lib/audit-clearance.sh
.claude/hooks/lib/audit-digest.sh
.claude/hooks/lib/gaia-version.sh
.claude/hooks/lib/audit-bypass-stamp.sh
.claude/hooks/lib/cross-repo-refusal.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-resolve-scope.sh
.gaia/scripts/resolve-audit-members.sh
.gaia/scripts/audit-noop-detect.sh
.claude/hooks/pr-merge-audit-check.sh
.claude/hooks/post-audit-status.sh
.github/audit/resolve-audit-base.sh
.claude/agents/code-audit-frontend.md
.claude/agents/code-audit-maintainer-shell.md
.claude/agents/code-audit-maintainer-node.md
.claude/agents/code-audit-github-workflows.md
.claude/maintainers/harness-triage-threshold.md
.gaia/VERSION
EOF
  [ -z "$unmatched" ] || { printf 'not matched by audit_path_is_machinery:%s\n' "$unmatched" >&2; return 1; }
}

# The three light-review files decide whether a clearance is written without
# the member having run. Each is asserted by name, per element, so dropping one
# entry reds that path rather than a count.

@test "each light-review file is machinery" {
  for light_path in \
    .gaia/scripts/audit-light-route.sh \
    .gaia/scripts/audit-light-mark.sh \
    .claude/hooks/lib/audit-quick-classify-lib.sh \
    .claude/agents/audit-light-reviewer.md; do
    audit_path_is_machinery "$light_path" || { echo "not machinery: $light_path" >&2; return 1; }
  done
}

@test "the batch classifier flags each light-review file as machinery" {
  run audit_machinery_flags <<'PATHS'
.gaia/scripts/audit-light-route.sh
.gaia/scripts/audit-light-mark.sh
.claude/hooks/lib/audit-quick-classify-lib.sh
.claude/agents/audit-light-reviewer.md
PATHS
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  for line in "${lines[@]}"; do
    case "$line" in
      *$'\t'1) ;;
      *) echo "not flagged: $line" >&2; return 1 ;;
    esac
  done
}

# The quick-route corpus decides what the classifier is proven against, so a
# change to it rotates every digest. It is a maintainer-only entry: the region
# fence around it keeps it out of an adopter bundle.
# bats test_tags=whole-tree
@test "the quick-route corpus is machinery and sits inside a maintainer-only region" {
  audit_path_is_machinery ".gaia/scripts/tests/fixtures/audit-quick-corpus.json" || return 1
  awk -v marker="gaia:""maintainer-only" '
    index($0, "# " marker ":start") { inside = 1; next }
    index($0, "# " marker ":end") { inside = 0; next }
    index($0, ".gaia/scripts/tests/fixtures/audit-quick-corpus.json") == 1 { seen++; if (!inside) bad++ }
    END { exit (seen == 1 && bad == 0) ? 0 : 1 }
  ' "$MACHINERY_LIBRARY"
}

# bats test_tags=whole-tree
@test "the loop unit definition is not machinery: it orchestrates rounds and writes no clearance" {
  run audit_path_is_machinery ".claude/agents/audit-loop-unit.md"
  [ "$status" -ne 0 ]
}

@test "a sibling of a light-review file is not machinery" {
  # Entries are exact paths, so a backup copy or a neighbor never inherits the
  # status. The guard can fail: the real entry matches, these must not.
  audit_path_is_machinery ".gaia/scripts/audit-light-route.sh" || return 1
  run audit_path_is_machinery ".gaia/scripts/audit-light-route.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_machinery ".gaia/scripts/audit-light-marks.sh"
  [ "$status" -ne 0 ]
  run audit_path_is_machinery ".claude/agents/audit-light-reviewer.md.orig"
  [ "$status" -ne 0 ]
}
