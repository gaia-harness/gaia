#!/usr/bin/env bats
# Unit tests for `.gaia/scripts/spec/ledger-lib.sh`, the shared helpers behind
# the single ledger-update chokepoint and the archive sweeps. The helpers are
# pure: they locate no file.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LIB="$REPO_ROOT/.gaia/scripts/spec/ledger-lib.sh"
  [ -f "$LIB" ]
  # shellcheck source=/dev/null
  . "$LIB"
  NOW_EPOCH=1800000000
}

_iso_days_before_now() {
  local epoch=$((NOW_EPOCH - $1 * 86400))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

@test "gaia_ledger_kind_for_id maps SPEC-n to spec and PLAN-n to plan, and prints nothing and returns 2 for anything else" {
  [ "$(gaia_ledger_kind_for_id SPEC-001)" = "spec" ]
  [ "$(gaia_ledger_kind_for_id PLAN-123)" = "plan" ]
  for bad in FOO-1 plan-001 SPEC- PLAN-1x SPEC-001-extra " SPEC-001" ""; do
    run gaia_ledger_kind_for_id "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "gaia_ledger_status_allowed accepts draft ready merged abandoned for spec, ready merged abandoned for plan, and rejects off-vocabulary values and unknown kinds" {
  for value in draft ready merged abandoned; do
    gaia_ledger_status_allowed spec "$value"
  done
  run gaia_ledger_status_allowed plan draft
  [ "$status" -eq 1 ]
  for value in ready merged abandoned; do
    gaia_ledger_status_allowed plan "$value"
  done
  for value in shipped allocated "" bogus; do
    run gaia_ledger_status_allowed spec "$value"
    [ "$status" -eq 1 ]
    run gaia_ledger_status_allowed plan "$value"
    [ "$status" -eq 1 ]
  done
  run gaia_ledger_status_allowed bogus ready
  [ "$status" -eq 1 ]
}

@test "gaia_ledger_age_past_window is past exactly at the boundary, parses fractional seconds, and never reaps on empty, garbage or non-positive now" {
  gaia_ledger_age_past_window "$(_iso_days_before_now 30)" "$NOW_EPOCH" 30
  run gaia_ledger_age_past_window "$(_iso_days_before_now 29)" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
  gaia_ledger_age_past_window "2020-01-01T00:00:00.123Z" "$NOW_EPOCH" 30
  run gaia_ledger_age_past_window "" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "not-a-date" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "2020-01-01T00:00:00Z" 0 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "2020-01-01T00:00:00Z" "" 30
  [ "$status" -eq 1 ]
}
