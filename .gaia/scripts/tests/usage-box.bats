#!/usr/bin/env bats
#
# The cost box (`usage.sh initiative <ref> --box`) and the plain-language notes
# that replace the old "(partial: ...)" suffixes. Every figure is a literal added
# up by hand from the fixture rows: opus at $2 per million input and $10 per
# million output, with only fresh input and output set.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-box.bats
#
# Expected lines carry literal dollar signs, so they are single-quoted on purpose.
# shellcheck disable=SC2016

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  mkdir -p "$MAIN/.claude" "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_BOX_FLUSH_CAP_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS
}

run_usage() { bash "$SCRIPTS/usage.sh" "$@" --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects"; }

# segment <key> <sid> <first_ts> <last_ts> <fresh_input> <output> [model]
segment() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"agent_type":"main","by_model":{"%s":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":%s}}}\n' \
    "$1" "$2" "$3" "$4" "${7:-claude-opus-5-5}" "$5" "$6" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
start() {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"%s","source":"transcript"}\n' "$1" "$2" "$3" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
close() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command"}\n' "$1" "$2" "$3" "$4" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
edge() {
  printf '{"schema_version":1,"kind":"edge","child":"%s","parent":"%s","source":"link-command","ts":"2026-10-02T08:00:00Z","session_id":null,"sidechain":false}\n' "$1" "$2" >>"$TELEMETRY_DIRECTORY/links.jsonl"
}

# A spec with its gaia-spec and gaia-plan runs closed.
#   Spec  101,000 tokens, $0.21, 09:00 to 09:30 is 30m0s
#   Plan  202,000 tokens, $0.42, 10:00 to 10:40 is 40m0s
# Total 303,000 tokens, $0.63; 09:10 to 10:20 is 1h10m0s.
spec_and_plan_rows() {
  start s2 2026-10-02T09:00:00Z gaia-spec
  segment session:s2 s2 2026-10-02T09:10:00Z 2026-10-02T09:20:00Z 100000 1000
  close s2 2026-10-02T09:30:00Z spec:SPEC-402 gaia-spec
  start s3 2026-10-02T10:00:00Z gaia-plan
  segment session:s3 s3 2026-10-02T10:10:00Z 2026-10-02T10:20:00Z 200000 2000
  close s3 2026-10-02T10:40:00Z spec:SPEC-402 gaia-plan
}

# The same spec after execution: the branch carries 1,010,000 tokens, $2.10,
# and a PR linked to it carries nothing.
full_cycle_rows() {
  spec_and_plan_rows
  segment branch:feat/build-x s4 2026-10-02T11:00:00Z 2026-10-02T11:45:00Z 1000000 10000
  edge branch:feat/build-x spec:SPEC-402
  edge pr:88 branch:feat/build-x
}

# A run with wide figures: 123,456,000 output tokens is $1234.56, and the
# close is 12h3m9s after the start.
wide_rows() {
  start w1 2026-10-03T08:00:00Z gaia-spec
  segment session:w1 w1 2026-10-03T08:10:00Z 2026-10-03T08:20:00Z 0 123456000
  close w1 2026-10-03T20:03:09Z spec:SPEC-499 gaia-spec
  start w2 2026-10-04T08:00:00Z gaia-plan
  segment session:w2 w2 2026-10-04T08:10:00Z 2026-10-04T08:20:00Z 0 5000
  close w2 2026-10-04T08:30:09Z spec:SPEC-499 gaia-plan
}

# border_columns <box text>: the column of each line's right border, one per
# line of the box. A line that is not a box row prints nothing.
border_columns() {
  awk '/^[|+]/ { print length($0) }' <<<"$1"
}
# straight_border <box text>: succeeds when every box row ends in one column.
straight_border() {
  local columns
  columns="$(border_columns "$1" | sort -u)"
  [ -n "$columns" ] && [ "$(wc -l <<<"$columns" | tr -d ' ')" -eq 1 ]
}
# row_figures <box text> <label>: "<tenths> <cents>" the row shows, tokens in 0.1M and price in cents.
row_figures() {
  awk -v label="$2" '$0 ~ "^\\| *" label ": " { split($0, parts, ": "); text = parts[2]
      sub(/M tokens.*/, "", text); tokens = text; gsub(/\./, "", tokens)
      price = parts[2]; sub(/^[^$]*\$/, "", price); sub(/,.*/, "", price); gsub(/\./, "", price)
      print tokens + 0, price + 0 }' <<<"$1"
}

@test "the box names the spec without its key prefix and labels the Spec and Plan rows" {
  spec_and_plan_rows
  run run_usage initiative spec:SPEC-402 --box
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'SPEC-402 Cost' ]
  [ "$(sed -n 2p <<<"$output")" = '' ]
  grep -qF 'spec:' <<<"$output" && return 1
  grep -qE '^\|  Spec: 0\.1M tokens, \$0\.21, 30m0s +\|$' <<<"$output" || { printf '%s\n' "$output" >&2; return 1; }
  grep -qE '^\|  Plan: 0\.2M tokens, \$0\.42, 40m0s +\|$' <<<"$output"
  grep -qE '^\| Total: 0\.3M tokens, \$0\.63, 1h10m0s +\|$' <<<"$output"
  grep -q 'Planner yields' <<<"$output" && return 1
  grep -q 'partial' <<<"$output" && return 1
  true
}

@test "the box is plain ASCII, so its width counted in bytes is its width on screen" {
  full_cycle_rows
  run run_usage initiative spec:SPEC-402 --box
  [ "$status" -eq 0 ]
  LC_ALL=C grep -q '[^ -~]' <<<"$output" && return 1
  true
}

@test "guard red: the ASCII check flags a box with a non-ASCII character" {
  local box
  box=$'| Total: 0.3M tokens, \xc3\xa9 |'
  LC_ALL=C grep -q '[^ -~]' <<<"$box"
}

@test "the right border is one column on every line for short and for wide figures" {
  local short wide
  spec_and_plan_rows
  short="$(run_usage initiative spec:SPEC-402 --box)"
  wide_rows
  wide="$(run_usage initiative spec:SPEC-499 --box)"
  straight_border "$short" || { printf '%s\n' "$short" >&2; return 1; }
  straight_border "$wide" || { printf '%s\n' "$wide" >&2; return 1; }
  grep -qE '^\|  Spec: 123\.5M tokens, \$1234\.56, 12h3m9s +\|$' <<<"$wide" || { printf '%s\n' "$wide" >&2; return 1; }
  [ "$(border_columns "$short" | sort -u)" != "$(border_columns "$wide" | sort -u)" ]
}

@test "guard red: the border check fails on a ragged box" {
  local ragged
  ragged=$'+------+\n| a  |\n| bb   |\n+------+'
  straight_border "$ragged" && return 1
  true
}

@test "the Spec and Plan rows add up to the Total row, in tokens and in dollars" {
  local box spec plan total
  spec_and_plan_rows
  box="$(run_usage initiative spec:SPEC-402 --box)"
  spec="$(row_figures "$box" Spec)"
  plan="$(row_figures "$box" Plan)"
  total="$(row_figures "$box" Total)"
  [ "$spec" = '1 21' ]
  [ "$plan" = '2 42' ]
  [ "$total" = "$(( ${spec% *} + ${plan% *} )) $(( ${spec#* } + ${plan#* } ))" ]
  wide_rows
  box="$(run_usage initiative spec:SPEC-499 --box)"
  spec="$(row_figures "$box" Spec)"
  plan="$(row_figures "$box" Plan)"
  total="$(row_figures "$box" Total)"
  [ "$total" = "$(( ${spec% *} + ${plan% *} )) $(( ${spec#* } + ${plan#* } ))" ]
}

@test "guard red: the sum check fails on rows that do not add up" {
  local box total
  box=$'|  Spec: 0.1M tokens, $0.21, 30m0s |\n|  Plan: 0.2M tokens, $0.42, 40m0s |\n| Total: 0.4M tokens, $0.63, 1h10m0s |'
  total="$(row_figures "$box" Total)"
  [ "$total" != "$(( $(row_figures "$box" Spec | cut -d' ' -f1) + $(row_figures "$box" Plan | cut -d' ' -f1) )) 63" ]
}

@test "implementation spend on the branch gets an Execute row and the rows still add up to the Total" {
  local box spec plan execute total
  full_cycle_rows
  box="$(run_usage initiative spec:SPEC-402 --box)"
  straight_border "$box"
  grep -qE '^\| Execute: 1\.0M tokens, \$2\.10, 45m0s +\|$' <<<"$box" || { printf '%s\n' "$box" >&2; return 1; }
  grep -qF 'pr:' <<<"$box" && return 1
  spec="$(row_figures "$box" Spec)" plan="$(row_figures "$box" Plan)" execute="$(row_figures "$box" Execute)" total="$(row_figures "$box" Total)"
  [ "$total" = "$(( ${spec% *} + ${plan% *} + ${execute% *} )) $(( ${spec#* } + ${plan#* } + ${execute#* } ))" ]
  [ "$total" = '13 273' ]
  grep -qE '^\| +Total: 1\.3M tokens, \$2\.73, 2h35m0s +\|$' <<<"$box"
}

@test "a row with an unpriced model says so in words, and the box notes the minimum" {
  local box
  spec_and_plan_rows
  segment session:s3 s3 2026-10-02T10:12:00Z 2026-10-02T10:13:00Z 10 0 claude-zeta-1
  box="$(run_usage initiative spec:SPEC-402 --box)"
  grep -qE '^\|  Plan: 0\.2M tokens, at least \$0\.42, 40m0s +\|$' <<<"$box" || { printf '%s\n' "$box" >&2; return 1; }
  grep -qE '^\|  Spec: 0\.1M tokens, \$0\.21, 30m0s +\|$' <<<"$box"
  grep -qE '^\| Total: 0\.3M tokens, at least \$0\.63, ' <<<"$box"
  grep -qxF 'Note: Includes a model GAIA has no price for, so the cost is a minimum.' <<<"$box"
  straight_border "$(grep -E '^[|+]' <<<"$box")"
}

@test "with no readable rate table every price reads cost unavailable and no figure is invented" {
  local box
  spec_and_plan_rows
  box="$(bash "$SCRIPTS/usage.sh" initiative spec:SPEC-402 --box --main-root "$MAIN" --rate-table "$TEMPORARY_DIRECTORY/missing.json" --projects-root "$TEMPORARY_DIRECTORY/projects")"
  if grep -qF 'cost unavailable' <<<"$box"; then
    grep -qF '$' <<<"$box" && return 1
  else
    # A distributed table still prices: the box then shows real prices, never a guess.
    grep -qE '\$[0-9]+\.[0-9]{2}' <<<"$box"
  fi
  true
}

@test "one line item prints as one plain Cost line, not a box" {
  local output_text
  start p1 2026-10-05T09:00:00Z gaia-plan
  segment session:p1 p1 2026-10-05T09:10:00Z 2026-10-05T09:20:00Z 100000 1000
  close p1 2026-10-05T09:30:00Z plan:PLAN-411 gaia-plan
  output_text="$(run_usage initiative plan:PLAN-411 --box)"
  [ "$output_text" = 'Cost: 0.1M tokens, $0.21, 30m0s' ]
  grep -q '[|+]' <<<"$output_text" && return 1
  [ "$(wc -l <<<"$output_text" | tr -d ' ')" -eq 1 ]
}

@test "two line items print a box with border characters and no plain Cost line" {
  local box
  spec_and_plan_rows
  box="$(run_usage initiative spec:SPEC-402 --box)"
  [ "$(grep -c '^+-*+$' <<<"$box")" -eq 3 ]
  grep -q '^Cost:' <<<"$box" && return 1
  true
}

@test "guard red: the border-character check flags a box and passes a plain line" {
  grep -q '[|+]' <<<'| Total: 0.3M tokens, $0.63, 1h10m0s |'
  grep -q '[|+]' <<<'Cost: 0.1M tokens, $0.21, 30m0s' && return 1
  true
}

@test "a spec-less plan after execution prints a PLAN-NNN box with Plan, Execute and Total" {
  local box
  start p1 2026-10-05T09:00:00Z gaia-plan
  segment session:p1 p1 2026-10-05T09:10:00Z 2026-10-05T09:20:00Z 100000 1000
  close p1 2026-10-05T09:30:00Z plan:PLAN-411 gaia-plan
  segment branch:feat/x s9 2026-10-05T11:00:00Z 2026-10-05T11:10:00Z 1000000 0
  edge branch:feat/x plan:PLAN-411
  box="$(run_usage initiative plan:PLAN-411 --box)"
  [ "$(head -n 1 <<<"$box")" = 'PLAN-411 Cost' ]
  grep -qE '^\|    Plan: 0\.1M tokens, \$0\.21, 30m0s +\|$' <<<"$box" || { printf '%s\n' "$box" >&2; return 1; }
  grep -qE '^\| Execute: 1\.0M tokens, \$2\.00, 10m0s +\|$' <<<"$box"
  grep -qE '^\|   Total: 1\.1M tokens, \$2\.21, ' <<<"$box"
  grep -qF 'Spec' <<<"$box" && return 1
  straight_border "$box"
}

# colon_columns <box text>: the column of the colon on every labelled row, one value per distinct column.
colon_columns() { awk '/^\| +[A-Za-z]+: / { print index($0, ":") }' <<<"$1" | sort -u; }
# one_space_margins <box text>: every row opens with the border and a space, and the longest row has
# exactly one space before the closing border, so no padding beyond the margin is added.
one_space_margins() {
  local rows
  rows="$(grep -E '^\|' <<<"$1")"
  [ "$(grep -cvE '^\| ' <<<"$rows")" = 0 ] || return 1
  [ "$(grep -cE '[^ ] \|$' <<<"$rows")" -ge 1 ]
}

@test "with an Execute row the labels right-align to the colon at the width of Execute, with one space inside each border" {
  local box
  full_cycle_rows
  box="$(run_usage initiative spec:SPEC-402 --box)"
  [ "$(colon_columns "$box")" = 10 ] || { printf '%s\n' "$box" >&2; return 1; }
  grep -qE '^\|    Spec: ' <<<"$box"
  grep -qE '^\|    Plan: ' <<<"$box"
  grep -qE '^\| Execute: ' <<<"$box"
  grep -qE '^\|   Total: ' <<<"$box"
  one_space_margins "$box"
}

@test "without an Execute row the width is set by Total, with no space reserved for Execute" {
  local box
  spec_and_plan_rows
  box="$(run_usage initiative spec:SPEC-402 --box)"
  [ "$(colon_columns "$box")" = 8 ] || { printf '%s\n' "$box" >&2; return 1; }
  grep -qE '^\|  Spec: ' <<<"$box"
  grep -qE '^\|  Plan: ' <<<"$box"
  grep -qE '^\| Total: ' <<<"$box"
  one_space_margins "$box"
}

@test "guard red: the colon and margin checks fail on a box with a fixed label width and loose padding" {
  local loose
  loose=$'+------+\n|    Spec: 0.1M |\n| Total:  0.3M |\n+------+'
  [ "$(colon_columns "$loose" | wc -l | tr -d ' ')" -gt 1 ]
  one_space_margins $'| Total: 0.3M   |' && return 1
  true
}

@test "a bare SPEC-NNN or PLAN-NNN resolves to its key and prints the same box" {
  local keyed bare
  spec_and_plan_rows
  keyed="$(run_usage initiative spec:SPEC-402 --box)"
  bare="$(run_usage initiative SPEC-402 --box)"
  [ -n "$bare" ]
  [ "$bare" = "$keyed" ]
  start p1 2026-10-05T09:00:00Z gaia-plan
  close p1 2026-10-05T09:30:00Z plan:PLAN-411 gaia-plan
  [ "$(run_usage initiative PLAN-411 --box)" = "$(run_usage initiative plan:PLAN-411 --box)" ]
  run --separate-stderr run_usage initiative SPEC-12 --box
  [ -z "$output" ]
  [ "$stderr" = 'usage initiative: initiative takes one valid ref' ]
}

@test "a run with no recorded usage says so in one line instead of drawing an empty box" {
  run run_usage initiative spec:SPEC-402 --box
  [ "$status" -eq 0 ]
  [ "$output" = $'SPEC-402 Cost\n\nNo usage has been recorded for this yet.' ]
}

@test "--box --json exposes the raw rows and total; --box with --line is refused" {
  local figures
  spec_and_plan_rows
  figures="$(run_usage initiative spec:SPEC-402 --box --json)"
  [ "$(jq -r '[.rows[].label] | join(",")' <<<"$figures")" = 'Spec,Plan' ]
  [ "$(jq -r '[.rows[].tokens] | add' <<<"$figures")" = "$(jq -r '.total.tokens' <<<"$figures")" ]
  [ "$(jq -r '.total.tokens' <<<"$figures")" = 303000 ]
  run --separate-stderr run_usage initiative spec:SPEC-402 --box --line
  [ -z "$output" ]
  [ "$stderr" = 'usage initiative: --box and --line are exclusive' ]
}

@test "--line prints the Cost line, then a plain note for an unpriced model, with no partial suffix" {
  spec_and_plan_rows
  segment session:s3 s3 2026-10-02T10:12:00Z 2026-10-02T10:13:00Z 10 0 claude-zeta-1
  run run_usage initiative spec:SPEC-402 --line
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == Cost:* ]]
  [[ "${lines[0]}" == *'(partial'* ]] && return 1
  [ "${lines[1]}" = 'Note: Includes a model GAIA has no price for, so the cost is a minimum.' ]
}

@test "the box waits for a still-running flusher and, when it outlasts the cap, notes that the figures may be low" {
  local scratch="$TEMPORARY_DIRECTORY/scripts" file box
  mkdir -p "$scratch/spec" "$scratch/notebook"
  for file in "$SCRIPTS"/usage*.sh "$SCRIPTS"/token-*.sh "$SCRIPTS"/token-rates.json "$SCRIPTS"/branch-name-lib.sh \
    "$SCRIPTS"/main-root-lib.sh "$SCRIPTS"/context-checkpoint-lib.sh; do
    [ -f "$file" ] && cp "$file" "$scratch/"
  done
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
  cp "$SCRIPTS"/notebook/*.sh "$scratch/notebook/"
  printf '#!/usr/bin/env bash\nsleep 3\n' >"$scratch/usage-flush.sh"
  spec_and_plan_rows
  box="$(CLAUDE_CODE_SESSION_ID=box-sess GAIA_USAGE_BOX_FLUSH_CAP_SECONDS=1 bash "$scratch/usage.sh" initiative SPEC-402 --box \
    --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects")"
  grep -qxF 'Note: Some usage was still being saved, so these figures may be low. For the final numbers run: bash .gaia/scripts/usage.sh initiative SPEC-402 --box' <<<"$box" ||
    { printf '%s\n' "$box" >&2; return 1; }
  grep -qE '^\| Total: ' <<<"$box"
  # Without a session there is nothing to wait for, so no note.
  box="$(bash "$scratch/usage.sh" initiative SPEC-402 --box --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects")"
  grep -qF 'Some usage was still being saved' <<<"$box" && return 1
  true
}
