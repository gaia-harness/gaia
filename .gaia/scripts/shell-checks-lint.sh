#!/usr/bin/env bash
# Runs shellcheck over the shell files the tests workflow's `Shellcheck and
# bats` job selected (.gaia/scripts/shell-checks-select.sh decides which).
#
# Usage: shell-checks-lint.sh --root <dir>
#
# Reads NUL-delimited paths, relative to --root, on stdin. `.sh` files get
# `shellcheck -S warning`; `.bats` files get `-s bash` as well, since bats is
# bash with `@test` sugar and carries no shebang shellcheck can read. A path
# that is not a regular file under the root is an error: the selector only
# names files present at the head. The root's own `.shellcheckrc` applies:
# that is the project's policy. Paths go through `xargs`, so a full-tree run
# never reaches the argument length limit.
#
# Exit: 0 when nothing is given or every lint passes, 1 on a lint failure, 2 on
# a usage error, a missing file, or a missing shellcheck.

set -euo pipefail

root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "shell-checks-lint: --root needs a value" >&2; exit 2; }
      root="$2"
      shift 2
      ;;
    *)
      echo "shell-checks-lint: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "shell-checks-lint: --root must name an existing directory" >&2
  exit 2
fi

shell_list="$(mktemp)"
bats_list="$(mktemp)"
trap 'rm -f "$shell_list" "$bats_list"' EXIT

count=0
while IFS= read -r -d '' path; do
  [ -f "$root/$path" ] || { echo "shell-checks-lint: not a file under the root: $path" >&2; exit 2; }
  case "$path" in
    *.bats) printf '%s\0' "$path" >> "$bats_list" ;;
    *) printf '%s\0' "$path" >> "$shell_list" ;;
  esac
  count=$((count + 1))
done

[ "$count" -gt 0 ] || { echo "shell-checks-lint: nothing to lint"; exit 0; }
command -v shellcheck >/dev/null 2>&1 || { echo "shell-checks-lint: shellcheck is not installed" >&2; exit 2; }

echo "shell-checks-lint: linting $count file(s)"
status=0
# Paths stay relative so findings name repo paths; the subshell keeps the
# caller's directory.
if [ -s "$shell_list" ]; then
  (cd "$root" && xargs -0 shellcheck -S warning -- < "$shell_list") || status=1
fi
if [ -s "$bats_list" ]; then
  (cd "$root" && xargs -0 shellcheck -S warning -s bash -- < "$bats_list") || status=1
fi
exit "$status"
