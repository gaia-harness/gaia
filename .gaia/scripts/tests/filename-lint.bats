#!/usr/bin/env bats
#
# .gaia/scripts/spec/filename-lint.mjs against the real frontend package's
# eslint config: a refused name carries eslint's suggested name, a spelled-out
# name is clean, only the filename rules ever fire, and the two setup failures
# split as plan-verify.sh needs them (eslint absent warns, a broken config fails).
#
# Assertion style follows .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/filename-lint.mjs"
  WEB_PACKAGE="$REPO_ROOT_REAL/apps/web"
}

@test "an abbreviated name is refused with the name eslint suggests" {
  run node "$SCRIPT" --package "$WEB_PACKAGE" .playwright/e2e/runtime/clean-checkout-dev-server-signs-in.spec.ts
  [ "$status" -eq 1 ]
  [[ "$output" == .playwright/e2e/runtime/clean-checkout-dev-server-signs-in.spec.ts$'\t'unicorn/prevent-abbreviations:* ]]
  [[ "$output" == *'`clean-checkout-development-server-signs-in.spec.ts`'* ]]
}

@test "spelled-out real-server and route test names are clean" {
  run node "$SCRIPT" --package "$WEB_PACKAGE" \
    .playwright/e2e/runtime/clean-checkout-development-server-signs-in.spec.ts \
    app/route-tests/checkout/tests/guest-checkout-confirms-order.test.ts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a rule outside the filename rules does not fire on the empty text" {
  # The empty text is what unicorn/no-empty-file refuses; prove the config
  # enforces it, so the clean result below means the scope held.
  run node --input-type=module -e "
    import {createRequire} from 'node:module';
    const require = createRequire('$WEB_PACKAGE/package.json');
    const {ESLint} = require('eslint');
    const config = await new ESLint({cwd: '$WEB_PACKAGE'}).calculateConfigForFile('$WEB_PACKAGE/app/route-tests/checkout/tests/a.test.ts');
    console.log(JSON.stringify(config.rules['unicorn/no-empty-file']));"
  [ "$status" -eq 0 ]
  [[ "$output" == '[2'* ]]
  run node "$SCRIPT" --package "$WEB_PACKAGE" app/route-tests/checkout/tests/a.test.ts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a package where eslint does not resolve exits 2" {
  local package="$BATS_TEST_TMPDIR/uninstalled"
  mkdir -p "$package"
  NODE_PATH='' run node "$SCRIPT" --package "$package" .playwright/e2e/a/b.spec.ts
  [ "$status" -eq 2 ]
  [[ "$output" == *'eslint does not resolve'* ]]
}

@test "a config that fails to load exits 3, never 0 or 2" {
  # eslint resolves through NODE_PATH from the real package, so the scratch
  # package needs no node_modules of its own; its config throws on load.
  local package="$BATS_TEST_TMPDIR/broken-config"
  mkdir -p "$package"
  printf '%s\n' "throw new Error('broken config fixture');" >"$package/eslint.config.mjs"
  NODE_PATH="$WEB_PACKAGE/node_modules" run node "$SCRIPT" --package "$package" .playwright/e2e/a/b.spec.ts
  [ "$status" -eq 3 ]
  [[ "$output" == *'broken config fixture'* ]]
}

@test "a call without paths is a usage error" {
  run node "$SCRIPT" --package "$WEB_PACKAGE"
  [ "$status" -eq 3 ]
  [[ "$output" == usage:* ]]
}
