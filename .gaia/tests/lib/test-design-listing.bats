#!/usr/bin/env bats

# Pins the test layer mapper and the existing-tests listing the test design
# planner reads. The layer table is the one exhaustive statement of the path to
# layer rule, so it is a single case table; the listing gets one case per
# reason kind on a scratch tree.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only: `.gaia/tests` is release-excluded.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LAYER_MAP="$REPO_ROOT/.gaia/scripts/test-design/layer-map.mjs"
  EXISTING_TESTS="$REPO_ROOT/.gaia/scripts/test-design/existing-tests.mjs"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/apps/web"
  cp "$REPO_ROOT/apps/web/gaia.package.json" "$TREE/apps/web/gaia.package.json"
  cat >"$TREE/apps/web/tsconfig.json" <<'JSON'
{"compilerOptions": {"paths": {"~/*": ["./app/*"]}}}
JSON
}

write_tree_file() {
  mkdir -p "$(dirname "$TREE/$1")"
  printf '%s\n' "$2" >"$TREE/$1"
}

@test "layer-map maps every layer, a page-less flow test to flow, and a bats file by --flow-tests" {
  write_tree_file apps/web/.playwright/flows/journey.spec.ts "import {test} from '@playwright/test';
test('journey', async ({request}) => { await request.get('/'); });"
  write_tree_file apps/web/.playwright/e2e/api.spec.ts "import {test} from '@playwright/test';
test('api', async ({request}) => { await request.get('/'); });"
  write_tree_file apps/web/.playwright/e2e/screen.spec.ts "import {test} from '@playwright/test';
test('screen', async ({page}) => { await page.goto('/'); });"
  write_tree_file apps/web/app/route-tests/home.test.ts "export {};"
  write_tree_file apps/web/test/session.server.test.ts "export {};"
  write_tree_file apps/web/app/components/button.stories.tsx "export {};"
  write_tree_file apps/web/app/utils/format.test.ts "export {};"
  write_tree_file apps/web/test/helpers.test.tsx "export {};"
  write_tree_file .gaia/tests/lib/a.bats "true"
  write_tree_file .gaia/tests/lib/b.bats "true"
  printf '%s\n' ".gaia/tests/lib/b.bats" >"$BATS_TEST_TMPDIR/flow-tests.txt"

  run --separate-stderr bash -c "printf '%s\0' \
    apps/web/.playwright/flows/journey.spec.ts \
    apps/web/.playwright/e2e/api.spec.ts \
    apps/web/.playwright/e2e/screen.spec.ts \
    apps/web/app/route-tests/home.test.ts \
    apps/web/test/session.server.test.ts \
    apps/web/app/components/button.stories.tsx \
    apps/web/app/utils/format.test.ts \
    apps/web/test/helpers.test.tsx \
    .gaia/tests/lib/a.bats \
    .gaia/tests/lib/b.bats \
    apps/web/app/utils/format.ts |
    node '$LAYER_MAP' --root '$TREE' --flow-tests '$BATS_TEST_TMPDIR/flow-tests.txt'"
  [ "$status" -eq 0 ]
  result="$(jq -r '.[] | "\(.file) \(.layer)"' <<<"$output")"
  expected="apps/web/.playwright/flows/journey.spec.ts flow
apps/web/.playwright/e2e/api.spec.ts real-server
apps/web/.playwright/e2e/screen.spec.ts browser
apps/web/app/route-tests/home.test.ts route
apps/web/test/session.server.test.ts route
apps/web/app/components/button.stories.tsx story
apps/web/app/utils/format.test.ts unit
apps/web/test/helpers.test.tsx unit
.gaia/tests/lib/a.bats shell
.gaia/tests/lib/b.bats flow"
  [ "$result" = "$expected" ]
}

@test "existing-tests lists a test by what it imports, requests and names" {
  write_tree_file apps/web/app/utils/format.ts "export const format = () => '';"
  write_tree_file apps/web/app/routes/_public._index.tsx "export default function Home() { return null; }"
  write_tree_file apps/web/app/utils/format.test.ts "import {format} from '~/utils/format';
import {test} from 'vitest';
test('formats', () => { format(); });"
  write_tree_file apps/web/.playwright/e2e/home.spec.ts "import {test} from '@playwright/test';
test('home responds', async ({request}) => { await request.get('/'); });"
  # The fixture's test line is assembled so bats does not preprocess it as one of this file's own tests.
  write_tree_file .gaia/tests/lib/format.bats "$(printf '%s "formats via the script" {\n  run bash apps/web/app/utils/format.ts\n}' '@test')"
  write_tree_file apps/web/app/utils/unrelated.test.ts "import {test} from 'vitest';
test('unrelated', () => {});"
  printf '%s\n%s\n' apps/web/app/utils/format.ts apps/web/app/routes/_public._index.tsx >"$BATS_TEST_TMPDIR/touched.txt"

  run --separate-stderr node "$EXISTING_TESTS" --root "$TREE" --touched "$BATS_TEST_TMPDIR/touched.txt"
  [ "$status" -eq 0 ]
  result="$(jq -r '.[] | "\(.file) | \(.fullName) | \(.layer) | \(.reason)"' <<<"$output")"
  expected=".gaia/tests/lib/format.bats | formats via the script | shell | names apps/web/app/utils/format.ts
apps/web/.playwright/e2e/home.spec.ts | home responds | real-server | requests /
apps/web/app/utils/format.test.ts | formats | unit | imports apps/web/app/utils/format.ts"
  [ "$result" = "$expected" ]
}
