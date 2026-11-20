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

@test "an answered audit writes its advisory ids sorted and unique, and an empty advisories object writes an empty set" {
  stub_pnpm '{"advisories":{"1102":{},"1099":{},"GHSA-x":{}}}' '' 1
  run_script "$OUT"
  [ "$status" -eq 0 ] || { echo "ids: status $status"; return 1; }
  [ "$(cat "$OUT")" = "$(printf '1099\n1102\nGHSA-x')" ] || { echo "ids: got '$(cat "$OUT")'"; return 1; }

  rm -f "$OUT"
  stub_pnpm '{"advisories":{}}' '' 0
  run_script "$OUT"
  [ "$status" -eq 0 ] || { echo "empty: status $status"; return 1; }
  [ -f "$OUT" ] || { echo "empty: no output file"; return 1; }
  [ ! -s "$OUT" ] || { echo "empty: output file not empty"; return 1; }
}

# bats test_tags=protected
@test "an audit that errored or printed no JSON exits 1 naming its reason and leaves no stale id set or raw capture behind" {
  local row stdout_text stderr_text expected
  for row in \
    '{"error":{"code":"ERR_PNPM_AUDIT_BAD_RESPONSE","message":"The audit endpoint responded with 503"}}||The audit endpoint responded with 503' \
    '|request to https://registry.npmjs.org failed, reason: getaddrinfo ENOTFOUND|ENOTFOUND' \
    '||pnpm audit produced no JSON'; do
    stdout_text=${row%%|*}
    stderr_text=${row#*|}; stderr_text=${stderr_text%%|*}
    expected=${row##*|}
    printf '1099\n' >"$OUT"
    stub_pnpm "$stdout_text" "$stderr_text" 1
    run_script "$OUT"
    [ "$status" -eq 1 ] || { echo "row $expected: status $status"; return 1; }
    grep -qF -- "$expected" <<<"$output" || { echo "row $expected: output '$output'"; return 1; }
    [ ! -s "$OUT" ] || { echo "row $expected: a stale id set stayed in the output file"; return 1; }
    [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'ids.*')" ] || { echo "row $expected: a raw capture file stayed beside the output"; return 1; }
  done
}
