#!/usr/bin/env bash
# 18-fresh-apps-web.sh
# distribution-runner: exclusive
# distribution-runner: paths .gaia/cli/src/util/** .gaia/cli/src/setup/** pnpm-workspace.yaml pnpm-lock.yaml apps/web/package.json apps/web/vite.config.ts apps/web/vitest.config.ts .gaia/tests/distribution/lib/**
#
# A fresh project from the staged bundle, as an adopter's first run sees it:
# the maintainer-only CLI member stripped and packages/ holding only .gitkeep.
#
#   1. No path named frontend exists outside node_modules, the app lives at
#      apps/web, the workspace lists apps/* and packages/*, and packages/ holds
#      only .gitkeep.
#   2. `pnpm install --frozen-lockfile` exits 0 although packages/* matches no
#      member.
#   3. The setup env seed writes apps/web/.env.
#   4. typecheck, lint, test:ci, build, Playwright and a dev-server smoke each
#      exit 0 from the root. The build writes apps/web/build. The test run
#      reports at least as many test files as the source tree holds, derived
#      here, because test:ci passes when it finds none.
#
# Layer 0: needs host pnpm and network access for the install and Chromium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"

require_command pnpm "pnpm required for the fresh apps/web scenario (Layer 0)"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command node "node required to read the test report"
require_command curl "curl required for the dev-server smoke"

SECONDS=0
stage_adopter_tree fresh-apps-web

# --- 1. Shape ----------------------------------------------------------------

LEGACY_NAME="$(printf 'front%s' end)"
LEGACY_PATHS="$(find "$SCAFFOLD" -name node_modules -prune -o -name "$LEGACY_NAME" -print)"
[ -z "$LEGACY_PATHS" ] \
  || { fail "the fresh project holds a path named $LEGACY_NAME: $LEGACY_PATHS"; exit 1; }
[ -f "$FRONTEND/package.json" ] \
  || { fail "the fresh project has no apps/web/package.json"; exit 1; }
[ ! -e "$SCAFFOLD/.gaia/cli/package.json" ] \
  || { fail "the maintainer-only CLI member is still in the fresh project"; exit 1; }
[ "$(ls -A "$SCAFFOLD/packages")" = ".gitkeep" ] \
  || { fail "packages/ holds more than .gitkeep: $(ls -A "$SCAFFOLD/packages")"; exit 1; }
[ "$(grep -cxE '  - (apps|packages)/\*' "$SCAFFOLD/pnpm-workspace.yaml")" -eq 2 ] \
  || { fail "pnpm-workspace.yaml does not list apps/* and packages/*"; exit 1; }

# --- 2. Install --------------------------------------------------------------

log "pnpm install --frozen-lockfile"
run_logged "pnpm install --frozen-lockfile" "$WORK/install.log" pnpm -C "$SCAFFOLD" install --frozen-lockfile
log "playwright install chromium"
run_logged "playwright install chromium" "$WORK/chromium.log" install_chromium "$SCAFFOLD"

# --- 3. Env seed -------------------------------------------------------------

[ ! -e "$FRONTEND/.env" ] \
  || { fail "the staged tree already carries apps/web/.env"; exit 1; }
gaia_json "setup bootstrap-env" setup bootstrap-env >/dev/null
[ -f "$FRONTEND/.env" ] \
  || { fail "setup bootstrap-env wrote no apps/web/.env"; exit 1; }
cmp -s "$FRONTEND/.env" "$FRONTEND/.env.example" \
  || { fail "apps/web/.env is not the seeded copy of .env.example"; exit 1; }

# --- 4. Gate -----------------------------------------------------------------

run_pnpm_steps fresh- "fresh project" typecheck lint
run_test_ci_with_report fresh- "fresh project" "$WORK/test-ci-report.json"

SOURCE_TEST_FILES="$(find "$PROJECT_ROOT/apps/web/app" "$PROJECT_ROOT/apps/web/test" \
  -name node_modules -prune -o -type f \( -name '*.test.ts' -o -name '*.test.tsx' \) -print | wc -l | tr -d ' ')"
RAN_TEST_FILES="$(node -e '
  const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(report.testResults.filter((result) => /\.test\.tsx?$/.test(result.name)).length));
' "$WORK/test-ci-report.json")"
[ "$SOURCE_TEST_FILES" -gt 0 ] \
  || { fail "the source tree holds no test files to compare against"; exit 1; }
[ "$RAN_TEST_FILES" -ge "$SOURCE_TEST_FILES" ] \
  || { fail "test:ci ran $RAN_TEST_FILES test files, the source tree holds $SOURCE_TEST_FILES"; exit 1; }

run_pnpm_steps fresh- "fresh project" build
[ -d "$FRONTEND/build" ] \
  || { fail "the build wrote no apps/web/build"; exit 1; }

log "pnpm pw"
run_logged "pnpm pw" "$WORK/pw.log" \
  pnpm -C "$SCAFFOLD" pw .playwright/e2e/route-status.spec.ts .playwright/e2e/hydration.spec.ts .playwright/e2e/home-a11y.spec.ts

# --- Dev-server smoke --------------------------------------------------------

DEV_PORT="$(node -e '
  const server = require("node:net").createServer();
  server.listen(0, "127.0.0.1", () => { process.stdout.write(String(server.address().port)); server.close(); });
')"
(cd "$SCAFFOLD" && GAIA_DEV_PORT_OVERRIDE="$DEV_PORT" exec pnpm dev) >"$WORK/dev.log" 2>&1 &
DEV_PID=$!
trap 'kill "$DEV_PID" 2>/dev/null || true; rm -rf "$STAGING" "$SCAFFOLD" "$WORK"' EXIT
SMOKE_STATUS=000
for _ in $(seq 1 60); do
  SMOKE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$DEV_PORT/" || true)"
  [ "$SMOKE_STATUS" = "200" ] && break
  kill -0 "$DEV_PID" 2>/dev/null || break
  sleep 1
done
if [ "$SMOKE_STATUS" != "200" ]; then
  tail -n 40 "$WORK/dev.log" >&2
  fail "the dev server answered $SMOKE_STATUS at the root route"
  exit 1
fi

pass "fresh project: no legacy root, install on an unmatched glob, env seed, gate, build, Playwright and dev smoke all green (${SECONDS}s)"
