#!/usr/bin/env bats
# Doc pins for the lifecycle page's handling of the requirements file and of
# AUDIT.md's author. Prose-to-prose only: whether the scripts behave as the
# sentences say is each script's own suite.
#
# GAIA_LIFECYCLE_MD overrides the page path so a mutated scratch copy can be
# driven through the same cases; it defaults to the real page.
#
# Assertion style: .claude/rules/bats-assertions.md.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LIFECYCLE_MD="${GAIA_LIFECYCLE_MD:-$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md}"

# The section from its heading up to the next second-level heading.
section_of() {
  awk -v heading="$1" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$LIFECYCLE_MD"
}

@test "post-merge close keeps the requirements file beside the summary" {
  local section
  section="$(section_of '## Post-merge close' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$section" ]
  [[ "$section" == *'`REQUIREMENTS.md`, when the SPEC folder holds one, is left in place beside `SUMMARY.md`'* ]]
  [[ "$section" == *'not a consolidation layer'* ]]
  # The removal step names the two layers only, never the requirements file.
  [[ "$section" == *'`rm <SPEC folder>/SPEC.md <SPEC folder>/AUDIT.md`'* ]]
}

@test "lifecycle names the fixer as the author of AUDIT.md" {
  local text sentence found=0
  text="$(tr '\n' ' ' <"$LIFECYCLE_MD" | tr -s ' ')"
  [[ "$text" != *'applier'* ]]
  while IFS= read -r sentence; do
    case "$sentence" in
      *AUDIT.md*writ*)
        found=1
        [[ "$sentence" == *fixer* ]] || { printf 'AUDIT.md author sentence names no fixer: %s\n' "$sentence" >&2; return 1; }
        ;;
    esac
  done < <(printf '%s' "$text" | sed 's/\. /.\n/g')
  [ "$found" -eq 1 ]
}
