#!/usr/bin/env bats
# Tests for `.gaia/scripts/simplify-discard.sh` in a throwaway repository, and
# for its reset against the real destructive-git hook and settings deny rows.
#
# The lossy-patch and unappliable-patch cases use a `git` shim on PATH that
# corrupts the saved patch, because a real `git diff` does not produce one on
# demand.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  . "$THIS_DIRECTORY/../../tests/hooks/helpers/run-hook.sh"
  SCRIPT="$THIS_DIRECTORY/../simplify-discard.sh"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.claude/hooks/block-main-destructive-git.sh"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  PAGE="$REPO_ROOT/.claude/skills/gaia/references/simplify-pass.md"
  TREE="$BATS_TEST_TMPDIR/tree"
  PATCH="$BATS_TEST_TMPDIR/out/simplify-discarded.patch"

  mkdir -p "$TREE"
  git -C "$TREE" init -q -b feature
  git -C "$TREE" config user.name test
  git -C "$TREE" config user.email test@example.invalid
  printf 'one\n' >"$TREE/tracked.txt"
  printf 'doomed\n' >"$TREE/doomed.txt"
  printf 'a\000b\000c\n' >"$TREE/image.bin"
  git -C "$TREE" add -A
  git -C "$TREE" commit -qm 'chore: fixture'
  HEAD_BEFORE="$(git -C "$TREE" rev-parse HEAD)"
}

# make_edits: every kind of change a pass can leave, including untracked and
# binary files, which a plain `git diff` would lose.
make_edits() {
  printf 'two\n' >"$TREE/tracked.txt"
  rm "$TREE/doomed.txt"
  printf 'x\000y\000z\n' >"$TREE/image.bin"
  mkdir -p "$TREE/src"
  printf 'new\n' >"$TREE/src/new.txt"
  printf 'p\000q\n' >"$TREE/src/new.bin"
  STATUS_BEFORE="$(git -C "$TREE" status --porcelain)"
  EDITED_SUMS="$(edited_sums)"
}

edited_sums() {
  cksum <"$TREE/tracked.txt"
  cksum <"$TREE/image.bin"
  cksum <"$TREE/src/new.txt"
  cksum <"$TREE/src/new.bin"
}

# git_shim <sed program>: a `git` whose `diff` output passes through sed.
git_shim() {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  if [ "\$argument" = diff ]; then
    "$real_git" "\$@" | sed '$1'
    exit 0
  fi
done
exec "$real_git" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
}

# assert_nothing_reset: the edits are in the tree exactly as made, unstaged.
assert_nothing_reset() {
  [ "$(git -C "$TREE" status --porcelain)" = "$STATUS_BEFORE" ] || {
    echo "the tree changed: $(git -C "$TREE" status --porcelain)" >&2
    return 1
  }
  [ "$(edited_sums)" = "$EDITED_SUMS" ] || { echo 'the edited bytes changed' >&2; return 1; }
  git -C "$TREE" diff --cached --quiet || { echo 'the real index was touched' >&2; return 1; }
}

# run_real_hook <command>: the real hook, invoked from inside the throwaway
# tree, because it treats a command aimed at another repository as out of scope
# and would allow anything.
run_real_hook() {
  local json
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook_in "$TREE" "$json" "$HOOK_ABSOLUTE_PATH"
}

# denied_by_settings <command>: exit 0 when a Bash deny row in settings matches.
denied_by_settings() {
  local row pattern
  while IFS= read -r row; do
    pattern="${row#Bash(}"
    pattern="${pattern%)}"
    # shellcheck disable=SC2254 # The row is a glob on purpose.
    case "$1" in
      $pattern) return 0 ;;
    esac
  done < <(jq -r '.permissions.deny[] | select(startswith("Bash("))' "$SETTINGS")
  return 1
}

@test "a discard saves every kind of edit, restores the tree, and the patch brings the edits back" {
  make_edits
  run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  [ -z "$(git -C "$TREE" status --porcelain)" ]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$HEAD_BEFORE" ]
  [ ! -e "$TREE/src/new.txt" ]
  [ -f "$TREE/doomed.txt" ]

  git -C "$TREE" apply --binary "$PATCH"
  [ "$(edited_sums)" = "$EDITED_SUMS" ]
  [ ! -e "$TREE/doomed.txt" ]
}

@test "a discard of edits the gate step already staged saves and restores them too" {
  make_edits
  git -C "$TREE" add -A
  run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -z "$(git -C "$TREE" status --porcelain)" ]
  git -C "$TREE" apply --binary "$PATCH"
  [ "$(edited_sums)" = "$EDITED_SUMS" ]
}

@test "a discard under a non-default diff format still saves a patch that applies" {
  make_edits
  git -C "$TREE" config diff.noprefix true
  git -C "$TREE" config color.ui always
  run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -z "$(git -C "$TREE" status --porcelain)" ]
  git -C "$TREE" apply --binary "$PATCH"
  [ "$(edited_sums)" = "$EDITED_SUMS" ]
}

@test "a patch that cannot be written refuses the reset" {
  make_edits
  printf 'a file, not a folder\n' >"$BATS_TEST_TMPDIR/blocker"
  run "$SCRIPT" --root "$TREE" --patch "$BATS_TEST_TMPDIR/blocker/simplify-discarded.patch"
  [ "$status" -eq 1 ]
  [[ "$output" == *'nothing was reset'* ]]
  assert_nothing_reset
}

@test "a patch path git cannot write to refuses the reset at the save" {
  make_edits
  mkdir -p "$BATS_TEST_TMPDIR/a-folder"
  run "$SCRIPT" --root "$TREE" --patch "$BATS_TEST_TMPDIR/a-folder"
  [ "$status" -eq 1 ]
  [[ "$output" == *'could not save'* ]]
  assert_nothing_reset
}

@test "an empty patch refuses the reset" {
  run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *'is empty'* ]]
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$HEAD_BEFORE" ]
}

@test "a patch that drops a binary file's change refuses the reset" {
  make_edits
  git_shim '/^diff --git a\/image.bin/,/^diff --git a\/src/{/^diff --git a\/src/!d;}'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *'does not restore the edits'* ]]
  assert_nothing_reset
}

@test "a patch that does not apply refuses the reset" {
  make_edits
  git_shim 's/^@@ .*/@@ corrupted @@/'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" --root "$TREE" --patch "$PATCH"
  [ "$status" -eq 1 ]
  [[ "$output" == *'does not apply'* ]]
  assert_nothing_reset
}

@test "a missing argument is a usage error and resets nothing" {
  make_edits
  run "$SCRIPT" --root "$TREE"
  [ "$status" -eq 2 ]
  assert_nothing_reset
}

@test "the script's own reset passes the real hook and every settings deny row" {
  local line
  line="$(grep -E '^if ! git -C "\$root" reset --hard; then$' "$SCRIPT")"
  [ -n "$line" ] || { echo 'the reset line moved; this test no longer reads it' >&2; return 1; }

  local command="git -C $TREE reset --hard"
  run_real_hook "$command"
  assert_allowed_by_json
  denied_by_settings "$command" && return 1
  denied_by_settings 'git reset --hard' && return 1
  true
}

@test "red twin: a reset that moves HEAD is denied by the hook and by the settings row" {
  printf 'more\n' >>"$TREE/tracked.txt"
  git -C "$TREE" add -A
  git -C "$TREE" commit -qm 'chore: another'
  run_real_hook "git -C $TREE reset --hard HEAD~1"
  assert_denied_by_json
  denied_by_settings 'git reset --hard HEAD~1'
}

@test "no allow rule covers the script, so a default-permission run asks before the reset" {
  [ "$(jq '[.permissions.allow[] | select(contains("simplify-discard"))] | length' "$SETTINGS")" -eq 0 ]
  [ "$(jq '.permissions.allow | length' "$SETTINGS")" -gt 0 ]
}

# page_pins <file>: what the pass depends on and an edit could quietly lose.
page_pins() {
  grep -qF '<merge base sha>...HEAD' "$1" || return 1
  grep -qF '@{upstream}...HEAD' "$1" || return 1
  grep -qF 'model: "opus"' "$1" || return 1
  grep -qF 'simplify-discard.sh --root' "$1" || return 1
  grep -qF '## Simplify pass (HALTED)' "$1" || return 1
  grep -qF 'Result: <applied | no changes | not run | discarded>' "$1" || return 1
}

@test "the page names the explicit range, the model, the discard and every result" {
  page_pins "$PAGE"
}

@test "red twin: a page without the explicit range fails the pin check" {
  local copy="$BATS_TEST_TMPDIR/page.md"
  sed 's/<merge base sha>\.\.\.HEAD/HEAD/' "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && { echo 'the range is not on the page' >&2; return 1; }
  run page_pins "$copy"
  [ "$status" -ne 0 ]
}
