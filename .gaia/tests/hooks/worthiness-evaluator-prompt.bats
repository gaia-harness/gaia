#!/usr/bin/env bats

# The worthiness evaluator prompt judges each `.test()` as its own test unit and
# a story's own render and play as the `base story` unit. The prompt is prose,
# so the clause is pinned by grep; the units it names are pinned against the
# extractor's output over a CSF4 fixture, so the prompt and the identity the
# worthiness ledger records cannot drift apart.

# bats file_tags=installed-dependencies

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  PROMPT="$HOME_ROOT/.claude/agents/worthiness-evaluator.md"
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  CSF4_FIXTURE=".gaia/tests/hooks/fixtures/red-ledger/csf4-with-tests.stories.tsx"
}

# Succeeds only for a prompt that names the per-test unit shape and `base story`
# and no longer calls a story's play "one test".
prompt_states_test_units() {
  local prompt_file="$1"
  grep -qF -- '`.test()` is its own test unit' "$prompt_file" || return 1
  grep -qF -- '<Story Name>   <test name>' "$prompt_file" || return 1
  grep -qF -- 'base story' "$prompt_file" || return 1
  grep -qF -- 'is judged as one test' "$prompt_file" && return 1
  return 0
}

@test "the evaluator prompt judges each .test() as its own unit and names base story" {
  prompt_states_test_units "$PROMPT"
}

@test "the clause check rejects the prompt text that equated one play with one test" {
  local old_prompt="$BATS_TEST_TMPDIR/old-prompt.md"
  printf '%s\n' \
    'A **story play function** is a test: each story export with' \
    'a `play` is judged as one test, and its `fullName` is the story name.' > "$old_prompt"
  run prompt_states_test_units "$old_prompt"
  [ "$status" -ne 0 ]
}

@test "the extractor emits the base story and each test fullName the prompt says the evaluator judges" {
  local names
  names=$( cd "$HOME_ROOT" && node "$EXTRACTOR" "$CSF4_FIXTURE" | jq -r '.fullName' )
  [ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" -eq 3 ]
  grep -qxF "Default   base story" <<<"$names"
  grep -qxF "Default   shows the marker" <<<"$names"
  grep -qxF "Default   hides nothing else" <<<"$names"
}

# Succeeds only for a prompt that names the verdict-file contract.
prompt_states_verdict_file_contract() {
  local prompt_file="$1"
  grep -qF -- 'Verdict file: <absolute path>' "$prompt_file" || return 1
  grep -qF -- 'JSON array' "$prompt_file" || return 1
  grep -qF -- '{file, fullName, verdict, artifact?}' "$prompt_file" || return 1
  return 0
}

# Succeeds only for a prompt that no longer calls the tdd skill the only
# dispatcher and still names the tdd skill as a dispatcher.
prompt_names_tdd_as_one_dispatcher() {
  local prompt_file="$1"
  grep -qiF -- 'only dispatcher' "$prompt_file" && return 1
  grep -qF -- 'tdd skill' "$prompt_file" || return 1
  grep -qF -- 'worthiness-step.md' "$prompt_file" || return 1
  return 0
}

@test "the evaluator prompt states the Verdict file contract" {
  prompt_states_verdict_file_contract "$PROMPT"
}

@test "the contract check rejects a prompt that returns a trailer instead of a file" {
  local old_prompt="$BATS_TEST_TMPDIR/old-prompt.md"
  printf '%s\n' 'Machine-readable trailer (the last fenced block of your return)' 'verdicts_json: []' > "$old_prompt"
  run prompt_states_verdict_file_contract "$old_prompt"
  [ "$status" -ne 0 ]
}

@test "the evaluator prompt keeps tdd as one named dispatcher beside the shared step" {
  prompt_names_tdd_as_one_dispatcher "$PROMPT"
}

@test "the dispatcher check rejects a prompt that calls the tdd skill the only dispatcher" {
  local old_prompt="$BATS_TEST_TMPDIR/old-prompt.md"
  printf '%s\n' "The tdd skill is the only dispatcher of this audit; see worthiness-step.md." > "$old_prompt"
  run prompt_names_tdd_as_one_dispatcher "$old_prompt"
  [ "$status" -ne 0 ]
}
