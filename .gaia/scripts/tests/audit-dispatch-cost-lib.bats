#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-dispatch-cost-lib.sh, the measurement library
# behind the per-dispatch cost record. Covers: the member and role figures on a
# hand-built session fixture, the descendant walk, call dedup, the zero-usage
# line, unpriced and mixed-role models, a missing timestamp, an unparsed
# transcript, the linkage and unreadable-meta states, the light reviewer, the
# Claude Code version, parity with the committed toolkit, a bounded jq process
# count, and red twins that prove the walk, the dedup, the bucket mapping and
# the bucket key can each be broken and are noticed.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# SC2016 is intentional file-wide: the mutation scripts are single-quoted sed
# programs whose `$` must reach sed literally.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY="$REPO_ROOT/.gaia/scripts/audit-dispatch-cost-lib.sh"
  PRICING_LIBRARY="$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  RATES_FILE="$REPO_ROOT/.gaia/scripts/token-rates.json"
  FIXTURE="$REPO_ROOT/.gaia/tests/audit-cost/fixtures/dispatch-cost"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  [ -f "$LIBRARY" ]
  [ -d "$FIXTURE/session/subagents" ]
  # shellcheck source=/dev/null
  . "$LIBRARY"
  gaia_rates_load "" "$RATES_FILE"

  MEMBER=a0000000000000001
  SPECIALIST_ONE=a0000000000000002
  SPECIALIST_TWO=a0000000000000003
  OTHER_CHILD=a0000000000000006
  GRANDCHILD=a0000000000000007
  LIGHT=a0000000000000008
  SUBAGENTS="$FIXTURE/session/subagents"
}

# Copies the fixture to a scratch directory and points SUBAGENTS at its copy.
scratch_fixture() {
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  rm -rf "$SCRATCH"
  cp -R "$FIXTURE" "$SCRATCH"
  SUBAGENTS="$SCRATCH/session/subagents"
}

measure() {
  gaia_dispatch_cost_measure "$SUBAGENTS" "$1" "$GAIA_RATES_JSON"
}

# field <json> <jq filter>
field() {
  jq -r "$2" <<<"$1"
}

# Distinct assistant calls in the given transcripts that carry any usage.
counted_calls() {
  jq -s '[.[] | select(.type == "assistant" and .message.usage != null)
          | select([.message.usage.input_tokens, .message.usage.cache_creation_input_tokens,
                    .message.usage.cache_read_input_tokens, .message.usage.output_tokens] | add > 0)
          | .message.id] | unique | length' "$@"
}

zero_usage_calls() {
  jq -s '[.[] | select(.type == "assistant" and .message.usage != null)
          | select([.message.usage.input_tokens, .message.usage.cache_creation_input_tokens,
                    .message.usage.cache_read_input_tokens, .message.usage.output_tokens] | add == 0)
          | .message.id] | unique | length' "$@"
}

# within <a> <b> <tolerance>
within() {
  awk -v a="$1" -v b="$2" -v tolerance="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= tolerance + 0.000000001) }'
}

# Runs a mutated copy of the library in a fresh shell, beside a copy of the
# pricing library it sources. Prints the member's measurement; fails when the
# sed script did not change the copy.
run_mutated_library() {
  local sed_script="$1" mutation_directory="$BATS_TEST_TMPDIR/mutated"
  rm -rf "$mutation_directory"
  mkdir -p "$mutation_directory"
  cp "$PRICING_LIBRARY" "$mutation_directory/token-pricing-lib.sh"
  sed "$sed_script" "$LIBRARY" >"$mutation_directory/audit-dispatch-cost-lib.sh"
  if cmp -s "$LIBRARY" "$mutation_directory/audit-dispatch-cost-lib.sh"; then
    echo "mutation did not change the library copy" >&2
    return 1
  fi
  env -u GAIA_PRICING_JQ_DEFS bash -c '. "$1/audit-dispatch-cost-lib.sh"; gaia_dispatch_cost_measure "$2" "$3" "$4"' \
    _ "$mutation_directory" "$SUBAGENTS" "$MEMBER" "$GAIA_RATES_JSON"
}

toolkit_json() {
  node "$REPO_ROOT/.gaia/tests/audit-cost/measure-dispatch.mjs" --session "$SCRATCH/session.jsonl" --rates "$RATES_FILE"
}

@test "member figures: state, role dispatches, models and longest wall per role" {
  run measure "$MEMBER"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.agent_type')" = code-audit-frontend ]
  [ "$(field "$output" '.children_state')" = ok ]
  [ "$(field "$output" '.children | keys | join(",")')" = "other,refuter,specialist" ]
  [ "$(field "$output" '.children.specialist.dispatches')" = 2 ]
  [ "$(field "$output" '.children.refuter.dispatches')" = 2 ]
  [ "$(field "$output" '.children.other.dispatches')" = 2 ]
  [ "$(field "$output" '.children.specialist.models | join(",")')" = claude-sonnet-5-5 ]
  [ "$(field "$output" '.children.refuter.models | join(",")')" = claude-opus-5-5 ]
  [ "$(field "$output" '.children.other.models | join(",")')" = claude-haiku-5-5 ]
  [ "$(field "$output" '.children.specialist.longest_wall_s')" = 120.5 ]
  [ "$(field "$output" '.children.refuter.longest_wall_s')" = 95.75 ]
  [ "$(field "$output" '.children.other.longest_wall_s')" = 45.875 ]
  [ "$(field "$output" '.own.wall_s')" = 371.309 ]
}

@test "descendant walk: a grandchild counts under its own type and the walk cannot be cut to direct children" {
  local expected output_text
  expected=$(( $(counted_calls "$SUBAGENTS/agent-$OTHER_CHILD.jsonl") + $(counted_calls "$SUBAGENTS/agent-$GRANDCHILD.jsonl") ))
  [ "$expected" -eq 4 ]
  run measure "$MEMBER"
  [ "$(field "$output" '.children.other.calls')" = "$expected" ]
  [ "$(field "$output" '.children.other.dispatches')" = 2 ]
  # The unrelated top-level agent adds nothing to any role.
  [ "$(field "$output" '[.children[].dispatches] | add')" = 6 ]

  output_text="$(run_mutated_library 's/range(0; ($agents | length) + 1)/range(0; 1)/')"
  [ "$(field "$output_text" '.state')" = ok ]
  [ "$(field "$output_text" '.children.other.dispatches')" = 1 ]
}

@test "dedup: a call repeated with growing usage counts once with its last block" {
  run measure "$MEMBER"
  [ "$(field "$output" '.own.calls')" = 4 ]
  [ "$(field "$output" '.own.output_tokens')" = 652 ]
  [ "$(field "$output" '.own.input_tokens')" = 34 ]
  [ "$(field "$output" '.own.cache_write_5m_tokens')" = 1750 ]
  [ "$(field "$output" '.own.cache_write_1h_tokens')" = 650 ]
  [ "$(field "$output" '.own.cache_read_tokens')" = 11500 ]
  [ "$(field "$output" '.own.dollars')" = 0.029426 ]
}

@test "zero-usage line: a synthetic call adds no call, tokens or model" {
  [ "$(zero_usage_calls "$SUBAGENTS/agent-$MEMBER.jsonl")" -eq 1 ]
  run measure "$MEMBER"
  [ "$(field "$output" '.own.models | join(",")')" = claude-opus-5-5 ]
  field "$output" '.own.unpriced | join(",")' | grep -qF -- "synthetic" && return 1
  [ "$(field "$output" '.own.unpriced | length')" = 0 ]
  [ "$(field "$output" '.own.dollars | type')" = number ]
}

@test "unpriced: a model with no rate row keeps every figure and nulls dollars" {
  scratch_fixture
  sed 's/claude-opus-5-5/claude-unrated-9/g' "$SUBAGENTS/agent-$MEMBER.jsonl" >"$SUBAGENTS/member.new"
  mv "$SUBAGENTS/member.new" "$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.own.calls')" = 4 ]
  [ "$(field "$output" '.own.output_tokens')" = 652 ]
  [ "$(field "$output" '.own.cache_read_tokens')" = 11500 ]
  [ "$(field "$output" '.own.dollars')" = null ]
  [ "$(field "$output" '.own.unpriced | join(",")')" = claude-unrated-9 ]

  scratch_fixture
  sed 's/claude-opus-5-5/gpt-9-mini/g' "$SUBAGENTS/agent-$MEMBER.jsonl" >"$SUBAGENTS/member.new"
  mv "$SUBAGENTS/member.new" "$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.own.calls')" = 4 ]
  [ "$(field "$output" '.own.dollars')" = null ]
  [ "$(field "$output" '.own.unpriced | join(",")')" = gpt-9-mini ]
}

@test "mixed role: one unrated specialist nulls the role and the children total only" {
  local baseline
  baseline="$(measure "$MEMBER")"
  scratch_fixture
  sed 's/claude-sonnet-5-5/claude-unrated-9/g' "$SUBAGENTS/agent-$SPECIALIST_ONE.jsonl" >"$SUBAGENTS/specialist.new"
  mv "$SUBAGENTS/specialist.new" "$SUBAGENTS/agent-$SPECIALIST_ONE.jsonl"
  run measure "$MEMBER"
  [ "$(field "$output" '.children.specialist.models | join(",")')" = "claude-sonnet-5-5,claude-unrated-9" ]
  [ "$(field "$output" '.children.specialist.calls')" = "$(field "$baseline" '.children.specialist.calls')" ]
  [ "$(field "$output" '.children.specialist.output_tokens')" = "$(field "$baseline" '.children.specialist.output_tokens')" ]
  [ "$(field "$output" '.children.specialist.dollars')" = null ]
  [ "$(field "$output" '.children.specialist.unpriced | join(",")')" = claude-unrated-9 ]
  [ "$(field "$output" '.children_dollars')" = null ]
  [ "$(field "$output" '.own.dollars | type')" = number ]
  [ "$(field "$output" '.children.refuter.dollars | type')" = number ]
  [ "$(field "$output" '.children.other.dollars | type')" = number ]
}

@test "missing timestamp: a call without one flags missing_anchor and nulls dollars, never zero" {
  scratch_fixture
  sed '/"id":"msg_m3"/ s/"timestamp":"[^"]*",//' "$SUBAGENTS/agent-$MEMBER.jsonl" >"$SUBAGENTS/member.new"
  mv "$SUBAGENTS/member.new" "$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.own.missing_anchor')" = true ]
  [ "$(field "$output" '.own.dollars')" = null ]
  [ "$(field "$output" '.own.calls')" = 4 ]
}

@test "unparsed: no countable call is transcript_unparsed with null figures, never ok with zero calls" {
  local first_output
  scratch_fixture
  printf 'not json\nstill not json\n' >"$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$status" -eq 0 ]
  first_output="$output"
  [ "$(field "$first_output" '.state')" = transcript_unparsed ]
  [ "$(field "$first_output" '[.own, .children_state, .children, .children_dollars] | map(. == null) | all')" = true ]

  scratch_fixture
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-19T08:00:00.000Z","message":{"role":"assistant"}}' \
    '{"type":"user","timestamp":"2026-10-19T08:00:01.000Z","message":{"role":"user","content":"x"}}' \
    >"$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$(field "$output" '.state')" = transcript_unparsed ]
  [ "$(field "$output" '[.own, .children_state, .children, .children_dollars] | map(. == null) | all')" = true ]
  [ "$(field "$first_output $output" '. | select(.state == "ok" and .own.calls == 0) | .state' | wc -l | tr -d ' ')" = 0 ]
}

@test "linkage: fewer parented metas than dispatched tool uses leaves own figures and unparsed children" {
  local name
  scratch_fixture
  for name in "$SPECIALIST_ONE" "$SPECIALIST_TWO"; do
    jq -c 'del(.parentAgentId)' "$SUBAGENTS/agent-$name.meta.json" >"$SUBAGENTS/meta.new"
    mv "$SUBAGENTS/meta.new" "$SUBAGENTS/agent-$name.meta.json"
  done
  run measure "$MEMBER"
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.own.calls')" = 4 ]
  [ "$(field "$output" '.own.dollars')" = 0.029426 ]
  [ "$(field "$output" '.children_state')" = unparsed ]
  [ "$(field "$output" '.children')" = null ]
  [ "$(field "$output" '.children_dollars')" = null ]
}

@test "light reviewer: no children is an empty object and zero dollars" {
  run measure "$LIGHT"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.agent_type')" = audit-light-reviewer ]
  [ "$(field "$output" '.children')" = "{}" ]
  [ "$(field "$output" '.children_state')" = ok ]
  [ "$(field "$output" '.children_dollars')" = 0 ]
  [ "$(field "$output" '.own.calls')" = 2 ]
  [ "$(field "$output" '.own.dollars | type')" = number ]
}

@test "version: read from the dispatch's own transcript, null when absent" {
  run measure "$MEMBER"
  [ "$(field "$output" '.claude_code_version')" = 2.1.304 ]
  run measure "$LIGHT"
  [ "$(field "$output" '.claude_code_version')" = 2.1.304 ]
  scratch_fixture
  sed 's/"version":"2.1.304",//' "$SUBAGENTS/agent-$MEMBER.jsonl" >"$SUBAGENTS/member.new"
  mv "$SUBAGENTS/member.new" "$SUBAGENTS/agent-$MEMBER.jsonl"
  run measure "$MEMBER"
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.claude_code_version')" = null ]
}

@test "unreadable meta: any torn meta clears the children and keeps own figures" {
  scratch_fixture
  printf '{"agentType": "general-pur\n' >"$SUBAGENTS/agent-a00000000000000ff.meta.json"
  run measure "$MEMBER"
  [ "$status" -eq 0 ]
  [ "$(field "$output" '.state')" = ok ]
  [ "$(field "$output" '.own.calls')" = 4 ]
  [ "$(field "$output" '.children_state')" = unparsed ]
  [ "$(field "$output" '.children')" = null ]
  [ "$(field "$output" '.children_dollars')" = null ]
}

@test "one pass: the jq process count does not grow with the descendant count" {
  local real_jq shim_directory count_file baseline_count grown_count index
  real_jq="$(command -v jq)"
  shim_directory="$BATS_TEST_TMPDIR/shim"
  count_file="$BATS_TEST_TMPDIR/jq-count"
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$count_file" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"

  : >"$count_file"
  PATH="$shim_directory:$PATH" measure "$MEMBER" >/dev/null
  baseline_count="$(wc -l <"$count_file" | tr -d ' ')"
  [ "$baseline_count" -ge 1 ]

  scratch_fixture
  for index in 1 2 3; do
    printf '{"agentType":"general-purpose","toolUseId":"toolu_x%s"}\n' "$index" >"$SUBAGENTS/agent-a00000000000000f$index.meta.json"
  done
  : >"$count_file"
  PATH="$shim_directory:$PATH" measure "$MEMBER" >/dev/null
  grown_count="$(wc -l <"$count_file" | tr -d ' ')"
  [ "$grown_count" -eq "$baseline_count" ]
}

# bats test_tags=whole-tree
@test "parity: agrees with the toolkit on calls, cache tokens, wall seconds and dollars" {
  local toolkit member_row role calls expected_calls zero_lines child_rows tolerance
  scratch_fixture
  toolkit="$(toolkit_json)"
  run measure "$MEMBER"
  local library_output="$output"

  member_row="$(jq -c --arg id "$MEMBER" '.dispatches[] | select(.agent_id == $id)' <<<"$toolkit")"
  zero_lines="$(zero_usage_calls "$SUBAGENTS/agent-$MEMBER.jsonl")"
  [ "$(field "$library_output" '.own.calls')" = "$(( $(field "$member_row" '.calls') - zero_lines ))" ]
  [ "$(( $(field "$library_output" '.own.cache_write_5m_tokens') + $(field "$library_output" '.own.cache_write_1h_tokens') ))" = "$(field "$member_row" '[.per_call[].cache_write] | add')" ]
  [ "$(field "$library_output" '.own.cache_read_tokens')" = "$(field "$member_row" '[.per_call[].cache_read] | add')" ]
  [ "$(printf '%.3f' "$(field "$library_output" '.own.wall_s')")" = "$(printf '%.3f' "$(field "$member_row" '.wall_s')")" ]
  within "$(field "$library_output" '.own.dollars')" "$(field "$member_row" '.cost_usd')" 0.0000005
  within "$(field "$library_output" '.children_dollars')" "$(field "$member_row" '.children_cost_usd')" 0.0000005

  for role in specialist refuter other; do
    child_rows="$(jq -c --arg member "$MEMBER" --arg role "$role" '
      .dispatches as $rows
      | ($rows | map(select(.parent_agent_id == $member) | .agent_id)) as $direct
      | [$rows[] | select(.agent_id != $member and (.parent_agent_id == $member or ((.parent_agent_id // "") as $parent | $direct | index($parent) != null)))
         | select((if .agent_type == "audit-rule-specialist" then "specialist" elif .agent_type == "audit-refuter" then "refuter" else "other" end) == $role)]' <<<"$toolkit")"
    expected_calls="$(field "$child_rows" 'map(.calls) | add')"
    [ "$(field "$library_output" ".children.$role.dispatches")" = "$(field "$child_rows" 'length')" ]
    [ "$(field "$library_output" ".children.$role.calls")" = "$expected_calls" ]
    [ "$(( $(field "$library_output" ".children.$role.cache_write_5m_tokens") + $(field "$library_output" ".children.$role.cache_write_1h_tokens") ))" = "$(field "$child_rows" '[.[].per_call[].cache_write] | add')" ]
    [ "$(field "$library_output" ".children.$role.cache_read_tokens")" = "$(field "$child_rows" '[.[].per_call[].cache_read] | add')" ]
    [ "$(field "$library_output" ".children.$role.longest_wall_s")" = "$(field "$child_rows" 'map(.wall_s) | max')" ]
    tolerance="$(awk -v n="$(field "$child_rows" 'length')" 'BEGIN { printf "%.7f", 0.0000005 * n }')"
    within "$(field "$library_output" ".children.$role.dollars")" "$(field "$child_rows" 'map(.cost_usd) | add')" "$tolerance"
  done
  calls="$(field "$library_output" '[.children[].dispatches] | add')"
  [ "$calls" = 6 ]
}

# bats test_tags=whole-tree
@test "parity red twins: first-wins dedup, unsplit to 1h and a wrong bucket key each fall outside the toolkit" {
  local toolkit toolkit_dollars mutated
  scratch_fixture
  toolkit="$(toolkit_json)"
  toolkit_dollars="$(jq -r --arg id "$MEMBER" '.dispatches[] | select(.agent_id == $id) | .cost_usd' <<<"$toolkit")"

  mutated="$(run_mutated_library 's/\.usage = ($record\.message\.usage | if type == "object" then \. else {} end) | \.model/.model/')"
  [ "$(field "$mutated" '.state')" = ok ]
  [ "$(field "$mutated" '.own.output_tokens')" = 445 ]
  within "$(field "$mutated" '.own.dollars')" "$toolkit_dollars" 0.0000005 && return 1

  mutated="$(run_mutated_library 's#($split.ephemeral_1h_input_tokens // 0) as $one_hour#($split.ephemeral_1h_input_tokens // (if $split == null then ($usage.cache_creation_input_tokens // 0) else 0 end)) as $one_hour#')"
  [ "$(field "$mutated" '.state')" = ok ]
  [ "$(field "$mutated" '.own.cache_write_1h_tokens')" = 1350 ]
  [ "$(field "$mutated" '.own.cache_write_5m_tokens')" = 1050 ]
  within "$(field "$mutated" '.own.dollars')" "$toolkit_dollars" 0.0000005 && return 1

  mutated="$(run_mutated_library 's#fresh_input: ($usage.input_tokens#input: ($usage.input_tokens#')"
  [ "$(field "$mutated" '.state')" = ok ]
  within "$(field "$mutated" '.own.dollars')" "$toolkit_dollars" 0.0000005 && return 1
  true
}
