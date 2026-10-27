#!/bin/sh
# Runs the project's bats suites through the pinned npm bats (`pnpm test:shell`).
#
# Refuses, with one stderr line and exit 1, when the first `bash` on PATH is
# older than 4, or when its version cannot be read as an integer. The npm bats
# launcher runs under that bash, and bash 3.2 (the stock macOS /bin/bash)
# silently skips a failing bare double-bracket test inside a test, so a broken assertion
# would pass with nothing to catch it.
#
# With no arguments it runs bats on `tests/shell` when that directory exists in
# the current directory, and otherwise prints one line and exits 0. Any
# arguments go to bats unchanged. The suite directory is never searched
# recursively.

bash_major=$(bash -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)

case $bash_major in
  '' | *[!0-9]*) bash_major_shown='unknown' ;;
  *) bash_major_shown=$bash_major ;;
esac

if [ "$bash_major_shown" = 'unknown' ] || [ "$bash_major" -lt 4 ]; then
  echo "test:shell: bats needs bash 4 or later first on PATH (found $bash_major_shown); see .claude/skills/tdd/references/tests-shell.md" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  if [ -d tests/shell ]; then
    exec bats tests/shell
  fi
  echo 'test:shell: no tests/shell directory, nothing to run'
  exit 0
fi

exec bats "$@"
