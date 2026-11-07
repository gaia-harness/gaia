#!/usr/bin/env bats

# The one extractor entry point over a .bats file: the dispatch to the bats
# reader, the per-test signal rules, and the refusal for an unterminated block.
# Every fixture is written under $BATS_TEST_TMPDIR and read by its absolute
# path.

bats_require_minimum_version 1.5.0

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/test-signals/extract-test-signals.mjs"
  FIXTURE="$BATS_TEST_TMPDIR/flow.bats"
  AT=@
}

# The fixture holds two tests; the first carries a comment line and a command.
write_two_test_fixture() {
  local comment="${1:-check the greeting}" command="${2:-echo hello}"
  cat >"$FIXTURE" <<BATS
#!/usr/bin/env bats

${AT}test "prints a greeting" {
  # $comment
  run $command
  [ "\$status" -eq 0 ]
}

${AT}test "prints a farewell" {
  run echo goodbye
  [ "\$status" -eq 0 ]
}
BATS
}

@test "a two-test bats file emits one line per test, named by its title" {
  write_two_test_fixture
  run --separate-stderr node "$EXTRACTOR" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p | jq -r .fullName)" = "prints a greeting" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | jq -r .fullName)" = "prints a farewell" ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p | jq -r .signal)" == sha256:* ]]
  [ "$(printf '%s\n' "$output" | sed -n 1p | jq -r .kind)" = "runtime" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p | jq -r .firstLine)" = "3" ]
}

@test "a comment-only edit keeps a test's signal and an executable edit changes it" {
  write_two_test_fixture "check the greeting" "echo hello"
  first_signal=$(node "$EXTRACTOR" "$FIXTURE" | sed -n 1p | jq -r .signal)
  [[ "$first_signal" == sha256:* ]]

  write_two_test_fixture "verify the greeting text" "echo hello"
  reworded_signal=$(node "$EXTRACTOR" "$FIXTURE" | sed -n 1p | jq -r .signal)
  [ "$reworded_signal" = "$first_signal" ]

  write_two_test_fixture "check the greeting" "echo goodbye"
  edited_signal=$(node "$EXTRACTOR" "$FIXTURE" | sed -n 1p | jq -r .signal)
  [[ "$edited_signal" == sha256:* ]]
  [ "$edited_signal" != "$first_signal" ]
}

@test "a single-quoted title is read" {
  cat >"$FIXTURE" <<BATS
${AT}test 'prints a quoted greeting' {
  run echo hello
  [ "\$status" -eq 0 ]
}
BATS
  run --separate-stderr node "$EXTRACTOR" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | jq -r .fullName)" = "prints a quoted greeting" ]
}

@test "an unterminated test block exits 6 with one stderr line and nothing on stdout" {
  cat >"$FIXTURE" <<BATS
${AT}test "never closes" {
  run echo hello
BATS
  BATS_READER="$HOME_ROOT/.gaia/scripts/test-signals/extract-bats-signals.mjs"
  [ -f "$BATS_READER" ]
  run --separate-stderr node "$BATS_READER" "$FIXTURE"
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the bats mode resolves no TypeScript" {
  write_two_test_fixture
  scratch="$BATS_TEST_TMPDIR/outside-repo/test-signals"
  mkdir -p "$scratch"
  cp "$HOME_ROOT/.gaia/scripts/test-signals/"*.mjs "$scratch/"
  # The copy proves the dispatch target ships beside the entry point.
  [ -f "$scratch/extract-bats-signals.mjs" ]
  run --separate-stderr env NODE_PATH=/nonexistent node "$scratch/extract-test-signals.mjs" "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p | jq -r .fullName)" = "prints a greeting" ]
}
