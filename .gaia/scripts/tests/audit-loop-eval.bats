#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-loop-eval.sh: the finding set, A(r), the
# verdicts and their grant windows, the allowance fold and the deny decision,
# the checkpoint brief, the PR-body record values, and the read-only CLI.
#
# Every verdict fixture is built from real commits and real findings
# sidecars (.gaia/tests/helpers/audit-loop-fixture.sh); no A value is ever
# injected, except where a case mutates a stored snapshot to prove it is read
# rather than recomputed.
#
# AUDIT_LOOP_SCRIPTS_DIRECTORY points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-eval.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup_file() {
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/../../tests/helpers/audit-loop-fixture.sh"
  alf_build_template
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  alf_init
  alf_branch feat/loop
  MEMBER=code-audit-frontend
}

# evaluate_round <r>: round r's snapshot through the sourced function (what the hook runs).
evaluate_round() {
  gaia_loop_evaluate_round "$ALF_ROOT" "$(cat "$ALF_STATE")" "$1"
}

# read_json <json> <filter>: one jq read.
read_json() {
  printf '%s' "$1" | jq -r "$2"
}

# plus <entries-json> <path> <line-json>: append one entry.
plus() {
  jq -n -c --argjson entries "$1" --arg path "$2" --argjson line "$3" '$entries + [{path: $path, line: $line, finding_class: "rule/x"}]'
}

# next_round <r> <entries-json>: commit the working tree as round r.
next_round() {
  alf_commit "round $1"
  alf_round "$1" "$MEMBER" "$2"
}

# cli_copy: the scripts in a scratch dir beside a stub usage.sh whose
# behaviour STUB_USAGE_MODE (ok, fail, hang) picks. Sets CLI.
cli_copy() {
  local script_file
  CLI="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$CLI"
  for script_file in audit-loop-eval.sh audit-loop-state-lib.sh exclusive-lock-lib.sh branch-authorship-lib.sh filing-outcomes-lib.sh audit-loop-signals-lib.sh context-checkpoint-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh audit-triage-lib.sh audit-veto-lib.sh audit-loop-stop-lib.sh audit-loop-allowance-lib.sh audit-loop-round-lib.sh audit-loop-report-lib.sh; do
    cp "$SCRIPTS/$script_file" "$CLI/$script_file"
  done
  cat >"$CLI/usage.sh" <<'EOF'
case "${STUB_USAGE_MODE:-ok}" in
  ok) printf 'spend for %s: 1.23 USD\n' "$3" ;;
  fail) exit 1 ;;
  hang) sleep 30; printf 'late\n' ;;
esac
EOF
}

# sequence_case <verdict> <decision> <A...>: build the A sequence and check the
# last round's verdict and the hook's decision on it.
sequence_case() {
  local want="$1" decision="$2" snapshot argument_count
  shift 2
  alf_sequence "$@"
  argument_count=$#
  snapshot="$(evaluate_round "$argument_count")"
  [ "$(read_json "$snapshot" '.A')" = "${!argument_count}" ] || { echo "A was $(read_json "$snapshot" '.A'), want ${!argument_count}"; return 1; }
  [ "$(read_json "$snapshot" '.verdict')" = "$want" ] || { echo "verdict $(read_json "$snapshot" '.verdict'), want $want"; return 1; }
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = "$decision" ]
}

@test "entry_id on findings and a resolutions key on the sidecar never change the verdict, A, or counted keys" {
  local plain decorated sidecar_file decorated_count=0
  alf_sequence 5 5 5
  plain="$(evaluate_round 3)"
  [ "$(read_json "$plain" '.verdict')" = stalled ]
  for sidecar_file in "$ALF_ROOT"/.gaia/local/audit/*.findings.json; do
    jq -c '.findings |= (to_entries | map(.value + {entry_id: ("r1-" + (.key + 1 | tostring))}))
           | . + {resolutions: [{entry_id: "r1-99", rationale: "fixed at HEAD"}]}' \
      "$sidecar_file" >"$sidecar_file.decorated" && mv "$sidecar_file.decorated" "$sidecar_file"
    [ "$(jq -r '.findings[0].entry_id' "$sidecar_file")" = "r1-1" ] || return 1
    decorated_count=$((decorated_count + 1))
  done
  [ "$decorated_count" -ge 1 ]
  decorated="$(evaluate_round 3)"
  [ "$(read_json "$decorated" '.verdict')" = "$(read_json "$plain" '.verdict')" ]
  [ "$(read_json "$decorated" '.A')" = "$(read_json "$plain" '.A')" ]
  [ "$(read_json "$decorated" '.evidence | tojson')" = "$(read_json "$plain" '.evidence | tojson')" ]
}

# bats test_tags=protected
@test "stalled verdict: each A sequence, the quiet-round reset and the stored-history read, as one case table" {
  local snapshot
  echo "case: A 5,5,5 stalls and denies"
  sequence_case stalled "deny stalled" 5 5 5
  fresh_fixture
  echo "case: A 5,6,7 stalls and denies"
  sequence_case stalled "deny stalled" 5 6 7
  fresh_fixture
  echo "case: A 5,4,4 continues and allows"
  sequence_case continue allow 5 4 4
  fresh_fixture
  echo "case: A 5,5,4 continues and allows"
  sequence_case continue allow 5 5 4
  fresh_fixture
  echo "case: A 5,5 continues and allows"
  sequence_case continue allow 5 5
  fresh_fixture
  echo "case: two quiet rounds then one finding continues, since a quiet round resets the window"
  sequence_case continue allow 0 0 1
  fresh_fixture
  echo "case: a quiet round as A(r-2) keeps a flat run after it from stalling"
  sequence_case continue allow 0 1 1
  fresh_fixture
  echo "case: A 3,2,1,1,1 continues at round 4 and stalls at round 5"
  alf_sequence 3 2 1 1 1
  [ "$(jq -r '.history.rounds[3].snapshot.verdict' "$ALF_STATE")" = continue ]
  snapshot="$(evaluate_round 5)"
  [ "$(read_json "$snapshot" '.verdict')" = stalled ]
  [ "$(read_json "$snapshot" '.evidence.A_series | map(tostring) | join(",")')" = "3,2,1,1,1" ]
}

@test "enriching verdict: a new key on a repaired line, and each shape that never makes enriching, as one case table" {
  local snapshot
  echo "case (i): a new key on a repaired line at round 3 is enriching and named"
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = enriching ]
  [ "$(read_json "$snapshot" '.evidence.new_keys_on_repaired_lines | tojson')" = '[["code-audit-frontend","rule/x","f.txt",8]]' ]
  fresh_fixture
  echo "case (ii): a persisting key on a repaired line while A falls continues"
  alf_sequence 6 5
  alf_set_line f.txt 2 repaired
  next_round 3 "$(alf_entries f.txt 1 3)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  fresh_fixture
  echo "case (iii): a new key on an unchanged line of a repaired path continues"
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 10)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  fresh_fixture
  echo "case (iv): the enriching shape at round 2 continues"
  alf_sequence 6
  alf_set_line f.txt 8 repaired
  next_round 2 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(read_json "$(evaluate_round 2)" '.verdict')" = continue ]
  fresh_fixture
  echo "case: a deletion-only hunk never makes enriching"
  alf_sequence 6 5
  awk 'NR != 12' "$ALF_ROOT/f.txt" >"$ALF_ROOT/f.tmp" && mv "$ALF_ROOT/f.tmp" "$ALF_ROOT/f.txt"
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 11)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  fresh_fixture
  echo "case: a pure rename never makes enriching"
  alf_sequence 6 5
  alf_git mv other.txt renamed.txt
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" renamed.txt 1)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  fresh_fixture
  echo "case: a null line never makes enriching"
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt null)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  fresh_fixture
  echo "case: the enriching shape after a round with missing evidence continues"
  alf_sequence 6
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_store_snapshot 1
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 2 20
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(jq -r '.history.rounds[1].snapshot.verdict' "$ALF_STATE")" = unknown ]
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  fresh_fixture
  echo "case: a new key on an upstream-merged line is not authored, so never enriching"
  alf_sequence 6 5
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(plus "$(alf_entries f.txt 1 3)" base.txt 18)" 31
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "COV-003: a sidecar written after the round's baseline is never evidence" {
  local snapshot
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 3)" 11
  alf_baseline 1 15
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 7)" 16 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  snapshot="$(evaluate_round 1)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  rm "$ALF_ROOT"/.gaia/local/audit/aaaa*.findings.json
  snapshot="$(evaluate_round 1)"
  [ "$(read_json "$snapshot" '.verdict')" = unknown ]
  [ "$(read_json "$snapshot" '.A')" = null ]
}

@test "grant window: enriching and stalled are suppressed for their g+1 / g+2 rounds, then return" {
  echo "case: enriching is off at the granted round and back on the round after"
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = enriching ]
  alf_add_checkpoint 3 enriching
  alf_add_answer 1 grant 3
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  alf_set_line f.txt 9 repaired
  next_round 4 "$(plus "$(plus "$(alf_entries f.txt 1 2)" f.txt 8)" f.txt 9)"
  [ "$(read_json "$(evaluate_round 4)" '.verdict')" = enriching ]
  fresh_fixture
  echo "case: stalled is off the round after a grant and back on the round after that"
  alf_sequence 5 5 5
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = stalled ]
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 grant 3
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  alf_set_line other.txt 4 "round 4"
  next_round 4 "$(alf_entries f.txt 1 5)"
  [ "$(read_json "$(evaluate_round 4)" '.verdict')" = continue ]
  alf_set_line other.txt 5 "round 5"
  next_round 5 "$(alf_entries f.txt 1 5)"
  [ "$(read_json "$(evaluate_round 5)" '.verdict')" = stalled ]
}

@test "UAT-008: only non-authored or disposed entries is quiet with a non-empty set; a null line on a changed path is not" {
  local rows snapshot
  alf_fill f.txt 12 feature
  alf_set_line base.txt 5 "branch edit"
  alf_set_line other.txt 1 "round 1"
  next_round 1 "$(alf_entries f.txt 1 2)"
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual"}]'
  rows='[{"path":"base.txt","line":15,"finding_class":"rule/x"},
         {"path":"untouched.txt","line":3,"finding_class":"rule/x"},
         {"path":"untouched.txt","line":null,"finding_class":"rule/x"},
         {"path":"f.txt","line":1,"finding_class":"rule/x"}]'
  alf_set_line other.txt 2 "round 2"
  next_round 2 "$rows"
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.A')" = 0 ]
  [ "$(read_json "$snapshot" '.keys | length')" -gt 0 ]
  [ "$(read_json "$snapshot" '.verdict')" = quiet ]
  alf_sidecar "$MEMBER" "$(plus "$rows" f.txt null)" 22
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.A')" = 1 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "a file entry the filer refused as branch-authored no longer disposes its key in A(r)" {
  local rows run_folder="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH" key_line
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  next_round 1 "$(alf_entries f.txt 1 2)"
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"file"}]'
  rows='[{"path":"f.txt","line":1,"finding_class":"rule/x"}]'
  alf_set_line other.txt 2 "round 2"
  next_round 2 "$rows"
  key_line='{"key":{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1},"disposition":"file","issue":null,"record":null,"outcome":'
  printf '%s"filed"}\n' "$key_line" >"$run_folder/filing-outcomes-1.jsonl"
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 0 ]
  printf '%s"refused-authored"}\n' "$key_line" >"$run_folder/filing-outcomes-1.jsonl"
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 1 ]
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual"}]'
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 0 ]
}

@test "UAT-018: re-reported residuals never stall a converging branch" {
  local fresh
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  next_round 1 "$(alf_entries f.txt 1 6)"
  alf_dispositions 1 "$(jq -n -c '[range(1;7) | {member: "code-audit-frontend", finding_class: "rule/x", path: "f.txt", line: .,
    disposition: (if . <= 2 then "accept-residual" else "fix" end)}]')"
  alf_set_line other.txt 2 "round 2"
  next_round 2 "$(plus "$(alf_entries f.txt 1 2)" f.txt 7)"
  alf_set_line other.txt 3 "round 3"
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 8)"
  alf_set_line other.txt 4 "round 4"
  next_round 4 '[]'
  alf_store_snapshot 4
  fresh="$(jq -r '[.history.rounds[1:][] | .snapshot.verdict] | join(",")' "$ALF_STATE")"
  [ "$fresh" = "continue,continue,quiet" ]
}

@test "UAT-021b: a missing, stale or unparseable member sidecar is unknown, still bounded by the allowance" {
  local variant snapshot two='["code-audit-frontend","code-audit-maintainer-shell"]'
  local shell_sidecar="$ALF_ROOT/.gaia/local/audit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.$ALF_SLUG.code-audit-maintainer-shell.findings.json"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "$two"
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 2)" 11
  for variant in missing stale unparseable; do
    rm -f "$shell_sidecar"
    case "$variant" in
      stale) alf_sidecar code-audit-maintainer-shell '[]' 5 ;;
      unparseable) printf 'not json' >"$shell_sidecar" && touch -t "$(alf_time 12)" "$shell_sidecar" ;;
    esac
    snapshot="$(evaluate_round 1)"
    [ "$(read_json "$snapshot" '.verdict')" = unknown ] || { echo "$variant gave $(read_json "$snapshot" '.verdict')"; return 1; }
    [ "$(read_json "$snapshot" '.A')" = null ] || return 1
    [ "$(read_json "$snapshot" '.evidence.missing_members | tojson')" = '["code-audit-maintainer-shell"]' ] || return 1
  done
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = allow ]
  alf_state_edit '.history.knobs.checkpoint_round = 1'
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = "deny allowance" ]
}

@test "UAT-030: each round keeps its own merge base; stored A is read, never recomputed" {
  local snapshot earlier_merge_base
  alf_sequence 5 5
  earlier_merge_base="$(jq -r '.history.rounds[0].snapshot.merge_base' "$ALF_STATE")"
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(plus "$(alf_entries f.txt 1 5)" base.txt 18)" 31
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.merge_base')" = "$(alf_git rev-parse origin/main)" ]
  [ "$(read_json "$snapshot" '.merge_base')" != "$earlier_merge_base" ]
  [ "$(jq -r '.history.rounds[1].snapshot.merge_base' "$ALF_STATE")" = "$earlier_merge_base" ]
  [ "$(read_json "$snapshot" '.A')" = 5 ]
  [ "$(read_json "$snapshot" '.verdict')" = stalled ]
  alf_state_edit '.history.rounds[1].snapshot.A = 6'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  [ "$(jq -r '[.history.rounds[].tree] | unique | length' "$ALF_STATE")" = 3 ]
}

@test "authorship fails closed: an invalid path, an invalid line and an uncomputable merge base count as authored; row text never reaches git argv" {
  echo "case: invalid rows count as authored; row text never reaches git argv; nothing written outside"
  local row snapshot stub log real_git before after sidecar_time=40
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 1 10
  for row in '{"path":"-rf","line":1}' '{"path":"a/../b","line":1}' '{"path":"f.txt","line":"x"}' '{"path":"f.txt","line":-1}'; do
    sidecar_time=$((sidecar_time + 1))
    alf_sidecar "$MEMBER" "[$row]" "$sidecar_time"
    [ "$(read_json "$(evaluate_round 1)" '.A')" = 1 ] || { echo "not counted: $row"; return 1; }
  done
  stub="$BATS_TEST_TMPDIR/stub"
  log="$stub/git.log"
  real_git="$(command -v git)"
  mkdir -p "$stub"
  : >"$log"
  printf '#!/bin/sh\nfor argument in "$@"; do printf "%%s\\n" "$argument"; done >>"%s"\nprintf "%%s\\n" "--END--" >>"%s"\nexec "%s" "$@"\n' "$log" "$log" "$real_git" >"$stub/git"
  chmod +x "$stub/git"
  alf_sidecar "$MEMBER" '[{"path":"-rf","line":1},{"path":"a/../b","line":null},{"path":"f.txt","line":"x"},{"path":"f.txt","line":-1}]' 50
  before="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  snapshot="$(PATH="$stub:$PATH" evaluate_round 1)"
  after="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  [ "$(read_json "$snapshot" '.A')" = 4 ]
  [ "$before" = "$after" ]
  [ -e "$PWD/-rf" ] && return 1
  [ -e "$ALF_ROOT/-rf" ] && return 1
  # Every diff invocation ends its revisions with `--`; no row path is argv.
  awk '/^--END--$/ { if (in_diff && !seen_double_dash) bad = 1; in_diff = 0; seen_double_dash = 0; record_count++; next }
       $0 == "diff" { in_diff = 1 } $0 == "--" { seen_double_dash = 1 }
       $0 == "-rf" || $0 == "a/../b" { bad = 1 }
       END { exit (bad || record_count == 0) }' "$log"
  [ "$(grep -c '^diff$' "$log")" -ge 2 ]
  fresh_fixture
  echo "case: an untouched line is not authored, but an uncomputable merge base counts every row as authored"
  alf_fill f.txt 12 feature
  alf_set_line base.txt 5 "branch edit"
  alf_commit "round 1"
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 1 10
  alf_sidecar "$MEMBER" '[{"path":"f.txt","line":1},{"path":"base.txt","line":15}]' 11
  [ "$(read_json "$(evaluate_round 1)" '.A')" = 1 ]
  (
    gaia_authorship_merge_base() { return 1; }
    [ "$(read_json "$(evaluate_round 1)" '.A')" = 2 ]
  )
}

@test "CLI read-only: every subcommand leaves the state byte-identical and takes no lock" {
  local state_copy subcommand
  cli_copy
  alf_sequence 4 3
  alf_store_snapshot 2
  state_copy="$(snapshot_file "$ALF_STATE")"
  for subcommand in findings evaluate-round brief record-values state-path current-round round-history veto-state reopened-round accepted-keys; do
    run "$CLI/audit-loop-eval.sh" "$subcommand" --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || { echo "$subcommand exited $status: $output"; return 1; }
    assert_files_identical "$state_copy" "$ALF_STATE" || { echo "$subcommand changed the state"; return 1; }
    [ -e "$ALF_STATE.lock" ] && { echo "$subcommand took the lock"; return 1; }
  done
  run "$CLI/audit-loop-eval.sh" state-path --root "$ALF_ROOT"
  [ "$output" = "$ALF_STATE" ]
  alf_state_edit '.history.units = [$unit]' --argjson unit "$(unit_entry 1 3 4 0)"
  state_copy="$(snapshot_file "$ALF_STATE")"
  for subcommand in next-unit unit-window pinned-question; do
    run "$CLI/audit-loop-eval.sh" "$subcommand" --root "$ALF_ROOT"
    assert_files_identical "$state_copy" "$ALF_STATE" || { echo "$subcommand changed the state"; return 1; }
    [ -e "$ALF_STATE.lock" ] && { echo "$subcommand took the lock"; return 1; }
  done
  true
}

@test "allowance fold: defaults, a grant sets g+n, an accept sets c+1 and the closing round" {
  local state
  echo "case: defaults, then a grant at round 5"
  alf_sequence 2
  state="$(cat "$ALF_STATE")"
  [ "$(gaia_loop_allowed "$state")" = 5 ]
  alf_add_checkpoint 5 allowance
  alf_add_answer 1 grant 2
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = 7 ]
  fresh_fixture
  echo "case: an accept allows one closing round"
  alf_sequence 4 4 4
  alf_add_checkpoint 3 stalled
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = false ]
  alf_add_answer 1 accept
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = 4 ]
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = true ]
}

@test "knobs: frozen at round 1 capped at the defaults; a live value only lowers; a malformed one is ignored with a note" {
  local state knob_value
  echo "case: a live checkpoint knob only lowers the frozen one; a malformed one is ignored"
  alf_sequence 2
  state="$(cat "$ALF_STATE")"
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_allowed "$state")" = 5 ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=4 gaia_loop_allowed "$state")" = 4 ]
  for knob_value in 0 -1 abc ''; do
    [ "$(GAIA_AUDIT_CHECKPOINT_ROUND="$knob_value" gaia_loop_allowed "$state" 2>/dev/null)" = 5 ] || { echo "'$knob_value' moved it"; return 1; }
  done
  run --separate-stderr env GAIA_AUDIT_CHECKPOINT_ROUND=abc bash -c '. "$1"; gaia_loop_allowed "$2"' _ "$SCRIPTS/audit-loop-eval.sh" "$state"
  [ "$output" = 5 ]
  case "$stderr" in *GAIA_AUDIT_CHECKPOINT_ROUND*) ;; *) return 1 ;; esac
  echo "case: knobs are frozen at round 1, capped at the defaults"
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=2 GAIA_AUDIT_GRANT_ROUNDS=1 gaia_loop_knobs_initial)" = '{"checkpoint_round":2,"grant_rounds":1}' ]
  [ "$(gaia_loop_knobs_initial)" = '{"checkpoint_round":6,"grant_rounds":3}' ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_knobs_initial | jq -r '.checkpoint_round')" = 6 ]
  [ "$(GAIA_AUDIT_GRANT_ROUNDS=7 gaia_loop_knobs_initial | jq -r '.grant_rounds')" = 3 ]
}

# brief_check <recommended> <pending> <critical> <major> <minor>: run the
# CLI brief and check the fields every verdict shares.
brief_check() {
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "brief exited $status: $output"; return 1; }
  BRIEF="$output"
  [ "$(read_json "$BRIEF" '.recommended')" = "$1" ] || { echo "recommended $(read_json "$BRIEF" '.recommended')"; return 1; }
  [ "$(read_json "$BRIEF" '.pending_checkpoint')" = "$2" ] || return 1
  [ "$(read_json "$BRIEF" '.grant_line')" = "$(gaia_loop_grant_line 3)" ] || return 1
  [ "$(read_json "$BRIEF" '.accept_line')" = "$(gaia_loop_accept_line)" ] || return 1
  [ "$(read_json "$BRIEF" '.remaining_by_severity | "\(.critical),\(.major),\(.minor)"')" = "$3,$4,$5" ] || { echo "severity $(read_json "$BRIEF" '.remaining_by_severity')"; return 1; }
  [ "$(read_json "$BRIEF" '.spend')" = "spend for feat/loop: 1.23 USD" ] || { echo "spend $(read_json "$BRIEF" '.spend')"; return 1; }
  [ "$(read_json "$BRIEF" '.spend_note')" = "information only" ]
}

@test "brief: the recommendation per verdict and checkpoint trigger, with spend information only" {
  local base mode
  cli_copy
  echo "case: continue at an allowance checkpoint recommends grant"
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  brief_check grant true 0 2 0
  [ "$(read_json "$BRIEF" '.verdict')" = continue ]
  [ "$(read_json "$BRIEF" '.rounds_run')" = 5 ]
  [ "$(read_json "$BRIEF" '.allowed')" = 5 ]
  [ "$(read_json "$BRIEF" '[.per_round[].A] | map(tostring) | join(",")')" = "6,5,4,3,2" ]
  fresh_fixture
  echo "case: quiet recommends accept"
  alf_fill f.txt 12 feature
  next_round 1 '[{"path":"untouched.txt","line":1,"severity":"critical"},{"path":"untouched.txt","line":2,"severity":"minor"},{"path":"untouched.txt","line":3,"severity":"minor"}]'
  brief_check accept false 1 0 2
  [ "$(read_json "$BRIEF" '.verdict')" = quiet ]
  fresh_fixture
  echo "case: stalled recommends stop"
  alf_sequence 5 5 5
  alf_add_checkpoint 3 stalled
  brief_check stop true 0 5 0
  [ "$(read_json "$BRIEF" '.verdict')" = stalled ]
  fresh_fixture
  echo "case: one finding after two quiet rounds late in a loop does not recommend stop"
  alf_sequence 12 7 9 3 0 5 0 0 1
  alf_add_checkpoint 9 rubric:small-tail
  brief_check grant true 0 1 0
  [ "$(read_json "$BRIEF" '.verdict')" = continue ]
  fresh_fixture
  echo "case: enriching recommends accept"
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  brief_check accept false 0 4 0
  [ "$(read_json "$BRIEF" '.verdict')" = enriching ]
  fresh_fixture
  echo "case: unknown recommends grant; a failing or hanging usage.sh only sets spend to unavailable"
  sed -i.bak 's/^_GAIA_LOOP_SPEND_TIMEOUT=5$/_GAIA_LOOP_SPEND_TIMEOUT=1/' "$CLI/audit-loop-eval.sh"
  grep -qx '_GAIA_LOOP_SPEND_TIMEOUT=1' "$CLI/audit-loop-eval.sh"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 2)" 11
  brief_check grant false 0 2 0
  [ "$(read_json "$BRIEF" '.verdict')" = unknown ]
  base="$(read_json "$BRIEF" 'del(.spend, .evidence) | tojson')"
  for mode in fail hang; do
    STUB_USAGE_MODE="$mode" run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || return 1
    [ "$(read_json "$output" '.spend')" = unavailable ] || { echo "$mode spend: $(read_json "$output" '.spend')"; return 1; }
    [ "$(read_json "$output" 'del(.spend, .evidence) | tojson')" = "$base" ] || { echo "$mode changed another field"; return 1; }
  done
  fresh_fixture
  echo "case: the brief reports the signals and the cap; a context checkpoint recommends grant unless a denying signal holds"
  rounds_sequence '[]'
  alf_add_checkpoint 1 context
  alf_state_edit '.history.checkpoints[-1].trigger = "context"'
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(read_json "$output" '.verdict')" = quiet ]
  [ "$(read_json "$output" '.recommended')" = grant ]
  [ "$(read_json "$output" '.rounds_cap')" = 10 ]
  [ "$(read_json "$output" '.accept_eligible')" = true ]
  [ "$(read_json "$output" '.accept_reasons | tojson')" = '["quiet"]' ]
  [ "$(read_json "$output" '.signals.quiet')" = true ]
  fresh_fixture
  authored_count_sequence major 5 5 5
  alf_add_checkpoint 3 context
  alf_state_edit '.history.checkpoints[-1].trigger = "context"'
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$(read_json "$output" '.verdict')" = stalled ]
  [ "$(read_json "$output" '.recommended')" = stop ]
}

@test "pending checkpoint and closing round follow the answers; current-round counts history" {
  local state
  cli_copy
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 0 ]
  alf_sequence 4 4 4
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 3 ]
  [ -z "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" ]
  alf_add_checkpoint 3 stalled
  state="$(cat "$ALF_STATE")"
  [ "$(read_json "$(gaia_loop_pending_checkpoint "$state")" '.index')" = 1 ]
  [ "$(gaia_loop_next_closing "$state")" = false ]
  alf_add_answer 1 accept
  state="$(cat "$ALF_STATE")"
  [ -z "$(gaia_loop_pending_checkpoint "$state")" ]
  [ "$(gaia_loop_next_closing "$state")" = true ]
  alf_set_line other.txt 4 "round 4"
  alf_commit "round 4"
  alf_add_round "[\"$MEMBER\"]" true
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = false ]
  alf_add_checkpoint 4 allowance
  [ "$(read_json "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" '.index')" = 2 ]
}

@test "unit-window: the closing field is true only for a unit an accept admitted" {
  cli_copy
  alf_sequence 4 4 4
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}]'
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 3 false" ]
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 accept
  alf_state_edit '.history.units += [{unit: 2, start_round: 4, k: 3, through_round: 4, admitted_on: "accept",
    after_checkpoint: 1, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}]'
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "2 4 4 true" ]
  # Red twin: a grant-admitted unit in the same position is not closing.
  alf_state_edit '.history.units[-1].admitted_on = "grant"'
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$output" = "2 4 4 false" ]
}

@test "red: an accept unit that joins the open round leaves the accept unspent, so the next unit is the closing round" {
  local decision admitted_on start_round through_round
  cli_copy
  alf_sequence 4 4 4
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 accept
  # The accept unit joined round 3 on its unmoved tree and recorded no round.
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"},
    {unit: 2, start_round: 4, k: 3, through_round: 4, admitted_on: "accept",
    after_checkpoint: 1, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}]'
  [ "$(jq '.history.rounds | length' "$ALF_STATE")" = 3 ]
  # After the tree moves, the next unit is judged with a reading below the line.
  decision="$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" null "$LOW" 300000 50)"
  [ "$decision" = "allow accept 4 4" ] || { echo "decision: $decision"; return 1; }
  read -r _ admitted_on start_round through_round <<<"$decision"
  alf_state_edit ".history.units += [{unit: 3, start_round: $start_round, k: 3, through_round: $through_round,
    admitted_on: \"$admitted_on\", after_checkpoint: 1, recorded_at: \"2026-01-01T00:00:00Z\", session_id: \"s1\"}]"
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$output" = "3 4 4 true" ]
  # The round this unit opens is recorded with the same closing flag.
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = true ]
}

@test "record-values: rounds, distinct trees per member, and grants" {
  cli_copy
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_add_round '["code-audit-frontend"]'
  alf_set_line other.txt 3 "round 3"
  alf_commit "round 3"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_add_checkpoint 3 allowance
  alf_add_answer 1 grant 2
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":3,"members":{"code-audit-frontend":3,"code-audit-maintainer-shell":2},"grants":1}' ]
}

# light_ledger_path: the sandbox ledger of light reviews for the fixture branch.
light_ledger_path() {
  printf '%s/.gaia/local/audit/light/%s.reviews.jsonl\n' "$ALF_ROOT" "$(gaia_branch_slug "$ALF_ROOT")"
}

# write_light_ledger <member>...: one ledger line per argument, the verdict cycling clear, escalate, failed.
write_light_ledger() {
  local ledger_path verdicts member index=0
  ledger_path="$(light_ledger_path)"
  mkdir -p "$(dirname "$ledger_path")"
  : >"$ledger_path"
  # sanctioned copy of .gaia/scripts/audit-light-mark.sh#light_review_outcomes
  verdicts=(clear escalate failed)
  for member in "$@"; do
    printf '{"member":"%s","digest":"%s","tree":"%s","verdict":"%s","at":"2026-01-01T00:00:00Z"}\n' \
      "$member" "$(printf 'a%.0s' $(seq 1 64))" "$ALF_TREE" "${verdicts[$((index % 3))]}" >>"$ledger_path"
    index=$((index + 1))
  done
}

@test "record-values: light and quick counts per ledger state" {
  cli_copy
  echo "case: light reviews are counted per member from the ledger and never enter total"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend"]'
  write_light_ledger code-audit-frontend code-audit-maintainer-shell code-audit-frontend
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":1,"members":{"code-audit-frontend":1},"grants":0,"light":{"code-audit-frontend":2,"code-audit-maintainer-shell":1}}' ]
  fresh_fixture
  echo "case: an absent ledger, an empty one and an unreadable one yield no light key"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend"]'
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":1,"members":{"code-audit-frontend":1},"grants":0}' ]
  write_light_ledger
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$output" = '{"total":1,"members":{"code-audit-frontend":1},"grants":0}' ]
  printf 'not json\n' >"$(light_ledger_path)"
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":1,"members":{"code-audit-frontend":1},"grants":0}' ]
  fresh_fixture
  echo "case: a ledger with no loop state still reads the ledger, counting legacy lines under light only"
  write_light_ledger code-audit-frontend code-audit-frontend
  [ -f "$(light_ledger_path)" ]
  [ ! -f "$ALF_STATE" ]
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0,"light":{"code-audit-frontend":2}}' ]
  fresh_fixture
  echo "case: with no state, one merge-base clear is a quick count, total 0 and no light key"
  write_review_ledger merge-base clear code-audit-frontend
  [ ! -f "$ALF_STATE" ]
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0,"quick":{"code-audit-frontend":1}}' ]
  fresh_fixture
  echo "case: one admitted unit and no rounds gives the same quick count, total 0, empty members and no light key"
  alf_seed_state '{}'
  alf_state_edit '.history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}]'
  [ "$(jq -c '.history.rounds' "$ALF_STATE")" = '[]' ]
  write_review_ledger merge-base clear code-audit-frontend
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0,"quick":{"code-audit-frontend":1}}' ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 3 false" ]
  fresh_fixture
  echo "case: a merge-base clear and a post-clearance clear count once each, in quick and in light"
  write_review_ledger merge-base clear code-audit-frontend
  write_review_ledger full clear code-audit-frontend
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0,"light":{"code-audit-frontend":1},"quick":{"code-audit-frontend":1}}' ]
  fresh_fixture
  echo "case: a member with a full round is dropped from quick, a quick-only member stays"
  alf_seed_state '{}'
  alf_state_edit '.history.knobs = {checkpoint_round: 5, grant_rounds: 3}
    | .history.rounds = [{round: 1, tree: ("a" * 40), commit: ("b" * 40), raw_branch_slug: "feat-loop",
        dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false, snapshot: null}]'
  write_review_ledger merge-base clear code-audit-frontend code-audit-maintainer-shell
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.quick' <<<"$output")" = '{"code-audit-maintainer-shell":1}' ]
  [ "$(jq -c '.members' <<<"$output")" = '{"code-audit-frontend":1}' ]
  fresh_fixture
  echo "case: a merge-base escalate and a merge-base failed run count in neither quick nor light"
  write_review_ledger merge-base escalate code-audit-frontend
  write_review_ledger merge-base failed code-audit-frontend
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0}' ]
  fresh_fixture
  echo "case: a refusal-anchored escalate and a null anchor kind still count under light"
  write_review_ledger refusal escalate code-audit-frontend
  write_review_ledger null clear code-audit-maintainer-shell
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0,"light":{"code-audit-frontend":1,"code-audit-maintainer-shell":1}}' ]
}

# write_review_ledger <anchor-kind|null> <verdict> <member>...: append one ledger line per member.
write_review_ledger() {
  local ledger_path member anchor_kind="$1" verdict="$2"
  ledger_path="$(light_ledger_path)"
  mkdir -p "$(dirname "$ledger_path")"
  shift 2
  for member in "$@"; do
    jq -n -c --arg member "$member" --arg verdict "$verdict" --arg tree "$ALF_TREE" --arg anchor_kind "$anchor_kind" \
      '{member: $member, digest: ("a" * 64), tree: $tree, verdict: $verdict, at: "2026-01-01T00:00:00Z",
        anchor_kind: (if $anchor_kind == "null" then null else $anchor_kind end),
        marked_at: "2026-01-01T00:00:00Z", reviewer_duration_ms: null}' >>"$ledger_path"
  done
}

# --- the evaluator's failure arms name their cause -----------------------------

# assert_failure_reason <status> <pattern>: the last run exited <status> and its
# last stderr line is an audit-loop-eval: reason matching <pattern>.
assert_failure_reason() {
  local last_line
  [ "$status" -eq "$1" ] || { echo "status $status, want $1; stderr: $stderr"; return 1; }
  last_line="$(printf '%s\n' "$stderr" | tail -n 1)"
  # shellcheck disable=SC2254 # <pattern> is a glob by design
  case "$last_line" in "audit-loop-eval: "$2) ;; *) echo "last stderr line: '$last_line'"; return 1 ;; esac
}

# malformed_vetoes: a vetoes.json the evaluator refuses to read.
malformed_vetoes() {
  local vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  mkdir -p "${vetoes%/*}"
  printf 'not json\n' >"$vetoes"
}

@test "CLI exit codes: detached 4, corrupt 5, jq missing 6, an evaluator failure's code and reason, and no recorded round 2" {
  cli_copy
  echo "case: detached is 4, corrupt state is 5, missing jq is 6, each with one diagnostic line"
  alf_sequence 2
  printf '{"schema":1,' >"$ALF_STATE"
  run --separate-stderr "$CLI/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT"
  [ "$status" -eq 5 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *corrupt*) ;; *) return 1 ;; esac
  PATH="$(path_shim_without jq)" run --separate-stderr "$CLI/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT"
  [ "$status" -eq 6 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *jq*) ;; *) return 1 ;; esac
  alf_git checkout -q --detach
  run --separate-stderr "$CLI/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT"
  [ "$status" -eq 4 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *detached*) ;; *) return 1 ;; esac
  fresh_fixture
  echo "case: evaluate-round and brief print the evaluator's reason and keep its exit code"
  alf_sequence 2 2
  malformed_vetoes
  [ "$(jq -r '.history.rounds[1].snapshot' "$ALF_STATE")" = null ]
  run --separate-stderr "$CLI/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT"
  assert_failure_reason 5 "*vetoes.json*"
  run --separate-stderr "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  assert_failure_reason 5 "*vetoes.json*"
  fresh_fixture
  echo "case: brief on a state with no rounds says so"
  alf_seed_state '{}'
  run --separate-stderr "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  assert_failure_reason 2 "*no recorded round*"
}

# failure_arm <arm>: one evaluator failure arm against the shared two-round fixture.
# The caller runs it in a subshell, so a stubbed internal never outlives its arm.
failure_arm() {
  case "$1" in
    round-not-positive)
      run --separate-stderr evaluate_round 0
      assert_failure_reason 2 "round 0 is not a positive integer"
      ;;
    round-past-history)
      run --separate-stderr evaluate_round 9
      assert_failure_reason 2 "*round 9*"
      ;;
    entry-without-oid)
      alf_state_edit '.history.rounds[1].tree = "not-an-oid"'
      run --separate-stderr evaluate_round 2
      assert_failure_reason 5 "*round 2*tree or commit*"
      ;;
    malformed-vetoes)
      malformed_vetoes
      run --separate-stderr evaluate_round 2
      assert_failure_reason 5 "*vetoes.json*"
      ;;
    findings-read)
      _gaia_loop_raw_findings() { return 1; }
      run --separate-stderr evaluate_round 2
      assert_failure_reason 2 "*findings*round 2*"
      ;;
    authorship-read)
      _gaia_loop_authorship() { return 1; }
      run --separate-stderr evaluate_round 2
      assert_failure_reason 2 "*authorship*round 2*"
      ;;
    authorship-annotation)
      _gaia_loop_annotate() { return 1; }
      run --separate-stderr evaluate_round 2
      assert_failure_reason 2 "*annotate*round 2*"
      ;;
    dispositions-read)
      _gaia_loop_disposed() { printf 'not json\n'; }
      run --separate-stderr evaluate_round 2
      assert_failure_reason 5 "*dispositions*round 2*"
      ;;
    snapshot-uncomputable)
      _gaia_loop_annotate() { printf '{}\n'; }
      run --separate-stderr evaluate_round 2
      [ "$status" -ne 0 ]
      assert_failure_reason "$status" "*snapshot*round 2*"
      ;;
    *)
      echo "unknown failure arm: $1"
      return 1
      ;;
  esac
}

@test "failure reason: every evaluator failure arm exits with its code and names its cause" {
  local arm saved_state="$BATS_TEST_TMPDIR/state.saved" vetoes arm_count=0
  alf_sequence 2 2
  cp "$ALF_STATE" "$saved_state"
  vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  for arm in round-not-positive round-past-history entry-without-oid malformed-vetoes findings-read authorship-read \
    authorship-annotation dispositions-read snapshot-uncomputable; do
    echo "arm: $arm"
    cp "$saved_state" "$ALF_STATE"
    rm -f "$vetoes"
    ( failure_arm "$arm" )
    arm_count=$((arm_count + 1))
  done
  [ "$arm_count" -eq 9 ]
  echo "case: an unreadable or malformed vetoes.json fails the evaluation, and an absent one does not"
  fresh_fixture
  local body
  vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  authored_count_sequence major 3 3
  mkdir -p "${vetoes%/*}"
  for body in 'not json' '{"version":1,"keys":[]} {"version":1,"keys":[]}' '{"version":2,"keys":[]}' \
    '{"version":1,"keys":[{"member":"m","finding_class":"c","path":"p","line":1}]}'; do
    printf '%s\n' "$body" >"$vetoes"
    run evaluate_round 2
    [ "$status" -ne 0 ] || { echo "accepted: $body"; return 1; }
  done
  rm "$vetoes"
  run evaluate_round 2
  [ "$status" -eq 0 ]
}

# --- rubric signals, accept eligibility, gate decisions ----------------------

# K comes from the shared lib, so a change of K needs no edit here.
UNIT_ROUNDS() { printf '%s\n' "$GAIA_CONTEXT_UNIT_ROUNDS"; }

LOW="fresh 100000 1000000"
HIGH="fresh 400000 1000000"

# non_security_entries <entries-json> [severity]: the entries with security false and a severity.
non_security_entries() {
  jq -c --arg severity "${2:-major}" 'map(. + {security: false, severity: $severity})' <<<"$1"
}

# rounds_sequence <entries-json>...: one round per argument on branch-added f.txt;
# every round's commit touches only other.txt, so no entry sits on a repaired line.
rounds_sequence() {
  local round=1 entries
  alf_fill f.txt 12 feature
  for entries in "$@"; do
    alf_set_line other.txt "$round" "round $round"
    alf_commit "round $round" || return 1
    alf_round "$round" "$MEMBER" "$entries" || return 1
    round=$((round + 1))
  done
}

# authored_count_sequence <severity> <A...>: rounds_sequence whose round r holds f.txt lines 1..A_r.
authored_count_sequence() {
  local severity="$1" authored_count
  local -a rows=()
  shift
  for authored_count in "$@"; do rows+=("$(non_security_entries "$(alf_entries f.txt 1 "$authored_count")" "$severity")"); done
  rounds_sequence "${rows[@]}"
}

# maintainer: make the fixture a maintainer repo (the triage rule present),
# kept out of every round commit.
maintainer() {
  mkdir -p "$ALF_ROOT/.claude/rules/maintainers"
  : >"$ALF_ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  printf '.claude/\n' >>"$ALF_ROOT/.git/info/exclude"
}

# only_signal <r> <signal> <decision>: round r raises exactly <signal>, is
# accept-eligible, and the unit decision on a fresh low reading is <decision>.
only_signal() {
  local snapshot decision
  snapshot="$(evaluate_round "$1")" || { echo "eval of round $1 failed"; return 1; }
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = "[\"$2\"]" ] ||
    { echo "reasons $(read_json "$snapshot" '.accept_reasons | tojson'), verdict $(read_json "$snapshot" '.verdict')"; return 1; }
  [ "$(read_json "$snapshot" '.accept_eligible')" = true ] || { echo "not eligible"; return 1; }
  [ "$(read_json "$snapshot" '[.signals | to_entries[] | select(.value) | .key] | tojson')" = "[\"$2\"]" ] || return 1
  decision="$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)"
  [ "$decision" = "$3" ] || { echo "decision '$decision', want '$3'"; return 1; }
}

# make_state <used> [jq-filter]: a synthetic state with <used> rounds and knobs 6/3.
make_state() {
  jq -n -c --argjson used "$1" '{schema: 1, key: "branch:feat/loop", branch: "feat/loop", pr: null,
    created_at: "2026-01-01T00:00:00Z",
    history: {rounds: [range(0; $used) | {round: (. + 1), tree: ("a" * 40), commit: ("b" * 40),
                raw_branch_slug: "feat-loop", dispatched_at: "2026-01-01T00:00:00Z", members: [], closing: false,
                snapshot: null}],
              checkpoints: [], knobs: {checkpoint_round: 6, grant_rounds: 3}},
    allowance: {answers: []}}' | jq -c "${2:-.}"
}

# unit_entry <unit> <start> <through> <after_checkpoint>: a units[] element.
unit_entry() {
  jq -n -c --argjson unit "$1" --argjson start_round "$2" --argjson through_round "$3" --argjson after_checkpoint "$4" --argjson unit_rounds "$(UNIT_ROUNDS)" \
    '{unit: $unit, start_round: $start_round, k: $unit_rounds, through_round: $through_round, admitted_on: "context", after_checkpoint: $after_checkpoint,
      recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}'
}

# checkpoint_entry <index> <at_round> <trigger>: a checkpoints[] element.
checkpoint_entry() {
  jq -n -c --argjson index "$1" --argjson at_round "$2" --arg trigger "$3" '{index: $index, at_round: $at_round, reason: $trigger, trigger: $trigger,
    recorded_at: "2026-01-01T00:00:00Z", session_id: "s1", audited_root: "/x"}'
}

# override_file: the per-machine line override of the fixture's main checkout.
override_file() {
  printf '%s/.gaia/local/protected/checkpoint-override.json\n' "$ALF_ROOT"
}

@test "signals: each signal raised alone with its accept-eligibility and unit decision, and the shapes that raise none" {
  local snapshot
  echo "case: cap at round 10 of a converging branch denies the unit dispatch"
  maintainer
  authored_count_sequence major 10 9 8 7 6 5 4 3 2 1
  only_signal 10 cap "deny cap true true"
  fresh_fixture
  echo "case: quiet, an empty A, never denies"
  maintainer
  rounds_sequence '[]'
  only_signal 1 quiet "allow context 2 $((2 + $(UNIT_ROUNDS) - 1))"
  fresh_fixture
  echo "case: enriching, a new key on a repaired line, denies"
  maintainer
  authored_count_sequence major 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(non_security_entries "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)")"
  only_signal 3 enriching "deny rubric:enriching true false"
  fresh_fixture
  echo "case: stalled, A 5,5,5, denies"
  maintainer
  authored_count_sequence major 5 5 5
  only_signal 3 stalled "deny rubric:stalled true false"
  fresh_fixture
  echo "case: nitpicky, two all-Minor rounds at round 6, denies"
  maintainer
  authored_count_sequence minor 8 7 6 5 4 3
  only_signal 6 nitpicky "deny rubric:nitpicky true false"
  fresh_fixture
  echo "case: nitpicky needs both rounds, a Minor-only round after a Major round raises nothing"
  maintainer
  authored_count_sequence major 8 7 6 5 4
  alf_set_line other.txt 6 "round 6"
  next_round 6 "$(non_security_entries "$(alf_entries f.txt 1 3)" minor)"
  snapshot="$(evaluate_round 6)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
  fresh_fixture
  echo "case: reintroduced, a key that vanished and came back, denies"
  maintainer
  authored_count_sequence major 3 2 3
  only_signal 3 reintroduced "deny rubric:reintroduced true false"
  fresh_fixture
  echo "case: reintroduced, a finding whose line moves three rounds running"
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" minor)" "$(non_security_entries "$(alf_entries f.txt 4 5)" minor)" \
    "$(non_security_entries "$(alf_entries f.txt 6 6)" minor)"
  only_signal 3 reintroduced "deny rubric:reintroduced true false"
  fresh_fixture
  echo "case: small-tail, two findings with no progress at round 6, denies"
  maintainer
  authored_count_sequence major 6 5 4 3 2 2
  only_signal 6 small-tail "deny rubric:small-tail true false"
  fresh_fixture
  echo "case: waiver-drift, half of each of two rounds waived on the triage threshold, denies"
  maintainer
  drift_fixture
  only_signal 2 waiver-drift "deny rubric:waiver-drift true false"
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '"\(.raw_count) \(.waived_count) \(.A)"')" = "4 2 2" ]
  fresh_fixture
  echo "case: waiver-drift is never raised outside a maintainer repo"
  drift_fixture
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.signals["waiver-drift"]')" = false ]
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  fresh_fixture
  echo "case: no signal is not accept-eligible and the unit dispatch is allowed"
  maintainer
  authored_count_sequence major 5 4
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)" = "allow context 3 $((3 + $(UNIT_ROUNDS) - 1))" ]
}

# drift_fixture: two rounds, each with half its four findings waived on the
# triage threshold in that round's own dispositions file.
drift_fixture() {
  local waive='[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":3,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"below threshold"},
                {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":4,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"below threshold"}]'
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")"
  alf_dispositions 1 "$waive"
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_round 2 "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")"
  alf_dispositions 2 "$waive"
}

@test "accept_eligible: unknown verdict, a security:true entry and a Critical each make a signalling round ineligible; a security:false Minor stays eligible" {
  local snapshot
  echo "case: an unknown verdict with a signal holding is not accept-eligible"
  maintainer
  drift_fixture
  alf_store_snapshot 2
  alf_set_line other.txt 3 "round 3"
  alf_commit "round 3"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")" 31
  alf_dispositions 3 "$(jq -c '.entries' "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/dispositions-2.json")"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = unknown ]
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["waiver-drift"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  fresh_fixture
  echo "case: a security:true Minor in A(r) makes a signalling round ineligible"
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" minor)" "$(non_security_entries "$(alf_entries f.txt 4 5)" minor)" \
    '[{"path":"f.txt","line":6,"finding_class":"rule/x","severity":"minor","security":true}]'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["reintroduced"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)" = "deny rubric:reintroduced false false" ]
  fresh_fixture
  echo "case: a Critical in A(r) makes a signalling round ineligible"
  maintainer
  authored_count_sequence major 5 5
  alf_set_line other.txt 3 "round 3"
  next_round 3 "$(jq -c '.[0].severity = "critical"' <<<"$(non_security_entries "$(alf_entries f.txt 1 5)")")"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["stalled"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  fresh_fixture
  echo "case: a round whose only A(r) entry is a security:false Minor stays eligible"
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" minor)" "$(non_security_entries "$(alf_entries f.txt 4 5)" minor)" \
    '[{"path":"f.txt","line":6,"finding_class":"rule/x","severity":"minor","security":false}]'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 1 ]
  [ "$(read_json "$snapshot" '.counted_keys[0].security')" = false ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = true ]
}

@test "security normalization: absent reads true, false stays false, a non-boolean reads true; cross_remit only on true" {
  local findings
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" '[{"path":"f.txt","line":1},
    {"path":"f.txt","line":2,"security":false,"cross_remit":true},
    {"path":"f.txt","line":3,"security":"no","cross_remit":"yes"},
    {"path":"untouched.txt","line":4,"security":true}]'
  findings="$(gaia_loop_findings "$ALF_ROOT" "$(cat "$ALF_STATE")" 1)"
  [ "$(read_json "$findings" '[.entries[] | .security] | tojson')" = '[true,false,true,true]' ]
  [ "$(read_json "$findings" '[.entries[] | .cross_remit] | tojson')" = '[false,true,false,false]' ]
  [ "$(read_json "$findings" '[.entries[] | .authored] | tojson')" = '[true,true,true,false]' ]
  [ "$(read_json "$findings" '.entries[0] | keys | join(",")')" = "authored,cross_remit,failure_mode,finding_class,line,member,path,security,severity" ]
}

@test "decision: 6 rounds used, a fresh reading below the line and no signal admit a unit past the fallback checkpoint" {
  local state
  state="$(make_state 6)"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow context 7 $((6 + $(UNIT_ROUNDS)))" ]
  # red: the round-count decision on the same state denies.
  [ "$(gaia_loop_decide "$state" null)" = "deny allowance" ]
}

@test "decision: a missing, stale, future or unparseable reading falls back to the round count" {
  local reading
  for reading in missing stale future unparseable "fresh abc 1" "fresh 0100 1000000" ""; do
    [ "$(gaia_loop_decide_unit "$(make_state 5)" null "$reading" 300000 50)" = "allow fallback 6 6" ] ||
      { echo "5 used, '$reading': $(gaia_loop_decide_unit "$(make_state 5)" null "$reading" 300000 50)"; return 1; }
    [ "$(gaia_loop_decide_unit "$(make_state 6)" null "$reading" 300000 50)" = "deny fallback false false" ] ||
      { echo "6 used, '$reading'"; return 1; }
  done
}

# bats test_tags=protected
@test "decision: ask_tokens 0 (checkpoint off) takes the round-count fallback, never a context allow" {
  [ "$(gaia_loop_decide_unit "$(make_state 5)" null "$HIGH" 0 50)" = "allow fallback 6 6" ]
  [ "$(gaia_loop_decide_unit "$(make_state 6)" null "$HIGH" 0 50)" = "deny fallback false false" ]
  [ "$(gaia_loop_decide_unit "$(make_state 6)" null "$LOW" 0 50)" = "deny fallback false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 6)" null false "$LOW" 0 50)" = "deny fallback false false" ]
}

@test "decision: an answer to the latest checkpoint admits exactly one unit; a spent accept or an answer to an older checkpoint admits nothing" {
  local state unit_rounds checkpoint
  unit_rounds="$(UNIT_ROUNDS)"
  echo "case: over the line denies context; an answer to the latest checkpoint admits exactly one unit"
  checkpoint="$(checkpoint_entry 1 3 context)"
  state="$(make_state 3)"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
  state="$(make_state 3 ".history.checkpoints = [$checkpoint] | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: $unit_rounds, source: \"ask\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "allow grant 4 $((3 + unit_rounds))" ]
  state="$(jq -c --argjson unit "$(unit_entry 1 4 $((3 + unit_rounds)) 1)" '.history.units = [$unit]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
  state="$(make_state 3 ".history.checkpoints = [$checkpoint] | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "allow accept 4 4" ]
  echo "case: an accept admits its closing round even on a fresh reading below the line"
  state="$(make_state 3 ".history.checkpoints = [$(checkpoint_entry 1 3 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow accept 4 4" ]
  [ "$(gaia_loop_decide_member "$state" null false "$LOW" 300000 50)" = "allow accept 4 4" ]
  echo "case: once the accepted closing round is recorded, a fresh reading below the line admits nothing"
  state="$(make_state 4 ".history.checkpoints = [$(checkpoint_entry 1 3 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 4 4 1)]")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "deny fallback false false" ]
  [ "$(gaia_loop_decide_member "$state" null false "$LOW" 300000 50)" = "deny fallback false false" ]
  # The checkpoint that deny records stays unanswered, and the spent accept
  # still denies on the next dispatch.
  state="$(jq -c --argjson checkpoint "$(checkpoint_entry 2 4 fallback)" '.history.checkpoints += [$checkpoint]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "deny fallback false false" ]
  # A grant answering that checkpoint admits again.
  state="$(jq -c '.allowance.answers += [{checkpoint: 2, kind: "grant", n: 3, at: "x", session_id: "s1"}]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow grant 5 $((4 + $(UNIT_ROUNDS)))" ]
  echo "case: a grant answering an older checkpoint, not the latest, admits nothing"
  state="$(make_state 3 ".history.checkpoints = [$(checkpoint_entry 1 2 context), $(checkpoint_entry 2 3 context)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: 3, at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
}

@test "decision: the effective line config is the frozen value lowered by the live override" {
  local settings state effective
  settings="$(override_file)"
  mkdir -p "${settings%/*}"
  state="$(make_state 3 '.history.context_config = {ask_tokens: 300000, ask_window_pct: 50}')"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":600000,"ask_window_pct":50}}\n' >"$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "300000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 350000 1000000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 290000 1000000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  printf '{"version":1,"context_checkpoint":{"ask_tokens":250000,"ask_window_pct":50}}\n' >"$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "250000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 260000 1000000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 240000 1000000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  rm "$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$(gaia_loop_decide_unit "$state" null "fresh 120000 200000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 90000 200000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  state="$(make_state 3 '.history.context_config = {ask_tokens: 250000, ask_window_pct: 50}')"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "250000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 260000 1000000" $effective)" = "deny context false false" ]
}

@test "decision: at 10 rounds with no unconsumed answer every path denies cap, though the fold itself stays uncapped" {
  local state reading
  state="$(make_state 10 ".history.checkpoints = [$(checkpoint_entry 1 10 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: 3, at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 8 10 1)]")"
  [ "$(gaia_loop_allowed "$state")" = 13 ]
  for reading in "$LOW" "$HIGH" missing; do
    [ "$(gaia_loop_decide_unit "$state" null "$reading" 300000 50)" = "deny cap false true" ] || { echo "unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null true "$reading" 300000 50)" = "deny cap false true" ] || { echo "member in-unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null false "$reading" 300000 50)" = "deny cap false true" ] || { echo "member inline, $reading"; return 1; }
  done
  [ "$(gaia_loop_decide "$state" null)" = "deny cap" ]
}

@test "decision: past the cap each unit needs an answer, a grant buying a whole unit and an accept its closing round" {
  local state reading cap next unit_rounds
  cap="$_GAIA_LOOP_HARD_CAP"
  next=$((cap + 1))
  unit_rounds="$(UNIT_ROUNDS)"
  state="$(make_state "$cap" ".history.checkpoints = [$(checkpoint_entry 1 "$cap" cap)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: $unit_rounds, at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 8 "$cap" 0)]")"
  for reading in "$LOW" "$HIGH" missing; do
    [ "$(gaia_loop_decide_unit "$state" null "$reading" 300000 50)" = "allow grant $next $((cap + unit_rounds))" ] || { echo "unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null false "$reading" 300000 50)" = "allow grant $next $next" ] || { echo "member inline, $reading"; return 1; }
  done
  # red: a unit admitted below the cap ends at it, so its members stop there.
  [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = "deny cap false true" ]
  # The unit admitted on that grant runs its whole window past the cap.
  state="$(jq -c --argjson unit "$(unit_entry 2 "$next" $((cap + unit_rounds)) 1)" '.history.units += [$unit]' <<<"$state")"
  [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = allow ]
  # red: the grant is consumed, so a second unit on it is denied at the cap.
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "deny cap false true" ]
  # red: once the window is spent, its members stop at the window end and
  # every new unit is denied at the cap again.
  state="$(make_state $((cap + unit_rounds)) ".history.checkpoints = [$(checkpoint_entry 1 "$cap" cap)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: $unit_rounds, at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 "$next" $((cap + unit_rounds)) 1)]")"
  for reading in "$LOW" "$HIGH" missing; do
    [ "$(gaia_loop_decide_unit "$state" null "$reading" 300000 50)" = "deny cap false true" ] || { echo "unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null true "$reading" 300000 50)" = "deny window false false" ] || { echo "member in-unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null false "$reading" 300000 50)" = "deny cap false true" ] || { echo "member inline, $reading"; return 1; }
  done
  # An accept at the next checkpoint buys exactly its one closing round.
  state="$(jq -c --argjson checkpoint "$(checkpoint_entry 2 $((cap + unit_rounds)) cap)" '.history.checkpoints += [$checkpoint]
    | .allowance.answers += [{checkpoint: 2, kind: "accept", at: "x", session_id: "s1"}]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow accept $((cap + unit_rounds + 1)) $((cap + unit_rounds + 1))" ]
}

@test "decision: a member in a unit is allowed only inside the unit's window" {
  local unit_rounds used state
  unit_rounds="$(UNIT_ROUNDS)"
  used=6
  while [ "$used" -le $((6 + unit_rounds)) ]; do
    state="$(make_state "$used" ".history.units = [$(unit_entry 1 7 $((6 + unit_rounds)) 0)]")"
    if [ "$used" -lt $((6 + unit_rounds)) ]; then
      [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = allow ] || { echo "used $used"; return 1; }
    else
      [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = "deny window false false" ] || { echo "used $used"; return 1; }
    fi
    used=$((used + 1))
  done
  [ "$(gaia_loop_decide_member "$(make_state 6)" null true "$LOW" 300000 50)" = "deny window false false" ]
  state="$(make_state 7 ".history.units = [$(unit_entry 1 7 $((6 + unit_rounds)) 0)]")"
  [ "$(gaia_loop_decide_member "$state" '{"round":7,"verdict":"continue","signals":{"stalled":true}}' true "$LOW" 300000 50)" = "deny rubric:stalled false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 5)" null false "$HIGH" 300000 50)" = "deny context false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 5)" null false missing 300000 50)" = "allow fallback 6 6" ]
}

# grant_window_state <used> [<jq-filter>]: an enriching checkpoint at round 3
# answered by a grant of K, and the unit that grant admitted (rounds 4..3+K).
grant_window_state() {
  local unit_rounds
  unit_rounds="$(UNIT_ROUNDS)"
  make_state "$1" ".history.checkpoints = [$(checkpoint_entry 1 3 rubric:enriching)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: $unit_rounds, at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 4 $((3 + unit_rounds)) 1) | .admitted_on = \"grant\"]
    | ${2:-.}"
}

@test "grant override: a grant window lifts enriching, stalled, nitpicky and small-tail for K rounds and nothing else" {
  local unit_rounds used signal snapshot through enriching state
  unit_rounds="$(UNIT_ROUNDS)"
  through=$((3 + unit_rounds))
  echo "case: a grant of K admits K rounds through enriching, stalled, nitpicky and small-tail, and the next unit is denied"
  [ "$(gaia_loop_decide_unit "$(grant_window_state 3 '.history.units = []')" '{"round":3,"verdict":"enriching","signals":{"enriching":true}}' "$HIGH" 300000 50)" = "allow grant 4 $through" ]
  for signal in enriching stalled nitpicky small-tail; do
    used=4
    while [ "$used" -lt "$through" ]; do
      snapshot="$(jq -n -c --argjson round "$used" --arg signal "$signal" '{round: $round, verdict: "continue", signals: {($signal): true}}')"
      [ "$(gaia_loop_decide_member "$(grant_window_state "$used")" "$snapshot" true "$HIGH" 300000 50)" = allow ] || { echo "$signal, used $used"; return 1; }
      used=$((used + 1))
    done
    snapshot="$(jq -n -c --argjson round "$through" --arg signal "$signal" '{round: $round, verdict: "continue", signals: {($signal): true}}')"
    [ "$(gaia_loop_decide_member "$(grant_window_state "$through")" "$snapshot" true "$LOW" 300000 50)" = "deny window false false" ] || { echo "$signal, window end"; return 1; }
    [ "$(gaia_loop_decide_unit "$(grant_window_state "$through")" "$snapshot" "$LOW" 300000 50)" = "deny rubric:$signal false false" ] || { echo "$signal, next unit"; return 1; }
  done
  echo "case: a unit dispatched inside an open grant window is admitted on the grant for the rest of it"
  enriching='{"round":4,"verdict":"enriching","signals":{"enriching":true}}'
  # The granted unit stopped after round 4; the next unit takes rounds 5..through, over the line too.
  [ "$(gaia_loop_decide_unit "$(grant_window_state 4)" "$enriching" "$HIGH" 300000 50)" = "allow grant 5 $through" ]
  # Inline, the same window admits one round.
  [ "$(gaia_loop_decide_member "$(grant_window_state 4)" "$enriching" false "$HIGH" 300000 50)" = "allow grant 5 5" ]
  # The unit that resumption records keeps the override for its members.
  state="$(grant_window_state 5 ".history.units += [$(unit_entry 2 5 "$through" 1) | .admitted_on = \"grant\"]")"
  [ "$(gaia_loop_decide_member "$state" '{"round":5,"verdict":"enriching","signals":{"enriching":true}}' true "$LOW" 300000 50)" = allow ]
  # red: a checkpoint pinned since the grant's unit ends the resumption.
  [ "$(gaia_loop_decide_unit "$(grant_window_state 4 ".history.checkpoints += [$(checkpoint_entry 2 4 context)]")" "$enriching" "$HIGH" 300000 50)" = "deny rubric:enriching false false" ]
  echo "case: reintroduced and waiver-drift still deny inside a grant, the cap ends a window admitted below it, and a later checkpoint or a non-grant unit ends the override"
  [ "$(gaia_loop_decide_member "$(grant_window_state 4)" '{"round":4,"verdict":"continue","signals":{"reintroduced":true,"enriching":true}}' true "$LOW" 300000 50)" = "deny rubric:reintroduced false false" ]
  [ "$(gaia_loop_decide_member "$(grant_window_state 4)" '{"round":4,"verdict":"continue","signals":{"waiver-drift":true}}' true "$LOW" 300000 50)" = "deny rubric:waiver-drift false false" ]
  # red: a checkpoint pinned after the grant's unit was admitted ends the override.
  [ "$(gaia_loop_decide_member "$(grant_window_state 4 ".history.checkpoints += [$(checkpoint_entry 2 4 context)]")" "$enriching" true "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
  # red: a unit admitted on anything but a grant gets no override.
  [ "$(gaia_loop_decide_member "$(grant_window_state 4 '.history.units[0].admitted_on = "context"')" "$enriching" true "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
  # The cap still ends a grant's window admitted below it.
  [ "$(gaia_loop_decide_member "$(grant_window_state 10 '.history.units[0].start_round = 9 | .history.units[0].through_round = 10')" '{"round":10,"verdict":"enriching","signals":{"cap":true,"enriching":true}}' true "$LOW" 300000 50)" = "deny cap false true" ]
}

@test "vetoes: a vetoed key re-enters A from its effective round, whatever was disposed" {
  local vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json" key
  authored_count_sequence major 3 3 3
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"r"}]'
  key='{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"vetoed_at":"x","unit":1'
  [ "$(read_json "$(evaluate_round 1)" '.A')" = 3 ]
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 2 ]
  printf '{"version":1,"keys":[%s,"effective_from_round":3}]}\n' "$key" >"$vetoes"
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 2 ]
  [ "$(read_json "$(evaluate_round 3)" '.A')" = 3 ]
  printf '{"version":1,"keys":[%s,"effective_from_round":2}]}\n' "$key" >"$vetoes"
  [ "$(read_json "$(evaluate_round 1)" '.A')" = 3 ]
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 3 ]
  # red: without the veto the waiver holds again.
  printf '{"version":1,"keys":[]}\n' >"$vetoes"
  [ "$(read_json "$(evaluate_round 3)" '.A')" = 2 ]
}

@test "legacy: a frozen checkpoint of 5 keeps 5; no frozen line config reads the override, window share at the default" {
  local settings
  settings="$(override_file)"
  [ "$(gaia_loop_allowed "$(make_state 2 '.history.knobs.checkpoint_round = 5')")" = 5 ]
  [ "$(gaia_loop_allowed "$(make_state 2)")" = 6 ]
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3)")" = "300000 50" ]
  mkdir -p "${settings%/*}"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":250000,"ask_window_pct":40}}\n' >"$settings"
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3)")" = "250000 50" ]
  [ "$(gaia_loop_context_config_initial "$ALF_ROOT")" = '{"ask_tokens":250000,"ask_window_pct":50}' ]
  printf '{"version":1,"context_checkpoint":{"ask_tokens":600000}}\n' >"$settings"
  [ "$(gaia_loop_context_config_initial "$ALF_ROOT")" = '{"ask_tokens":400000,"ask_window_pct":50}' ]
  printf '{"version":1,"context_checkpoint":{"ask_tokens":0}}\n' >"$settings"
  [ "$(gaia_loop_context_config_initial "$ALF_ROOT")" = '{"ask_tokens":0,"ask_window_pct":50}' ]
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3 '.history.context_config = {ask_tokens: 300000, ask_window_pct: 50}')")" = "300000 50" ]
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3 '.history.context_config = {ask_tokens: 0, ask_window_pct: 50}')")" = "0 50" ]
  rm "$settings"
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3 '.history.context_config = {ask_tokens: 0, ask_window_pct: 50}')")" = "300000 50" ]
}

@test "legacy: a stored snapshot without counted_keys turns off each history signal that reads it and eligibility, and enriching still reads stored keys" {
  local snapshot
  echo "case: the history signals and eligibility go off"
  maintainer
  authored_count_sequence major 6 5 4 3 2 2
  [ "$(read_json "$(evaluate_round 6)" '.signals["small-tail"]')" = true ]
  alf_state_edit 'del(.history.rounds[4].snapshot.counted_keys)'
  snapshot="$(evaluate_round 6)"
  [ "$(read_json "$snapshot" '[.signals["small-tail"], .signals.nitpicky, .signals.reintroduced, .signals["waiver-drift"]] | tojson')" = '[false,false,false,false]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  fresh_fixture
  echo "case: a legacy round r-2 turns reintroduced off"
  maintainer
  authored_count_sequence major 3 2 3
  alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.signals.reintroduced')" = false ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  fresh_fixture
  echo "case: a legacy round r-1 turns waiver-drift off"
  maintainer
  drift_fixture
  alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
  [ "$(read_json "$(evaluate_round 2)" '.signals["waiver-drift"]')" = false ]
  fresh_fixture
  echo "case: the enriching verdict still reads the stored keys of round r-1"
  authored_count_sequence major 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(non_security_entries "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)")"
  alf_state_edit 'del(.history.rounds[1].snapshot.counted_keys)'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = enriching ]
  [ "$(read_json "$snapshot" '.signals.enriching')" = true ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" '{"round":3,"verdict":"enriching"}' "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
}

@test "CLI: next-unit, unit-window and pinned-question" {
  local question='{"questions":[{"question":"q","header":"Audit loop","multiSelect":false,"options":[{"label":"Stop and file the remainder","description":"d"},{"label":"Accept the remainder","description":"d"}]}]}'
  cli_copy
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_sequence 4 3
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$output" = "1 3" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_state_edit '.history.units = [$unit]' --argjson unit "$(unit_entry 1 3 $((2 + $(UNIT_ROUNDS))) 0)"
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$output" = "2 3" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 3 $((2 + $(UNIT_ROUNDS))) false" ]
  alf_add_checkpoint 2 context
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_state_edit '.history.checkpoints[-1].question = $question' --argjson question "$question"
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -c . <<<"$question")" ]
  alf_add_answer 1 accept
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
}

# --- the default stop ---------------------------------------------------------

SHELL_MAINTAINER=code-audit-maintainer-shell

# minor_entries <path> <first> <last> [class]: non-security Minor entries.
minor_entries() {
  non_security_entries "$(alf_entries "$1" "$2" "$3" "${4:-rule/x}")" minor
}

# with_entries <entries-json> <extra-json>: the two lists joined.
with_entries() {
  jq -n -c --argjson entries "$1" --argjson extra "$2" '$entries + $extra'
}

# fresh_fixture: a new repository and branch, for a case that builds twice.
fresh_fixture() {
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/origin.git"
  alf_init && alf_branch feat/loop
}

# stop_roster: a roster giving lib/ to the shell maintainer and the rest to the
# default member. It lives under the ignored .gaia/, so no digest moves.
stop_roster() {
  printf 'auditors:\n  - name: %s\n    globs:\n      - "lib/**"\n    audience: adopter\n  - name: code-audit-shell\n    globs:\n      - "scripts/**"\n    audience: adopter\n  - name: code-audit-frontend\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' \
    "$SHELL_MAINTAINER" >"$ALF_ROOT/.gaia/audit-ci.yml"
}

# review_base_all <reason|absent>: every sidecar's review_base reason, its mtime kept.
review_base_all() {
  local sidecar_file
  for sidecar_file in "$ALF_ROOT"/.gaia/local/audit/*.findings.json; do
    if [ "$1" = absent ]; then
      jq -c 'del(.review_base)' "$sidecar_file" >"$sidecar_file.edited"
    else
      jq -c --arg reason "$1" '.review_base = {sha: ("c" * 40), reason: $reason}' "$sidecar_file" >"$sidecar_file.edited"
    fi
    touch -r "$sidecar_file" "$sidecar_file.edited" && mv "$sidecar_file.edited" "$sidecar_file"
  done
}

# earn_marker <member> <round>: an earned clearance for the member's digest at round r's tree.
earn_marker() {
  local tree digest marker_name
  tree="$(jq -r --argjson round "$2" '.history.rounds[$round - 1].tree' "$ALF_STATE")"
  digest="$(bash "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" --root "$ALF_ROOT" --member "$1" --ref "$tree")" || return 1
  marker_name="$digest.$1.ok"
  [ "$1" = code-audit-frontend ] && marker_name="$digest.ok"
  jq -n -c --arg digest "$digest" --arg member "$1" '{digest: $digest, member: $member, provenance: "earned"}' >"$ALF_ROOT/.gaia/local/audit/$marker_name"
}

# stop_case <entries-json>...: rounds_sequence with every sidecar reviewed
# incrementally and the last round's marker earned.
stop_case() {
  stop_roster
  rounds_sequence "$@" || return 1
  review_base_all member-clearance
  earn_marker "$MEMBER" $#
}

# stop_base: the round-3 base meeting every term: A 3, 2, 2 of stable Minors.
stop_base() {
  stop_case "$(minor_entries f.txt 1 3)" "$(minor_entries f.txt 1 2)" "${1:-$(minor_entries f.txt 1 2)}"
}

# stop_of <r>: round r's snapshot with the audited root, as the hook evaluates it.
stop_of() {
  gaia_loop_evaluate_round "$ALF_ROOT" "$(cat "$ALF_STATE")" "$1" "$ALF_ROOT"
}

# stop_is <r> <true|false>: round r's default_stop.
stop_is() {
  local snapshot
  snapshot="$(stop_of "$1")" || { echo "evaluation of round $1 failed"; return 1; }
  [ "$(read_json "$snapshot" '.default_stop')" = "$2" ] ||
    { echo "default_stop $(read_json "$snapshot" '.default_stop'), want $2: $(read_json "$snapshot" '{verdict, A, signals, review_bases}')"; return 1; }
}

# mutant_tree <file> <sed-args...>: a scratch tree mirroring .gaia/scripts and
# .claude/hooks/lib (copies, never links), with <file> run through sed, then
# sourced. Fails when sed changed nothing.
mutant_tree() {
  local tree="$BATS_TEST_TMPDIR/mutant" target="$1"
  shift
  rm -rf "$tree"
  mkdir -p "$tree/.gaia/scripts" "$tree/.claude/hooks/lib"
  cp "$REPO_ROOT"/.gaia/scripts/*.sh "$tree/.gaia/scripts/"
  cp -R "$REPO_ROOT"/.claude/hooks/lib/. "$tree/.claude/hooks/lib/"
  sed "$@" "$REPO_ROOT/.gaia/scripts/$target" >"$tree/.gaia/scripts/$target"
  cmp -s "$REPO_ROOT/.gaia/scripts/$target" "$tree/.gaia/scripts/$target" && { echo "mutant of $target changed nothing"; return 1; }
  MUTANT_SCRIPTS="$tree/.gaia/scripts"
  # shellcheck source=/dev/null
  . "$MUTANT_SCRIPTS/audit-loop-eval.sh"
}

# stop_base_save: keep the built stop_base fixture so each case restores it instead of rebuilding.
stop_base_save() {
  STOP_BASE_SAVE="$BATS_TEST_TMPDIR/stop-base-saved"
  mkdir -p "$STOP_BASE_SAVE"
  cp -Rp "$ALF_ROOT" "$STOP_BASE_SAVE/repo" || return 1
  cp -Rp "$ALF_ORIGIN" "$STOP_BASE_SAVE/origin.git"
}

# stop_base_restore: put the saved stop_base fixture back at its own path.
stop_base_restore() {
  rm -rf "$ALF_ROOT" "$ALF_ORIGIN"
  cp -Rp "$STOP_BASE_SAVE/repo" "$ALF_ROOT" || return 1
  cp -Rp "$STOP_BASE_SAVE/origin.git" "$ALF_ORIGIN" || return 1
  alf_git update-index -q --refresh >/dev/null 2>&1 || true
}

# Each case after the first runs in its own subshell, so a mutant sourced into one never
# reaches the next, and a failed assertion stops the whole test (errexit).
@test "default stop: the base stops, and each conjunct of the default-stop formula denies it alone" {
  local snapshot extra round unreadable_sidecar token want
  local -a rows=() tokens=()
  echo "case: a round-3 base meeting every term stops with S as its keys and records each member's review base"
  stop_base
  stop_base_save
  snapshot="$(stop_of 3)"
  [ "$(read_json "$snapshot" '.default_stop')" = true ] || { echo "$snapshot"; return 1; }
  [ "$(read_json "$snapshot" '.default_stop_keys | tojson')" = "[[\"$MEMBER\",\"rule/x\",\"f.txt\",1],[\"$MEMBER\",\"rule/x\",\"f.txt\",2]]" ]
  [ "$(read_json "$snapshot" '.review_bases | tojson')" = "{\"$MEMBER\":\"member-clearance\"}" ]

  echo "case: still true on a stalled round and on an enriching round"
  (
    fresh_fixture
    stop_case "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)"
    snapshot="$(stop_of 3)"
    [ "$(read_json "$snapshot" '"\(.verdict) \(.default_stop)"')" = "stalled true" ] || { echo "$snapshot"; return 1; }
    fresh_fixture
    stop_roster
    alf_fill f.txt 12 feature2
    alf_set_line other.txt 1 "enriching 1"
    alf_commit "enriching 1"
    alf_round 1 "$MEMBER" "$(minor_entries f.txt 1 3)"
    alf_set_line other.txt 2 "enriching 2"
    next_round 2 "$(minor_entries f.txt 1 2)"
    alf_set_line f.txt 8 repaired
    next_round 3 "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 8 8 rule/y)")"
    review_base_all member-clearance
    earn_marker "$MEMBER" 3
    snapshot="$(stop_of 3)"
    [ "$(read_json "$snapshot" '"\(.verdict) \(.default_stop)"')" = "enriching true" ] || { echo "$snapshot"; return 1; }
  )

  echo "case: still true at round 6 with nitpicky and small-tail holding"
  (
    fresh_fixture
    stop_case "$(minor_entries f.txt 1 3)" "$(minor_entries f.txt 1 3)" "$(minor_entries f.txt 1 3)" "$(minor_entries f.txt 1 3)" \
      "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)"
    snapshot="$(stop_of 6)"
    [ "$(read_json "$snapshot" '[.signals.nitpicky, .signals["small-tail"], .signals.reintroduced, .default_stop] | tojson')" = '[true,true,false,true]' ] ||
      { echo "$snapshot"; return 1; }
  )

  echo "case: false at round 2 (mutant dropping the lower bound goes red)"
  (
    fresh_fixture
    stop_case "$(minor_entries f.txt 1 3)" "$(minor_entries f.txt 1 2)"
    stop_is 2 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$round >= 3$/d'
    sed -i.bak '/\[ "\$round" -ge 3 \] ||/d' "$MUTANT_SCRIPTS/audit-loop-stop-lib.sh"
    . "$MUTANT_SCRIPTS/audit-loop-eval.sh"
    stop_is 2 true
  )

  echo "case: false at round 10 and true at round 9 (mutant dropping the upper bound goes red)"
  (
    fresh_fixture
    round=1
    while [ "$round" -le 10 ]; do rows+=("$(minor_entries f.txt 1 2)"); round=$((round + 1)); done
    stop_case "${rows[@]}"
    earn_marker "$MEMBER" 9
    stop_is 9 true
    stop_is 10 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$round <= 9$/d'
    sed -i.bak '/\[ "\$round" -le 9 \] ||/d' "$MUTANT_SCRIPTS/audit-loop-stop-lib.sh"
    . "$MUTANT_SCRIPTS/audit-loop-eval.sh"
    stop_is 10 true
  )

  echo "case: false on an unknown verdict, where A(r) is null too (mutant dropping both goes red)"
  (
    stop_base_restore
    # A second member whose sidecar has a review base and a marker but no
    # readable findings: only the unknown verdict and A(r) fail.
    alf_state_edit '.history.rounds[2].members += ["code-audit-shell"]'
    unreadable_sidecar="$ALF_ROOT/.gaia/local/audit/$(printf 'a%.0s' $(seq 1 40)).$ALF_SLUG.code-audit-shell.findings.json"
    printf '{"schema":1,"member":"code-audit-shell","findings":"unreadable","review_base":{"sha":"%s","reason":"member-clearance"}}\n' "$(printf 'c%.0s' $(seq 1 40))" >"$unreadable_sidecar"
    touch -t "$(alf_time 31)" "$unreadable_sidecar"
    earn_marker code-audit-shell 3
    [ "$(read_json "$(stop_of 3)" '"\(.verdict) \(.A) \(.review_bases | tojson)"')" = "unknown null {\"$MEMBER\":\"member-clearance\",\"code-audit-shell\":\"member-clearance\"}" ]
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$verdict != "unknown"$/d' -e '/^   and \$authored_count != null$/d'
    sed -i.bak '/^    and (\$findings.missing_members | length) == 0$/d' "$MUTANT_SCRIPTS/audit-loop-stop-lib.sh"
    . "$MUTANT_SCRIPTS/audit-loop-eval.sh"
    stop_is 3 true
  )

  echo "case: false when A(r-2) or A(r-1) is null (each mutant goes red)"
  (
    stop_base_restore
    alf_state_edit '.history.rounds[0].snapshot.A = null'
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$second_previous_authored_count != null$/d'
    stop_is 3 true
    . "$SCRIPTS/audit-loop-eval.sh"
    alf_state_edit '.history.rounds[0].snapshot.A = 3 | .history.rounds[1].snapshot.A = null'
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$previous_authored_count != null$/d'
    stop_is 3 true
  )

  echo "case: false over a legacy stored snapshot (mutant goes red)"
  (
    stop_base_restore
    alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and all(\$history\[\]; .triples != null)$/d'
    stop_is 3 true
  )

  echo "case: false on a Major of non-branch authorship, an absent security flag or an unknown severity (mutant goes red)"
  (
    for extra in '[{"path":"base.txt","line":3,"finding_class":"rule/q","severity":"major","security":false}]' \
      '[{"path":"f.txt","line":5,"finding_class":"rule/s","severity":"minor"}]' \
      '[{"path":"f.txt","line":5,"finding_class":"rule/s","severity":"note","security":false}]'; do
      fresh_fixture
      stop_base "$(with_entries "$(minor_entries f.txt 1 2)" "$extra")"
      stop_is 3 false || { echo "extra $extra"; return 1; }
    done
    mutant_tree audit-loop-signals-lib.sh -e '/^   and all(\$findings.entries\[\]; honored_in/d'
    sed -i.bak '/^    and all(\$findings.entries\[\]; .triage == true or/d' "$MUTANT_SCRIPTS/audit-loop-stop-lib.sh"
    . "$MUTANT_SCRIPTS/audit-loop-eval.sh"
    stop_is 3 true
  )

  echo "case: false when S is empty because every counted finding is cross-remit (mutant goes red)"
  (
    fresh_fixture
    stop_base "$(jq -c 'map(. + {cross_remit: true})' <<<"$(minor_entries f.txt 1 2)")"
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and (\$stop_keys | length) > 0$/d'
    stop_is 3 true
  )

  echo "case: false under an unsatisfied veto no member reported, and its twin a member re-reported (mutant goes red)"
  (
    stop_base_restore
    write_veto 11
    stop_is 3 false
    write_veto 1
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and (\$stop_inputs.unsatisfied_vetoes | length) == 0$/d'
    stop_is 3 true
  )

  echo "case: a member with no marker for its digest at round r's tree fails; earned, a later HEAD move leaves it true (mutant goes red)"
  (
    stop_base_restore
    rm -f "$ALF_ROOT"/.gaia/local/audit/*.ok
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and (\$stop_inputs.marker_gaps | length) == 0$/d'
    stop_is 3 true
    . "$SCRIPTS/audit-loop-eval.sh"
    earn_marker "$MEMBER" 3
    stop_is 3 true
    alf_set_line other.txt 9 "after the round"
    alf_commit "after the round"
    stop_is 3 true
  )

  echo "case: without the audited root no marker is provable (mutant ignoring the missing inputs goes red)"
  (
    stop_base_restore
    snapshot="$(evaluate_round 3)"
    [ "$(read_json "$snapshot" '.default_stop')" = false ]
    mutant_tree audit-loop-signals-lib.sh -e '/^   and \$stop_inputs != null$/d'
    snapshot="$(evaluate_round 3)"
    [ "$(read_json "$snapshot" '.default_stop')" = true ]
  )

  echo "case: every incremental reason in the resolver's closed set stops, every other token and an absent base does not (mutant reading absent as incremental goes red)"
  (
    while IFS= read -r token; do tokens+=("$token"); done < <(awk '/Closed reason set:/ { reading = 1; next } /^# Exit code/ { reading = 0 }
      reading && /^#     [a-z-]+  / { print $2 }' "$REPO_ROOT/.github/audit/resolve-audit-base.sh")
    [ "${#tokens[@]}" -ge 4 ] || { echo "read ${#tokens[@]} tokens"; return 1; }
    for want in member-clearance member-refusal team-signal; do
      printf '%s\n' "${tokens[@]}" | grep -qxF -- "$want" || { echo "resolver lacks $want"; return 1; }
    done
    stop_base_restore
    for token in "${tokens[@]}"; do
      review_base_all "$token"
      case "$token" in
        # sanctioned copy of .gaia/scripts/audit-loop-signals-lib.sh#_GAIA_LOOP_INCREMENTAL_BASE_REASONS
        member-clearance | member-refusal | team-signal) want=true ;;
        *) want=false ;;
      esac
      stop_is 3 "$want" || { echo "token $token"; return 1; }
    done
    review_base_all absent
    stop_is 3 false
    [ "$(read_json "$(stop_of 3)" '.review_bases | tojson')" = "{\"$MEMBER\":null}" ]
    mutant_tree audit-loop-signals-lib.sh -e 's/def incremental_base: IN(/def incremental_base: . == null or IN(/'
    stop_is 3 true
  )

  echo "case: reintroduced denies the stop (mutant dropping the term goes red)"
  (
    stop_base_restore
    alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1,\"disposition\":\"fix\",\"reason\":\"r\"}]"
    [ "$(read_json "$(stop_of 3)" '.signals.reintroduced')" = true ]
    stop_is 3 false
    mutant_tree audit-loop-signals-lib.sh -e '/^   and (\$signals.reintroduced | not)$/d'
    stop_is 3 true
  )

  echo "case: a Major with an honored triage mark is exempt and outside S; unmarked it blocks (mutant removing the exemption goes red)"
  (
    fresh_fixture
    honored_case true
    snapshot="$(stop_of 3)"
    [ "$(read_json "$snapshot" '.default_stop')" = true ] || { echo "$snapshot"; return 1; }
    [ "$(read_json "$snapshot" '.default_stop_keys | map(.[1]) | unique | tojson')" = '["rule/x"]' ]
    mutant_tree audit-loop-signals-lib.sh -e 's/^   and all(\$findings.entries\[\]; honored_in(\$honored_keys) or (/   and all($findings.entries[]; (/'
    stop_is 3 false
    . "$SCRIPTS/audit-loop-eval.sh"
    fresh_fixture
    MEMBER=code-audit-frontend
    honored_case false
    stop_is 3 false
  )
}

# write_veto <line>: vetoes.json vetoing the member's rule/x key on f.txt:<line> from round 1.
write_veto() {
  mkdir -p "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  jq -n -c --arg member "$MEMBER" --argjson line "$1" \
    '{version: 1, keys: [{member: $member, finding_class: "rule/x", path: "f.txt", line: $line, effective_from_round: 1}]}' \
    >"$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
}

@test "reintroduced: each clause of the widened repeat signal, with the member-ran and class-identity boundaries" {
  local mode snapshot
  echo "case: a triple back at a shifted line after a two-round gap holds it"
  rounds_sequence "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 3 3 rule/z)")" "$(minor_entries f.txt 1 2)" \
    "$(minor_entries f.txt 1 2)" "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 5 5 rule/z)")"
  [ "$(read_json "$(evaluate_round 4)" '.signals.reintroduced')" = true ]
  fresh_fixture
  echo "case: a triple moving through overlapping line sets holds it"
  rounds_sequence "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 2 3)" "$(minor_entries f.txt 3 4)"
  [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = true ]
  fresh_fixture
  echo "case: a fixed triple re-reported at its line or at a shifted line holds it"
  rounds_sequence "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)"
  [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = false ]
  alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1,\"disposition\":\"fix\",\"reason\":\"r\"}]"
  [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = true ]
  fresh_fixture
  rounds_sequence "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 2 3)"
  [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = false ]
  alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1,\"disposition\":\"fix\",\"reason\":\"r\"}]"
  [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = true ]
  echo "case: a round the member did not run, and a reopened round, are no gap (mutant counting them goes red)"
  for mode in skip reopen; do
    fresh_fixture
    skipped_member_case "$mode"
    [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = false ] || { echo "$mode: $(evaluate_round 3)"; return 1; }
  done
  (
    mutant_tree audit-loop-signals-lib.sh -e 's/\.round > \$earlier and member_ran(\$triple) and/.round > $earlier and/'
    for mode in skip reopen; do
      fresh_fixture
      skipped_member_case "$mode"
      [ "$(read_json "$(evaluate_round 3)" '.signals.reintroduced')" = true ] || { echo "mutant stayed green on $mode"; return 1; }
    done
  )
  fresh_fixture
  echo "case: a fresh Minor of a different class on the path a fixed class held keeps reintroduced false and stops"
  stop_roster
  rounds_sequence "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 3 3 rule/w)")" "$(minor_entries f.txt 1 2)" \
    "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 3 3 rule/y)")"
  alf_dispositions 1 "[{\"member\":\"$MEMBER\",\"finding_class\":\"rule/w\",\"path\":\"f.txt\",\"line\":3,\"disposition\":\"fix\",\"reason\":\"r\"}]"
  review_base_all member-clearance
  earn_marker "$MEMBER" 3
  snapshot="$(stop_of 3)"
  [ "$(read_json "$snapshot" '[.signals.reintroduced, .default_stop] | tojson')" = '[false,true]' ] || { echo "$snapshot"; return 1; }
}

# honored_case <triage:true|false>: the shell maintainer reports stable Minors
# on lib/s.sh and, at round 3, one Major there, triage-marked or not.
honored_case() {
  local mark='{}'
  [ "$1" = true ] && mark='{"triage":true,"triage_reason":"below the threshold"}'
  MEMBER="$SHELL_MAINTAINER"
  alf_fill lib/s.sh 12 shell
  stop_case "$(minor_entries lib/s.sh 1 3)" "$(minor_entries lib/s.sh 1 2)" \
    "$(with_entries "$(minor_entries lib/s.sh 1 2)" "$(jq -n -c --argjson mark "$mark" '[{path: "lib/s.sh", line: 4, finding_class: "rule/t", severity: "major", security: false} + $mark]')")"
}

# --- the widened repeat signal ------------------------------------------------

# skipped_member_case <skip|reopen>: rule/z reported at round 1, then a round
# the member did not run (another member ran, or a reopened round with no
# members), then rule/z back at a shifted line.
skipped_member_case() {
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 3 3 rule/z)")"
  alf_store_snapshot 1
  if [ "$1" = skip ]; then
    alf_set_line other.txt 2 "round 2"
    alf_commit "round 2"
    alf_add_round '["code-audit-shell"]'
    alf_stamp 2 20
    alf_sidecar code-audit-shell "$(minor_entries g.txt 1 1)" 21
  else
    alf_add_round '[]'
    alf_state_edit '.history.rounds[1].reopened = true'
  fi
  alf_set_line other.txt 3 "round 3"
  next_round 3 "$(with_entries "$(minor_entries f.txt 1 2)" "$(minor_entries f.txt 5 5 rule/z)")"
}

# --- the stop override at the decision layer ----------------------------------

@test "stop override: lifts enriching and the fallback on every decision path; reintroduced and the cap still deny" {
  local plain overridden state unit_state through
  echo "case: enriching and the round-6 fallback deny without the override and allow with it, on every decision path"
  plain='{"round":4,"verdict":"enriching","signals":{"enriching":true},"default_stop":true}'
  overridden="$(jq -c '. + {stop_override: true}' <<<"$plain")"
  state="$(make_state 4)"
  through="$(_gaia_loop_minimum $((5 + $(UNIT_ROUNDS) - 1)) 10)"
  [ "$(gaia_loop_decide_unit "$state" "$plain" "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
  [ "$(gaia_loop_decide_unit "$state" "$overridden" "$LOW" 300000 50)" = "allow context 5 $through" ]
  [ "$(gaia_loop_decide_unit "$state" "$(jq -c '.stop_override = false' <<<"$overridden")" "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
  unit_state="$(make_state 4 ".history.units = [$(unit_entry 1 4 6 0)]")"
  [ "$(gaia_loop_decide_member "$unit_state" "$plain" true "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
  [ "$(gaia_loop_decide_member "$unit_state" "$overridden" true "$LOW" 300000 50)" = allow ]
  [ "$(gaia_loop_decide "$state" "$plain")" = "deny enriching" ]
  [ "$(gaia_loop_decide "$state" "$overridden")" = allow ]
  plain='{"round":6,"verdict":"continue","signals":{},"default_stop":true}'
  overridden="$(jq -c '. + {stop_override: true}' <<<"$plain")"
  state="$(make_state 6)"
  through="$(_gaia_loop_minimum $((7 + $(UNIT_ROUNDS) - 1)) 10)"
  [ "$(gaia_loop_decide_unit "$state" "$plain" unparseable 300000 50)" = "deny fallback false false" ]
  [ "$(gaia_loop_decide_unit "$state" "$overridden" unparseable 300000 50)" = "allow fallback 7 $through" ]
  [ "$(gaia_loop_decide "$state" "$plain")" = "deny allowance" ]
  [ "$(gaia_loop_decide "$state" "$overridden")" = allow ]
  echo "case: reintroduced still denies and the cap still fires at used 10"
  overridden='{"round":4,"verdict":"continue","signals":{"reintroduced":true,"enriching":true},"default_stop":true,"stop_override":true}'
  state="$(make_state 4)"
  [ "$(gaia_loop_decide_unit "$state" "$overridden" "$LOW" 300000 50)" = "deny rubric:reintroduced false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 4 ".history.units = [$(unit_entry 1 4 6 0)]")" "$overridden" true "$LOW" 300000 50)" = "deny rubric:reintroduced false false" ]
  overridden='{"round":10,"verdict":"continue","signals":{"cap":true},"default_stop":true,"stop_override":true}'
  state="$(make_state 10)"
  [ "$(gaia_loop_decide_unit "$state" "$overridden" "$LOW" 300000 50)" = "deny cap false true" ]
  [ "$(gaia_loop_decide_member "$state" "$overridden" true "$LOW" 300000 50)" = "deny cap false true" ]
  [ "$(gaia_loop_decide "$state" "$overridden")" = "deny cap" ]
}

# --- the read-only CLI arms -----------------------------------------------------

@test "cli evaluate-round: a qualifying round prints default_stop true (mutant dropping the root argument goes red)" {
  stop_base
  run bash "$SCRIPTS/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT" --round 3
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(read_json "$output" '.default_stop')" = true ] || return 1
  mutant_tree audit-loop-eval.sh -e 's/gaia_loop_evaluate_round "\$main" "\$state" "\$round" "\$root"/gaia_loop_evaluate_round "$main" "$state" "$round"/' || return 1
  run bash "$MUTANT_SCRIPTS/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT" --round 3
  [ "$(read_json "$output" '.default_stop')" = false ]
}

@test "cli findings: entries carry failure_mode and the findings carry review_bases, neither in counted_keys" {
  stop_base
  run bash "$SCRIPTS/audit-loop-eval.sh" findings --root "$ALF_ROOT" --round 3
  [ "$(read_json "$output" '[.entries[0].failure_mode, (.review_bases | tojson)] | join(" ")')" = "f {\"$MEMBER\":\"member-clearance\"}" ] || return 1
  [ "$(read_json "$(stop_of 3)" '.counted_keys[0] | has("failure_mode")')" = false ]
}

# tree_snapshot: every file under the fixture's .gaia with its digest, so a write anywhere shows.
tree_snapshot() {
  find "$ALF_ROOT/.gaia" -type f | sort | while IFS= read -r file_path; do printf '%s %s\n' "$(shasum <"$file_path")" "$file_path"; done
}

@test "cli round-history and reopened-round: pinned output, an accepted key holds every later round, and neither writes a file" {
  local before expected head_tree
  alf_sequence 2 1
  alf_add_checkpoint 2 stalled
  alf_add_answer 1 accept
  alf_state_edit '.history.rounds[1].reopened = true | .allowance.accepted_keys = [{checkpoint: 1, key: ["m", "c", "a.ts", 4], source: "typed", at: "t", session_id: "s1"}]'
  before="$(tree_snapshot)"
  expected="$(jq -c --arg member "$MEMBER" '[.history.rounds[0], .history.rounds[1]] as [$first, $second]
    | [{round: 1, tree: $first.tree, members: [$member], keys: [[$member, "rule/x", "f.txt", 1], [$member, "rule/x", "f.txt", 2]],
        counted_keys: [[$member, "rule/x", "f.txt", 1], [$member, "rule/x", "f.txt", 2]], closing: false, reopened: false, human_accept: false, human_accepted_keys: []},
       {round: 2, tree: $second.tree, members: [$member], keys: null, counted_keys: null, closing: false, reopened: true, human_accept: true,
        human_accepted_keys: [["m", "c", "a.ts", 4]]}]' "$ALF_STATE")"
  run bash "$SCRIPTS/audit-loop-eval.sh" round-history --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$expected" ] || { printf 'got  %s\nwant %s\n' "$output" "$expected"; return 1; }
  run bash "$SCRIPTS/audit-loop-eval.sh" reopened-round --root "$ALF_ROOT"
  [ "$output" = 2 ] || { echo "reopened-round at HEAD: $output"; return 1; }
  [ "$before" = "$(tree_snapshot)" ] || { echo "a read wrote a file"; return 1; }
  head_tree="$(alf_git rev-parse 'HEAD^{tree}')"
  alf_state_edit '.history.rounds[1].tree = $tree' --arg tree "$(printf 'd%.0s' $(seq 1 40))"
  run bash "$SCRIPTS/audit-loop-eval.sh" reopened-round --root "$ALF_ROOT"
  [ "$output" = 0 ] || return 1
  alf_state_edit '.history.rounds[1].tree = $tree | .history.rounds[1].reopened = false' --arg tree "$head_tree"
  run bash "$SCRIPTS/audit-loop-eval.sh" reopened-round --root "$ALF_ROOT"
  [ "$output" = 0 ] || return 1
  alf_state_edit '.history.rounds += [.history.rounds[1], .history.rounds[1]]'
  run bash "$SCRIPTS/audit-loop-eval.sh" round-history --root "$ALF_ROOT"
  [ "$(jq -c '.[3].human_accepted_keys' <<<"$output")" = '[["m","c","a.ts",4]]' ] || { echo "accept lost two rounds after its checkpoint: $output"; return 1; }
}

# Round r's stored counted_keys rewritten so line 1 is a non-security Major,
# line 2 a security Major and line 3 a non-security Critical.
grade_round_keys() {
  alf_state_edit '.history.rounds[$round - 1].snapshot.counted_keys |= map(
    .security = (.line == 2) | .severity = (if .line == 3 then "critical" else "major" end))' --argjson round "$1"
}

@test "cli accepted-keys: only a human accept lists a key, and only a non-security Major or Minor of a round >= 1" {
  local accepted
  alf_sequence 3 1
  alf_store_snapshot 2
  grade_round_keys 1
  grade_round_keys 2
  accepted="[{\"key\":[\"$MEMBER\",\"rule/x\",\"f.txt\",1],\"lines\":[1,4]}]"
  alf_add_checkpoint 0 stalled
  alf_add_answer 1 accept
  run bash "$SCRIPTS/audit-loop-eval.sh" accepted-keys --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = '[]' ] || { echo "a round-0 accept listed the newest round's keys: $output"; return 1; }
  alf_add_checkpoint 1 stalled
  alf_add_answer 2 grant 3
  run bash "$SCRIPTS/audit-loop-eval.sh" accepted-keys --root "$ALF_ROOT"
  [ "$output" = '[]' ] || { echo "a grant accepted keys: $output"; return 1; }
  alf_add_answer 2 accept
  run bash "$SCRIPTS/audit-loop-eval.sh" accepted-keys --root "$ALF_ROOT"
  [ "$output" = "$accepted" ] || { printf 'a security or Critical key leaked\ngot  %s\nwant %s\n' "$output" "$accepted"; return 1; }
  alf_add_checkpoint 1 stalled
  alf_state_edit '.allowance.accepted_keys = [{checkpoint: 3, key: ["m", "c", "a.ts", 4], source: "typed", at: "t", session_id: "s1"},
    {checkpoint: 3, key: [$member, "rule/x", "f.txt", 2], source: "typed", at: "t", session_id: "s1"},
    {checkpoint: 3, key: [$member, "rule/x", "f.txt", 1], source: "typed", at: "t", session_id: "s1"}]' --arg member "$MEMBER"
  run bash "$SCRIPTS/audit-loop-eval.sh" accepted-keys --root "$ALF_ROOT"
  [ "$output" = "$accepted" ] || { echo "an ungraded or security accepted finding, or a duplicate, leaked: $output"; return 1; }
}

@test "cli accepted-keys: an accepted key's lines follow a later commit that moved it" {
  alf_sequence 1
  alf_store_snapshot 1
  grade_round_keys 1
  alf_add_checkpoint 1 stalled
  alf_add_answer 1 accept
  { printf 'inserted %s\n' 1 2 3 4 5; cat "$ALF_ROOT/f.txt"; } >"$ALF_ROOT/f.txt.new" && mv "$ALF_ROOT/f.txt.new" "$ALF_ROOT/f.txt"
  alf_commit fixer
  run bash "$SCRIPTS/audit-loop-eval.sh" accepted-keys --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "[{\"key\":[\"$MEMBER\",\"rule/x\",\"f.txt\",1],\"lines\":[3,9]}]" ] || { echo "the accepted line did not follow the commit: $output"; return 1; }
}

@test "cli veto-state: unsatisfied keys and their reviewers" {
  echo "case: a vetoed key no member reported is unsatisfied for the round"
  stop_base
  write_veto 11
  run bash "$SCRIPTS/audit-loop-eval.sh" veto-state --root "$ALF_ROOT" --round 3
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{\"satisfied\":[],\"unsatisfied\":[[\"$MEMBER\",\"rule/x\",\"f.txt\",11]],\"reviewers\":[\"$MEMBER\"]}" ]
  echo "case: an unsatisfied cross-remit key lists its path's roster owner among the reviewers"
  jq -c '.keys[0].path = "lib/s.sh"' "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json" >"$BATS_TEST_TMPDIR/vetoes.json"
  mv "$BATS_TEST_TMPDIR/vetoes.json" "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  run bash "$SCRIPTS/audit-loop-eval.sh" veto-state --root "$ALF_ROOT" --round 3
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '.reviewers' <<<"$output")" = "[\"$MEMBER\",\"$SHELL_MAINTAINER\"]" ] || { echo "$output"; return 1; }
}

# review_record_setup: the review scripts beside the scratch copy, and the run
# folder the CLI derives for the fixture branch. Sets REVIEW_RUN_FOLDER.
review_record_setup() {
  local script_file
  cli_copy
  for script_file in audit-code-review-record.sh audit-code-review-decide.sh audit-code-review-handover.sh; do
    cp "$SCRIPTS/$script_file" "$CLI/$script_file"
  done
  REVIEW_RUN_FOLDER="$(gaia_loop_run_directory "$ALF_ROOT" "$(gaia_loop_key "$ALF_ROOT")")"
  mkdir -p "$REVIEW_RUN_FOLDER"
}

# write_review_record <outcome> <reason-or-empty> <cost-json>: a record with no findings.
write_review_record() {
  jq -n -c --arg outcome "$1" --arg reason "$2" --argjson cost "$3" '{version: 1, pr: 7, base: null, head: null,
    outcome: $outcome, reason: (if $reason == "" then null else $reason end), level: "high", model: null,
    claude_version: null, attempts: [], cost: $cost, denials: {count: 0, tools: [], detail: []}, findings: [],
    handover: "none", reconcile_passes: 0, rounds: null, members_dispatched: null, convergence: null}' \
    >"$REVIEW_RUN_FOLDER/code-review.json"
}

@test "record-values: the review object per review-record state" {
  echo "case: a recorded round and no review record publishes not run: no record with cost none"
  review_record_setup
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend"]'
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(read_json "$output" '.review | tojson')" = '{"outcome":"not run","reason":"no record","cost":"none"}' ]
  fresh_fixture
  echo "case: an unreadable review record publishes unreadable record with cost unknown"
  review_record_setup
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend"]'
  printf 'not json\n' >"$REVIEW_RUN_FOLDER/code-review.json"
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(read_json "$output" '.review | tojson')" = '{"outcome":"not run","reason":"unreadable record","cost":"unknown"}' ]
  fresh_fixture
  echo "case: no round and no review record prints no review key"
  review_record_setup
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":0,"members":{},"grants":0}' ]
  fresh_fixture
  echo "case: no round and a not needed record still publishes it"
  review_record_setup
  write_review_record 'not needed' 'release branch' '"none"'
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(read_json "$output" '.review.outcome')" = 'not needed' ]
  [ "$(read_json "$output" '.review.reason')" = 'release branch' ]
  [ "$(read_json "$output" '.review.cost')" = 'none' ]
  fresh_fixture
  echo "case: a pending review record publishes interrupted with the record's cost and writes nothing"
  review_record_setup
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend"]'
  write_review_record pending '' '0.5'
  local before
  before="$(cat "$REVIEW_RUN_FOLDER/code-review.json")"
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$(read_json "$output" '.review | tojson')" = '{"outcome":"not run","reason":"interrupted","cost":0.5}' ]
  [ "$(cat "$REVIEW_RUN_FOLDER/code-review.json")" = "$before" ]
}
