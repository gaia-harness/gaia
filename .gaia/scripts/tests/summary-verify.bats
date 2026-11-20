#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/summary-verify.sh: the deterministic verify-gate
# every consolidation producer (the orchestrator's consolidation step and the
# pre-flight sweep's cold consolidation) calls before removing SPEC.md /
# AUDIT.md at merge. Exercises the pinned SUMMARY.md shape against every
# malformed/absent/empty variant, the optional Divergence section, and the
# wiki_promote_default vocabulary.
#
# Fixtures are inline heredocs written to $BATS_TEST_TMPDIR; this suite never
# touches real .gaia/local.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../summary-verify.sh"
  [ -x "$SCRIPT" ]
  FIXTURE="$BATS_TEST_TMPDIR/SUMMARY.md"
}

# --- 1. well-formed passes ---------------------------------------------------

@test "well-formed SUMMARY.md (frontmatter + H1 + body) exits 0" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# Unify spec and plan knowledge lifecycles

The orchestrator writes PROGRESS.md during execution; SUMMARY.md is produced
once at merge by layered override-resolution.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# --- 2. optional Divergence section still passes -----------------------------

@test "a SUMMARY.md with a Divergence section still exits 0" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: yes
wiki_promote_targets: [modules]
---
# Retention symmetry for spec-less plans

Spec-less plans are reduced to SUMMARY.md instead of deleted.

## Divergence
The age-backstop reap was deferred to a follow-up task.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# --- 3. a SUMMARY.md missing any required part -------------------------------

@test "a SUMMARY.md missing any required part exits 1 naming it (absent, empty, no frontmatter, no default key, no targets key, no H1, empty body)" {
  local case_name expected_message
  for case_name in absent empty no-frontmatter no-default no-targets no-h1 empty-body; do
    expected_message=""
    case "$case_name" in
      absent) rm -f "$FIXTURE" ;;
      empty) : > "$FIXTURE" ;;
      no-frontmatter)
        expected_message="frontmatter"
        printf '# A title with no frontmatter at all\n\nSome body text.\n' > "$FIXTURE" ;;
      no-default)
        expected_message="wiki_promote_default"
        printf -- '---\nwiki_promote_targets: [decisions]\n---\n# A title\n\nSome body text.\n' > "$FIXTURE" ;;
      no-targets)
        expected_message="wiki_promote_targets"
        printf -- '---\nwiki_promote_default: ask\n---\n# A title\n\nSome body text.\n' > "$FIXTURE" ;;
      no-h1)
        expected_message="H1"
        printf -- '---\nwiki_promote_default: ask\nwiki_promote_targets: [decisions]\n---\nSome body text with no H1 title at all.\n' > "$FIXTURE" ;;
      empty-body)
        expected_message="empty body"
        printf -- '---\nwiki_promote_default: ask\nwiki_promote_targets: [decisions]\n---\n# A title with nothing after it\n\n' > "$FIXTURE" ;;
    esac
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 1 ] || { echo "case $case_name: status $status"; return 1; }
    if [ -n "$expected_message" ]; then
      grep -qF -- "$expected_message" <<<"$output" || { echo "case $case_name: message $output"; return 1; }
    fi
  done
}

# --- 10. wiki_promote_default vocabulary ------------------------------------------

_write_with_default() {
  printf -- '---\nwiki_promote_default: %s\nwiki_promote_targets: [decisions]\n---\n# A title\n\nSome body text.\n' "$1" > "$FIXTURE"
}

@test "wiki_promote_default accepts yes, ask, no and their quoted forms" {
  for value in yes ask no '"yes"' "'ask'" '"no"'; do
    _write_with_default "$value"
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ] || { echo "rejected: $value: $output"; return 1; }
  done
}

@test "wiki_promote_default outside yes/ask/no (including empty) exits 1 naming the value" {
  for value in maybe True 1 YES true false "'false'" '"yes' "yes'" ""; do
    _write_with_default "$value"
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 1 ] || { echo "accepted: $value"; return 1; }
    grep -qF -- "wiki_promote_default must be yes, ask or no (got '$value')" <<<"$output" || { echo "message: $output"; return 1; }
  done
}

@test "only the first wiki_promote_default line is judged" {
  printf -- '---\nwiki_promote_default: ask\nwiki_promote_default: maybe\nwiki_promote_targets: []\n---\n# A title\n\nBody.\n' > "$FIXTURE"
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# --- 11. a yes default needs a target to promote to ----------------------------

_write_with_targets() {
  printf -- '---\nwiki_promote_default: %s\nwiki_promote_targets:%s\n---\n# A title\n\nSome body text.\n' "$1" "$2" > "$FIXTURE"
}

@test "yes with an empty wiki_promote_targets exits 1" {
  for targets in ' []' ' [ ]' '' ' '; do
    _write_with_targets yes "$targets"
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 1 ] || { echo "accepted targets: '$targets'"; return 1; }
    grep -qF -- "wiki_promote_default yes needs a non-empty wiki_promote_targets" <<<"$output" || { echo "message: $output"; return 1; }
  done
}

@test "yes with a non-empty wiki_promote_targets exits 0, inline or block form" {
  _write_with_targets yes ' [concepts]'
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ] || { echo "inline: $output"; return 1; }
  _write_with_targets yes $'\n  - concepts\n  - modules'
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "ask and no tolerate an empty wiki_promote_targets" {
  for default_value in ask no; do
    _write_with_targets "$default_value" ' []'
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ] || { echo "rejected: $default_value: $output"; return 1; }
  done
}
