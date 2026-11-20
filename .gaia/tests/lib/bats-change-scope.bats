#!/usr/bin/env bats

# Pins .gaia/tests/bats-change-scope.sh, the classifier that tells a change
# scoped CI leg whether a diff touches harness machinery (a static path list or
# a shell file other shell files source) or a dependency install input.
#
# The fixture cases build a throwaway git repository under $BATS_TEST_TMPDIR,
# commit a base, commit a change, and classify `HEAD~1 HEAD`. The pairs that
# differ by one line (a sourced file versus a standalone one, a `source` line
# present versus removed) prove the shared-library rule can tell the two apart.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only: `.gaia/tests` is release-excluded.

bats_require_minimum_version 1.5.0

reset_fixture() {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.name fixture
  git -C "$FIXTURE" config user.email fixture@example.invalid
  git -C "$FIXTURE" config commit.gpgsign false
}

setup() {
  CLASSIFIER="$BATS_TEST_DIRNAME/../bats-change-scope.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  reset_fixture
}

write_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "${2:-content}" > "$FIXTURE/$1"
}

commit_all() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "$1"
}

# Commits the files already written as the base, then one edit to each named
# path as the change.
commit_base_then_change() {
  commit_all base
  local changed_path
  for changed_path in "$@"; do
    printf 'changed\n' >> "$FIXTURE/$changed_path"
  done
  commit_all change
}

classify() {
  run bash "$CLASSIFIER" --dir "$FIXTURE" HEAD~1 HEAD
}

# Fails the test unless the output is exactly the given lines, in order.
expect_output_lines() {
  local expected
  expected="$(printf '%s\n' "$@")"
  if [ "$output" != "$expected" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
    return 1
  fi
}

@test "each path category classifies as the expected change class (harness, near-miss, install input, change-scoped)" {
  local row changed_path expected_class
  write_file base.txt
  commit_all base
  for row in \
    ".github/workflows/audit-ci-tests.yml|harness" \
    ".gaia/tests/bats-shards.sh|harness" \
    ".gaia/tests/bats-change-scope.sh|harness" \
    ".gaia/scripts/bats-suites-for-change.sh|harness" \
    ".gaia/tests/install-bats.sh|harness" \
    ".gaia/tests/vendor/bats/x|harness" \
    ".gaia/tests/hooks/helpers/x.sh|harness" \
    ".gaia/tests/helpers/x.sh|harness" \
    ".gaia/scripts/tests/helpers/x.sh|harness" \
    ".github/actions/a/action.yml|harness" \
    ".gaia/release-exclude|harness" \
    ".claude/hooks/lib/x.sh|harness" \
    ".claude/hooks/a/lib/x.sh|harness" \
    ".gaia/scripts/lib/x.sh|harness" \
    "foo/bar-lib.sh|harness" \
    "bar-lib.sh|harness" \
    ".gaia/tests/hooks/x.sh|none" \
    ".github/workflows/other.yml|none" \
    "foo/bar-lib.sh.bak|none" \
    "package.json|dependency" \
    "pnpm-lock.yaml|dependency" \
    "pnpm-workspace.yaml|dependency" \
    ".npmrc|dependency" \
    ".node-version|dependency" \
    "apps/web/package.json|dependency" \
    ".gaia/cli/package.json|dependency" \
    ".claude/skills/x/SKILL.md|none" \
    ".claude/commands/x.md|none" \
    ".claude/agents/x.md|none" \
    ".claude/hooks/x.sh|none" \
    ".gaia/cli/src/x.ts|none" \
    "wiki/x/Y Z.md|none"; do
    changed_path=${row%|*}
    expected_class=${row##*|}
    printf '%s\n' "$changed_path" > "$BATS_TEST_TMPDIR/paths.txt"
    run bash "$CLASSIFIER" --dir "$FIXTURE" --paths "$BATS_TEST_TMPDIR/paths.txt"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    if [ "$expected_class" = none ]; then
      [ -z "$output" ] || { echo "row $row: got '$output'"; return 1; }
    else
      [ "$output" = "$(printf '%s\t%s' "$expected_class" "$changed_path")" ] || { echo "row $row: got '$output'"; return 1; }
    fi
  done
}

@test "a shell file is harness only when another file sources it (literal, variable-built, shellcheck directive), not for assignment alone, heredoc, comment or jq dot" {
  reset_fixture
  write_file a.sh '. "$DIR/shared.sh"'
  write_file shared.sh
  commit_base_then_change shared.sh
  classify
  [ "$status" -eq 0 ] || { echo "literal operand: status $status"; return 1; }
  expect_output_lines "$(printf 'harness\tshared.sh')" || { echo "literal operand"; return 1; }

  reset_fixture
  write_file entry.sh 'lib_path="$DIR/../x/gaia-packages.sh"
source "$lib_path"'
  write_file x/gaia-packages.sh
  commit_base_then_change x/gaia-packages.sh
  classify
  [ "$status" -eq 0 ] || { echo "variable-built path: status $status"; return 1; }
  expect_output_lines "$(printf 'harness\tx/gaia-packages.sh')" || { echo "variable-built path"; return 1; }

  reset_fixture
  write_file entry.sh 'lib_path="$DIR/../x/gaia-packages.sh"
echo "$lib_path"'
  write_file x/gaia-packages.sh
  commit_base_then_change x/gaia-packages.sh
  classify
  [ "$status" -eq 0 ] || { echo "assignment alone: status $status"; return 1; }
  [ -z "$output" ] || { echo "assignment alone: got '$output'"; return 1; }

  reset_fixture
  write_file entry.sh '# shellcheck source=lib/thing.sh
. "$resolved"'
  write_file pkg/thing.sh
  commit_base_then_change pkg/thing.sh
  classify
  [ "$status" -eq 0 ] || { echo "shellcheck directive: status $status"; return 1; }
  expect_output_lines "$(printf 'harness\tpkg/thing.sh')" || { echo "shellcheck directive"; return 1; }

  reset_fixture
  write_file standalone.sh
  write_file other.sh 'echo hello'
  commit_base_then_change standalone.sh
  classify
  [ "$status" -eq 0 ] || { echo "standalone: status $status"; return 1; }
  [ -z "$output" ] || { echo "standalone: got '$output'"; return 1; }
  write_file other.sh 'source "$DIR/standalone.sh"'
  commit_all sourcing
  printf 'again\n' >> "$FIXTURE/standalone.sh"
  commit_all change-again
  classify
  [ "$status" -eq 0 ] || { echo "once sourced: status $status"; return 1; }
  expect_output_lines "$(printf 'harness\tstandalone.sh')" || { echo "once sourced"; return 1; }

  reset_fixture
  write_file entry.sh 'cat <<EOF
source "$DIR/in-heredoc.sh"
EOF
# source "$DIR/in-comment.sh"
echo done'
  write_file in-heredoc.sh
  write_file in-comment.sh
  commit_base_then_change in-heredoc.sh in-comment.sh
  classify
  [ "$status" -eq 0 ] || { echo "heredoc and comment: status $status"; return 1; }
  [ -z "$output" ] || { echo "heredoc and comment: got '$output'"; return 1; }

  reset_fixture
  write_file entry.sh "jq -r '. as \$rows | \$rows' < input.json"
  write_file as.sh
  commit_base_then_change as.sh
  classify
  [ "$status" -eq 0 ] || { echo "jq dot: status $status"; return 1; }
  [ -z "$output" ] || { echo "jq dot: got '$output'"; return 1; }
}

@test "--list-install-inputs prints exactly the install inputs, one per line" {
  run bash "$CLASSIFIER" --list-install-inputs
  [ "$status" -eq 0 ]
  expect_output_lines package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc .node-version apps/web/package.json .gaia/cli/package.json
}

@test "a renamed file lists both its old and new path" {
  write_file old-lib.sh
  commit_all base
  git -C "$FIXTURE" mv old-lib.sh new-lib.sh
  commit_all rename
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tnew-lib.sh')" "$(printf 'harness\told-lib.sh')"
}

@test "--paths classifies a newline-delimited path list" {
  write_file entry.sh 'source "$DIR/shared.sh"'
  write_file shared.sh
  commit_all base
  printf 'shared.sh\npackage.json\nwiki/x/Y Z.md\n' > "$BATS_TEST_TMPDIR/paths.txt"
  run bash "$CLASSIFIER" --dir "$FIXTURE" --paths "$BATS_TEST_TMPDIR/paths.txt"
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'dependency\tpackage.json')" "$(printf 'harness\tshared.sh')"
}

@test "the classifier refuses a bad repository, diff or option with its documented exit code" {
  write_file x.txt
  commit_all base
  mkdir -p "$BATS_TEST_TMPDIR/plain"

  run --separate-stderr bash "$CLASSIFIER" --dir "$FIXTURE" no-such-commit HEAD
  [ "$status" -eq 3 ] || { echo "missing commit: status $status"; return 1; }
  [ -z "$output" ] || { echo "missing commit: stdout '$output'"; return 1; }

  run --separate-stderr bash "$CLASSIFIER" --dir "$BATS_TEST_TMPDIR/plain" HEAD~1 HEAD
  [ "$status" -eq 3 ] || { echo "not a repository: status $status"; return 1; }
  [ -z "$output" ] || { echo "not a repository: stdout '$output'"; return 1; }

  run bash "$CLASSIFIER" --dir "$FIXTURE"
  [ "$status" -eq 2 ] || { echo "no diff argument: status $status"; return 1; }

  run bash "$CLASSIFIER" --dir "$FIXTURE" --bogus
  [ "$status" -eq 2 ] || { echo "unknown option: status $status"; return 1; }
}

@test "--list-harness-paths prints the static globs in order" {
  run bash "$CLASSIFIER" --list-harness-paths
  [ "$status" -eq 0 ]
  expect_output_lines \
    '.github/workflows/audit-ci-tests.yml' \
    '.gaia/tests/bats-shards.sh' \
    '.gaia/tests/bats-change-scope.sh' \
    '.gaia/scripts/bats-suites-for-change.sh' \
    '.gaia/tests/install-bats.sh' \
    '.gaia/tests/vendor/**' \
    '.gaia/tests/helpers/**' \
    '.gaia/tests/**/helpers/**' \
    '.gaia/scripts/tests/helpers/**' \
    '.github/actions/**' \
    '.gaia/release-exclude' \
    '.claude/hooks/**/lib/**' \
    '.gaia/scripts/**/lib/**' \
    '**/*-lib.sh'
}

# bats test_tags=whole-tree
@test "the real tree maps its shared libraries to harness" {
  local real_root
  real_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  local library_path
  for library_path in ".claude/hooks/lib/gaia-packages.sh" ".gaia/scripts/spec/flows-lib.sh"; do
    printf '%s\n' "$library_path" > "$BATS_TEST_TMPDIR/real-paths.txt"
    run bash "$CLASSIFIER" --dir "$real_root" --paths "$BATS_TEST_TMPDIR/real-paths.txt"
    [ "$status" -eq 0 ]
    expect_output_lines "$(printf 'harness\t%s' "$library_path")"
  done
}

# bats test_tags=whole-tree
@test "the real tree keeps change-scoped categories out of harness" {
  local real_root
  real_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  local skill_doc command_doc agent_doc cli_source wiki_page lone_hook
  skill_doc="$(git -C "$real_root" ls-files -z -- '.claude/skills/*/SKILL.md' | tr '\0' '\n' | sed -n 1p)"
  command_doc="$(git -C "$real_root" ls-files -z -- '.claude/commands/*.md' | tr '\0' '\n' | sed -n 1p)"
  agent_doc="$(git -C "$real_root" ls-files -z -- '.claude/agents/*.md' | tr '\0' '\n' | sed -n 1p)"
  cli_source="$(git -C "$real_root" ls-files -z -- '.gaia/cli/src/*.ts' | tr '\0' '\n' | sed -n 1p)"
  wiki_page="$(git -C "$real_root" ls-files -z -- 'wiki/*.md' | tr '\0' '\n' | sed -n 1p)"
  lone_hook=""
  local hook_path hook_name
  while IFS= read -r hook_path; do
    hook_name="$(basename "$hook_path")"
    if ! git -C "$real_root" grep -q -F -e "$hook_name" -- '*.sh' ':!'"$hook_path"; then
      lone_hook="$hook_path"
      break
    fi
  done < <(git -C "$real_root" ls-files -z -- '.claude/hooks/*.sh' | tr '\0' '\n')
  local category_path
  for category_path in "$skill_doc" "$command_doc" "$agent_doc" "$cli_source" "$wiki_page" "$lone_hook"; do
    [ -n "$category_path" ]
  done
  printf '%s\n' "$skill_doc" "$command_doc" "$agent_doc" "$cli_source" "$wiki_page" "$lone_hook" \
    > "$BATS_TEST_TMPDIR/real-paths.txt"
  run bash "$CLASSIFIER" --dir "$real_root" --paths "$BATS_TEST_TMPDIR/real-paths.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
