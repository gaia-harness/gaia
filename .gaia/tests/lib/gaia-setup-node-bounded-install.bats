#!/usr/bin/env bats
# Behavior of .github/actions/gaia-setup-node/bounded-install.sh off a real
# runner: timeout is a stub on PATH that records its bound and runs the
# command, and the install is a fake that exits with the status each attempt
# is scripted to return, so every path the helper can take (in time, bounded
# then in time, bounded twice, failed on its own) is driven, not inferred.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], no `!`-negated non-final assertion.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  helper="$BATS_TEST_DIRNAME/../../../.github/actions/gaia-setup-node/bounded-install.sh"
  [ -f "$helper" ]
  stub_directory="$BATS_TEST_TMPDIR/stubs"
  call_log="$BATS_TEST_TMPDIR/calls.log"
  export CALL_LOG="$call_log"
  export ATTEMPT_COUNTER="$BATS_TEST_TMPDIR/attempts"
  mkdir -p "$stub_directory"
  : >"$call_log"
  echo 0 >"$ATTEMPT_COUNTER"

  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "timeout $1 $2" >>"$CALL_LOG"' \
    'shift 2' \
    'exec "$@"' >"$stub_directory/timeout"
  # Exits with the Nth word of STUB_ATTEMPT_STATUSES on its Nth run.
  printf '%s\n' '#!/usr/bin/env bash' \
    'attempt=$(( $(cat "$ATTEMPT_COUNTER") + 1 ))' \
    'echo "$attempt" >"$ATTEMPT_COUNTER"' \
    'echo "fake-install $*" >>"$CALL_LOG"' \
    'set -- $STUB_ATTEMPT_STATUSES' \
    'shift $(( attempt - 1 ))' \
    'exit "${1:-0}"' >"$stub_directory/fake-install"
  chmod +x "$stub_directory"/*
  PATH="$stub_directory:$PATH"
}

attempts_made() {
  cat "$ATTEMPT_COUNTER"
}

@test "an install that finishes inside the bound runs once and passes" {
  STUB_ATTEMPT_STATUSES="0" run bash "$helper" --attempt-seconds 180 -- fake-install --frozen-lockfile
  [ "$status" -eq 0 ] || return 1
  [ "$(attempts_made)" -eq 1 ] || return 1
  grep -qxF "timeout --kill-after=15 180" "$call_log" || return 1
  grep -qxF "fake-install --frozen-lockfile" "$call_log"
}

@test "an install the bound ends once is retried, warns, and passes" {
  STUB_ATTEMPT_STATUSES="124 0" run bash "$helper" --attempt-seconds 180 -- fake-install
  [ "$status" -eq 0 ] || return 1
  [ "$(attempts_made)" -eq 2 ] || return 1
  grep -qF "::warning::" <<<"$output" || return 1
  grep -qF "180s" <<<"$output"
}

@test "an install the bound ends twice fails with an error naming the bound and the input to raise" {
  STUB_ATTEMPT_STATUSES="124 137" run bash "$helper" --attempt-seconds 180 -- fake-install
  [ "$status" -eq 137 ] || return 1
  [ "$(attempts_made)" -eq 2 ] || return 1
  grep -qF "::error::" <<<"$output" || return 1
  grep -qF "both attempts" <<<"$output" || return 1
  grep -qF "install-attempt-seconds" <<<"$output"
}

@test "an install that fails on its own returns its status at once, without a retry" {
  STUB_ATTEMPT_STATUSES="1 0" run bash "$helper" --attempt-seconds 180 -- fake-install
  [ "$status" -eq 1 ] || return 1
  [ "$(attempts_made)" -eq 1 ] || return 1
  grep -qF "::warning::" <<<"$output" && return 1
  true
}

@test "a usage error exits 2 and runs nothing" {
  run bash "$helper" -- fake-install
  [ "$status" -eq 2 ] || return 1
  run bash "$helper" --attempt-seconds soon -- fake-install
  [ "$status" -eq 2 ] || return 1
  run bash "$helper" --attempt-seconds 0 -- fake-install
  [ "$status" -eq 2 ] || return 1
  run bash "$helper" --attempt-seconds 180 --
  [ "$status" -eq 2 ] || return 1
  [ "$(attempts_made)" -eq 0 ]
}

# The stub above proves what the helper does with each status; this proves the
# real coreutils timeout produces the status that arms the retry. Linux CI has
# GNU timeout; a stock Mac does not, so the test skips there and says why.
@test "the real timeout ends a hung install at the bound and both attempts fail" {
  local real_timeout
  real_timeout="$(PATH="${PATH#"$stub_directory:"}" command -v timeout || true)"
  [ -n "$real_timeout" ] || skip "no coreutils timeout on PATH"
  ln -sf "$real_timeout" "$stub_directory/timeout"
  printf '%s\n' '#!/usr/bin/env bash' 'exec sleep 30' >"$stub_directory/hung-install"
  chmod +x "$stub_directory/hung-install"
  SECONDS=0
  run bash "$helper" --attempt-seconds 1 -- hung-install
  [ "$status" -eq 124 ] || return 1
  [ "$SECONDS" -lt 10 ] || return 1
  grep -qF "::error::" <<<"$output"
}

# The `run:` command and the attempt-seconds env value of the composite step
# armed by one install mode.
install_step() {
  awk -v mode="$2" '
    $0 ~ ("if: inputs\\.install == ." mode ".") { armed = 1; next }
    armed && /^[[:space:]]+- name:/ { exit }
    armed && /^[[:space:]]+run:/ { sub(/^[[:space:]]+run:[[:space:]]*/, ""); print "run=" $0 }
    armed && /INSTALL_ATTEMPT_SECONDS:/ { sub(/^[[:space:]]+INSTALL_ATTEMPT_SECONDS:[[:space:]]*/, ""); print "seconds=" $0 }
  ' "$1"
}

every_install_is_bounded() {
  local action="$1" modes mode step
  modes="$(grep -oE "inputs\.install == '[a-z]+'" "$action" | sed "s/.*== '\\([a-z]*\\)'/\\1/" | sort -u)"
  [ "$modes" = "$(printf 'cli\nroot')" ] || return 1
  for mode in $modes; do
    step="$(install_step "$action" "$mode")"
    grep -qE '^run=bash "\$GITHUB_ACTION_PATH/bounded-install\.sh" --attempt-seconds "\$INSTALL_ATTEMPT_SECONDS" -- pnpm install ' <<<"$step" || return 1
    grep -qxF 'seconds=${{ inputs.install-attempt-seconds }}' <<<"$step" || return 1
  done
  awk '/^  install-attempt-seconds:/ { armed = 1; next } armed && /^  [a-z]/ { exit } armed && /default:/ { print }' "$action" |
    grep -qE "default: '[0-9]+'"
}

@test "gaia-setup-node: every install mode runs pnpm install through the bound, sized by its input" {
  every_install_is_bounded "$BATS_TEST_DIRNAME/../../../.github/actions/gaia-setup-node/action.yml"
}

@test "gaia-setup-node: an install step that calls pnpm directly fails the wiring guard (the guard can fail)" {
  local action="$BATS_TEST_DIRNAME/../../../.github/actions/gaia-setup-node/action.yml"
  local scratch="$BATS_TEST_TMPDIR/action.yml"
  sed "/if: inputs.install == 'cli'/{n;n;s|run: .*|run: pnpm install --frozen-lockfile --filter \"@gaia-harness/cli...\"|;}" "$action" >"$scratch"
  cmp -s "$action" "$scratch" && return 1
  run every_install_is_bounded "$scratch"
  [ "$status" -ne 0 ]
}
