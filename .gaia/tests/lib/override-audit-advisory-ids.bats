#!/usr/bin/env bats
# Pins `.gaia/scripts/override-audit-advisory-ids.sh`, the check the update-deps
# override audit runs before it trusts a `pnpm audit` advisory set: it writes
# the set only when the audit answered with an `advisories` object, and exits
# non-zero with the reason otherwise, so an audit that errored never reads as
# an empty set that makes every security-floor override look obsolete.
#
# `pnpm` is a stub on PATH, so no test reaches the registry.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/.gaia/scripts/override-audit-advisory-ids.sh"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  OUT="${BATS_TEST_TMPDIR}/ids"
  mkdir -p "$STUB_BIN"
}

# stub_pnpm <stdout> <stderr> <exit>: a pnpm that prints the given text and
# exits with the given status, whatever its arguments.
stub_pnpm() {
  printf '%s' "$1" >"${BATS_TEST_TMPDIR}/pnpm.out"
  printf '%s' "$2" >"${BATS_TEST_TMPDIR}/pnpm.err"
  cat >"${STUB_BIN}/pnpm" <<EOF
#!/bin/sh
cat '${BATS_TEST_TMPDIR}/pnpm.out'
cat '${BATS_TEST_TMPDIR}/pnpm.err' >&2
exit $3
EOF
  chmod +x "${STUB_BIN}/pnpm"
}

run_script() {
  run env PATH="${STUB_BIN}:${PATH}" bash "$SCRIPT" "$@"
}

@test "an answered audit writes its advisory ids sorted and unique" {
  stub_pnpm '{"advisories":{"1102":{},"1099":{},"GHSA-x":{}}}' '' 1
  run_script "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = "$(printf '1099\n1102\nGHSA-x')" ]
}

@test "an answered audit with no advisories writes an empty set and exits 0" {
  stub_pnpm '{"advisories":{}}' '' 0
  run_script "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ ! -s "$OUT" ]
}

@test "an audit that returned an error object exits 1 naming its message" {
  stub_pnpm '{"error":{"code":"ERR_PNPM_AUDIT_BAD_RESPONSE","message":"The audit endpoint responded with 503"}}' '' 1
  run_script "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The audit endpoint responded with 503"* ]]
}

@test "an audit that printed no JSON exits 1 naming its first stderr line" {
  stub_pnpm '' 'request to https://registry.npmjs.org failed, reason: getaddrinfo ENOTFOUND' 1
  run_script "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ENOTFOUND"* ]]
}

@test "an audit that printed nothing at all exits 1 with a fallback reason" {
  stub_pnpm '' '' 1
  run_script "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pnpm audit produced no JSON"* ]]
}

@test "a failed audit leaves no stale id set behind in the output file" {
  printf '1099\n' >"$OUT"
  stub_pnpm '' 'ECONNRESET' 1
  run_script "$OUT"
  [ "$status" -eq 1 ]
  [ ! -s "$OUT" ]
}

@test "a failed audit leaves no raw capture file beside the output" {
  stub_pnpm '' 'ECONNRESET' 1
  run_script "$OUT"
  [ "$status" -eq 1 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'ids.*')" ]
}

@test "no output path is a usage error" {
  stub_pnpm '{"advisories":{}}' '' 0
  run_script
  [ "$status" -eq 2 ]
}
