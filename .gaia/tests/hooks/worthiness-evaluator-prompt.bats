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
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/test-signals/extract-test-signals.mjs"
  CSF4_FIXTURE=".gaia/tests/hooks/fixtures/test-signals/csf4-with-tests.stories.tsx"
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
  grep -qF -- 'shared worthiness step' "$prompt_file" || return 1
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
  printf '%s\n' "The tdd skill is the only dispatcher of this audit, not the shared worthiness step." > "$old_prompt"
  run prompt_names_tdd_as_one_dispatcher "$old_prompt"
  [ "$status" -ne 0 ]
}

# Whitespace-collapsed prompt text, so a pin survives the prompt's hard wrapping.
normalized_prompt() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

# Fails with the first needle of the list the prompt lacks.
prompt_carries_every() {
  local prompt_file="$1"
  shift
  local needle text
  text=$(normalized_prompt "$prompt_file")
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$text" || {
      printf 'missing needle: %s\n' "$needle" >&2
      return 1
    }
  done
  return 0
}

flow_input_needles() {
  FLOW_INPUT_NEEDLES=(
    'Flows spec: <path>'
    'Flow: <file> › <flowId> <slug>'
  )
}

# shellcheck disable=SC2016
flow_verdict_needles() {
  FLOW_VERDICT_NEEDLES=(
    'missingOutcome'
    'undeclaredFolders'
    'any non-empty member makes the verdict `fix`, never `keep`'
    'only for a test that had a `Flow:` line'
  )
}

flow_judgment_needles() {
  FLOW_JUDGMENT_NEEDLES=(
    'name the error paths the build actually has'
    'the SPEC does not list'
    'honesty axis applies to every test it judges, strict included'
  )
}

@test "the evaluator prompt names each flow input line it takes" {
  flow_input_needles
  local needle
  for needle in "${FLOW_INPUT_NEEDLES[@]}"; do
    prompt_carries_every "$PROMPT" "$needle"
  done
}

@test "the evaluator prompt pins each flow verdict member and the rule that a non-empty one forbids keep" {
  flow_verdict_needles
  local needle
  for needle in "${FLOW_VERDICT_NEEDLES[@]}"; do
    prompt_carries_every "$PROMPT" "$needle"
  done
}

@test "the evaluator prompt reads flow source for error paths, excludes SPEC-listed folders, and judges honesty on strict tests" {
  flow_judgment_needles
  local needle
  for needle in "${FLOW_JUDGMENT_NEEDLES[@]}"; do
    prompt_carries_every "$PROMPT" "$needle"
  done
}

@test "the flow pin check rejects a prompt that lacks any one flow needle" {
  flow_input_needles
  flow_verdict_needles
  flow_judgment_needles
  local all_needles=("${FLOW_INPUT_NEEDLES[@]}" "${FLOW_VERDICT_NEEDLES[@]}" "${FLOW_JUDGMENT_NEEDLES[@]}")
  local needle scratch="$BATS_TEST_TMPDIR/prompt.md" other
  for needle in "${all_needles[@]}"; do
    : > "$scratch"
    for other in "${all_needles[@]}"; do
      [ "$other" = "$needle" ] || printf '%s\n' "$other" >> "$scratch"
    done
    run prompt_carries_every "$scratch" "${all_needles[@]}"
    [ "$status" -ne 0 ] || {
      printf 'check stayed green without: %s\n' "$needle" >&2
      return 1
    }
  done
}

# shellcheck disable=SC2016
sole_driver_needles() {
  SOLE_DRIVER_NEEDLES=(
    'only test below the browser layer (`.claude/doctrine/testing.md`, `## Guards and security rows`) driving a guard, refusal or validation into its failing state is `keep` or `fix`, never `delete`'
    'A browser test or a flow test never counts as the covering sibling'
    'neither does a sibling also proposed for `delete`'
  )
}

@test "the evaluator prompt never proposes deleting the only lower-layer test driving a guard, and never counts a browser test as its sibling" {
  sole_driver_needles
  prompt_carries_every "$PROMPT" "${SOLE_DRIVER_NEEDLES[@]}"
}

@test "the sole-driver check rejects a carve-out that any verified sibling satisfies" {
  local old_prompt="$BATS_TEST_TMPDIR/old-prompt.md"
  printf '%s\n' \
    'It stays even when a sibling looks redundant, unless a sibling is machine-verified' \
    'to assert the exact same security property.' > "$old_prompt"
  sole_driver_needles
  run prompt_carries_every "$old_prompt" "${SOLE_DRIVER_NEEDLES[@]}"
  [ "$status" -ne 0 ]
}
