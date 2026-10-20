#!/usr/bin/env bats
# Suite for the audit-cost measurement toolkit under .gaia/tests/audit-cost:
# the transcript library and its role classifier, measure-dispatch.mjs,
# summarize-runs.mjs, the scratch-clone helper, the probe and replay drivers'
# argument and scratch-root guards, and the replay patches.
#
# Every test reads the committed fixtures (or the toolkit scripts) through the
# real tree, so each carries the whole-tree mark. Mutation twins run on scratch
# copies in $BATS_TEST_TMPDIR and assert the mutated copy behaves differently;
# none touches the shared checkout. No test calls claude or gh: the drivers run
# against stubs first on PATH.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  TOOLKIT="$REPO_ROOT/.gaia/tests/audit-cost"
  FIXTURES="$TOOLKIT/fixtures"
  RC3="$FIXTURES/rc3-trimmed"
  SYNTHETIC="$FIXTURES/synthetic"
  REAL_RATES="$REPO_ROOT/.gaia/scripts/token-rates.json"
}

# measure_to_files <session jsonl> <rates file> [<script directory>]: runs
# measure-dispatch.mjs, leaving stdout in $MEASURE_OUT, stderr in $MEASURE_ERR
# and the exit status in $MEASURE_STATUS.
measure_to_files() {
  local script_directory="${3:-$TOOLKIT}"
  MEASURE_OUT="$BATS_TEST_TMPDIR/measure.out"
  MEASURE_ERR="$BATS_TEST_TMPDIR/measure.err"
  MEASURE_STATUS=0
  node "$script_directory/measure-dispatch.mjs" --session "$1" --rates "$2" >"$MEASURE_OUT" 2>"$MEASURE_ERR" || MEASURE_STATUS=$?
}

# The dollars token-pricing-lib.sh computes for one call's token buckets.
library_cost() {
  local rates_file="$1" call_time="$2" model="$3" fresh="$4" write5m="$5" write1h="$6" read_tokens="$7" output_tokens="$8"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  jq -n --argjson rates "$(cat "$rates_file")" --arg ts "$call_time" --arg model "$model" \
    --argjson fresh "$fresh" --argjson write5m "$write5m" --argjson write1h "$write1h" --argjson read "$read_tokens" --argjson output "$output_tokens" \
    "$GAIA_PRICING_JQ_DEFS"'
    priced_row({ts: $ts, by_model: {($model): {fresh_input: $fresh, cache_write_5m: $write5m, cache_write_1h: $write1h, cache_read: $read, output: $output}}}) | .dollars'
}

# Prints 0 when $1 and $2 agree to a millionth of a dollar.
costs_agree() {
  jq -n --argjson left "$1" --argjson right "$2" '((($left - $right) | fabs) < 0.0000005)'
}

# Copies the committed pricing fixture and the library to a scratch directory.
scratch_toolkit() {
  SCRATCH_TOOLKIT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$SCRATCH_TOOLKIT"
  cp -R "$TOOLKIT/lib" "$SCRATCH_TOOLKIT/lib"
  cp "$TOOLKIT/measure-dispatch.mjs" "$SCRATCH_TOOLKIT/measure-dispatch.mjs"
}

classify_json() {
  LIBRARY_PATH="$1" FIXTURE_SESSION="$RC3/session.jsonl" node --input-type=module -e '
    const library = await import(process.env.LIBRARY_PATH);
    const agents = library.listAgents(process.env.FIXTURE_SESSION);
    const byDescription = {};
    for (const agent of agents) {
      if (agent.parentAgentId === null) continue;
      byDescription[agent.dispatch.description] = library.classifyChild(agent.dispatch);
    }
    const literal = {
      afterSpecialist: library.classifyChild({ subagentType: "audit-rule-specialist", description: "translation specialist", prompt: "" }),
      afterRefuter: library.classifyChild({ subagentType: "audit-refuter", description: "refute", prompt: "" }),
      beforeRefuter: library.classifyChild({ subagentType: "general-purpose", description: "Check a finding", prompt: "You are an adversarial reviewer. Try to refute it about TypeScript." }),
      unrelated: library.classifyChild({ subagentType: "general-purpose", description: "Summarize the changelog", prompt: "Write a summary." }),
    };
    process.stdout.write(JSON.stringify({ byDescription, literal }));
  '
}

# bats test_tags=whole-tree
@test "measure-dispatch over the rc3 slice reproduces expected.json exactly" {
  measure_to_files "$RC3/session.jsonl" "$RC3/token-rates.json"
  [ "$MEASURE_STATUS" -eq 0 ]
  jq -S . "$MEASURE_OUT" >"$BATS_TEST_TMPDIR/actual.json"
  jq -S . "$RC3/expected.json" >"$BATS_TEST_TMPDIR/expected.json"
  cmp "$BATS_TEST_TMPDIR/actual.json" "$BATS_TEST_TMPDIR/expected.json"
}

# bats test_tags=whole-tree
@test "a repeated message id counts once at its last usage block, and the no-dedupe twin differs" {
  measure_to_files "$SYNTHETIC/pricing/session.jsonl" "$REAL_RATES"
  [ "$MEASURE_STATUS" -eq 0 ]
  [ "$(jq '.dispatches[0].calls' "$MEASURE_OUT")" -eq 1 ]
  [ "$(jq '.dispatches[0].per_call | length' "$MEASURE_OUT")" -eq 1 ]
  [ "$(jq -r '.dispatches[0].cost_usd' "$MEASURE_OUT")" = "0.2" ]
  scratch_toolkit
  sed 's/const dedupeKey = message\.id;/const dedupeKey = message.id + "-" + calls.length;/' "$TOOLKIT/lib/transcripts.mjs" >"$SCRATCH_TOOLKIT/lib/transcripts.mjs"
  grep -qF 'calls.length;' "$SCRATCH_TOOLKIT/lib/transcripts.mjs" || return 1
  measure_to_files "$SYNTHETIC/pricing/session.jsonl" "$REAL_RATES" "$SCRATCH_TOOLKIT"
  [ "$MEASURE_STATUS" -eq 0 ]
  [ "$(jq '.dispatches[0].calls' "$MEASURE_OUT")" -eq 2 ]
  [ "$(jq -r '.dispatches[0].cost_usd' "$MEASURE_OUT")" != "0.2" ]
}

# bats test_tags=whole-tree
@test "an unpriceable model exits 3 naming the model on stderr and prints no JSON" {
  local scratch_session="$BATS_TEST_TMPDIR/unknown-model"
  cp -R "$SYNTHETIC/pricing" "$scratch_session"
  sed 's/claude-sonnet-5-5/claude-unknown-0/' "$SYNTHETIC/pricing/session/subagents/agent-member1.jsonl" >"$scratch_session/session/subagents/agent-member1.jsonl"
  measure_to_files "$scratch_session/session.jsonl" "$REAL_RATES"
  [ "$MEASURE_STATUS" -eq 3 ]
  grep -qF 'claude-unknown-0' "$MEASURE_ERR" || return 1
  [ ! -s "$MEASURE_OUT" ]
}

# bats test_tags=whole-tree
@test "measure-dispatch rejects a missing flag with exit 2" {
  run node "$TOOLKIT/measure-dispatch.mjs" --session "$RC3/session.jsonl"
  [ "$status" -eq 2 ]
  grep -qF 'usage: measure-dispatch.mjs' <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "pricing parity: the script's cost for a 1h-cache-write call equals token-pricing-lib.sh, from the rates file" {
  grep -qF '"ephemeral_1h_input_tokens":30000' "$SYNTHETIC/pricing/session/subagents/agent-member1.jsonl" || return 1
  measure_to_files "$SYNTHETIC/pricing/session.jsonl" "$REAL_RATES"
  [ "$MEASURE_STATUS" -eq 0 ]
  local script_cost library_cost_value
  script_cost="$(jq '.dispatches[0].cost_usd' "$MEASURE_OUT")"
  library_cost_value="$(library_cost "$REAL_RATES" "2026-10-03T09:00:12Z" claude-sonnet-5-5 1000 20000 30000 40000 2000)"
  [ "$(costs_agree "$script_cost" "$library_cost_value")" = "true" ]

  # A different write_1h multiplier changes the script's cost, and the library agrees on it.
  jq '.cache_multipliers.write_1h = 3' "$REAL_RATES" >"$BATS_TEST_TMPDIR/rates-write1h.json"
  measure_to_files "$SYNTHETIC/pricing/session.jsonl" "$BATS_TEST_TMPDIR/rates-write1h.json"
  [ "$MEASURE_STATUS" -eq 0 ]
  local changed_cost
  changed_cost="$(jq '.dispatches[0].cost_usd' "$MEASURE_OUT")"
  [ "$(costs_agree "$changed_cost" "$script_cost")" = "false" ]
  [ "$(costs_agree "$changed_cost" "$(library_cost "$BATS_TEST_TMPDIR/rates-write1h.json" "2026-10-03T09:00:12Z" claude-sonnet-5-5 1000 20000 30000 40000 2000)")" = "true" ]

  # Moving the first row's effective_through before the call's date selects the other row.
  jq '.models["claude-sonnet-5-5"][0].effective_through = "2026-10-01"' "$REAL_RATES" >"$BATS_TEST_TMPDIR/rates-window.json"
  measure_to_files "$SYNTHETIC/pricing/session.jsonl" "$BATS_TEST_TMPDIR/rates-window.json"
  [ "$MEASURE_STATUS" -eq 0 ]
  local windowed_cost
  windowed_cost="$(jq '.dispatches[0].cost_usd' "$MEASURE_OUT")"
  [ "$(costs_agree "$windowed_cost" "$script_cost")" = "false" ]
  [ "$(costs_agree "$windowed_cost" "$(library_cost "$BATS_TEST_TMPDIR/rates-window.json" "2026-10-03T09:00:12Z" claude-sonnet-5-5 1000 20000 30000 40000 2000)")" = "true" ]
}

# bats test_tags=whole-tree
@test "first_call.context sums the four buckets and steady_state_context is the first Agent or oracle call" {
  measure_to_files "$SYNTHETIC/dup-dispatch/session.jsonl" "$RC3/token-rates.json"
  [ "$MEASURE_STATUS" -eq 0 ]
  local member_filter='.dispatches[] | select(.agent_type == "code-audit-frontend")'
  [ "$(jq "$member_filter | .first_call.context" "$MEASURE_OUT")" -eq 15002 ]
  [ "$(jq "$member_filter | (.first_call.fresh_input + .first_call.cache_write + .first_call.cache_read)" "$MEASURE_OUT")" -eq 15002 ]
  # The first call runs a plain Bash command; the second dispatches a specialist.
  [ "$(jq "$member_filter | .steady_state_context" "$MEASURE_OUT")" -eq 16802 ]
  measure_to_files "$SYNTHETIC/after-extension/session.jsonl" "$RC3/token-rates.json"
  # The first call names the oracle script.
  [ "$(jq "$member_filter | .steady_state_context" "$MEASURE_OUT")" -eq 15002 ]
  # A specialist that issues neither has no steady-state context.
  [ "$(jq '.dispatches[] | select(.agent_type == "audit-rule-specialist") | .steady_state_context' "$MEASURE_OUT")" = "null" ]
}

# bats test_tags=whole-tree
@test "classifyChild maps the rc3 specialist descriptions and the literal cases, and the twin without the translation rule differs" {
  local expected='{
    "byDescription": {
      "TypeScript rules audit": {"kind": "specialist", "role": "typescript"},
      "TypeScript specialist review": {"kind": "specialist", "role": "typescript"},
      "React patterns specialist review": {"kind": "specialist", "role": "react-patterns"},
      "Translation rules audit": {"kind": "specialist", "role": "translation"}
    },
    "literal": {
      "afterSpecialist": {"kind": "specialist", "role": "translation"},
      "afterRefuter": {"kind": "refuter", "role": null},
      "beforeRefuter": {"kind": "refuter", "role": null},
      "unrelated": {"kind": "other", "role": null}
    }
  }'
  local actual
  actual="$(classify_json "$TOOLKIT/lib/transcripts.mjs")"
  # Only the four specialist descriptions are asserted from the fixture; the fixture also holds a fixer.
  jq -n --argjson actual "$actual" --argjson expected "$expected" \
    '($expected.byDescription | to_entries | all(.value == $actual.byDescription[.key])) and ($expected.literal == $actual.literal)' | grep -qx true

  scratch_toolkit
  grep -v 'translation|i18n' "$TOOLKIT/lib/transcripts.mjs" >"$SCRATCH_TOOLKIT/lib/transcripts.mjs"
  [ "$(grep -c 'translation|i18n' "$TOOLKIT/lib/transcripts.mjs")" -eq 1 ]
  local mutated
  mutated="$(classify_json "$SCRATCH_TOOLKIT/lib/transcripts.mjs")"
  # Without the rule the description matches nothing, so the prompt (which names React) decides: not translation.
  [ "$(jq -r '.byDescription["Translation rules audit"].role' <<<"$mutated")" != "translation" ]
  [ "$(jq -c '.byDescription["TypeScript rules audit"]' <<<"$mutated")" = '{"kind":"specialist","role":"typescript"}' ]
}

# bats test_tags=whole-tree
@test "noop_retries counts a repeated specialist role and the duplicate's cost lands in the parent's children totals" {
  measure_to_files "$SYNTHETIC/dup-dispatch/session.jsonl" "$RC3/token-rates.json"
  [ "$MEASURE_STATUS" -eq 0 ]
  local member_filter='.dispatches[] | select(.agent_type == "code-audit-frontend")'
  [ "$(jq "$member_filter | .noop_retries" "$MEASURE_OUT")" -eq 1 ]
  [ "$(jq -c "$member_filter | .children_by_role" "$MEASURE_OUT")" = '{"typescript":2}' ]
  jq -e "($member_filter) as \$member | ([.dispatches[] | select(.parent_agent_id == \$member.agent_id) | .cost_usd] | add) as \$children
    | ((((\$member.children_cost_usd - \$children) | fabs) < 0.000001) and (((\$member.cost_usd + \$member.children_cost_usd - \$member.member_plus_children_cost_usd) | fabs) < 0.000001))" "$MEASURE_OUT" >/dev/null
  [ "$(jq '[.dispatches[] | select(.child_kind == "specialist")] | length' "$MEASURE_OUT")" -eq 2 ]
}

# bats test_tags=whole-tree
@test "reads_refuter_reference, extension_rule_files and prompt_chars come from the transcript and the dispatch" {
  measure_to_files "$SYNTHETIC/refuter-read/session.jsonl" "$RC3/token-rates.json"
  [ "$(jq '.dispatches[] | select(.agent_type == "code-audit-frontend") | .reads_refuter_reference' "$MEASURE_OUT")" = "true" ]
  [ "$(jq '[.dispatches[] | select(.agent_type != "code-audit-frontend") | .reads_refuter_reference] | any' "$MEASURE_OUT")" = "false" ]

  measure_to_files "$RC3/session.jsonl" "$RC3/token-rates.json"
  [ "$(jq '[.dispatches[] | select(.agent_type == "code-audit-frontend") | .reads_refuter_reference] | any' "$MEASURE_OUT")" = "false" ]
  [ "$(jq '[.dispatches[] | .extension_rule_files] | all(. == null)' "$MEASURE_OUT")" = "true" ]
  # prompt_chars is the dispatch prompt's length.
  FIXTURE_SESSION="$RC3/session.jsonl" LIBRARY_PATH="$TOOLKIT/lib/transcripts.mjs" node --input-type=module -e '
    const library = await import(process.env.LIBRARY_PATH);
    const lengths = {};
    for (const agent of library.listAgents(process.env.FIXTURE_SESSION)) lengths[agent.agentId] = agent.dispatch.prompt.length;
    process.stdout.write(JSON.stringify(lengths));
  ' >"$BATS_TEST_TMPDIR/prompt-lengths.json"
  jq -e --slurpfile lengths "$BATS_TEST_TMPDIR/prompt-lengths.json" '.dispatches | length > 0 and all(.prompt_chars == $lengths[0][.agent_id] and .prompt_chars > 0)' "$MEASURE_OUT" >/dev/null

  measure_to_files "$SYNTHETIC/after-extension/session.jsonl" "$RC3/token-rates.json"
  [ "$(jq -c '.dispatches[] | select(.agent_type == "audit-rule-specialist") | .extension_rule_files' "$MEASURE_OUT")" = '[".claude/rules/extensions/translation-extra.md",".claude/rules/extensions/second-extra.md"]' ]
  [ "$(jq '[.dispatches[] | select(.agent_type != "audit-rule-specialist") | .extension_rule_files] | all(. == null)' "$MEASURE_OUT")" = "true" ]
}

# bats test_tags=whole-tree
@test "summarize-runs refuses a short file set and reports single-run medians for identical runs" {
  measure_to_files "$RC3/session.jsonl" "$RC3/token-rates.json"
  local run_index
  for run_index in 1 2 3 4 5; do cp "$MEASURE_OUT" "$BATS_TEST_TMPDIR/run-$run_index.json"; done
  run node "$TOOLKIT/summarize-runs.mjs" --bundle before --runs 5 "$BATS_TEST_TMPDIR"/run-1.json "$BATS_TEST_TMPDIR"/run-2.json "$BATS_TEST_TMPDIR"/run-3.json "$BATS_TEST_TMPDIR"/run-4.json
  [ "$status" -eq 1 ]

  node "$TOOLKIT/summarize-runs.mjs" --bundle before --runs 5 "$BATS_TEST_TMPDIR"/run-[1-5].json >"$BATS_TEST_TMPDIR/summary-5.json"
  node "$TOOLKIT/summarize-runs.mjs" --bundle before --runs 1 "$BATS_TEST_TMPDIR/run-1.json" >"$BATS_TEST_TMPDIR/summary-1.json"
  [ "$(jq '.runs' "$BATS_TEST_TMPDIR/summary-5.json")" -eq 5 ]
  [ "$(jq '[.by_agent_type[].runs] | all(. == 5)' "$BATS_TEST_TMPDIR/summary-5.json")" = "true" ]
  [ "$(jq -S -c '[.unit_cost_usd_median, (.by_agent_type | map_values(.median)), (.by_role | map_values(.median))]' "$BATS_TEST_TMPDIR/summary-5.json")" = "$(jq -S -c '[.unit_cost_usd_median, (.by_agent_type | map_values(.median)), (.by_role | map_values(.median))]' "$BATS_TEST_TMPDIR/summary-1.json")" ]
  # Round-1 only: the rc3 slice's round-2 dispatches stay out of the medians.
  [ "$(jq '.by_agent_type["code-audit-frontend"].dispatches' "$BATS_TEST_TMPDIR/summary-5.json")" -eq 5 ]
}

# bats test_tags=whole-tree
@test "the transcript library lists nested sub-agents with their parent and dispatch block" {
  LIBRARY_PATH="$TOOLKIT/lib/transcripts.mjs" FIXTURE_SESSION="$RC3/session.jsonl" node --input-type=module -e '
    const library = await import(process.env.LIBRARY_PATH);
    const agents = library.listAgents(process.env.FIXTURE_SESSION);
    process.stdout.write(JSON.stringify(agents.map((agent) => ({ id: agent.agentId, type: agent.agentType, parent: agent.parentAgentId, tool: agent.dispatch.toolUseId, sent: agent.dispatch.prompt.length > 0 }))));
  ' >"$BATS_TEST_TMPDIR/agents.json"
  [ "$(jq 'length' "$BATS_TEST_TMPDIR/agents.json")" -eq 12 ]
  [ "$(jq '[.[] | select(.parent == null) | .type] | sort | join(",")' "$BATS_TEST_TMPDIR/agents.json")" = '"audit-loop-unit,fitness-judge,worthiness-evaluator"' ]
  [ "$(jq '[.[] | select(.parent == "ae44e7eaa984fc0df")] | length' "$BATS_TEST_TMPDIR/agents.json")" -eq 2 ]
  [ "$(jq 'all(.sent)' "$BATS_TEST_TMPDIR/agents.json")" = "true" ]
}

# bats test_tags=whole-tree
@test "session-checks reports a returned round-1 wave and the callability of listed tools" {
  run node "$TOOLKIT/lib/session-checks.mjs" wave-done "$RC3/session.jsonl"
  [ "$status" -eq 0 ]
  run node "$TOOLKIT/lib/session-checks.mjs" callability "$SYNTHETIC/after-extension/session.jsonl" code-audit-frontend Bash,Monitor
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | {tool, called, toolsearch_used, error}]' <<<"$output")" = '[{"tool":"Bash","called":true,"toolsearch_used":false,"error":false},{"tool":"Monitor","called":false,"toolsearch_used":false,"error":false}]' ]
}

# bats test_tags=whole-tree
@test "the probe, replay and scratch-clone scripts exit 2 with a usage line on no arguments or a missing required flag" {
  local script
  for script in prepare-scratch-clone.sh probe-first-call.sh run-replay.sh; do
    run bash "$TOOLKIT/$script"
    [ "$status" -eq 2 ]
    grep -qF "usage: $script" <<<"$output" || return 1
  done
  run bash "$TOOLKIT/prepare-scratch-clone.sh" --source "$REPO_ROOT" --ref HEAD
  [ "$status" -eq 2 ]
  run bash "$TOOLKIT/probe-first-call.sh" --root "$BATS_TEST_TMPDIR" --types code-audit-frontend --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  grep -qF 'usage: probe-first-call.sh' <<<"$output" || return 1
  run bash "$TOOLKIT/run-replay.sh" --scaffold "$BATS_TEST_TMPDIR" --replay language-file --run 1 --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  grep -qF 'usage: run-replay.sh' <<<"$output" || return 1
  run bash "$TOOLKIT/run-replay.sh" --scaffold "$BATS_TEST_TMPDIR" --replay other-replay --run 1 --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 2 ]
  grep -qF 'language-file or tsx-variant' <<<"$output" || return 1
}

# Stubs claude and gh first on PATH; each invocation appends to $STUB_LOG.
make_stubs() {
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  mkdir -p "$STUB_DIRECTORY"
  : >"$STUB_LOG"
  # shellcheck disable=SC2016 # the stub bodies are written literally, to expand when the stub runs
  printf '#!/usr/bin/env bash\nprintf "claude %%s\\n" "$*" >>"%s"\n' "$STUB_LOG" >"$STUB_DIRECTORY/claude"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >>"%s"\nif [ "$1 $2" = "pr create" ]; then echo https://github.example/owner/repo/pull/7; fi\nexit 0\n' "$STUB_LOG" >"$STUB_DIRECTORY/gh"
  chmod +x "$STUB_DIRECTORY/claude" "$STUB_DIRECTORY/gh"
}

# A throwaway adopter checkout: a bare origin and a clone whose main carries the
# files the replay patches touch, copied from this checkout.
make_throwaway() {
  local relative_path
  THROWAWAY_ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  THROWAWAY="$BATS_TEST_TMPDIR/throwaway"
  git init -q --bare "$THROWAWAY_ORIGIN"
  git init -q -b main "$THROWAWAY"
  for relative_path in frontend/app/languages/en/common.ts frontend/app/languages/en/errors.ts frontend/app/routes/_public.tsx; do
    mkdir -p "$THROWAWAY/$(dirname "$relative_path")"
    git -C "$REPO_ROOT" show "HEAD:$relative_path" >"$THROWAWAY/$relative_path"
  done
  git -C "$THROWAWAY" add -A
  git -C "$THROWAWAY" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m "seed"
  git -C "$THROWAWAY" remote add origin "$THROWAWAY_ORIGIN"
  git -C "$THROWAWAY" push -q origin main
}

# bats test_tags=whole-tree
@test "the probe refuses a root without the scratch sentinel before any claude call, and passes the guard with it" {
  make_stubs
  mkdir -p "$BATS_TEST_TMPDIR/root"
  PATH="$STUB_DIRECTORY:$PATH" run bash "$TOOLKIT/probe-first-call.sh" --root "$BATS_TEST_TMPDIR/root" --types code-audit-frontend --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]

  mkdir -p "$BATS_TEST_TMPDIR/root/.gaia/local"
  : >"$BATS_TEST_TMPDIR/root/.gaia/local/measurement-scratch"
  PATH="$STUB_DIRECTORY:$PATH" run bash "$TOOLKIT/probe-first-call.sh" --root "$BATS_TEST_TMPDIR/root" --types code-audit-frontend --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 3 ]
  grep -q '^claude ' "$STUB_LOG" || return 1
}

# bats test_tags=whole-tree
@test "the replay refuses a scaffold without the sentinel before any claude call, and passes the guard with it" {
  make_stubs
  make_throwaway
  PATH="$STUB_DIRECTORY:$PATH" run bash "$TOOLKIT/run-replay.sh" --scaffold "$THROWAWAY" --replay language-file --run 1 --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]

  mkdir -p "$THROWAWAY/.gaia/local"
  : >"$THROWAWAY/.gaia/local/measurement-scratch"
  PATH="$STUB_DIRECTORY:$PATH" run bash "$TOOLKIT/run-replay.sh" --scaffold "$THROWAWAY" --replay language-file --run 1 --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  # The stub claude writes no session, so the run ends 3 after the guard.
  [ "$status" -eq 3 ]
  grep -q '^claude ' "$STUB_LOG" || return 1
  grep -q '^gh pr create --draft' "$STUB_LOG" || return 1
  # The exit trap closed the draft pull request, deleted the branch and returned to main.
  grep -q '^gh pr close 7 --delete-branch' "$STUB_LOG" || return 1
  [ "$(git -C "$THROWAWAY_ORIGIN" branch --list 'replay-*' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(git -C "$THROWAWAY" rev-parse --abbrev-ref HEAD)" = "main" ]
}

# bats test_tags=whole-tree
@test "prepare-scratch-clone strips the marker on the clone's main, cuts a throwaway branch and leaves the source alone" {
  local source_repo="$BATS_TEST_TMPDIR/source" clone="$BATS_TEST_TMPDIR/clone" marker=".claude/rules/maintainers/harness-triage-threshold.md"
  git init -q -b main "$source_repo"
  mkdir -p "$source_repo/.claude/rules/maintainers"
  printf 'marker\n' >"$source_repo/$marker"
  printf 'content\n' >"$source_repo/file.txt"
  git -C "$source_repo" add -A
  git -C "$source_repo" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m "seed"
  local source_head
  source_head="$(git -C "$source_repo" rev-parse HEAD)"
  local refs_before status_before
  refs_before="$(git -C "$source_repo" for-each-ref)"
  status_before="$(git -C "$source_repo" status --porcelain)"

  run bash "$TOOLKIT/prepare-scratch-clone.sh" --source "$source_repo" --ref "$source_head" --out "$clone"
  [ "$status" -eq 0 ]
  git -C "$clone" ls-tree -r --name-only main | grep -qxF "$marker" && return 1
  git -C "$clone" ls-tree -r --name-only main | grep -qxF 'file.txt' || return 1
  [ "$(git -C "$clone" rev-parse main~1)" = "$source_head" ]
  [ "$(git -C "$clone" log -1 --format=%s main | cut -c 1-9)" = "scratch: " ]
  git -C "$clone" rev-parse --abbrev-ref HEAD | grep -q '^scratch-[0-9]' || return 1
  [ -f "$clone/.gaia/local/measurement-scratch" ]
  [ "$(git -C "$clone" rev-parse --git-common-dir)" = ".git" ]
  [ -d "$clone/.git" ]
  [ "$(git -C "$source_repo" for-each-ref)" = "$refs_before" ]
  [ "$(git -C "$source_repo" status --porcelain)" = "$status_before" ]
  [ -f "$source_repo/$marker" ]

  run bash "$TOOLKIT/prepare-scratch-clone.sh" --source "$source_repo" --ref "$source_head" --out "$clone"
  [ "$status" -eq 2 ]
}

# bats test_tags=whole-tree
@test "the replay patches name only the contract's paths, add more than the quick line cap, and apply to HEAD's frontend/app" {
  local patch changed_paths
  changed_paths="$(grep '^diff --git' "$TOOLKIT/replays/language-file.patch" | sed 's#^diff --git a/\(.*\) b/.*#\1#' | sort | tr '\n' ' ')"
  [ "$changed_paths" = "frontend/app/languages/en/common.ts frontend/app/languages/en/errors.ts " ]
  changed_paths="$(grep '^diff --git' "$TOOLKIT/replays/tsx-variant.patch" | sed 's#^diff --git a/\(.*\) b/.*#\1#' | sort | tr '\n' ' ')"
  [ "$changed_paths" = "frontend/app/languages/en/common.ts frontend/app/languages/en/errors.ts frontend/app/routes/_public.tsx " ]
  grep -q '^+import {useTranslation} from' "$TOOLKIT/replays/tsx-variant.patch" || return 1
  grep -q "^+.*{t('" "$TOOLKIT/replays/tsx-variant.patch" || return 1

  local scratch_export="$BATS_TEST_TMPDIR/export"
  mkdir -p "$scratch_export"
  git -C "$REPO_ROOT" archive HEAD frontend/app | tar -x -C "$scratch_export"
  for patch in language-file tsx-variant; do
    (cd "$scratch_export" && git apply --check "$TOOLKIT/replays/$patch.patch")
  done
  # More than 40 added plus deleted lines across the two locale files, so the router's line cap fires.
  local total_lines
  total_lines="$(cd "$scratch_export" && git apply --numstat "$TOOLKIT/replays/language-file.patch" | awk '{ total += $1 + $2 } END { print total }')"
  [ "$total_lines" -gt 40 ]
}

# bats test_tags=whole-tree
@test "no committed toolkit file carries a home path, an email address or a token" {
  grep -rnE '/Users/|@gmail|sk-ant' "$TOOLKIT" && return 1
  true
}
