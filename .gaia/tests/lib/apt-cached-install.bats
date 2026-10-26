#!/usr/bin/env bats

# Behavior of .github/actions/gaia-apt-cache/apt-cached-install.sh off a real
# runner: sudo, timeout, apt-get and sleep are stubs on PATH that record each
# call, and APT_CONFIGURATION_FILE keeps the apt.conf.d snippet out of /etc.
# The stubs exit with the status the test sets, so each path the helper can
# take (warm, warm falling through to cold, cold retries, exhaustion) is
# driven, not inferred.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], no `!`-negated non-final assertion.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  helper="$BATS_TEST_DIRNAME/../../../.github/actions/gaia-apt-cache/apt-cached-install.sh"
  [ -f "$helper" ]
  stub_directory="$BATS_TEST_TMPDIR/stubs"
  archive_directory="$BATS_TEST_TMPDIR/archives"
  call_log="$BATS_TEST_TMPDIR/calls.log"
  export APT_CONFIGURATION_FILE="$BATS_TEST_TMPDIR/90gaia-archive-cache"
  export CALL_LOG="$call_log"
  mkdir -p "$stub_directory" "$archive_directory"
  : >"$call_log"

  printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$stub_directory/sudo"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "timeout $1" >>"$CALL_LOG"' \
    'shift' \
    'exec "$@"' >"$stub_directory/timeout"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "sleep $*" >>"$CALL_LOG"' >"$stub_directory/sleep"
  # A warm install also records the snippet apt would read at that moment,
  # so a test can tell it was written before the offline install ran.
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "apt-get $*" >>"$CALL_LOG"' \
    'case " $* " in' \
    '  *" --no-download "*)' \
    '    cat "$APT_CONFIGURATION_FILE" >>"$CALL_LOG" 2>/dev/null || echo "no snippet" >>"$CALL_LOG"' \
    '    exit "${STUB_WARM_STATUS:-0}" ;;' \
    '  " update ") exit "${STUB_UPDATE_STATUS:-0}" ;;' \
    'esac' \
    'exit "${STUB_INSTALL_STATUS:-0}"' >"$stub_directory/apt-get"
  chmod +x "$stub_directory"/*
  PATH="$stub_directory:$PATH"
}

run_helper() {
  run bash "$helper" --archive-dir "$archive_directory" "$@"
}

@test "a usage error exits 2" {
  run bash "$helper" --update-seconds 1 --install-seconds 1 --attempts 1 -- apt-get install -y zsh
  [ "$status" -eq 2 ]
  run_helper --update-seconds 1 --install-seconds 1 --attempts three -- apt-get install -y zsh
  [ "$status" -eq 2 ]
  run_helper --update-seconds soon --install-seconds 1 --attempts 1 -- apt-get install -y zsh
  [ "$status" -eq 2 ]
  run_helper --update-seconds 1 --install-seconds 1 --attempts 1 --
  [ "$status" -eq 2 ]
  run_helper --update-seconds 1 --install-seconds 0 --attempts 1 -- apt-get install -y zsh
  [ "$status" -eq 2 ]
}

@test "cached archives install offline and the install command never runs" {
  touch "$archive_directory/zsh_5.9_amd64.deb"
  run_helper --update-seconds 45 --install-seconds 150 --attempts 3 -- apt-get install -y zsh
  [ "$status" -eq 0 ]
  grep -qF -- "--no-download" "$call_log"
  grep -qF "Dir::Cache::Archives \"$archive_directory/\";" "$call_log"
  grep -qF "apt-get update" "$call_log" && return 1
  grep -qxF "apt-get install -y zsh" "$call_log" && return 1
  true
}

@test "a failed offline install falls through to the mirror" {
  touch "$archive_directory/zsh_5.9_amd64.deb"
  STUB_WARM_STATUS=100 run_helper --update-seconds 45 --install-seconds 150 --attempts 3 -- apt-get install -y zsh
  [ "$status" -eq 0 ]
  grep -qxF "apt-get update" "$call_log"
  grep -qxF "apt-get install -y zsh" "$call_log"
  grep -qxF "timeout 45" "$call_log"
  grep -qxF "timeout 150" "$call_log"
}

@test "an empty archive directory goes straight to the mirror" {
  run_helper --update-seconds 45 --install-seconds 150 --attempts 3 -- apt-get install -y zsh
  [ "$status" -eq 0 ]
  grep -qF -- "--no-download" "$call_log" && return 1
  grep -qxF "apt-get install -y zsh" "$call_log"
}

@test "update-seconds 0 skips the separate apt-get update" {
  run_helper --update-seconds 0 --install-seconds 180 --attempts 3 -- apt-get install -y zsh
  [ "$status" -eq 0 ]
  grep -qxF "apt-get update" "$call_log" && return 1
  grep -qxF "apt-get install -y zsh" "$call_log"
}

@test "exhausted attempts exit 1, back off between them and name the re-run" {
  GITHUB_RUN_ID=4242 STUB_INSTALL_STATUS=100 run_helper --update-seconds 45 --install-seconds 150 --attempts 3 -- apt-get install -y zsh
  [ "$status" -eq 1 ]
  [ "$(grep -cxF "apt-get install -y zsh" "$call_log")" -eq 3 ]
  [ "$(grep -c '^sleep ' "$call_log")" -eq 2 ]
  grep -qxF "sleep 10" "$call_log"
  grep -qxF "sleep 20" "$call_log"
  [[ "$output" == *"gh run rerun 4242 --failed"* ]]
}

@test "the apt.conf.d snippet and apt's root-only leftovers are removed on exit" {
  STUB_INSTALL_STATUS=100 run_helper --update-seconds 0 --install-seconds 1 --attempts 1 -- apt-get install -y zsh
  [ "$status" -eq 1 ]
  [ -e "$APT_CONFIGURATION_FILE" ] && return 1
  [ -e "$archive_directory/partial" ] && return 1
  [ -d "$archive_directory" ]
}
