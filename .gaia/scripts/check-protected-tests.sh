#!/usr/bin/env bash
# Protected-test gate. A bats test tagged `protected` (`# bats test_tags=protected`
# above it, or `# bats file_tags=protected` over its suite) is the one real case
# of a security, permission, enforcement-hook or data-loss behavior; when to tag
# one is `.claude/rules/bats-assertions.md`. This gate fails when a test that
# carries the tag at the merge base is gone from the working tree, or has lost
# the tag, unless a commit since the merge base carries a waiver trailer naming
# it:
#
#   Protected-Test-Removed: <suite path> :: <test name> -- <reason>
#
# A test is keyed by suite path and name, so a rename or a move counts as a
# disappearance and needs the waiver too. The trailer lives in a commit message
# rather than a tracked file because a deleted suite has no file left to carry
# it, and the squash merge keeps it in the history the reviewer reads.
#
# Usage: check-protected-tests.sh [--base <rev>]
#
# The base defaults to the merge base of HEAD with the remote default branch.
# With no such ref (a shallow CI checkout) the gate prints that it checked
# nothing and exits 0: `verify-harness.sh branch`, which every audit dispatch
# waits on, runs it with the full history.
#
# Exit 0 clean (or no base to compare). Exit 1 on an unwaived removal or a
# waiver with no reason. Exit 2 on a usage error or a git read that failed.
#
# Output lines:
#   REMOVED <suite path> :: <test name>   a protected test gone or untagged
#   BAD-WAIVER <trailer text>             a waiver whose reason is empty

set -uo pipefail

PROGRAM_NAME=check-protected-tests
base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || { printf '%s: --base needs a revision\n' "$PROGRAM_NAME" >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    *)
      printf '%s: unknown argument %s\n' "$PROGRAM_NAME" "$1" >&2
      exit 2
      ;;
  esac
done

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { printf '%s: not inside a git checkout\n' "$PROGRAM_NAME" >&2; exit 2; }

if [ -z "$base" ]; then
  default_branch="$(git -C "$repository_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  default_branch="${default_branch#refs/remotes/origin/}"
  [ -n "$default_branch" ] || default_branch=main
  if ! base="$(git -C "$repository_root" merge-base "refs/remotes/origin/$default_branch" HEAD 2>/dev/null)"; then
    printf '%s: no merge base with refs/remotes/origin/%s; nothing was compared\n' "$PROGRAM_NAME" "$default_branch" >&2
    exit 0
  fi
fi
git -C "$repository_root" rev-parse -q --verify "$base^{commit}" >/dev/null \
  || { printf '%s: %s is not a commit\n' "$PROGRAM_NAME" "$base" >&2; exit 2; }

# protected_names: the names of the protected tests in the suite text on stdin,
# one per line. bats applies a test_tags line to the next @test only, and keeps
# the last one before it; a file_tags line applies to every test after it.
protected_names() {
  awk '
    function tagged(line,   list, items, count, position) {
      list = line
      sub(/^# bats (test|file)_tags=/, "", list)
      count = split(list, items, ",")
      for (position = 1; position <= count; position++) {
        gsub(/[ \t]/, "", items[position])
        if (items[position] == "protected") return 1
      }
      return 0
    }
    /^# bats file_tags=/ { file_protected = tagged($0); next }
    /^# bats test_tags=/ { test_protected = tagged($0); next }
    /^@test / {
      if (file_protected || test_protected) {
        name = $0
        sub(/^@test[ \t]+/, "", name)
        sub(/[ \t]*\{[ \t]*$/, "", name)
        quote = substr(name, 1, 1)
        if ((quote == "\"" || quote == "'"'"'") && substr(name, length(name), 1) == quote) {
          name = substr(name, 2, length(name) - 2)
        }
        print name
      }
      test_protected = 0
    }
  '
}

scratch_directory="$(mktemp -d)" || { printf '%s: cannot create a scratch directory\n' "$PROGRAM_NAME" >&2; exit 2; }
trap 'rm -rf "$scratch_directory"' EXIT

# Only a suite that differs from the base can have lost a test.
git -C "$repository_root" -c core.quotepath=false diff --name-only --no-renames -z "$base" -- '*.bats' \
  >"$scratch_directory/changed" \
  || { printf '%s: git diff against %s failed\n' "$PROGRAM_NAME" "$base" >&2; exit 2; }

git -C "$repository_root" log --format=%B "$base..HEAD" >"$scratch_directory/messages" \
  || { printf '%s: reading the commit messages since %s failed\n' "$PROGRAM_NAME" "$base" >&2; exit 2; }
sed -n 's/^Protected-Test-Removed:[[:space:]]*//p' "$scratch_directory/messages" >"$scratch_directory/waivers"

status=0
while IFS= read -r waiver; do
  case "$waiver" in
    *' -- '*) reason="${waiver#* -- }" ;;
    *) reason="" ;;
  esac
  if [ -z "${reason//[[:space:]]/}" ]; then
    printf 'BAD-WAIVER %s\n' "$waiver"
    status=1
  fi
done <"$scratch_directory/waivers"

while IFS= read -r -d '' suite_path; do
  git -C "$repository_root" cat-file -e "$base:$suite_path" 2>/dev/null || continue
  git -C "$repository_root" show "$base:$suite_path" | protected_names >"$scratch_directory/before" \
    || { printf '%s: reading %s at %s failed\n' "$PROGRAM_NAME" "$suite_path" "$base" >&2; exit 2; }
  : >"$scratch_directory/after"
  if [ -f "$repository_root/$suite_path" ]; then
    protected_names <"$repository_root/$suite_path" >"$scratch_directory/after"
  fi
  while IFS= read -r test_name; do
    grep -qxF -- "$test_name" "$scratch_directory/after" && continue
    awk -v key="$suite_path :: $test_name" 'index($0, key " -- ") == 1 { found = 1 } END { exit !found }' \
      "$scratch_directory/waivers" && continue
    printf 'REMOVED %s :: %s\n' "$suite_path" "$test_name"
    status=1
  done <"$scratch_directory/before"
done <"$scratch_directory/changed"

if [ "$status" -ne 0 ]; then
  printf '%s: a protected test was removed or untagged. Keep it, or add a trailer to a commit on this branch:\n' "$PROGRAM_NAME" >&2
  printf '  Protected-Test-Removed: <suite path> :: <test name> -- <reason>\n' >&2
  exit 1
fi
printf '%s: clean\n' "$PROGRAM_NAME" >&2
exit 0
