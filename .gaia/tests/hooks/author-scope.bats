#!/usr/bin/env bats

# Tests for .gaia/scripts/red-ledger/author-scope.sh, the plan orchestrator's
# check that a wave's test authors changed only their New tests files and the
# stubs those tests import. The orchestrator snapshots the tree before the
# authors run and checks it after; these cases pin the verdict it routes on
# (exit 0 in scope, exit 1 with `<path><TAB><reason>` lines) and the revert.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  SCRIPT="$HOME_ROOT/.gaia/scripts/red-ledger/author-scope.sh"
  REPO=$(mktemp -d -t author-scope-test-XXXXXX)
  SNAPSHOT=$(mktemp -d -t author-scope-snapshot-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  write_file apps/web/package.json '{}'
  write_file apps/web/app/env.server.ts $'export const apiUrl = "a";\n'
  write_file apps/web/app/services/api/index.ts $'export const create = () => 1;\n'
  write_file .env.example $'API_URL=\n'
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m init
}

teardown() {
  rm -rf "${REPO:-}" "${SNAPSHOT:-}"
  return 0
}

write_file() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s' "$2" > "$REPO/$1"
}

snapshot() {
  run bash "$SCRIPT" snapshot --root "$REPO" --out "$SNAPSHOT/wave"
  [ "$status" -eq 0 ]
}

check() {
  run bash "$SCRIPT" check --root "$REPO" --snapshot "$SNAPSHOT/wave" "$@"
}

TEST_FILE=apps/web/app/services/api/tests/base-url.test.ts

@test "an author that changes an implementation file is out of scope" {
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  write_file apps/web/app/env.server.ts $'export const apiUrl = "b";\n'
  printf 'API_URL=x\n' >> "$REPO/.env.example"
  check --tests "$TEST_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'apps/web/app/env.server.ts\toutside the tests and their stubs'* ]]
  [[ "$output" == *$'.env.example\toutside'* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a new untracked implementation file is out of scope" {
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  write_file apps/web/app/sessions.server/secret.ts $'export const sessionSecret = "s";\n'
  check --tests "$TEST_FILE"
  [ "$status" -eq 1 ]
  [ "$output" = $'apps/web/app/sessions.server/secret.ts\toutside the tests and their stubs' ]
}

@test "tests plus a new stub file they import are in scope" {
  snapshot
  write_file "$TEST_FILE" $'import {resolveUrl} from \'~/utils/url\';\nimport {create} from \'../index\';\n'
  write_file apps/web/app/utils/url.ts $'export const resolveUrl = (): string => \'\';\n'
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an existing stub file may gain lines but not lose or change them" {
  snapshot
  write_file "$TEST_FILE" $'import {create, remove} from \'..\';\n'
  printf 'export const remove = () => 0;\n' >> "$REPO/apps/web/app/services/api/index.ts"
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
  write_file apps/web/app/services/api/index.ts $'export const create = () => 2;\nexport const remove = () => 0;\n'
  check --tests "$TEST_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == $'apps/web/app/services/api/index.ts\tstub file edit removes or changes existing lines'* ]]
}

@test "a later round may change a stub the wave added to an existing file" {
  snapshot
  write_file "$TEST_FILE" $'import {create, remove} from \'..\';\n'
  printf 'export const remove = () => 0;\n' >> "$REPO/apps/web/app/services/api/index.ts"
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
  write_file apps/web/app/services/api/index.ts $'export const create = () => 1;\nexport const remove = () => 99;\n'
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
}

@test "an earlier wave's uncommitted edit the authors left alone is not flagged" {
  write_file apps/web/app/env.server.ts $'export const apiUrl = "wave one";\n'
  write_file apps/web/app/wave-one.ts $'export const one = 1;\n'
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
}

@test "two authors in one wave share the union of their tests and stubs" {
  snapshot
  local second=apps/web/app/routes/tests/home.test.ts
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  write_file "$second" $'import {home} from \'~/routes/home\';\n'
  write_file apps/web/app/routes/home.ts $'export const home = () => null;\n'
  check --tests "$TEST_FILE" "$second"
  [ "$status" -eq 0 ]
  write_file apps/web/app/env.server.ts $'export const apiUrl = "b";\n'
  check --tests "$TEST_FILE" "$second"
  [ "$status" -eq 1 ]
  [ "$output" = $'apps/web/app/env.server.ts\toutside the tests and their stubs' ]
}

@test "--revert restores a changed, a new and an earlier wave's file to the snapshot" {
  write_file apps/web/app/wave-one.ts $'export const one = 1;\n'
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  write_file apps/web/app/env.server.ts $'export const apiUrl = "b";\n'
  write_file apps/web/app/wave-one.ts $'export const one = 2;\n'
  write_file apps/web/app/sessions.server/secret.ts $'export const s = 1;\n'
  check --revert --tests "$TEST_FILE"
  [ "$status" -eq 1 ]
  [ "$(cat "$REPO/apps/web/app/env.server.ts")" = 'export const apiUrl = "a";' ]
  [ "$(cat "$REPO/apps/web/app/wave-one.ts")" = 'export const one = 1;' ]
  [ ! -e "$REPO/apps/web/app/sessions.server/secret.ts" ]
  [ -f "$REPO/$TEST_FILE" ]
  check --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
}

@test "an absolute or comma-terminated --tests path is matched and the test file is kept" {
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  write_file apps/web/app/sessions.server/secret.ts $'export const s = 1;\n'
  check --revert --tests "$REPO/$TEST_FILE,"
  [ "$status" -eq 1 ]
  [ "$output" = $'apps/web/app/sessions.server/secret.ts\toutside the tests and their stubs' ]
  [ -f "$REPO/$TEST_FILE" ]
  [ ! -e "$REPO/apps/web/app/sessions.server/secret.ts" ]
}

@test "a --tests value that cannot be normalized exits 2 and deletes nothing" {
  snapshot
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  check --revert --tests /elsewhere/base-url.test.ts
  [ "$status" -eq 2 ]
  check --revert --tests "$TEST_FILE,other.test.ts"
  [ "$status" -eq 2 ]
  check --revert --tests ../outside.test.ts
  [ "$status" -eq 2 ]
  [ -f "$REPO/$TEST_FILE" ]
}

@test "a snapshot dir inside the tree is never reported" {
  run bash "$SCRIPT" snapshot --root "$REPO" --out "$REPO/plan/.work/author-scope/unit"
  [ "$status" -eq 0 ]
  write_file "$TEST_FILE" $'import {create} from \'..\';\n'
  run bash "$SCRIPT" check --root "$REPO" --snapshot "$REPO/plan/.work/author-scope/unit" --tests "$TEST_FILE"
  [ "$status" -eq 0 ]
}
