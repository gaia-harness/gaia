#!/usr/bin/env bats
#
# Doc-conformance suite: the wiki index lists the Test Layering page, and every
# wikilink in the pages CHANGED_PAGES names resolves to a wiki page.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Test Layering.md"
  ROUTING="$REPO_ROOT/wiki/modules/Routing.md"
  INDEX="$REPO_ROOT/wiki/index.md"
  CHANGED_PAGES=(
    "$PAGE"
    "$ROUTING"
    "$REPO_ROOT/wiki/modules/Testing.md"
    "$REPO_ROOT/wiki/modules/Claude Integration.md"
    "$REPO_ROOT/wiki/decisions/Determinism Classifier.md"
    "$REPO_ROOT/wiki/decisions/Worthiness Audit.md"
    "$REPO_ROOT/wiki/decisions/Worthiness Presence Gate.md"
    "$REPO_ROOT/wiki/decisions/Worthiness And Wiki Before The Audit.md"
    "$REPO_ROOT/wiki/concepts/Task Orchestration.md"
  )
}

# Every [[wikilink]] in the files resolves to a wiki page by title.
check_wikilinks() {
  local file target
  for file in "$@"; do
    while IFS= read -r target; do
      target="${target%%|*}"
      target="${target%%#*}"
      [ -n "$target" ] || continue
      # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this find carries the per-test mark
      find "$REPO_ROOT/wiki" -name "$target.md" | grep -q . || {
        echo "broken: $target in $file"
        return 1
      }
    done < <(grep -o '\[\[[^]]*\]\]' "$file" | sed 's/^\[\[//; s/\]\]$//')
  done
}

@test "the index lists the page" {
  run grep -qF -- '[[Test Layering]]' "$INDEX"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "every wikilink in the changed pages resolves to a wiki page" {
  [ "${#CHANGED_PAGES[@]}" -gt 0 ]
  run check_wikilinks "${CHANGED_PAGES[@]}"
  [ "$status" -eq 0 ]
}
