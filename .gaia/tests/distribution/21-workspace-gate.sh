#!/usr/bin/env bash
# 21-workspace-gate.sh
# distribution-runner: exclusive
# distribution-runner: paths package.json pnpm-workspace.yaml pnpm-lock.yaml apps/web/package.json .claude/hooks/lib/gaia-packages.sh .gaia/scripts/gate-member-warnings.sh wiki/decisions/Quality* .gaia/tests/distribution/lib/**
#
# The root gate across members that are not the web app, run with the staged
# bundle's own root scripts and gate tooling. Two members run Vitest, a third
# runs a runner that exits 1 on any argument, so the root test:ci must forward
# none. The staged scaffold's tsc and vitest run against the scratch files; the
# scratch tree has no install.
#
#   1. A green control: the root typecheck and test:ci exit 0, the third
#      member's test:ci passes on its own, and its runner does refuse an argument.
#   2. A type break in the first member fails the root typecheck naming that
#      member's error, while the other members still run.
#   3. A test break in the second member fails the root test:ci naming its
#      test, while the other members still run.
#   4. The member warning script names a member with test files and no test:ci
#      and a member with TypeScript and no typecheck, and exits 0.
#   5. The Quality Gate's Quick check, read from the staged page, selects the
#      gate with only the web member's package.json staged and with only a
#      library tsconfig staged.
#
# Layer 0: no Docker; needs host pnpm and network access to install the
# scaffold that supplies tsc and vitest. Exclusive because Vitest uses every
# core.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"
source "$HERE/lib/crossed-fixture.sh"
source "$HERE/lib/workspace-proof.sh"

require_command jq "jq is required to read the registry"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command pnpm "pnpm required to run the root gate scripts"

stage_adopter_tree workspace-gate
TOOL_BIN="$(proof_tool_bin)" || exit 1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

FIXTURE="$WORK/workspace"
mkdir -p "$FIXTURE"
_crossed_fixture_git_init "$FIXTURE"

for member in apps/web apps/alpha apps/beta packages/gamma apps/delta packages/epsilon; do
  proof_member "$FIXTURE" "$member" "$(basename "$member")"
done
proof_write_registry "$FIXTURE" web=apps/web alpha=apps/alpha beta=apps/beta gamma=packages/gamma delta=apps/delta epsilon=packages/epsilon
jq '. + {stack: "web"}' "$FIXTURE/apps/web/gaia.package.json" >"$WORK/web-descriptor.json"
cp "$WORK/web-descriptor.json" "$FIXTURE/apps/web/gaia.package.json"
jq '. + {scripts: {typecheck: "echo web typecheck ok"}}' "$FIXTURE/apps/web/package.json" >"$WORK/web-package.json"
cp "$WORK/web-package.json" "$FIXTURE/apps/web/package.json"
mkdir -p "$FIXTURE/.claude/hooks/lib" "$FIXTURE/.gaia/scripts"
cp "$STAGING/.claude/hooks/lib/gaia-packages.sh" "$FIXTURE/.claude/hooks/lib/"
cp "$STAGING/.gaia/scripts/gate-member-warnings.sh" "$FIXTURE/.gaia/scripts/"

# The root scripts are the staged bundle's own.
jq '{name: "project", private: true, scripts: {typecheck: .scripts.typecheck, "test:ci": .scripts["test:ci"]}}' \
  "$STAGING/package.json" >"$FIXTURE/package.json"
printf 'packages:\n  - apps/*\n  - packages/*\n' >"$FIXTURE/pnpm-workspace.yaml"
printf 'node_modules\n' >"$FIXTURE/.gitignore"

TSCONFIG='{"compilerOptions":{"strict":true,"noEmit":true,"target":"es2022","module":"esnext","moduleResolution":"bundler"},"include":["src/index.ts"]}'
for member in apps/alpha apps/beta; do
  name="$(basename "$member")"
  jq '. + {scripts: {typecheck: "tsc --noEmit -p .", "test:ci": "vitest --run --passWithNoTests"}}' \
    "$FIXTURE/$member/package.json" >"$WORK/$name-package.json"
  cp "$WORK/$name-package.json" "$FIXTURE/$member/package.json"
  printf '%s\n' "$TSCONFIG" >"$FIXTURE/$member/tsconfig.json"
  printf 'export default {test: {globals: true}};\n' >"$FIXTURE/$member/vitest.config.mjs"
  printf "test('%s adds', () => { expect(1 + 1).toBe(2); });\n" "$name" >"$FIXTURE/$member/src/index.test.js"
done

# The third member's runner takes no argument at all.
printf 'if (process.argv.length > 2) process.exit(1);\nconsole.log("gamma runner ok");\n' >"$FIXTURE/packages/gamma/runner.mjs"
jq '. + {scripts: {typecheck: "echo gamma typecheck ok", "test:ci": "node runner.mjs"}}' \
  "$FIXTURE/packages/gamma/package.json" >"$WORK/gamma-package.json"
cp "$WORK/gamma-package.json" "$FIXTURE/packages/gamma/package.json"

# Gaps the warning script names: tests and no test:ci, TypeScript and no typecheck.
printf "test('delta', () => {});\n" >"$FIXTURE/apps/delta/src/index.test.ts"
_crossed_fixture_commit "$FIXTURE" 'workspace'

root_run() {
  GATE_STATUS=0
  (cd "$FIXTURE" && PATH="$TOOL_BIN:$PATH" pnpm "$1") >"$WORK/gate-$1.log" 2>&1 </dev/null || GATE_STATUS=$?
}

# --- 1. Green control --------------------------------------------------------

root_run typecheck
[ "$GATE_STATUS" -eq 0 ] || { tail -n 30 "$WORK/gate-typecheck.log" >&2; fail "the root typecheck fails on the green control"; exit 1; }
root_run test:ci
[ "$GATE_STATUS" -eq 0 ] || { tail -n 30 "$WORK/gate-test:ci.log" >&2; fail "the root test:ci fails on the green control"; exit 1; }
(cd "$FIXTURE/packages/gamma" && pnpm test:ci) >/dev/null 2>&1 </dev/null \
  || { fail "the third member's test:ci fails on its own"; exit 1; }
if (cd "$FIXTURE/packages/gamma" && node runner.mjs --reporter=default) >/dev/null 2>&1; then
  fail "the third member's runner accepted an argument, so the control proves nothing"
  exit 1
fi

# --- 2. Type break -----------------------------------------------------------

printf "export const value: number = 'text';\n" >"$FIXTURE/apps/alpha/src/index.ts"
root_run typecheck
[ "$GATE_STATUS" -ne 0 ] || { fail "a type break did not fail the root typecheck"; exit 1; }
grep -qE 'alpha.*TS2322' "$WORK/gate-typecheck.log" \
  || { cat "$WORK/gate-typecheck.log" >&2; fail "the typecheck failure does not name the first member's error"; exit 1; }
grep -q 'gamma typecheck ok' "$WORK/gate-typecheck.log" \
  || { fail "the third member did not run beside the failing one"; exit 1; }
printf 'export const value: number = 1;\n' >"$FIXTURE/apps/alpha/src/index.ts"

# --- 3. Test break -----------------------------------------------------------

printf "test('beta adds', () => { expect(1 + 1).toBe(3); });\n" >"$FIXTURE/apps/beta/src/index.test.js"
root_run test:ci
[ "$GATE_STATUS" -ne 0 ] || { fail "a test break did not fail the root test:ci"; exit 1; }
grep -q 'beta adds' "$WORK/gate-test:ci.log" \
  || { tail -n 40 "$WORK/gate-test:ci.log" >&2; fail "the test failure does not name the second member's test"; exit 1; }
grep -q 'gamma runner ok' "$WORK/gate-test:ci.log" \
  || { fail "the third member's runner did not run beside the failing one"; exit 1; }

# --- 4. Member warnings ------------------------------------------------------

WARNINGS="$(bash "$FIXTURE/.gaia/scripts/gate-member-warnings.sh" "$FIXTURE")" \
  || { fail "the member warning script exited non-zero"; exit 1; }
grep -q '^WARN delta .*no test:ci' <<<"$WARNINGS" \
  || { printf '%s\n' "$WARNINGS" >&2; fail "no warning names the member with tests and no test:ci"; exit 1; }
grep -q '^WARN epsilon .*no typecheck' <<<"$WARNINGS" \
  || { printf '%s\n' "$WARNINGS" >&2; fail "no warning names the member with TypeScript and no typecheck"; exit 1; }
if grep -Eq '^WARN (alpha|beta|gamma|web) ' <<<"$WARNINGS"; then
  printf '%s\n' "$WARNINGS" >&2
  fail "a member with its gate scripts drew a warning"
  exit 1
fi

# --- 5. Quick check ----------------------------------------------------------

QUICK_CHECK="$(awk '/^Quick check:/ { found = 1 } found && /^git diff --cached/ { print; exit }' "$STAGING/wiki/decisions/Quality Gate.md")"
[ -n "$QUICK_CHECK" ] || { fail "the staged Quality Gate page carries no Quick check command"; exit 1; }
printf '{"compilerOptions":{}}\n' >"$FIXTURE/packages/gamma/tsconfig.json"
for staged_path in apps/web/package.json packages/gamma/tsconfig.json; do
  git -C "$FIXTURE" reset -q
  printf '\n' >>"$FIXTURE/$staged_path"
  git -C "$FIXTURE" add -- "$staged_path"
  selected="$(cd "$FIXTURE" && eval "$QUICK_CHECK" || true)"
  [ "$selected" = "$staged_path" ] \
    || { fail "the Quick check selected '$selected' with only $staged_path staged"; exit 1; }
done

pass "workspace gate: green control, named type and test failures with every member run, member warnings and Quick check selection hold"
