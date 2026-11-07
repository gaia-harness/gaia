#!/usr/bin/env bats

# Playwright collects a spec placed in apps/web/.playwright/flows/ beside the
# template specs in apps/web/.playwright/e2e/, and nothing else under
# .playwright/ (no output folder, no helper module). The listing runs against
# the real config, which starts no web server. The run goes through a scratch
# config that imports the real config and drops webServer and globalSetup, so
# no server boots and no browser launches (the spec opens no page).
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WEB_DIRECTORY="$ROOT/apps/web"
  FLOWS_DIRECTORY="$WEB_DIRECTORY/.playwright/flows"
  SPEC_NAME="collection-$$-${BATS_TEST_NAME//[^A-Za-z0-9]/-}.spec.ts"
  SPEC_PATH="$FLOWS_DIRECTORY/$SPEC_NAME"
  mkdir -p "$FLOWS_DIRECTORY"
  cat >"$SPEC_PATH" <<'SPEC'
import {expect, test} from '@playwright/test';

test('flow collection probe', () => {
  expect(1 + 1).toBe(2);
});
SPEC
}

teardown() {
  rm -f "$SPEC_PATH"
}

@test "Playwright lists and runs a spec in the flows folder beside the e2e specs" {
  run bash -c 'pnpm -C "$1" exec playwright test --list --reporter=json 2>/dev/null' _ "$WEB_DIRECTORY"
  [ "$status" -eq 0 ]
  listing="$output"

  # The JSON reporter prints each spec file relative to the config's testDir.
  listed_files="$(jq -r '[.. | objects | .file? // empty] | unique | .[]' <<<"$listing")"

  for expected in \
    "flows/$SPEC_NAME" \
    "e2e/home-a11y.spec.ts" \
    "e2e/route-status.spec.ts"; do
    if ! grep -qxF -- "$expected" <<<"$listed_files"; then
      echo "listing is missing $expected" >&2
      return 1
    fi
  done
  if grep -qE '(^|/)output/' <<<"$listed_files"; then
    echo "listing holds a file under the output folder" >&2
    return 1
  fi
  if grep -qE '(^|/)fixtures\.ts$' <<<"$listed_files"; then
    echo "listing holds the fixtures helper" >&2
    return 1
  fi

  scratch_config="$BATS_TEST_TMPDIR/playwright.scratch.config.mts"
  cat >"$scratch_config" <<SCRATCH
import path from 'node:path';
import realConfig from '$WEB_DIRECTORY/playwright.config.ts';

export default {
  ...realConfig,
  globalSetup: undefined,
  testDir: path.resolve('$WEB_DIRECTORY', realConfig.testDir ?? '.'),
  webServer: undefined,
};
SCRATCH

  run pnpm -C "$WEB_DIRECTORY" exec playwright test --config "$scratch_config" "$SPEC_PATH"
  [ "$status" -eq 0 ]
  grep -qE '1 passed' <<<"$output"
}
