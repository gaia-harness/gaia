#!/usr/bin/env bats
# The quick classifier's path allowlist reads the web member's path from the
# package registry: the language, component and page shapes hold at any web
# member path, and a path under a member that is not web-stack is class none.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-quick-classify-web-member.bats < /dev/null
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE/.gaia" "$FIXTURE/apps/storefront" "$FIXTURE/libs/kit"
  write_descriptor apps/storefront storefront web
  write_descriptor libs/kit kit
  printf '%s\n' '[{"name":"storefront","path":"apps/storefront"},{"name":"kit","path":"libs/kit"}]' >"$FIXTURE/.gaia/packages.json"
}

# write_descriptor <directory> <name> [web]: a descriptor with empty glob lists.
write_descriptor() {
  {
    printf '{"schemaVersion":1,"name":"%s",' "$2"
    if [ "${3:-}" = web ]; then printf '"stack":"web",'; fi
    printf '"globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},'
    printf '"wiki":{"sourcePaths":[],"inventoryPaths":[],"flowPaths":[]}}\n'
  } >"$FIXTURE/$1/gaia.package.json"
}

# class_of <path>: the path's class with the fixture registry loaded.
class_of() {
  bash -c '
    . "$1/.claude/hooks/lib/audit-quick-classify-lib.sh" || exit 9
    quick_load_registry "$2" || exit 8
    quick_path_class "$3"
  ' _ "$REPO_ROOT" "$FIXTURE" "$1"
}

@test "a language file under a web member classifies as a language file" {
  run class_of apps/storefront/app/languages/en/common.ts
  [ "$status" -eq 0 ]
  [ "$output" = "language" ]
}

@test "the same shape under a non-web member is class none" {
  run class_of libs/kit/app/languages/en/common.ts
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "a component and a page under a web member keep their classes, under a non-web member they are none" {
  run class_of apps/storefront/app/components/button/index.tsx
  [ "$output" = "component" ]
  run class_of apps/storefront/app/pages/home/page.tsx
  [ "$output" = "page" ]
  run class_of libs/kit/app/components/button/index.tsx
  [ "$output" = "none" ]
  run class_of libs/kit/app/pages/home/page.tsx
  [ "$output" = "none" ]
}

@test "the old literal root no longer classifies when no member sits there" {
  run class_of apps/web/app/components/button/index.tsx
  [ "$output" = "none" ]
}

@test "an unreadable registry makes the stage entry points fail closed" {
  printf 'not json' >"$FIXTURE/.gaia/packages.json"
  run bash -c '
    . "$1/.claude/hooks/lib/audit-quick-classify-lib.sh" || exit 9
    quick_load_registry "$2"
  ' _ "$REPO_ROOT" "$FIXTURE"
  [ "$status" -eq 2 ]
}
