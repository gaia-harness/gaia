#!/usr/bin/env bats
#
# The interval view and the shared Cost line in usage-render-lib.sh
# (gaia_usage_interval_view, gaia_usage_cost_line, gaia_usage_human_duration),
# called the way usage.sh's shell calls them: libraries sourced, the telemetry
# directory set, rates loaded. Figures are hand-added literals: opus at $2 per
# million input and $10 per million output, fresh input and output only.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-interval-view.bats
#
# Expected lines carry literal dollar signs and the child shells expand their
# own arguments, so both are single-quoted on purpose.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  mkdir -p "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT
}

# view <sid> <t0> <t1>: gaia_usage_interval_view in a fresh shell set up as
# usage.sh sets up its own before a subcommand runs.
view() {
  # shellcheck disable=SC2016  # the child shell expands these
  bash -c '. "$1/usage-lib.sh" && . "$1/usage-resolve-lib.sh" && . "$1/usage-active-lib.sh" && . "$1/usage-render-lib.sh" && . "$1/token-pricing-lib.sh" || exit 9
    TELEMETRY_DIRECTORY="$2" MAIN_ROOT="$3"
    usage_rates_load "$4" "$MAIN_ROOT"
    gaia_usage_interval_view "$5" "$6" "$7"' _ "$SCRIPTS" "$TELEMETRY_DIRECTORY" "$MAIN" "$RATES" "$@"
}

render() {
  # shellcheck disable=SC2016  # the child shell expands these
  bash -c '. "$1/usage-active-lib.sh" && . "$1/usage-render-lib.sh" || exit 9; shift; "$@"' _ "$SCRIPTS" "$@"
}

# segment <key> <sid> <first_ts> <fresh_input> <output> [model]
segment() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"agent_type":"main","by_model":{"%s":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":%s}}}\n' \
    "$1" "$2" "$3" "$3" "${6:-claude-opus-5-5}" "$4" "$5" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
binding() {
  if [ "$1" = start ]; then
    printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"%s","source":"transcript"}\n' "$2" "$3" "$4"
  else
    printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command"}\n' "$2" "$3" "$5" "$4"
  fi >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}

# s1 runs gaia-spec from 10:00 to the close at 11:00: inside are 202,000 and
# 303,000 tokens ($1.05). The 09:00 segment is before the start, the 11:00 one
# starts at the close, and s2 spends 1,008,990 tokens in the same window.
interval_rows() {
  binding start s1 2026-10-01T10:00:00Z gaia-spec
  segment session:s1 s1 2026-10-01T09:00:00Z 50000 500
  segment session:s1 s1 2026-10-01T10:05:00Z 200000 2000
  segment session:s1 s1 2026-10-01T10:30:00Z 300000 3000
  binding close s1 2026-10-01T11:00:00Z gaia-spec spec:SPEC-501
  segment session:s1 s1 2026-10-01T11:00:00Z 400000 4000
  segment session:s2 s2 2026-10-01T10:20:00Z 999000 9990
}

@test "the interval view counts a session's segments in [t0, t1), by key kind, and prices them as the initiative does" {
  local figures initiative
  interval_rows
  segment branch:feat/x s4 2026-10-01T13:10:00Z 1000 0
  segment session:s4 s4 2026-10-01T13:20:00Z 2000 0

  # case: in-window segments of one session, priced as the initiative prices them
  run view s1 2026-10-01T10:00:00Z 2026-10-01T11:00:00Z
  [ "$status" -eq 0 ] || { echo "case window: view exited $status"; return 1; }
  [ "${#lines[@]}" -eq 1 ] || { echo "case window: view printed ${#lines[@]} lines"; return 1; }
  figures="$output"
  [ "$(jq -c '{tokens, elapsed_seconds, unpriced}' <<<"$figures")" = '{"tokens":505000,"elapsed_seconds":3600,"unpriced":false}' ] ||
    { echo "case window: figures differ: $figures"; return 1; }
  [ "$(LC_ALL=C printf '%.2f' "$(jq -r '.dollars' <<<"$figures")")" = 1.05 ] || { echo "case window: dollars differ"; return 1; }
  initiative="$(bash "$SCRIPTS/usage.sh" initiative spec:SPEC-501 --line --json --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects")"
  [ "$(jq -r '.tokens' <<<"$initiative")" = 505000 ] || { echo "case window: initiative tokens differ"; return 1; }
  [ "$(jq -r '.dollars' <<<"$initiative")" = "$(jq -r '.dollars' <<<"$figures")" ] || { echo "case window: initiative dollars differ"; return 1; }

  # case: the spend the view leaves out is real (the segment at the close instant, the other session's window)
  run view s1 2026-10-01T11:00:00Z 2026-10-01T11:30:00Z
  [ "$(jq -r '.tokens' <<<"$output")" = 404000 ] || { echo "case close instant: tokens differ"; return 1; }
  run view s2 2026-10-01T10:00:00Z 2026-10-01T11:00:00Z
  [ "$(jq -r '.tokens' <<<"$output")" = 1008990 ] || { echo "case other session: tokens differ"; return 1; }

  # case: a span with no paired close takes only session spend, a command interval takes branch-keyed spend too
  run view s4 2026-10-01T13:00:00Z 2026-10-01T13:30:00Z
  [ "$(jq -r '.tokens' <<<"$output")" = 2000 ] || { echo "case unpaired span: tokens differ"; return 1; }
  binding start s4 2026-10-01T13:00:00Z gaia-debt
  binding close s4 2026-10-01T13:30:00Z gaia-debt command:gaia-debt-20261001T130000Z-c3d4
  run view s4 2026-10-01T13:00:00Z 2026-10-01T13:30:00Z
  [ "$(jq -r '.tokens' <<<"$output")" = 3000 ] || { echo "case command interval: tokens differ"; return 1; }
}

@test "the interval view reports an unpriced claude- model" {
  binding start s3 2026-10-01T12:00:00Z gaia-debt
  segment session:s3 s3 2026-10-01T12:10:00Z 100 0 claude-zeta-1
  segment session:s3 s3 2026-10-01T12:15:00Z 1000 0
  binding close s3 2026-10-01T12:30:00Z gaia-debt command:gaia-debt-20261001T120000Z-a1b2
  run view s3 2026-10-01T12:00:00Z 2026-10-01T12:30:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -c '{tokens, elapsed_seconds, unpriced}' <<<"$output")" = '{"tokens":1100,"elapsed_seconds":1800,"unpriced":true}' ]
}

@test "the Cost line and duration format: millions to one decimal, dollars or cost unavailable, leading zero units dropped" {
  run render gaia_usage_cost_line 10600000 1.5 399
  [ "$status" -eq 0 ] || { echo "case cost line: exited $status"; return 1; }
  [ "$output" = 'Cost: 10.6M tokens, $1.50, 6m39s' ] || { echo "case cost line dollars: $output"; return 1; }
  run render gaia_usage_cost_line 10600000 null 399
  [ "$output" = 'Cost: 10.6M tokens, cost unavailable, 6m39s' ] || { echo "case cost line unavailable: $output"; return 1; }
  run render gaia_usage_cost_line 49999 0.004 45 'spec:SPEC-001 $0.00'
  [ "$output" = 'Cost: 0.0M tokens, $0.00, 45s' ] || { echo "case cost line terms: $output"; return 1; }
  local duration_case seconds expected
  for duration_case in 45:45s 399:6m39s 3605:1h0m5s 0:0s; do
    seconds="${duration_case%%:*}" expected="${duration_case#*:}"
    run render gaia_usage_human_duration "$seconds"
    [ "$output" = "$expected" ] || { echo "case duration $seconds: got $output, want $expected"; return 1; }
  done
}
