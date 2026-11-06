#!/usr/bin/env bats
#
# The request-only stub that .gaia/scripts/spec/uat-write.sh renders for a
# real-server row is lint-clean and a formatter fixed point under the web
# ESLint config, so an adopter's first lint run never rewrites a fresh stub.
# Needs the installed apps/web workspace, which the lib suites' legs lack.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/uat-real-server-stub-lint.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT_REAL"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/plan"
  write_builtin_descriptor "$WORK"
  # The probe sits one folder deep, like the stub's own feature folder, so
  # the stub's relative fixtures import resolves from it.
  PROBE_DIR="$REPO_ROOT_REAL/apps/web/.playwright/e2e/zz-lint-probe-$$"
  mkdir -p "$PROBE_DIR"
  PROBE_NAME="zz-lint-probe-$$/real-server.spec.ts"
  PROBE="$REPO_ROOT_REAL/apps/web/.playwright/e2e/$PROBE_NAME"
}

teardown() {
  rm -rf "$PROBE_DIR"
}

# render_real_server_stub: render one real-server row into the scratch project
# and print the path of the stub.
render_real_server_stub() {
  cat >"$WORK/SPEC.md" <<'SPEC_EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor
    when: they request the orders page
    then: the response lists the orders
---
SPEC_EOF
  {
    printf '# Plan\n\n<!-- gaia:uat-routing:start -->\n'
    printf '| uat_id | surface | phase | feature_folder | file_name |\n|---|---|---|---|---|\n'
    printf '| UAT-001 | real-server | 1 | orders | orders-list-in-response.spec.ts |\n'
    printf '<!-- gaia:uat-routing:end -->\n'
  } >"$WORK/plan/README.md"
  (cd "$WORK" && bash "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-write.sh" "$WORK/SPEC.md" --routing "$WORK/plan/README.md" >/dev/null 2>&1) || return 1
  printf '%s\n' "$WORK/apps/web/.playwright/e2e/orders/orders-list-in-response.spec.ts"
}

@test "the real-server stub is a lint fixed point under the web eslint config" {
  stub="$(render_real_server_stub)" || return 1
  [ -f "$stub" ] || return 1
  cp "$stub" "$PROBE"
  run pnpm -C "$REPO_ROOT_REAL/apps/web" exec eslint --no-fix ".playwright/e2e/$PROBE_NAME"
  lint_status=$status
  lint_output=$output
  run pnpm -C "$REPO_ROOT_REAL/apps/web" exec eslint --fix-dry-run --format json ".playwright/e2e/$PROBE_NAME"
  dry_status=$status
  dry_output=$output
  [ "$lint_status" -eq 0 ] || { printf '%s\n' "$lint_output" >&2; return 1; }
  [ "$dry_status" -eq 0 ] || return 1
  jq -e 'all(.[]; has("output") | not)' <<<"$dry_output" >/dev/null
}
