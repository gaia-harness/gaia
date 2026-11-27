#!/usr/bin/env bats
#
# Guard red-proofs for audit-loop-automatic-lib.sh and the round cap helpers in
# audit-loop-allowance-lib.sh: each range and validity guard of
# gaia_loop_round_cap_state, gaia_loop_round_cap_effective and the freeze, and
# each ask guard of gaia_loop_automatic_answer, is broken in a scratch copy and
# a case goes red. The behavior itself is proved
# through the bound hook (audit-loop-bound.bats), not here.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-automatic-lib.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AUTO_LIB="$SCRIPTS/audit-loop-automatic-lib.sh"
  ALLOW_LIB="$SCRIPTS/audit-loop-allowance-lib.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia/local/protected"
}

write_override() {
  printf '%s\n' "$1" >"$MAIN/.gaia/local/protected/checkpoint-override.json"
}

# probe <function> <args...>: run a lib function with the libraries named by
# AUTO_LIB and ALLOW_LIB (the real ones unless a case swapped in a mutant).
probe() {
  run bash -c '. "$1/audit-loop-state-lib.sh"; . "$1/context-checkpoint-lib.sh"; . "$1/audit-loop-signals-lib.sh"; . "$2"; . "$3"; shift 3; "$@"' \
    _ "$SCRIPTS" "$AUTO_LIB" "$ALLOW_LIB" "$@"
}

# mutate <variable-name> <file> <sed-args...>: copy <file> with the edit applied,
# point the named variable at the copy, and fail unless the copy differs.
mutate() {
  local variable="$1" file="$2" copy
  shift 2
  copy="$BATS_TEST_TMPDIR/mutant-$file"
  sed "$@" "$SCRIPTS/$file" >"$copy"
  if cmp -s "$copy" "$SCRIPTS/$file"; then
    echo "mutation did not change $file" >&2
    return 1
  fi
  printf -v "$variable" '%s' "$copy"
}

# expect_state <override-json> <expected-line>: the real lib prints the line.
expect_state() {
  write_override "$1"
  probe gaia_loop_round_cap_state "$MAIN"
  [ "$status" -eq 0 ] && [ "$output" = "$2" ] || { printf 'got [%s] want [%s]\n' "$output" "$2" >&2; return 1; }
}

# mutant_state_differs <override-json> <real-expected-line>: with the mutant lib
# loaded the same input no longer prints the real line.
mutant_state_differs() {
  write_override "$1"
  probe gaia_loop_round_cap_state "$MAIN"
  [ "$output" != "$2" ]
}

frozen_state() {
  printf '{"history":{"context_config":%s}}' "$1"
}

@test "round cap state: a cap above the hard cap reads as capped, and without that guard it reads ok" {
  expect_state '{"version":1,"audit_loop":{"round_cap":15}}' 'capped 10 15'
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e '/elif \$value > \$hard then "capped/d'
  mutant_state_differs '{"version":1,"audit_loop":{"round_cap":15}}' 'capped 10 15'
}

@test "round cap state: zero, a negative and a string are invalid, and without the lower bound zero reads ok" {
  expect_state '{"version":1,"audit_loop":{"round_cap":0}}' 'invalid 10 0'
  expect_state '{"version":1,"audit_loop":{"round_cap":-1}}' 'invalid 10 -1'
  expect_state '{"version":1,"audit_loop":{"round_cap":"4"}}' 'invalid 10 "4"'
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e 's/ or \$value < 1//'
  mutant_state_differs '{"version":1,"audit_loop":{"round_cap":0}}' 'invalid 10 0'
}

@test "round cap state: a fraction is invalid, and without the whole-number guard it reads ok" {
  expect_state '{"version":1,"audit_loop":{"round_cap":4.5}}' 'invalid 10 4.5'
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e 's/ or \$value != (\$value | floor)//'
  mutant_state_differs '{"version":1,"audit_loop":{"round_cap":4.5}}' 'invalid 10 4.5'
}

@test "round cap state: a file whose version is not 1 is invalid, and without the version guard its cap reads ok" {
  expect_state '{"version":2,"audit_loop":{"round_cap":4}}' 'invalid 10 -'
  expect_state '[1]' 'invalid 10 -'
  expect_state '{"version":1,"audit_loop":{"round_cap":4}}' 'ok 4 4'
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e 's/ or \.\[0\]\.version != 1//'
  mutant_state_differs '{"version":2,"audit_loop":{"round_cap":4}}' 'invalid 10 -'
}

@test "round cap state: no file, no audit_loop and no round_cap key read as absent" {
  rm -f "$MAIN/.gaia/local/protected/checkpoint-override.json"
  probe gaia_loop_round_cap_state "$MAIN"
  [ "$output" = 'absent 10 -' ]
  expect_state '{"version":1,"context_checkpoint":{"ask_tokens":350000}}' 'absent 10 -'
  expect_state '{"version":1,"audit_loop":{}}' 'absent 10 -'
  expect_state '{"version":1,"audit_loop":"x"}' 'invalid 10 -'
  expect_state 'not json' 'invalid 10 -'
}

@test "round cap effective: the frozen cap only lowers the live one, and without the minimum a lowering is ignored" {
  write_override '{"version":1,"audit_loop":{"round_cap":8}}'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":6}')"
  [ "$output" = '6 true' ]
  write_override '{"version":1,"audit_loop":{"round_cap":4}}'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":6}')"
  [ "$output" = '4 true' ]
  mutate ALLOW_LIB audit-loop-allowance-lib.sh -e 's/cap="\$(_gaia_loop_minimum "\$frozen" "\$live_cap")"/cap="$frozen"/'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":6}')"
  [ "$output" != '4 true' ]
}

@test "round cap effective: with nothing usable frozen the live cap applies, and without the lower bound a frozen zero wins" {
  write_override '{"version":1,"audit_loop":{"round_cap":5}}'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"ask_tokens":0}')"
  [ "$output" = '5 true' ]
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":0}')"
  [ "$output" = '5 true' ]
  mutate ALLOW_LIB audit-loop-allowance-lib.sh -e 's/ and \. >= 1 and \. <= \$hard/ and . <= $hard/'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":0}')"
  [ "$output" != '5 true' ]
}

@test "round cap effective: an invalid live cap reads false and C is the hard cap, and without the flag it reads true" {
  write_override '{"version":1,"audit_loop":{"round_cap":"4"}}'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"ask_tokens":0}')"
  [ "$output" = '10 false' ]
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"round_cap":6}')"
  [ "$output" = '6 false' ]
  mutate ALLOW_LIB audit-loop-allowance-lib.sh -e '/\[ "\$cap_status" != invalid \] || valid=false/d'
  probe gaia_loop_round_cap_effective "$MAIN" "$(frozen_state '{"ask_tokens":0}')"
  [ "$output" != '10 false' ]
}

@test "round cap effective: an unreadable state is rc 5" {
  probe gaia_loop_round_cap_effective "$MAIN" 'not json'
  [ "$status" -eq 5 ]
}

@test "freeze: the cap in use is stored, and an invalid cap is left out of it" {
  write_override '{"version":1,"audit_loop":{"round_cap":4}}'
  probe gaia_loop_context_config_initial "$MAIN"
  [ "$(jq -c '.round_cap' <<<"$output")" = 4 ]
  write_override '{"version":1,"audit_loop":{"round_cap":15}}'
  probe gaia_loop_context_config_initial "$MAIN"
  [ "$(jq -c '.round_cap' <<<"$output")" = 10 ]
  write_override '{"version":1,"audit_loop":{"round_cap":"4"}}'
  probe gaia_loop_context_config_initial "$MAIN"
  [ "$(jq -c 'has("round_cap")' <<<"$output")" = false ]
  mutate ALLOW_LIB audit-loop-allowance-lib.sh -e 's/if \[ "\$cap_status" = invalid \]; then/if false; then/'
  probe gaia_loop_context_config_initial "$MAIN"
  [ "$(jq -c 'has("round_cap")' <<<"$output")" = true ]
}

@test "grant window trigger: exactly the budget's set answers, and a dropped member is caught" {
  local trigger
  for trigger in fallback rubric:enriching rubric:stalled rubric:nitpicky rubric:small-tail; do
    probe gaia_loop_grant_window_trigger "$trigger"
    [ "$status" -eq 0 ] || { echo "$trigger refused" >&2; return 1; }
  done
  for trigger in context cap reintroduced waiver-drift '' rubric:quiet; do
    probe gaia_loop_grant_window_trigger "$trigger"
    [ "$status" -eq 1 ] || { echo "$trigger answered" >&2; return 1; }
  done
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e 's/ | rubric:small-tail)/)/'
  probe gaia_loop_grant_window_trigger rubric:small-tail
  [ "$status" -eq 1 ]
}

# A question whose in-session grant leads under its plain label: with nothing
# else at stake, below the line it continues automatically.
IN_SESSION_LEAD='{"questions":[{"options":[{"label":"Continue audit in this session (Recommended)"},{"label":"Stop and file the remainder"}]}]}'

# guard_holds <sed-expression> <trigger> <reading> <ask_tokens> <line> <disputes> <latest> <cap_valid> <used> <cap>:
# the real lib asks on these arguments, and with the guard the expression
# deletes it no longer does.
guard_holds() {
  local expression="$1"
  shift
  probe gaia_loop_automatic_answer "$1" "$IN_SESSION_LEAD" "${@:2}"
  [ "$status" -eq 0 ] && [ "$output" = ask ] || { printf 'real lib: status %s output [%s]\n' "$status" "$output" >&2; return 1; }
  mutate AUTO_LIB audit-loop-automatic-lib.sh -e "$expression"
  probe gaia_loop_automatic_answer "$1" "$IN_SESSION_LEAD" "${@:2}"
  AUTO_LIB="$SCRIPTS/audit-loop-automatic-lib.sh"
  [ "$output" != ask ] || { printf 'mutant still asks: %s\n' "$expression" >&2; return 1; }
}

@test "automatic answer: each human-decision guard asks, and without it the answer is automatic" {
  guard_holds 's/\[ "\$cap_valid" != true \] || //' rubric:enriching 'fresh 50000 1000000' 300000 300000 '[]' '' false 4 10
  guard_holds 's/ || \[ "\$used" -ge "\$cap" \]//' rubric:enriching 'fresh 50000 1000000' 300000 300000 '[]' '' true 4 4
  guard_holds 's/ || \[ "\$disputed" != false \]//' rubric:enriching 'fresh 50000 1000000' 300000 300000 '[{"path":"a","line":1,"severity":null,"reason":"x","repeated":false}]' '' true 4 10
  guard_holds 's/ || \[ "\$latest_answer_kind" = accept \]//' rubric:enriching 'fresh 50000 1000000' 300000 300000 '[]' accept true 4 10
}

@test "automatic answer: each live-line and reading guard asks, and without it the answer continues or hands off" {
  guard_holds 's/\[ "\$ask_tokens" -eq 0 \] || //' rubric:enriching 'fresh 50000 1000000' 0 300000 '[]' '' true 4 10
  guard_holds 's/ || \[ -z "\$line" \]//' context 'fresh 50000 1000000' 300000 '' '[]' '' true 4 10
  guard_holds 's/ || \[ "\$line" -eq 0 \]//' context 'fresh 50000 1000000' 300000 0 '[]' '' true 4 10
  guard_holds 's/ || ! \[\[ \$reading =~ .* \]\]; then/; then/' context stale 300000 300000 '[]' '' true 4 10
}
