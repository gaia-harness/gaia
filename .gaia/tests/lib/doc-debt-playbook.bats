#!/usr/bin/env bats
#
# Doc-conformance suite for the split of `/gaia-debt`'s playbook
# (.claude/skills/gaia/references/debt.md and the sub-references under
# .claude/skills/gaia/references/debt/): a sub-reference read is a step a model
# can skip, so `debt.md` routes to every debt/*.md through a `Read` line and
# names no sub-reference that does not exist. No lint guard covers these links
# yet, so the two checks stay here.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAYBOOK_DIR="${DOC_DEBT_PLAYBOOK_DIR:-$REPO_ROOT/.claude/skills/gaia/references}"
}

# --- every sub-reference is routed, and every route resolves ----------------

ROUTE_PREFIX='Read `.claude/skills/gaia/references/debt/'

# every_sub_reference_routed <references-dir>: succeeds when debt.md holds a
# `Read` line naming each debt/*.md by its repo path. The set comes from the
# directory, and an independent count catches a glob that read fewer files than
# exist; an empty set fails rather than passing vacuously.
every_sub_reference_routed() {
  local dir="$1" file name count=0 expected=0
  [ -f "$dir/debt.md" ] || return 1
  for file in "$dir"/debt/*.md; do
    [ -f "$file" ] && expected=$((expected + 1))
  done
  [ "$expected" -ge 1 ] || return 1
  for file in "$dir"/debt/*.md; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    count=$((count + 1))
    if ! grep -qF -- "${ROUTE_PREFIX}${name}\`" "$dir/debt.md"; then
      printf 'debt/%s has no Read line in debt.md\n' "$name" >&2
      return 1
    fi
  done
  [ "$count" -eq "$expected" ] || return 1
  return 0
}

@test "every sub-reference is routed from debt.md by a Read line" {
  every_sub_reference_routed "$PLAYBOOK_DIR"
}

# no_orphan_route <references-dir>: succeeds when every debt/<name>.md that
# debt.md names, by full repo path or by the short form, exists. A path such
# as `file-tech-debt/SKILL.md` is not a sub-reference, so the match requires
# `debt/` to start a path segment that is not part of a longer name.
no_orphan_route() {
  local dir="$1" names name
  names="$(grep -oE -- '(^|[^A-Za-z0-9_-])debt/[A-Za-z0-9_-]+\.md' "$dir/debt.md" | sed -E 's|^.*debt/||' | sort -u)"
  [ -n "$names" ] || return 1
  while IFS= read -r name; do
    if [ ! -f "$dir/debt/$name" ]; then
      printf 'debt.md names missing debt/%s\n' "$name" >&2
      return 1
    fi
  done <<<"$names"
  return 0
}

@test "every sub-reference debt.md names exists" {
  no_orphan_route "$PLAYBOOK_DIR"
}
