#!/usr/bin/env bats
#
# End-to-end suite for a branch that adds a utility test, a hook test and a test
# under the app's test helper folder (apps/web/test/), and changes no browser or
# real-server test. The determinism classifier labels the utility and hook tests
# strict, so this is the case the widened surface exists for: every gate has to
# do its part on the one branch.
#
#   - worthiness-step.sh route lists all three tests for review.
#   - the merge-time presence gate denies until each has a recorded verdict.
#   - an unattended delete verdict is recorded and leaves the test file as it was.
#   - the RED gate still refuses a commit of the utility or hook test with no
#     recorded failing run, and does not newly demand one for the helper folder.
#   - the overlap pass runs instead of skipping.
#
# Every case builds one fixture repo with a real merge base: the harness is
# linked in, a base commit holds a readme, and the feature branch adds the three
# tests. The RED-gate cases stage the tests instead of committing them, since
# the RED gate judges tests new at HEAD. The two scripts a case may mutate are
# copied into the fixture's own .gaia/scripts, so a mutant runs against a
# scratch copy and never touches the real file.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/worthiness-widened-surface.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

UTIL_TEST='apps/web/app/utils/slugify/index.test.ts'
HOOK_TEST='apps/web/app/hooks/use-counter/index.test.ts'
HELPER_TEST='apps/web/test/fixture-builder.test.ts'
UTIL_NAME='slugifies a title'
HOOK_NAME='increments the counter'
HELPER_NAME='builds a fixture'
NEEDLE='With no human, run `settle --as residual` and keep the test'

setup() {
  HOME_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE WORTHINESS_LEDGER_PATH

  REPO="$BATS_TEST_TMPDIR/repo"
  RUN_FOLDER="$BATS_TEST_TMPDIR/run"
  mkdir -p "$REPO" "$RUN_FOLDER"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config commit.gpgsign false
  # The default emergent list plus the helper-folder glob, as the live descriptor
  # carries it; the shared fixture's default does not track the live descriptor.
  write_builtin_descriptor "$REPO" '' '' '["app/components/**/*.test.ts","app/components/**/*.test.tsx",".playwright/**/*.spec.ts",".playwright/**/*.spec.tsx",".playwright/**/*.test.ts",".playwright/**/*.test.tsx","app/route-tests/**/*.test.ts","test/**/*.test.ts"]'
  install_harness
  printf '# readme\n' >"$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b feature
  STEP="$REPO/.gaia/scripts/worthiness-step.sh"
  CHECK="$REPO/.gaia/scripts/overlap-check.sh"
  PRESENCE_HOOK="$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh"
  RED_HOOK="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
}

# The fixture mirrors the repo-relative layout every script resolves from its
# own root. Libraries and helper trees are links to the checkout; the two
# scripts a case may mutate are copies.
install_harness() {
  mkdir -p "$REPO/.claude/hooks" "$REPO/.gaia/scripts"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  local entry name
  for entry in "$HOME_ROOT/.gaia/scripts/"*; do
    name="$(basename "$entry")"
    case "$name" in
      overlap-check.sh | worthiness-step.sh) ;;
      *) ln -sfn "$entry" "$REPO/.gaia/scripts/$name" ;;
    esac
  done
  cp "$HOME_ROOT/.gaia/scripts/overlap-check.sh" "$REPO/.gaia/scripts/overlap-check.sh"
  cp "$HOME_ROOT/.gaia/scripts/worthiness-step.sh" "$REPO/.gaia/scripts/worthiness-step.sh"
}

test_source() {
  printf '%s\n' \
    "import {expect, test} from 'vitest';" \
    "" \
    "test('$1', () => {" \
    "  expect(1 + 1).toBe(2);" \
    "});"
}

write_test() {
  mkdir -p "$REPO/$(dirname "$1")"
  test_source "$2" >"$REPO/$1"
}

# The three tests, committed on the feature branch so the branch diff holds them.
commit_branch_tests() {
  write_test "$UTIL_TEST" "$UTIL_NAME"
  write_test "$HOOK_TEST" "$HOOK_NAME"
  write_test "$HELPER_TEST" "$HELPER_NAME"
  git -C "$REPO" add apps
  git -C "$REPO" commit -q -m "add tests"
}

classification_of() {
  (cd "$REPO" && node "$HOME_ROOT/.gaia/scripts/classifier/classify-determinism.mjs" "$1" | jq -r '.classification')
}

run_route() {
  run --separate-stderr bash "$STEP" route --root "$REPO" --run-folder "$RUN_FOLDER"
}

# Records one verdict through the shipped recorder, which is how the step writes
# the ledger line the presence gate reads.
record_verdict() {
  local file="$1" name="$2" verdict="$3" artifact="${4:-}"
  jq -n --arg f "$file" --arg n "$name" --arg v "$verdict" --arg a "$artifact" \
    '[{file: $f, fullName: $n, verdict: $v} + (if $a == "" then {} else {artifact: $a} end)]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ]
}

run_merge_hook() {
  local json
  json=$(jq -nc '{tool_name:"Bash", tool_input:{command:"gh pr merge 30 --squash --delete-branch"}}')
  invoke_hook_in "$REPO" "$json" "$PRESENCE_HOOK"
}

run_commit_hook() {
  local json
  json=$(jq -nc '{tool_name:"Bash", tool_input:{command:"git commit -m change"}}')
  invoke_hook_in "$REPO" "$json" "$RED_HOOK"
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }
refute_denied() { if denied; then return 1; fi; }

# Replaces the first occurrence of $1 with $2 in $3, writing $4; refuses an
# absent anchor so a mutant that matched nothing cannot pass for one that did.
mutate() {
  awk -v from="$1" -v to="$2" '{ if (!done && (i = index($0, from)) > 0) { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); done = 1 } print }' "$3" >"$4"
  if cmp -s "$3" "$4"; then printf '"%s" is not in %s\n' "$1" "$3" >&2; return 1; fi
}

@test "the utility and hook tests are labeled strict by the determinism classifier" {
  commit_branch_tests
  [ "$(classification_of "$UTIL_TEST")" = strict ]
  [ "$(classification_of "$HOOK_TEST")" = strict ]
}

@test "the worthiness step lists a strict utility test, a strict hook test and a helper folder test" {
  commit_branch_tests
  run_route
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'map(.file) | sort | join(",")')" = "$HOOK_TEST,$UTIL_TEST,$HELPER_TEST" ]
  [ "$(printf '%s' "$output" | jq 'map(select(.route == "evaluate")) | length')" -eq 3 ]
}

@test "the presence gate denies each unrecorded test, names the worthiness step, and allows once all three are recorded" {
  commit_branch_tests
  run_merge_hook
  denied
  [[ "$output" == *"$UTIL_NAME"* ]]
  [[ "$output" == *"$HOOK_NAME"* ]]
  [[ "$output" == *"$HELPER_NAME"* ]]
  [[ "$output" == *"worthiness-step.md"* ]]

  record_verdict "$UTIL_TEST" "$UTIL_NAME" keep
  run_merge_hook
  denied
  [[ "$output" == *"$HOOK_NAME"* ]]
  [[ "$output" == *"$HELPER_NAME"* ]]
  [[ "$output" != *"$UTIL_NAME"* ]]

  record_verdict "$HOOK_TEST" "$HOOK_NAME" keep
  record_verdict "$HELPER_TEST" "$HELPER_NAME" keep
  run_merge_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "an unattended delete verdict is recorded as a residual and leaves the test file unchanged" {
  commit_branch_tests
  run_route
  signal="$(printf '%s' "$output" | jq -r --arg f "$UTIL_TEST" '.[] | select(.file == $f) | .signal')"
  [ -n "$signal" ]
  before="$(cksum <"$REPO/$UTIL_TEST")"

  record_verdict "$UTIL_TEST" "$UTIL_NAME" delete "covered by a route test"
  run bash "$STEP" settle --run-folder "$RUN_FOLDER" --file "$UTIL_TEST" --full-name "$UTIL_NAME" --signal "$signal" --as residual --first-line 3 --reason 'delete verdict, no human to confirm'
  [ "$status" -eq 0 ]

  [ "$(jq -r --arg f "$UTIL_TEST" 'select(.file == $f) | .settlement' "$RUN_FOLDER/worthiness-settlements.jsonl")" = residual ]
  [ "$(jq -r --arg f "$UTIL_TEST" 'select(.path == $f) | .fullName' "$RUN_FOLDER/recorded-residuals.jsonl")" = "$UTIL_NAME" ]
  [ "$(cksum <"$REPO/$UTIL_TEST")" = "$before" ]
  run_route
  [ "$(printf '%s' "$output" | jq -r --arg f "$UTIL_TEST" '.[] | select(.file == $f) | .route')" = settled ]
}

@test "the step instructions state the no-human branch of a delete, and a copy without it fails the check" {
  grep -qF -- "$NEEDLE" "$HOME_ROOT/.claude/skills/gaia/references/worthiness-step.md"
  mutate "$NEEDLE" 'With no human, ask again.' "$HOME_ROOT/.claude/skills/gaia/references/worthiness-step.md" "$BATS_TEST_TMPDIR/worthiness-step.md"
  if grep -qF -- "$NEEDLE" "$BATS_TEST_TMPDIR/worthiness-step.md"; then return 1; fi
}

@test "the RED gate refuses an unrecorded failing run for the utility test and for the hook test" {
  write_test "$UTIL_TEST" "$UTIL_NAME"
  git -C "$REPO" add "$UTIL_TEST"
  run_commit_hook
  denied
  git -C "$REPO" reset -q "$UTIL_TEST"

  write_test "$HOOK_TEST" "$HOOK_NAME"
  git -C "$REPO" add "$HOOK_TEST"
  run_commit_hook
  denied
}

@test "the RED gate does not newly demand a failing run for the helper folder test" {
  write_test "$HELPER_TEST" "$HELPER_NAME"
  git -C "$REPO" add "$HELPER_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "the overlap route runs on a branch that changed only unit and helper folder tests" {
  commit_branch_tests
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = run ]
}

@test "red twin: a route that only counts browser and real-server tests skips this branch" {
  commit_branch_tests
  mutate '.layer != null' '.layer == "real-server" or .layer == "browser"' "$HOME_ROOT/.gaia/scripts/overlap-check.sh" "$BATS_TEST_TMPDIR/overlap-check-mutant.sh"
  cp "$BATS_TEST_TMPDIR/overlap-check-mutant.sh" "$CHECK"
  run bash "$CHECK" route --root "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = skip-no-test-change ]
}
