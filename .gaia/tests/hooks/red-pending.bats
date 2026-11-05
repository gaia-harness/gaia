#!/usr/bin/env bats

# Tests for .gaia/scripts/red-ledger/red-pending.sh, the plan orchestrator's
# check that every new test the commit gate would demand a RED for has one on
# record, run between a test-author dispatch and its implementer dispatch.
#
# The script runs the commit gate itself (.claude/hooks/red-verify-commit-check.sh)
# against a temporary copy of the index holding the whole working tree, so its
# verdict is the gate's own. These cases pin the contract the orchestrator
# reads: exit 0 none pending, exit 1 with one `file<TAB>fullName` line per
# pending test, exit 2 when the gate could not decide; that the run leaves
# the real index and the tree untouched; and the deny-reason line shape the
# script parses.
#
# The fixture mirrors red-verify-commit-check.bats: a tmp repo with a HEAD
# commit, the hook's libraries and helpers linked in at their repo-relative
# paths, and a ledger seeded with the real signal so a match is exact.

# bats file_tags=installed-dependencies

install_tree_links() {
  local directory="$1"
  mkdir -p "$directory/.claude/hooks/lib" "$directory/.gaia/scripts"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$directory/.claude/hooks/lib/red-ledger.sh"
  for repo_scope_file in repo-scope.sh repo-scope-segment.sh repo-scope-scan.sh repo-scope-home.sh; do
    ln -sfn "$HOME_ROOT/.claude/hooks/lib/$repo_scope_file" "$directory/.claude/hooks/lib/$repo_scope_file"
  done
  ln -sfn "$HOME_ROOT/.gaia/scripts/red-ledger" "$directory/.gaia/scripts/red-ledger"
  ln -sfn "$HOME_ROOT/.gaia/scripts/main-root-lib.sh" "$directory/.gaia/scripts/main-root-lib.sh"
  ln -sfn "$HOME_ROOT/.gaia/scripts/classifier" "$directory/.gaia/scripts/classifier"
  # The links are fixture plumbing, not work under test: keep them out of the
  # `git add -A` the script stages into its temporary index.
  printf '%s\n' .claude/ .gaia/scripts/ >> "$directory/.git/info/exclude"
}

setup() {
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  SCRIPT="$HOME_ROOT/.gaia/scripts/red-ledger/red-pending.sh"
  HOOK="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"

  REPO=$(mktemp -d -t red-pending-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  write_builtin_descriptor "$REPO"
  install_tree_links "$REPO"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "init"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Write a file into the working tree without staging it: the orchestrator runs
# the check on an executor's uncommitted, unstaged output.
write_file() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
}

seed_matching_red() {
  local relative_path="$1" want_full="$2" signal ledger
  signal=$( (cd "$REPO" && node "$HELPER" "$relative_path") \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$signal" ] || { echo "no signal for '$want_full'" >&2; return 1; }
  ledger="$( . "$REPO/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$REPO" )"
  mkdir -p "$(dirname "$ledger")"
  jq -nc --arg f "$relative_path" --arg n "$want_full" --arg s "$signal" \
    '{schema:1, file:$f, fullName:$n, signal:$s, failureKind:"assertion", observedAt:"2026-06-04T00:00:00Z"}' \
    >> "$ledger"
}

UNIT_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'
UNIT_TEST_EDITED='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(2 + 2).toBe(4);
});
'
UNIT_PATH="apps/web/app/utils/x/index.test.ts"

@test "a new unstaged test with no recorded RED exits 1 and names it" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 1 ]
  [ "$output" = "$UNIT_PATH	adds two numbers" ]
}

@test "a new test with a matching recorded RED exits 0 with no output" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  seed_matching_red "$UNIT_PATH" "adds two numbers"
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a test body edited after its RED exits 1: the stale RED does not count" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  seed_matching_red "$UNIT_PATH" "adds two numbers"
  write_file "$UNIT_PATH" "$UNIT_TEST_EDITED"
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adds two numbers"* ]]
}

CASE_TABLE_TEST='import {expect, test} from "vitest";
test.for([{email: "a@x.io"}, {email: "b@x.io"}])("rejects $email", ({email}) => {
  expect(email).toContain("@");
});
'
CASE_TABLE_NAME='rejects $email'

@test "a new test.for whose rows never failed is pending under its template name" {
  write_file "$UNIT_PATH" "$CASE_TABLE_TEST"
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 1 ]
  [ "$output" = "$UNIT_PATH	$CASE_TABLE_NAME" ]
}

@test "a new test.for clears once a RED is recorded under its template name" {
  write_file "$UNIT_PATH" "$CASE_TABLE_TEST"
  seed_matching_red "$UNIT_PATH" "$CASE_TABLE_NAME"
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an emergent test owes no RED, the same as at the commit gate" {
  write_file "apps/web/app/components/Widget/tests/index.test.tsx" 'import {expect, test} from "vitest";
test("renders something", () => { expect(true).toBe(true); });
'
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the run changes nothing in the tree or the real index" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  index_before=$(git -C "$REPO" rev-parse --git-path index)
  index_before=$(cd "$REPO" && shasum "$index_before")
  # Every path under the repo and its git dir, with content hashes, so a write
  # anywhere (ledger, sentinel, log) shows up as a difference.
  tree_before=$(cd "$REPO" && find . -type f -not -path './.git/objects/*' -exec shasum {} + | sort)
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 1 ]
  index_after=$(git -C "$REPO" rev-parse --git-path index)
  index_after=$(cd "$REPO" && shasum "$index_after")
  tree_after=$(cd "$REPO" && find . -type f -not -path './.git/objects/*' -exec shasum {} + | sort)
  [ "$index_before" = "$index_after" ]
  [ "$tree_before" = "$tree_after" ]
  [ -z "$(git -C "$REPO" diff --cached --name-only -z)" ]
}

@test "a gate that denies with no pending test (unusable registry) exits 2, never 0" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  write_package_registry "$REPO" '{'
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"gaia-packages"* ]]
}

@test "a root that is not a git work tree exits 2" {
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "a missing --root is a usage error, exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "two pending tests in two files print one line each" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  write_file "apps/web/app/utils/y/index.test.ts" 'import {expect, test} from "vitest";
test("subtracts", () => {
  expect(2 - 1).toBe(1);
});
'
  run bash "$SCRIPT" --root "$REPO"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 2 ]
  printf '%s\n' "${lines[@]}" | grep -qxF "$UNIT_PATH	adds two numbers"
  printf '%s\n' "${lines[@]}" | grep -qxF "apps/web/app/utils/y/index.test.ts	subtracts"
}

# The script reads the gate's offenders from its deny reason, so this pins the
# exact line shape it parses: a reworded bullet must fail here, not turn every
# pending test into an exit 2.
@test "the commit gate names each offender as a '  • file › test' line" {
  write_file "$UNIT_PATH" "$UNIT_TEST"
  git -C "$REPO" add "$UNIT_PATH"
  payload=$(jq -nc '{tool_name:"Bash", tool_input:{command:"git commit -m x"}}')
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$REPO" "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | grep -qxF "  • $UNIT_PATH › adds two numbers"
}
