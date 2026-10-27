#!/usr/bin/env bats

# Suite for .gaia/scripts/test-shell.sh, the pnpm test:shell wrapper adopters use
# to run the pinned bats. It must refuse, with one stderr line, when the first
# bash on PATH is older than 4 (a failing bare [[ ]] silently passes there), and
# must otherwise hand the suite directory or the caller's arguments to bats.
#
# Also guards the shipped assertion-hygiene rule: with its maintainer-only blocks
# stripped the way the release scrub strips them, nothing GAIA-internal remains.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRAPPER="$REPO/.gaia/scripts/test-shell.sh"
  RULE="$REPO/.claude/rules/bats-assertions.md"
  SHIMS="$BATS_TEST_TMPDIR/shims"
  WORK="$BATS_TEST_TMPDIR/work"
  CALLS="$BATS_TEST_TMPDIR/bats-calls"
  mkdir -p "$SHIMS" "$WORK"
  cat >"$SHIMS/bats" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >>"$CALLS"
SHIM
  chmod +x "$SHIMS/bats"
  BASH5_DIR="$(dirname "$BASH")"
}

fake_bash_printing() {
  printf '#!/bin/sh\nprintf %%s %s\n' "$1" >"$SHIMS/bash"
  chmod +x "$SHIMS/bash"
}

run_wrapper() {
  cd "$WORK" || return 1
  run env PATH="$SHIMS:$BASH5_DIR:/usr/bin:/bin" /bin/sh "$WRAPPER" "$@"
}

stderr_of_wrapper() {
  cd "$WORK" || return 1
  PATH="$SHIMS:$BASH5_DIR:/usr/bin:/bin" /bin/sh "$WRAPPER" >/dev/null 2>"$BATS_TEST_TMPDIR/stderr" || true
  cat "$BATS_TEST_TMPDIR/stderr"
}

@test "refuses when the first bash reports major 3" {
  fake_bash_printing 3
  mkdir -p "$WORK/tests/shell"
  run_wrapper
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$CALLS" ] || return 1
}

@test "refusal prints exactly one stderr line naming the version and the stack reference" {
  fake_bash_printing 3
  local err
  err="$(stderr_of_wrapper)"
  [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || return 1
  case "$err" in *"found 3"*) ;; *) return 1 ;; esac
  case "$err" in *".claude/skills/tdd/references/tests-shell.md"*) ;; *) return 1 ;; esac
}

@test "refuses a non-integer probe result" {
  fake_bash_printing abc
  run_wrapper
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$CALLS" ] || return 1
}

@test "refuses an empty probe result" {
  printf '#!/bin/sh\nexit 0\n' >"$SHIMS/bash"
  chmod +x "$SHIMS/bash"
  run_wrapper
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$CALLS" ] || return 1
}

@test "refuses under the real /bin/bash when it is older than 4" {
  local major
  major="$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}"')"
  [ "$major" -lt 4 ] || skip "/bin/bash is $major"
  cd "$WORK" || return 1
  run env PATH="$SHIMS:/bin:/usr/bin" /bin/sh "$WRAPPER"
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$CALLS" ] || return 1
}

@test "no arguments runs bats on tests/shell when it exists" {
  mkdir -p "$WORK/tests/shell"
  run_wrapper
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$CALLS")" = "tests/shell" ] || return 1
}

@test "explicit arguments pass through unchanged" {
  mkdir -p "$WORK/tests/shell"
  run_wrapper tests/shell/a.bats --filter x
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$CALLS")" = "tests/shell/a.bats --filter x" ] || return 1
}

@test "no arguments and no tests/shell prints one line and exits 0 without calling bats" {
  run_wrapper
  [ "$status" -eq 0 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
  [ ! -e "$CALLS" ] || return 1
}

@test "the wrapper is clean POSIX sh" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  run shellcheck -s sh "$WRAPPER"
  [ "$status" -eq 0 ] || return 1
  head -n 1 "$WRAPPER" | grep -qx '#!/bin/sh' || return 1
  grep -nE '\[\[|\blocal\b|\$'"'"'|=\(' "$WRAPPER" && return 1
  true
}

strip_maintainer_blocks() {
  awk '/^<!-- gaia:maintainer-only:start -->$/ {skip=1; next}
       /^<!-- gaia:maintainer-only:end -->$/ {skip=0; next}
       !skip' "$1"
}

denylist_hits() {
  grep -nF -e 'bats5' -e 'guard below' -e 'verify-harness' -e 'whole-tree' \
    -e '.gaia/tests/' -e 'change selector' -e 'gaia-lint-ignore' -e 'than CI'
}

@test "the stripped rule holds no GAIA-internal text and keeps its scope and pointer" {
  local stripped="$BATS_TEST_TMPDIR/stripped.md"
  strip_maintainer_blocks "$RULE" >"$stripped"
  denylist_hits <"$stripped" && return 1
  grep -qF "'**/*.bats'" "$stripped" || return 1
  grep -qF ".claude/skills/tdd/references/tests-shell.md" "$stripped" || return 1
  true
}

@test "the denylist check fails over the unstripped rule" {
  denylist_hits <"$RULE"
}
