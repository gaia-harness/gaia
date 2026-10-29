#!/usr/bin/env bats
# Tests for the tests workflow's Lint step: the delta selector
# (.gaia/scripts/frontend-lint-delta.sh) and the step's call in tests.yml.
#
# Each case builds a scratch git repository, commits a base, commits a change
# on top, and reads the script's --plan output, so no case runs ESLint.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/scripts/tests/frontend-lint-delta.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/frontend-lint-delta.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE/frontend/app" "$FIXTURE/wiki"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.email bats@example.com
  git -C "$FIXTURE" config user.name bats
  git -C "$FIXTURE" config commit.gpgsign false
  printf 'export const kept = 1;\n' > "$FIXTURE/frontend/app/kept.ts"
  printf 'export const moved = 1;\n' > "$FIXTURE/frontend/app/old-name.ts"
  printf 'export const gone = 1;\n' > "$FIXTURE/frontend/app/gone.ts"
  printf '{}\n' > "$FIXTURE/package.json"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m base
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
}

# commit_change: commit whatever the case changed in the fixture.
commit_change() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m change
}

@test "a changed frontend source file is linted and a non-frontend file is not" {
  printf 'export const kept = 2;\n' > "$FIXTURE/frontend/app/kept.ts"
  printf 'body {}\n' > "$FIXTURE/frontend/app/style.css"
  printf 'note\n' > "$FIXTURE/wiki/page.md"
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'delta\napp/kept.ts')" ]
}

@test "each lintable extension is selected" {
  for extension in js jsx ts tsx mjs cjs; do
    printf 'export const value = 1;\n' > "$FIXTURE/frontend/app/file.$extension"
  done
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = delta ]
  [ "${#lines[@]}" -eq 7 ]
}

@test "a deleted file is dropped and a moved file lists only its new path" {
  git -C "$FIXTURE" rm -q frontend/app/gone.ts
  git -C "$FIXTURE" mv frontend/app/old-name.ts frontend/app/new-name.ts
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'delta\napp/new-name.ts')" ]
}

@test "a path with a non-ASCII name is selected, not C-quoted out" {
  printf 'export const value = 1;\n' > "$FIXTURE/frontend/app/café.ts"
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'delta\napp/café.ts')" ]
}

@test "each lint input change selects the full lint" {
  for input in frontend/eslint.config.mjs frontend/prettier.config.js frontend/tsconfig.json \
    frontend/tsconfig.node.json frontend/package.json package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    git -C "$FIXTURE" reset -q --hard "$BASE"
    mkdir -p "$FIXTURE/$(dirname "$input")"
    printf 'changed %s\n' "$input" >> "$FIXTURE/$input"
    commit_change
    run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
    [ "$status" -eq 0 ] || { echo "status $status for $input" >&2; return 1; }
    [ "$output" = full ] || { echo "expected full for $input, got: $output" >&2; return 1; }
  done
}

# The diff lists paths sorted, so package.json matches early and the wiki
# paths after it run well past a pipe buffer: a reader that exits on the match
# while the writer is still writing is the SIGPIPE shape, and a missed full
# lint here reads as `none`, since no wiki path is lintable.
@test "a lint input listed before a long tail of other paths still selects the full lint" {
  for index in $(seq 1 3000); do
    printf 'note\n' > "$FIXTURE/wiki/a-long-page-name-to-fill-the-pipe-buffer-$index.md"
  done
  printf '{"changed": true}\n' > "$FIXTURE/package.json"
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "$output" = full ]
}

@test "a change with nothing lintable selects no lint" {
  printf 'note\n' > "$FIXTURE/wiki/page.md"
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base "$BASE" --plan
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "an unreadable base fails rather than reading as no change" {
  printf 'export const kept = 2;\n' > "$FIXTURE/frontend/app/kept.ts"
  commit_change
  run "$SCRIPT" --root "$FIXTURE" --base refs/heads/no-such-branch --plan
  [ "$status" -eq 2 ]
  grep -qF -- "could not read the diff" <<<"$output"
}

@test "a missing --base or --root is a usage error" {
  run "$SCRIPT" --root "$FIXTURE" --plan
  [ "$status" -eq 2 ]
  run "$SCRIPT" --base "$BASE" --plan
  [ "$status" -eq 2 ]
}

@test "the workflow's Lint step calls the script with the resolved base" {
  grep -qF -- 'run: bash .gaia/scripts/frontend-lint-delta.sh --root . --base "$CHECK_BASE"' "$WORKFLOW"
  grep -qF -- 'CHECK_BASE: ${{ steps.base.outputs.base }}' "$WORKFLOW"
}
