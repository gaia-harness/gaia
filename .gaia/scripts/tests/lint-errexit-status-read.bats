#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so `$?`, `$(...)`, and the variable references inside reach the fixture file as
# literal text. The unexpanded status reference IS the thing under test, so
# letting the shell expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-errexit-status-read.sh: the static gate that flags
# a read of `$?` following a bare command-substitution assignment while errexit
# is armed, where the assignment takes the substitution's status and the shell
# has already exited by the time the read would run.
#
# Three jobs. Prove the detector fires on the class, on both surfaces and
# through every spelling the shape takes; prove it stays quiet on the legitimate
# shapes, which for this gate is the load-bearing half, because the repair its
# own hint text advertises, the `local` form shellcheck already owns, the
# deferred `trap` capture, and every script that simply never arms errexit are
# all things a naive detector reds on; and assert the real scanned tree is clean
# so a regression fails CI.
#
# One test is load-bearing beyond coverage. A gate written for a class must red
# against that class's historical form, or it asserts nothing about the class it
# was written for: "reds against the shipped composite-action shape" carries the
# `run:` body with no explicit `set -e`, which is how both instances in
# gaia-react/gaia#1477 and gaia-react/gaia#1478 were live, so it proves the
# detector reaches the shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. It also requires
# every half of that surface to be non-empty, so fixture_repo seeds one benign
# file of each scanned kind and each test adds the file it is actually about.
# The tests that are ABOUT an empty surface take fixture_repo_bare instead and
# seed only the kinds they need present, since a seed would answer the very
# question they ask.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_file <relpath> <body>: write <body> verbatim to $TEMPORARY_DIRECTORY/<relpath> and
# track it. `printf %s` never interprets an escape, so the fixture reaches the
# file as the characters the gate is meant to read.
fixture_file() {
  local destination="$TEMPORARY_DIRECTORY/$1"
  mkdir -p "$( dirname "$destination" )"
  printf '%s\n' "$2" > "$destination"
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# fixture_repo_bare: an initialized git repo carrying nothing at all. The tests
# that pin the gate's empty-surface hard errors build on this and seed only the
# kinds they mean to be present.
fixture_repo_bare() {
  # A case-table test builds one repo per case; teardown removes only the last.
  if [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ]; then
    rm -rf "$TEMPORARY_DIRECTORY"
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d -t errexit-status-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
}

seed_sh() { fixture_file seed.sh 'echo seed'; }

seed_workflow() {
  fixture_file .github/workflows/seed.yml 'jobs:
  seed:
    steps:
      - run: |
          echo seed'
}

# A benign suite, clean of this class, so the bats half of the precondition is
# met wherever the test is about something else.
seed_bats() {
  fixture_file seed.bats '@test "seed" {
  true
}'
}

# fixture_repo: an initialized git repo in $TEMPORARY_DIRECTORY carrying one benign file of each
# scanned kind, so the gate's non-empty-surface preconditions are met and a test
# can add just the file it is about.
fixture_repo() {
  fixture_repo_bare
  seed_sh
  seed_workflow
  seed_bats
}

# fixture_script <body>: the common case, a tracked shell script.
fixture_script() {
  fixture_file check.sh "$1"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
}

# run_case <label> <case function>: run one case of a case-table test, echoing its
# label first so a red case names itself in the bats output.
run_case() {
  echo "case: $1"
  "$2"
}

case_flags_the_unquoted_spelling() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_flags_the_spelling_shellcheck_sees() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
if [ $? -ne 0 ]; then
  echo dead
fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_flags_across_an_intervening_comment() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
# Capture the status so the branch below can report it.
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_flags_across_an_intervening_blank_line() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)

rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_flags_a_legacy_backtick_substitution() {
  fixture_repo
  fixture_script 'set -e
out=`some_command`
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_flags_after_long_form_set_minus_o_errexit() {
  fixture_repo
  fixture_script 'set -o errexit
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_follows_a_command_substitution_spanning_several_lines() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command \
  --flag one \
  --flag two)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:5:' <<<"$output"
  grep -qF -- 'assignment at line 2' <<<"$output"
}

case_flags_a_status_read_inside_double_quotes() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
echo "command exited $?"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_rearms_after_set_plus_e_block_closes() {
  fixture_repo
  fixture_script 'set -e
set +e
lenient=$(some_command)
rc=$?
set -e
strict=$(other_command)
rc=$?
echo "$lenient $strict $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:7:' <<<"$output"
  grep -qF -- 'check.sh:4:' <<<"$output" && return 1
  true
}

case_flags_the_one_line_semicolon_spelling() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) ; rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:2:' <<<"$output"
}

case_flags_an_appending_assignment() {
  fixture_repo
  fixture_script 'set -e
out=seed
out+=$(some_command)
rc=$?
echo "$out $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_flags_a_real_read_on_a_line_with_a_comment() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
rc=$?   # capture before anything else runs
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_quiet_on_a_script_that_never_arms_errexit() {
  fixture_repo
  fixture_script 'out=$(some_command)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "failed" >&2
fi'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_the_repair_the_hint_advertises() {
  fixture_repo
  fixture_script 'set -euo pipefail
rc=0
out="$(some_command)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "failed" >&2
fi'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_a_local_prefixed_assignment() {
  fixture_repo
  fixture_script 'set -e
f() {
  local out=$(some_command)
  local rc=$?
  echo "$out $rc"
}
f'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_export_and_readonly_prefixed_assignments() {
  fixture_repo
  fixture_script 'set -e
export OUT=$(some_command)
rc=$?
readonly OTHER=$(other_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_a_deferred_trap_capture() {
  fixture_repo
  fixture_script 'set -euo pipefail
TMP=$(mktemp -d)
trap '"'"'rc=$?; if [ "$rc" -ne 0 ]; then cat "$TMP/log"; fi; rm -rf "$TMP"'"'"' EXIT
echo "$TMP"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_under_set_plus_e() {
  fixture_repo
  fixture_script 'set -e
set +e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_when_a_command_separates_assignment_and_read() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
echo "ran"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_an_assignment_used_as_an_if_condition() {
  fixture_repo
  fixture_script 'set -e
if out=$(some_command); then
  echo "$out"
fi
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_an_assignment_with_no_substitution() {
  fixture_repo
  fixture_script 'set -e
out=literal
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_a_pipeline() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) | tee log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_the_second_statement_when_the_first_is_guarded() {
  fixture_repo
  fixture_script 'set -e
rc=0
out=$(some_command) || rc=$?; echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_arithmetic_expansion() {
  fixture_repo
  fixture_script 'set -euo pipefail
x=$((1 + 2))
rc=$?
echo "$x $rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_a_trailing_comment_mentioning_the_status() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
some_cmd   # returns $? to the caller
echo done'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_after_long_form_set_plus_o_errexit() {
  fixture_repo
  fixture_script 'set -o errexit
set +o errexit
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_flags_an_executed_helper_in_a_bats_suite() {
  fixture_repo
  # The shape reaches disk UNESCAPED and outside any heredoc, which is what makes
  # this fixture non-vacuous. Written with `\$` it would be quiet whatever the
  # surface (walk consumes the escape), and written inside a heredoc the swallow
  # would hide it, so both spellings would test nothing. `setup` is invoked by
  # bats itself and never through `run`, so the run-only exemption does not reach
  # it and the arming is the whole reason this reds.
  fixture_file suite.bats 'setup() {
  set -e
  out=$(some_command)
  rc=$?
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:4:' <<<"$output"
}

case_the_same_bytes_are_flagged_in_a_tracked_shell_script() {
  fixture_repo
  # The mirror of the test above, and the pair is the claim: one class, two
  # surfaces, the same verdict. Neither surface quiets the shape any more, so
  # what these two pin together is that nothing about the file extension decides
  # whether the assignment kills the shell.
  fixture_script 'setup() {
  set -e
  out=$(some_command)
  rc=$?
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_arms_a_bats_test_body_without_set_minus_e() {
  fixture_repo
  # Without its own arm the bats set folds into the off-by-default `*.sh` arm,
  # a suite carries no `set -e`, and the whole surface reads clean by
  # construction. This is the test that keeps it from silently reverting.
  fixture_file suite.bats '@test "captures a status" {
  out=$(some_command)
  rc=$?
  echo "$rc"
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:3:' <<<"$output"
}

case_set_plus_e_inside_a_test_body_still_disarms() {
  fixture_repo
  fixture_file suite.bats '@test "opts out" {
  set +e
  out=$(some_command)
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

# bats disables errexit under `run`, so a helper whose every invocation in its
# own file is `run <name>` hands its status to `run` and the read below it is
# live rather than dead. Each shape below carries its own verdict and every one
# of them is required: with any missing, the exemption is unfalsifiable in that
# direction.
case_a_helper_invoked_only_through_run_is_not_armed() {
  fixture_repo
  fixture_file suite.bats 'helper() {
  out=$(some_command)
  rc=$?
  echo "$rc"
}

@test "a" {
  run helper
}

@test "b" {
  run helper
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_helper_with_one_plain_call_site_is_armed() {
  fixture_repo
  fixture_file suite.bats 'helper() {
  out=$(some_command)
  rc=$?
  echo "$rc"
}

@test "a" {
  run helper
}

@test "b" {
  helper
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:3:' <<<"$output"
}

case_a_helper_with_no_call_site_is_armed() {
  fixture_repo
  # An uninvoked helper is evidence of nothing, so it does not earn the
  # exemption. Failing open here would hand a free pass to every helper whose
  # call sites the census cannot see.
  fixture_file suite.bats 'helper() {
  out=$(some_command)
  rc=$?
  echo "$rc"
}

@test "a" {
  true
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:3:' <<<"$output"
}

case_quiet_on_a_fixture_body_written_through_a_quoted_literal() {
  fixture_repo
  # TWO mechanisms agree that this is data, and the load-bearing one is this
  # gate's own: a multi-line quoted literal is ONE continued statement to its
  # tokenizer, so the interior lines are never statements at all. The shared
  # library's argument-region rule reaches the same verdict from the other
  # direction. Neither is redundant with the other on the sibling gates, which
  # read raw lines and have only the library's answer.
  fixture_file suite.bats "$(cat <<'FIXTURE'
@test "writes a fixture" {
  fixture_script 'set -e
out=$(some_command)
rc=$?'
}
FIXTURE
)"
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_a_fixture_body_written_into_a_quoted_heredoc() {
  fixture_repo
  fixture_file suite.bats "$(cat <<'FIXTURE'
@test "writes a fixture" {
  cat <<'EOF' > check.sh
set -e
out=$(some_command)
rc=$?
EOF
}
FIXTURE
)"
  run_linter
  [ "$status" -eq 0 ]
}

case_executed_shell_beside_a_fixture_write_is_still_reported() {
  fixture_repo
  # The region ends with the statement, so the test body behind it is shell
  # again. Without that bound a suite could hide a live instance behind any
  # fixture-writing call.
  fixture_file suite.bats "$(cat <<'FIXTURE'
@test "writes a fixture then runs" {
  fixture_script 'set -e'
  out=$(some_command)
  rc=$?
}
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:4:' <<<"$output"
}

case_keeps_reading_past_a_paren_inside_a_quoted_string() {
  fixture_repo
  fixture_script 'set -euo pipefail
cand=$(printf "%s" "$rest" | sed -E "s/[[:space:])].*$//")
echo "$cand"
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:5:' <<<"$output"
}

case_follows_a_heredoc_opened_inside_a_command_substitution() {
  fixture_repo
  fixture_script 'set -euo pipefail
PATHS="$(cat <<EOF
a lone apostrophe that must not leak into the walk: it'"'"'s here
EOF
)"
out=$(some_command)
rc=$?
echo "$PATHS $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:7:' <<<"$output"
}

case_quiet_on_a_heredoc_body_carrying_the_shape_as_a_fixture() {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/fixture.sh <<EOF
set -e
out=$(some_command)
rc=$?
EOF
echo done'
  run_linter
  [ "$status" -eq 0 ]
}

case_set_plus_e_inside_a_heredoc_body_does_not_disarm() {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.sh <<EOF
set +e
EOF
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:6:' <<<"$output"
}

case_an_apostrophe_inside_a_heredoc_body_does_not_swallow_the_file() {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<EOF
this body carries an apostrophe: it'"'"'s the byte that desyncs
EOF
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:6:' <<<"$output"
}

case_a_double_quoted_string_closes_before_a_later_trap_capture() {
  fixture_repo
  # The deferred-trap case in "stays quiet on the common legitimate shapes" covers
  # the trap alone. If has_status_read never leaves double-quote
  # state, everything after the first `"` on the line reads as quoted, the trap
  # body stops being recognised as single-quoted, and this reports.
  fixture_script 'set -euo pipefail
TMP=$(mktemp -d)
echo "working in $TMP"; trap '"'"'rc=$?; rm -rf "$TMP"'"'"' EXIT
echo done'
  run_linter
  [ "$status" -eq 0 ]
}

# Inside `$'"'"'...'"'"'` a backslash ESCAPES, so an escaped quote does not close the
# literal. Read as an ordinary single-quoted span it closes at the escaped quote
# and reopens at the real terminator, and because quote state is carried across
# lines the REST OF THE FILE is then swallowed as quoted text.
#
# These two fixtures carry a literal single quote, which a single-quoted bats
# string cannot hold, so they are written through a quoted heredoc. The bytes
# still reach disk unescaped, which is the property that makes them non-vacuous.
case_an_ansi_c_literal_with_an_escaped_quote_does_not_swallow_the_file() {
  fixture_repo
  fixture_file check.sh "$(cat <<'FIXTURE'
set -e
msg=$'it\'s here'
echo "$msg"
FIXTURE
)"
  run_linter
  [ "$status" -eq 0 ]
}

case_the_remainder_after_an_ansi_c_literal_is_classified() {
  fixture_repo
  # The strong form of the test above. A file that scans clean proves only that
  # no ERROR printed; this one puts a genuine instance BEHIND the literal, so a
  # tokenizer that lost sync there would swallow the instance as quoted text and
  # green for the wrong reason.
  fixture_file check.sh "$(cat <<'FIXTURE'
set -e
msg=$'it\'s here'
echo "$msg"
out=$(some_command)
rc=$?
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:5:' <<<"$output"
}

case_an_ansi_c_literal_with_no_escaped_quote_is_clean() {
  fixture_repo
  # Pins the CAUSE to the escaped quote specifically rather than to ANSI-C
  # quoting at large: an ordinary single-quote reading handles this one, so it
  # was clean before the frame existed and stays clean after.
  fixture_file check.sh "$(cat <<'FIXTURE'
set -e
msg=$'plain literal'
echo "$msg"
FIXTURE
)"
  run_linter
  [ "$status" -eq 0 ]
}

case_a_quote_after_an_escaped_dollar_opens_an_ordinary_span() {
  fixture_repo
  # The frame opens only on a `$` the walk actually reaches from the unquoted
  # state. An escaped dollar is consumed by the escape arm, so what follows is an
  # ordinary single-quoted string that a backslash does not escape inside: the
  # span closes at the FIRST quote, and the second one opens and closes another.
  fixture_file check.sh "$(cat <<'FIXTURE'
set -e
printf '%s\n' \$'a''b'
out=$(some_command)
rc=$?
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_a_dollar_inside_double_quotes_does_not_open_an_ansi_c_frame() {
  fixture_repo
  # Bash does not expand ANSI-C quoting inside double quotes, so the quote after
  # the `$` is an ordinary character of the string. Read as a frame opener the
  # walk would consume the rest of the line looking for a terminator and the hit
  # below would go unseen.
  fixture_file check.sh "$(cat <<'FIXTURE'
set -e
echo "cost is $' today"
out=$(some_command)
rc=$?
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

# `<<` inside arithmetic is a left shift, not a redirection. Read as a
# redirection, the digits become a heredoc delimiter and every line below is
# consumed as body, so the walk loses shell state and the gate reports that it
# cannot certify the file rather than scanning it.
case_a_left_shift_in_a_bare_arithmetic_command_leaves_the_file_classified() {
  fixture_repo
  fixture_script 'n=1
(( n = n << 3 ))
echo "$n"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_left_shift_in_a_bare_arithmetic_command_after_if_is_classified() {
  fixture_repo
  fixture_script 'n=1
if (( n << 3 )); then n=0; fi
echo "$n"'
  run_linter
  [ "$status" -eq 0 ]
}

# The carve-out must not swallow a real heredoc: the class still has to fire
# below one.
case_the_arithmetic_carve_out_does_not_hide_a_hit_below_a_real_heredoc() {
  fixture_repo
  fixture_script 'set -euo pipefail
n=1
(( n = n << 3 ))
cat <<EOF
body
EOF
out="$(some_command --json)"
rc=$?
echo "$rc$out"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:8:' <<<"$output"
}

case_a_left_shift_in_a_for_header_leaves_the_file_classified() {
  fixture_repo
  fixture_script 'set -euo pipefail
n=4
for (( i = 0; i < (n << 2); i++ )); do :; done
echo "$i"'
  run_linter
  [ "$status" -eq 0 ]
}

case_reports_a_file_it_could_not_tokenize_to_the_end() {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<NEVERCLOSED
one
two'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'check.sh' <<<"$output"
}

case_a_desync_report_omits_the_status_read_repair() {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<NEVERCLOSED
one'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'letting the assignment hand its status on' <<<"$output" && return 1
  true
}

case_a_run_body_that_cannot_be_tokenized_is_reported() {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out="$(gh pr view 1
      - name: next
        run: echo done'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'a run: body' <<<"$output"
}

case_the_last_run_body_in_a_file_is_checked_for_desync_too() {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out="$(gh pr view 1'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'the last run: body' <<<"$output"
}

case_a_bats_suite_that_cannot_be_tokenized_is_reported() {
  fixture_repo
  fixture_file suite.bats "$(cat <<'FIXTURE'
@test "opens a heredoc that never closes" {
  cat <<'NEVERCLOSED'
  body
}
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats: ERROR: the scan lost track of shell state' <<<"$output"
}

case_one_desync_line_is_printed_for_one_unreadable_bats_file() {
  fixture_repo
  # This gate keeps its own desync verdict and asks the shared library not to
  # emit a second one. Both running would print two ERROR lines about one file
  # and read as two separate failures.
  fixture_file suite.bats "$(cat <<'FIXTURE'
@test "opens a heredoc that never closes" {
  cat <<'NEVERCLOSED'
  body
}
FIXTURE
)"
  run_linter
  [ "$status" -eq 1 ]
  [ "$( grep -cF -- 'suite.bats: ERROR: the scan lost track' <<<"$output" )" -eq 1 ]
}

case_does_not_flag_a_git_hook_with_no_set_e() {
  fixture_repo
  fixture_file .githooks/pre-commit 'out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_flags_a_git_hook_once_its_own_set_e_has_armed_errexit() {
  fixture_repo
  fixture_file .githooks/pre-commit 'set -e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.githooks/pre-commit:3:' <<<"$output"
}

case_set_plus_e_in_a_git_hook_still_disarms() {
  fixture_repo
  fixture_file .githooks/pre-commit 'set -e
set +e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_sh_under_githooks_is_scanned_once() {
  fixture_repo
  fixture_file .githooks/helper.sh 'set -e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  # A git pathspec glob crosses `/`, so this file matches BOTH the `*.sh` set and
  # the `.githooks/*` set. Armed by its own `set -e` it would be hit in each pass
  # and reported twice, which reads as two defects on one line.
  [ "$(grep -cF -- '.githooks/helper.sh:3:' <<<"$output")" -eq 1 ]
}

case_an_ordinary_tracked_script_is_still_off_by_default() {
  fixture_repo
  fixture_script 'out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_quiet_on_an_env_prefix_assignment() {
  fixture_repo
  fixture_script 'set -e
FOO=$(some_command) run_thing --flag
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_env_prefix_pair_with_no_command_is_still_a_bare_assignment() {
  fixture_repo
  fixture_script 'set -e
FOO=$(some_command) BAR=1
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_redirection_after_the_value_is_not_an_env_prefix() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) > log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_redirection_with_an_explicit_file_descriptor_is_still_a_redirection() {
  fixture_repo
  # `2>` is the shape that exempted itself: the leading digit read as the first
  # letter of a command word, so the identical statement was reported with `>`
  # and silently passed with `2>`.
  fixture_script 'set -e
out=$(some_command) 2> log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_descriptor_duplicating_redirection_is_not_a_control_operator() {
  fixture_repo
  # The `&` in `2>&1` is file-descriptor syntax on the same simple command, not
  # an AND-OR or a background operator, so the assignment still stands alone.
  fixture_script 'set -e
out=$(some_command) 2>&1
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_an_all_streams_redirection_is_not_a_control_operator() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) &>log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_redirection_before_the_command_word_does_not_hide_the_env_prefix() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) > log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_with_an_explicit_file_descriptor() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2> log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_behind_a_descriptor_duplicate() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2>&1 run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_greater_ampersand_redirection_is_consumed_whole() {
  fixture_repo
  # `>&` has to be consumed by the operator pattern in one piece. Matched as a
  # bare `>`, the leftover `&` reads as a control operator and terminates the
  # prefix walk one token early, which is the single-token failure in a new
  # spelling.
  fixture_script 'set -e
out=$(some_command) >& log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_ampersand_greater_redirection_reaches_the_loop() {
  fixture_repo
  # `&>` needs its own alternative in the operator pattern: its leading `&`
  # matches no part of `[0-9]*[<>]`, so without one it never enters the loop at
  # all and falls through to the statement-separator test.
  fixture_script 'set -e
out=$(some_command) &> log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_further_assignment_before_the_command_word_is_consumed() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) FOO=1 run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_env_prefix_indented_inside_a_function_is_not_the_class() {
  fixture_repo
  fixture_script 'set -e
f() {
  FOO=$(some_command) run_thing --flag
  rc=$?
  echo "$rc"
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_indented_bare_assignment_is_still_flagged() {
  fixture_repo
  fixture_script 'set -e
f() {
  out=$(some_command)
  rc=$?
  echo "$rc"
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_an_env_prefix_inside_a_run_body_is_not_the_class() {
  fixture_repo
  # The YAML half is the surface armed by DEFAULT and every line of a block
  # scalar is indented, so this is where an exclusion keyed on the wrong
  # whitespace goes silently inert.
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          FOO=$(gh pr view 1) run_thing --flag
          rc=$?
          echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_process_substitution_operand_is_followed() {
  fixture_repo
  # The operand is a nested command rather than a word. Broken on at its `(` the
  # leftover paren reads as a statement separator and `run_thing` behind it is
  # never reached, so the line is reported although the shell runs it and takes
  # `run_thing`'s status.
  fixture_script 'set -e
out=$(some_command) > >(cat >/dev/null) run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_for_an_input_process_substitution() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) < <(echo x) run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_later_substitution_in_the_same_assignment_list_takes_the_status() {
  fixture_repo
  # A statement that is only assignments takes the status of the LAST
  # substitution it ran, so `out=$(false) FOO=$(true)` survives while
  # `out=$(false) BAR=1` exits. What the `$?` below reads is the second
  # substitution's status, never the flagged assignment's.
  fixture_script 'set -e
out=$(some_command) FOO=$(other_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_later_substitution_in_a_redirection_operand_takes_the_status() {
  fixture_repo
  # The same last-substitution-wins behaviour reached by a different route, and
  # the spelling the narrower "in the same assignment list" reading missed. The
  # unquoted and concatenated operand spellings behave identically.
  fixture_script 'set -e
out=$(some_command) > "$(other_command)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_single_quoted_substitution_in_an_operand_runs_nothing() {
  fixture_repo
  # The negative control for the two above: single quotes make the operand a
  # literal filename, no second substitution runs, and the flagged assignment's
  # own status is what the shell takes. Confirmed against the shell, which exits
  # here on both bash 3.2 and bash 5.
  fixture_script 'set -e
out=$(some_command) > '"'"'$(other_command)'"'"'
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_two_substitutions_in_one_assignment_value_exempt_it() {
  fixture_repo
  # A word boundary is not a distinction the shell draws: `out="$(a)$(b)"` and
  # `out=$(a) FOO=$(b)` are one statement to it, and both reach the next line
  # with rc=0 when the last substitution succeeds. Measured on bash 3.2.57 and
  # 5.3.15: `out="$(false)$(true)"` gives REACHED rc=0 on both. So the count
  # deliberately does not care where the second substitution sits. What the
  # fixture below runs is the BOTH-FAIL instance of the same shape, where the
  # shell exits and the gate is quiet, which is the miss the header's
  # undecidable family names; no static reader can separate the two instances.
  fixture_script 'set -e
out="$(some_command)$(other_command)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_for_two_adjacent_quoted_words_in_one_value() {
  fixture_repo
  fixture_script 'set -e
out="$(some_command)""$(other_command)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_same_for_a_substitution_inside_a_parameter_expansion() {
  fixture_repo
  # walk() does not track `${`, so both substitutions here open at depth 0 and
  # the count reaches two, which is the same verdict the shell justifies.
  fixture_script 'set -e
out="${x:-$(some_command)}$(other_command)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_two_top_level_backtick_substitutions_exempt_the_statement() {
  fixture_repo
  # The count reaches a backtick substitution the same way it reaches `$(`, so
  # the legacy spelling is not a hole in the exemption. Measured on bash 3.2.57
  # and 5.3.15: `out=`false` FOO=`true`` gives REACHED rc=0 on both.
  fixture_script 'set -e
out=`some_command` FOO=`other_command`
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_backtick_nested_inside_a_substitution_does_not_count() {
  fixture_repo
  # The depth guard on the backtick arm of the count. A backtick inside a `$(`
  # region completes before the substitution containing it, so it can never be
  # the last one this statement ran; counted, it would reach two and exempt the
  # ordinary single-substitution class. One substitution here, and it is the
  # flagged one, so the message the gate prints is true and it reports.
  fixture_script 'set -e
out=$(echo `other_command`)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_substitution_inside_a_process_substitution_does_not_count() {
  fixture_repo
  # The operand's body runs in an async subshell, so a substitution in it can
  # never be the last one THIS statement ran and the flagged assignment's status
  # is still the one the shell takes. Left uncounted by walk() opening the
  # operand as a region; counted, it would exempt a live defect. Measured on
  # bash 3.2.57 and 5.3.15: `out=$(false) > >(echo "$(true)" >/dev/null)` exits
  # on both, and the same line with a succeeding first substitution reaches, so
  # the body's own status never reaches the parent.
  fixture_script 'set -e
out=$(some_command) > >(echo "$(other_command)" >/dev/null)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_an_input_redirection_with_no_command_word_is_reported() {
  fixture_repo
  # The one shape here whose ground truth is version-dependent, so it is a
  # documented modelling decision rather than a bound. bash 3.2 takes the
  # substitution status and exits, so the read is unreachable. bash 5 resets the
  # status to zero and carries on, so the read is reachable and ALWAYS READS
  # ZERO while `out` is empty and the command failed. Both readings are the
  # defect this gate exists to catch, approached from opposite sides, and the
  # repair it prints (`rc=0; out="$(cmd)" || rc=$?`) is correct for both, so the
  # gate reports on either. The output direction exits on both versions and is
  # covered above. Deliberately absent from the prefix matrix, which measures one
  # interpreter and would record whichever it ran as the whole truth.
  fixture_script 'set -e
out=$(some_command) < log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_redirection_whose_operand_is_quoted_is_still_reported() {
  fixture_repo
  # The regression the reverted loop introduced: its operand matcher stopped at
  # whitespace, so `> "my log"` left `log"` behind, which read as a command word
  # and certified a genuine defect clean. Confirmed against the shell:
  # `set -e; out=$(false) > "/tmp/my log"` exits.
  fixture_script 'set -e
out=$(some_command) > "my log"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_redirection_with_no_command_is_still_a_bare_assignment() {
  fixture_repo
  # The other direction of the same consumption: an empty tail means the
  # statement was the assignment plus its redirections and nothing else.
  fixture_script 'set -e
out=$(some_command) > log 2> err
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

case_a_genuine_background_still_exempts_the_statement() {
  fixture_repo
  # The discrimination above must not swallow the real control operator: a
  # backgrounded assignment does not kill the shell on failure.
  fixture_script 'set -e
out=$(some_command) &
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

case_errors_when_no_tracked_shell_matches() {
  fixture_repo_bare
  seed_workflow
  seed_bats
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'the scan surface (shell)' <<<"$output"
}

case_errors_when_no_tracked_workflow_matches() {
  fixture_repo_bare
  seed_sh
  seed_bats
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'the scan surface (workflows)' <<<"$output"
}

case_errors_when_no_tracked_bats_suite_matches() {
  fixture_repo_bare
  seed_sh
  seed_workflow
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'no tracked bats suites matched the scan surface' <<<"$output"
  grep -qF -- 'nothing was scanned' <<<"$output"
}

# The `|| exit $?` on each discovery call is the whole mechanism here. `|| exit 1`
# folds a discovery that never ran into the status the empty-surface tests above
# use for a surface this gate read and found nothing in, and an operator handed
# that would go looking at the tree. Run outside any repository, so git fails rather
# than answering empty; that is the one discovery failure a fixture can produce
# without a stub.
#
# It reaches this gate's FIRST discovery call and no later one. Failing is a
# property of the repository rather than of the pathspec, so no fixture can make
# one set's discovery fail while another's answers, and the first failure exits
# before the rest are asked. What the later calls rely on is the library reading
# each set's own status, which guard-awk-lib.bats pins on its own terms.
case_a_discovery_that_never_ran_exits_distinctly_from_an_empty_surface() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t errexit-status-lint-XXXXXX)"
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- 'discovery failed' <<<"$output" || return 1
  grep -qF -- 'nothing was scanned' <<<"$output"
}

# --- the prefix matrix, differential against a real shell -------------------
#
# Four defects landed on the env-prefix exclusion across four review rounds,
# each one a shape the previous enumeration had not reached, and the fourth
# widening was a silent fail-open. Enumerating a fifth shape by hand is the move
# that produced them, so this asserts AGREEMENT WITH THE SHELL rather than a
# remembered list: every row below is run under a real bash to see whether the
# line after the assignment is reached, and the gate's verdict has to match what
# the shell did. The ground truth is measured on every run, so a row nobody
# reasoned about correctly still fails here, and a new shape costs one line.

# probe_shell: the interpreter the ground truth is measured with, echoed on
# stdout; non-zero when none is available.
#
# Bash 4 or newer is required rather than whatever `bash` resolves to. Some rows
# use operators bash 3.2 cannot PARSE at all (`&>>` is bash 4.0+), and a shell
# that cannot parse a row measures nothing about it. Resolution mirrors
# .gaia/scripts/bats5.sh, which the project's bats rule already routes these
# suites through.
probe_shell() {
  local candidate major
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$( command -v bash )"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    major="$( "$candidate" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null )"
    case "$major" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$major" -ge 4 ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# prefix_reaches <shell> <suffix>: the ground truth, as three outcomes rather
# than two.
#
#   0  a real shell runs past the assignment: the prefixed command's status is
#      the one it takes, the `$?` read below is live, and the gate must stay
#      quiet.
#   1  errexit kills the script on the assignment: the class, and the gate must
#      report.
#   2  the shell could not PARSE the row, so nothing about it was measured.
#
# The third outcome is what keeps the matrix from certifying itself. Folding an
# unparseable row into `report` makes a syntax error indistinguishable from
# errexit firing, so a row edited into nonsense reads as measured ground truth
# and greens against a gate that is also reporting, having established nothing.
# That is the same fail-open the gate under test refuses to commit when it loses
# tokenizer sync, and the matrix owes the same answer.
#
# `log` and `my log` are pre-created so a `<` redirection fails on nothing but
# the shape under test.
#
# A PROCESS SUBSTITUTION row picks its operand carefully: the row is EXECUTED
# here, so `<(cat)` would leave cat reading the stdin this probe inherits and the
# whole suite blocks forever. That is the same stdin-inheritance trap the fd-9
# read below exists for, reached from the other end. Every such row names a
# command that terminates on its own: `<(echo x)` writes and exits, and
# `>(cat >/dev/null)` reads the pipe to EOF.
#
# Two shapes the gate handles are deliberately absent from this matrix rather
# than forgotten, both because a measured row would record something untrue.
# `out=$(false) FOO=$(false)` has no static answer at all, since it is the same
# shape as the `FOO=$(true)` row and differs only in a runtime status. `< log`
# with no command word has no version-stable one, since bash 3.2 exits and bash 5
# carries on, so a row measured under whichever interpreter this probe resolved
# would pin that interpreter's answer as the gate's contract. Both are pinned by
# named tests above instead, and the script header carries the reasoning.
prefix_reaches() {
  local shell_path="$1" suffix="$2" directory probe_output
  directory="$(mktemp -d -t errexit-status-probe-XXXXXX)"
  : > "$directory/log"
  : > "$directory/my log"
  printf '%s\n' 'set -e' "out=\$(false) $suffix" 'rc=$?' 'echo REACHED' > "$directory/probe.sh"
  if ! "$shell_path" -n "$directory/probe.sh" 2>/dev/null; then
    rm -rf "$directory"
    return 2
  fi
  probe_output="$( cd "$directory" && "$shell_path" probe.sh 2>/dev/null || true )"
  rm -rf "$directory"
  case "$probe_output" in *REACHED*) return 0 ;; *) return 1 ;; esac
}

# prefix_verdict <suffix>: set PREFIX_VERDICT to the gate's verdict on the same
# body. `error` rather than `report` when the gate exits non-zero without the
# location pin, so a desync is told apart from a verdict.
prefix_verdict() {
  PREFIX_VERDICT=""
  fixture_repo
  fixture_script "set -e
out=\$(false) $1
rc=\$?
echo \"\$rc\""
  run_linter
  rm -rf "$TEMPORARY_DIRECTORY"
  TEMPORARY_DIRECTORY=""
  if [ "$status" -eq 0 ]; then
    PREFIX_VERDICT=quiet
  elif grep -qF -- 'check.sh:3:' <<<"$output"; then
    PREFIX_VERDICT=report
  else
    PREFIX_VERDICT=error
  fi
}

case_follows_a_continued_assignment_in_a_tracked_script() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command \
  --flag)
rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

case_follows_a_continued_assignment_in_a_git_hook() {
  fixture_repo
  fixture_file .githooks/pre-commit 'set -e
out=$(some_command \
  --flag)
rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.githooks/pre-commit:4:' <<<"$output"
}

case_follows_a_continued_assignment_in_a_workflow_run_body() {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1 \
            --json state)
          rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/workflows/probe.yml:7:' <<<"$output"
}

case_follows_a_continued_assignment_in_a_bats_test_body() {
  fixture_repo
  fixture_file suite.bats '@test "continues" {
  out=$(some_command \
    --flag)
  rc=$?
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:4:' <<<"$output"
}

case_a_pragma_naming_this_gate_suppresses_the_instance() {
  fixture_repo
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read: the dead read IS the subject here
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_the_token_resolves_from_a_fixture_repo_without_gaia_scripts() {
  fixture_repo
  # Resolution is against the gate's OWN directory rather than a cwd-relative
  # .gaia/scripts. Read cwd-relative, every well-formed token in every fixture
  # repo would resolve as orphaned and this whole section would be vacuous.
  [ ! -d "$TEMPORARY_DIRECTORY/.gaia/scripts" ]
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read: the dead read IS the subject here
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_pragma_with_no_instance_is_reported_unused() {
  fixture_repo
  fixture_file suite.bats '@test "waives nothing" {
  # gaia-lint-ignore lint-errexit-status-read: nothing below this to waive
  echo hello
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:2: unused gaia-lint-ignore for lint-errexit-status-read' <<<"$output"
}

case_a_wrapped_reason_continues_the_pragma() {
  fixture_repo
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read: the dead read IS the subject,
  # and this second comment line continues the reason above it
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_ordinary_prose_comment_does_not_interrupt_a_pragma_block() {
  fixture_repo
  # A wrapped reason is textually an ordinary comment line, so the two cannot be
  # told apart and neither ends the block. The pragma is still honored.
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read: the dead read IS the subject here
  # an unrelated remark about something else entirely
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_blank_line_terminates_the_block_leaving_the_pragma_unused() {
  fixture_repo
  # The single stated verdict for an interrupted block, and both halves of it
  # are pinned: the pragma waives nothing, AND the instance below is reported.
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read: separated from its target

  rc=$?
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'suite.bats:3: unused gaia-lint-ignore for lint-errexit-status-read' <<<"$output"
  grep -qF -- 'suite.bats:5: `$?` read after' <<<"$output"
}

case_stacked_pragmas_both_apply_to_the_same_target() {
  fixture_repo
  # The second names this gate and the first names a sibling, so the instance is
  # waived and neither pragma is reported unused by this gate. A stack that only
  # ever honored its first member would red here.
  fixture_file suite.bats '@test "demonstrates the class" {
  out=$(some_command)
  # gaia-lint-ignore lint-git-path-quoting: a sibling class on the same line
  # gaia-lint-ignore lint-errexit-status-read: the dead read IS the subject here
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_an_orphaned_guard_token_draws_no_malformed_error() {
  fixture_repo
  # lint-git-path-quoting.sh is the designated reader for a malformed pragma,
  # because it has the widest scan surface of the three and so sees one anywhere
  # in the tree exactly once. This gate reports only the UNUSED pragma naming
  # itself, and a pragma naming a token that resolves nowhere is not that.
  fixture_file suite.bats '@test "names a guard that does not exist" {
  # gaia-lint-ignore lint-no-such-guard: names nothing that resolves
  echo hello
}'
  run_linter
  [ "$status" -eq 0 ]
}

case_a_pragma_with_no_reason_draws_no_malformed_error() {
  fixture_repo
  fixture_file suite.bats '@test "gives no reason" {
  out=$(some_command)
  # gaia-lint-ignore lint-errexit-status-read:
  rc=$?
}'
  run_linter
  grep -qF -- 'malformed gaia-lint-ignore' <<<"$output" && return 1
  true
}

case_a_pragma_above_an_instance_in_a_tracked_script_waives_nothing() {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
# gaia-lint-ignore lint-errexit-status-read: waives nothing on this surface
rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'gaia-lint-ignore is honored only in *.bats' <<<"$output"
  grep -qF -- 'check.sh:4: `$?` read after' <<<"$output"
}

case_the_same_in_a_git_hook() {
  fixture_repo
  fixture_file .githooks/pre-commit 'set -e
out=$(some_command)
# gaia-lint-ignore lint-errexit-status-read: waives nothing on this surface
rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.githooks/pre-commit:4: gaia-lint-ignore is honored only in *.bats' <<<"$output"
  grep -qF -- '.githooks/pre-commit:4: `$?` read after' <<<"$output"
}

case_the_same_in_a_workflow_run_body() {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1 --json state)
          # gaia-lint-ignore lint-errexit-status-read: waives nothing here
          rc=$?'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/workflows/probe.yml:7: gaia-lint-ignore is honored only in *.bats' <<<"$output"
  grep -qF -- '.github/workflows/probe.yml:7: `$?` read after' <<<"$output"
}

case_the_honored_nowhere_finding_fires_above_a_line_with_no_instance() {
  fixture_repo
  # Read at the print point instead of per line, this finding would be silently
  # inert over every pragma above a clean line, which is most of them. The gate
  # is otherwise clean here, so the pragma is the only thing that can red it.
  fixture_script 'set -e
# gaia-lint-ignore lint-errexit-status-read: waives nothing on this surface
echo hello'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3: gaia-lint-ignore is honored only in *.bats' <<<"$output"
}

# --- the class fires, workflow surface -------------------------------------

@test "reds against the shipped composite-action shape" {
  fixture_repo
  fixture_file .github/actions/merge-and-watch/action.yml 'runs:
  using: composite
  steps:
    - shell: bash
      run: |
        revert_out="$(gh pr view "$PR" --json state)"
        revert_rc=$?
        if [ "$revert_rc" -ne 0 ]; then
          echo "::error::revert failed" >&2
          exit 1
        fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/actions/merge-and-watch/action.yml:7:' <<<"$output"
  grep -qF -- 'the assignment takes the substitution status' <<<"$output"
}

@test "arms a run: body with no explicit set -e, because Actions runs bash -e" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1 --json state)
          rc=$?
          echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/workflows/probe.yml:6:' <<<"$output"
}

@test "leaves a run: body at the first dedent, so surrounding YAML is not shell" {
  fixture_repo
  # The `$?` sits on the FIRST line past the dedent, with nothing between it and
  # the assignment. An intervening key would consume the pending assignment as an
  # ordinary statement and leave the test green even with the dedent check
  # broken, which is the shape that made this test hollow.
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1)
        RC: $?'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- 'probe.yml' <<<"$output" && return 1
  true
}

# --- the class fires, shell surface ----------------------------------------

# bats test_tags=protected
@test "flags a quoted command-substitution assignment under set -euo pipefail" {
  fixture_repo
  fixture_script 'set -euo pipefail
out="$(some_command --json)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
  grep -qF -- 'assignment at line 2' <<<"$output"
}

@test "flags a bare \$? read after a command-substitution assignment, in every spelling" {
  run_case 'flags the unquoted spelling' case_flags_the_unquoted_spelling
  run_case 'flags the read spelling shellcheck sees, so the two agree rather than diverge' case_flags_the_spelling_shellcheck_sees
  run_case 'flags across an intervening comment, which executes nothing' case_flags_across_an_intervening_comment
  run_case 'flags across an intervening blank line' case_flags_across_an_intervening_blank_line
  run_case 'flags a legacy backtick substitution' case_flags_a_legacy_backtick_substitution
  run_case 'flags after set -o errexit written the long way' case_flags_after_long_form_set_minus_o_errexit
  run_case 'follows a command substitution spanning several lines' case_follows_a_command_substitution_spanning_several_lines
  run_case 'flags a status read inside double quotes, which does expand' case_flags_a_status_read_inside_double_quotes
  run_case 're-arms after a set +e block closes' case_rearms_after_set_plus_e_block_closes
  run_case 'flags the one-line semicolon spelling, which separates rather than joins' case_flags_the_one_line_semicolon_spelling
  run_case 'flags an appending assignment, which takes the substitution status too' case_flags_an_appending_assignment
  run_case 'still flags a real read on a line that also carries a comment' case_flags_a_real_read_on_a_line_with_a_comment
}

# --- the legitimate shapes stay quiet --------------------------------------

@test "stays quiet on the common legitimate shapes" {
  run_case 'quiet on a script that never arms errexit' case_quiet_on_a_script_that_never_arms_errexit
  run_case 'quiet on the repair the gate own hint text advertises' case_quiet_on_the_repair_the_hint_advertises
  run_case 'quiet on a local-prefixed assignment, which shellcheck owns as SC2155' case_quiet_on_a_local_prefixed_assignment
  run_case 'quiet on export- and readonly-prefixed assignments' case_quiet_on_export_and_readonly_prefixed_assignments
  run_case 'quiet on a deferred trap capture' case_quiet_on_a_deferred_trap_capture
  run_case 'quiet while set +e holds' case_quiet_under_set_plus_e
  run_case 'quiet when a real command separates the assignment from the read' case_quiet_when_a_command_separates_assignment_and_read
  run_case 'quiet on an assignment used as an if condition' case_quiet_on_an_assignment_used_as_an_if_condition
  run_case 'quiet on an assignment with no command substitution at all' case_quiet_on_an_assignment_with_no_substitution
  run_case 'quiet on a pipeline, where the assignment is not a bare simple command' case_quiet_on_a_pipeline
  run_case 'quiet on the second statement of a line whose first is guarded' case_quiet_on_the_second_statement_when_the_first_is_guarded
  run_case 'quiet on arithmetic expansion, which runs no command and cannot trip errexit' case_quiet_on_arithmetic_expansion
  run_case 'quiet on a trailing comment that merely mentions the status variable' case_quiet_on_a_trailing_comment_mentioning_the_status
  run_case 'quiet after the long-form set +o errexit disarm' case_quiet_after_long_form_set_plus_o_errexit
}

@test "bats surface: helper, test body and fixture-write handling" {
  run_case 'flags an executed helper in a bats suite' case_flags_an_executed_helper_in_a_bats_suite
  run_case 'the same bytes are flagged in a tracked .sh, so the class is surface-independent' case_the_same_bytes_are_flagged_in_a_tracked_shell_script
  run_case 'arms a bats test body with no set -e anywhere, because bats runs it under errexit' case_arms_a_bats_test_body_without_set_minus_e
  run_case 'a set +e inside a test body still disarms from that point' case_set_plus_e_inside_a_test_body_still_disarms
  run_case 'a helper invoked only through run is not armed' case_a_helper_invoked_only_through_run_is_not_armed
  run_case 'the same helper with one plain call site is armed' case_the_same_helper_with_one_plain_call_site_is_armed
  run_case 'a helper with no call site at all is armed, which is the closed direction' case_a_helper_with_no_call_site_is_armed
  run_case 'quiet on a fixture body a suite writes through a quoted literal' case_quiet_on_a_fixture_body_written_through_a_quoted_literal
  run_case 'quiet on a fixture body written into a quoted heredoc' case_quiet_on_a_fixture_body_written_into_a_quoted_heredoc
  run_case 'executed shell beside a fixture write is still reported' case_executed_shell_beside_a_fixture_write_is_still_reported
}

# --- the tokenizer holds sync, or says it could not --------------------------
#
# These pin the detector's cross-line state. State is carried across lines
# deliberately, so a tokenizer that desyncs does not misread one statement, it
# swallows every remaining line of the file while the gate still prints `clean`.

@test "tokenizer keeps classifying past heredocs, quotes, ANSI-C and arithmetic" {
  run_case 'keeps reading past a substitution carrying a paren inside a quoted string' case_keeps_reading_past_a_paren_inside_a_quoted_string
  run_case 'follows a heredoc opened inside a command substitution' case_follows_a_heredoc_opened_inside_a_command_substitution
  run_case 'quiet on a heredoc body carrying the shape as a fixture' case_quiet_on_a_heredoc_body_carrying_the_shape_as_a_fixture
  run_case 'a set +e inside a heredoc body does not disarm the script around it' case_set_plus_e_inside_a_heredoc_body_does_not_disarm
  run_case 'an apostrophe inside a heredoc body does not swallow the rest of the file' case_an_apostrophe_inside_a_heredoc_body_does_not_swallow_the_file
  run_case 'a double-quoted string closes, so a later trap capture is still deferred' case_a_double_quoted_string_closes_before_a_later_trap_capture
  run_case 'an ANSI-C literal with an escaped quote does not swallow the rest of the file' case_an_ansi_c_literal_with_an_escaped_quote_does_not_swallow_the_file
  run_case 'the remainder after an ANSI-C literal is still classified, not merely quiet' case_the_remainder_after_an_ansi_c_literal_is_classified
  run_case 'an ANSI-C literal with no escaped quote is clean either way' case_an_ansi_c_literal_with_no_escaped_quote_is_clean
  run_case 'a quote after an escaped dollar opens an ordinary span, not an ANSI-C frame' case_a_quote_after_an_escaped_dollar_opens_an_ordinary_span
  run_case 'a dollar inside double quotes does not open an ANSI-C frame' case_a_dollar_inside_double_quotes_does_not_open_an_ansi_c_frame
  run_case 'a left shift in a bare (( )) leaves the rest of the file classified' case_a_left_shift_in_a_bare_arithmetic_command_leaves_the_file_classified
  run_case 'a left shift in a bare (( )) after an if keyword is classified too' case_a_left_shift_in_a_bare_arithmetic_command_after_if_is_classified
  run_case 'the arithmetic carve-out does not hide a hit below a real heredoc' case_the_arithmetic_carve_out_does_not_hide_a_hit_below_a_real_heredoc
  run_case 'a left shift in a for (( )) header leaves the rest of the file classified' case_a_left_shift_in_a_for_header_leaves_the_file_classified
}

@test "a file the tokenizer cannot follow to its end is reported as a desync ERROR, never certified" {
  run_case 'reports a file it could not tokenize to the end rather than certifying it' case_reports_a_file_it_could_not_tokenize_to_the_end
  run_case 'a desync report does not print the status-read repair, which is not its fix' case_a_desync_report_omits_the_status_read_repair
  run_case 'a run: body that cannot be tokenized to its end is reported, not certified' case_a_run_body_that_cannot_be_tokenized_is_reported
  run_case 'the last run: body in a file is checked for desync too' case_the_last_run_body_in_a_file_is_checked_for_desync_too
  run_case 'a bats suite the scan could not tokenize to the end is reported, not certified' case_a_bats_suite_that_cannot_be_tokenized_is_reported
  run_case 'exactly one desync line is printed for one unreadable bats file' case_one_desync_line_is_printed_for_one_unreadable_bats_file
}

# --- the git hooks arm like a script: off until the file's own set -e --------

@test "git hook surface: armed only by its own set -e, scanned once" {
  run_case 'does not flag a git hook with no set -e' case_does_not_flag_a_git_hook_with_no_set_e
  run_case 'flags a git hook once its own set -e has armed errexit' case_flags_a_git_hook_once_its_own_set_e_has_armed_errexit
  run_case 'a set +e in a git hook still disarms from that point' case_set_plus_e_in_a_git_hook_still_disarms
  run_case 'a .sh under .githooks is scanned once, not once per overlapping pathspec' case_a_sh_under_githooks_is_scanned_once
  run_case 'an ordinary tracked script is still off by default' case_an_ordinary_tracked_script_is_still_off_by_default
}

# --- assignment shapes ------------------------------------------------------

# The named cases below complement the prefix matrix: the matrix fails as one
# test naming a row, a named case says which shape broke.
@test "env-prefix and redirection shapes decide whether an assignment is bare" {
  run_case 'quiet on an env-prefix assignment, whose status belongs to the command' case_quiet_on_an_env_prefix_assignment
  run_case 'an env-prefix pair with no command is still a bare assignment' case_an_env_prefix_pair_with_no_command_is_still_a_bare_assignment
  run_case 'a redirection after the value does not read as an env prefix' case_a_redirection_after_the_value_is_not_an_env_prefix
  run_case 'a redirection carrying an explicit file descriptor is still a redirection' case_a_redirection_with_an_explicit_file_descriptor_is_still_a_redirection
  run_case 'a descriptor-duplicating redirection is not a control operator' case_a_descriptor_duplicating_redirection_is_not_a_control_operator
  run_case 'an all-streams redirection is not a control operator either' case_an_all_streams_redirection_is_not_a_control_operator
  run_case 'a redirection before the command word does not hide the env prefix' case_a_redirection_before_the_command_word_does_not_hide_the_env_prefix
  run_case 'the same with an explicit file descriptor' case_the_same_with_an_explicit_file_descriptor
  run_case 'the same behind a descriptor duplicate' case_the_same_behind_a_descriptor_duplicate
  run_case 'a >& redirection is consumed whole, so its & is not read as an operator' case_a_greater_ampersand_redirection_is_consumed_whole
  run_case 'an &> redirection reaches the loop rather than being read as an operator' case_an_ampersand_greater_redirection_reaches_the_loop
  run_case 'a further assignment before the command word is consumed, not stopped at' case_a_further_assignment_before_the_command_word_is_consumed
  run_case 'an env-prefix indented inside a function is still not the class' case_an_env_prefix_indented_inside_a_function_is_not_the_class
  run_case 'an indented BARE assignment is still flagged, so the exclusion is not blanket' case_an_indented_bare_assignment_is_still_flagged
  run_case 'an env-prefix inside a run: body is not the class either' case_an_env_prefix_inside_a_run_body_is_not_the_class
}

# The two mechanisms the prefix consumption loop does not supply on its own: the
# redirection operand that is a nested command rather than a word, and the
# knowledge of WHICH substitution ran last. Both are the quiet verdict the
# shell justifies, and both are asserted against a real shell in the prefix
# matrix test ("the gate agrees with a real shell across the prefix matrix") as
# well: the matrix fails as one test naming a row, a named case says which shape
# broke.

@test "only a later substitution that runs, or a background &, exempts the statement" {
  run_case 'a process substitution operand is followed rather than broken on' case_a_process_substitution_operand_is_followed
  run_case 'the same for an input process substitution' case_the_same_for_an_input_process_substitution
  run_case 'a later substitution in the same assignment list takes the status' case_a_later_substitution_in_the_same_assignment_list_takes_the_status
  run_case 'a later substitution in a REDIRECTION OPERAND takes the status too' case_a_later_substitution_in_a_redirection_operand_takes_the_status
  run_case 'a SINGLE-QUOTED substitution in an operand runs nothing, so it still reports' case_a_single_quoted_substitution_in_an_operand_runs_nothing
  run_case 'two substitutions in ONE assignment'\''s own value exempt it too' case_two_substitutions_in_one_assignment_value_exempt_it
  run_case 'the same for two adjacent quoted words in one value' case_the_same_for_two_adjacent_quoted_words_in_one_value
  run_case 'the same for a substitution inside a parameter expansion' case_the_same_for_a_substitution_inside_a_parameter_expansion
  run_case 'two top-level BACKTICK substitutions exempt the statement too' case_two_top_level_backtick_substitutions_exempt_the_statement
  run_case 'a BACKTICK nested inside a substitution does not count' case_a_backtick_nested_inside_a_substitution_does_not_count
  run_case 'a substitution inside a PROCESS-SUBSTITUTION operand does not count' case_a_substitution_inside_a_process_substitution_does_not_count
  run_case 'an input redirection with no command word is reported on both bash readings' case_an_input_redirection_with_no_command_word_is_reported
  run_case 'a redirection whose operand is quoted is still reported' case_a_redirection_whose_operand_is_quoted_is_still_reported
  run_case 'a redirection with no command behind it is still a bare assignment' case_a_redirection_with_no_command_is_still_a_bare_assignment
  run_case 'a genuine background & still exempts the statement' case_a_genuine_background_still_exempts_the_statement
}

# --- the gate refuses to report clean over nothing -------------------------

# Every empty-surface message carries `nothing was scanned`, so a grep for that
# phrase alone would green whichever precondition happened to fire first. Each
# assertion below names the set it is about, or it pins the wrong surface.
#
# A tree carrying no tracked hook is NOT among them: the githooks set is the one
# this gate reads tolerantly, because a repository legitimately has no hooks.

@test "an empty or failed scan-set discovery errors instead of passing" {
  run_case 'errors rather than passing when no tracked shell matches' case_errors_when_no_tracked_shell_matches
  run_case 'errors rather than passing when no tracked workflow matches' case_errors_when_no_tracked_workflow_matches
  run_case 'errors rather than passing when no tracked bats suite matches' case_errors_when_no_tracked_bats_suite_matches
  run_case 'a discovery that never ran exits distinctly from a surface that came back empty' case_a_discovery_that_never_ran_exits_distinctly_from_an_empty_surface
}

@test "the gate agrees with a real shell across the prefix matrix" {
  local suffix expected shell_path reach_status failures=""
  # Refuse to report clean over nothing, the same posture the gate itself takes
  # on a region it cannot read: with no bash 4+ to measure against, this test has
  # no ground truth and says so rather than passing.
  shell_path="$( probe_shell )" || {
    printf 'no bash 4+ available to measure ground truth; the matrix measured nothing\n'
    return 1
  }
  # Read on fd 9: the gate is run through bats `run`, which inherits stdin, and
  # a matrix on stdin would be eaten a row at a time by whatever the fixture
  # runs.
  while IFS= read -r suffix <&9; do
    # The guarded form this gate itself advertises: bats runs a test body under
    # errexit, so a bare call returning non-zero would abort the loop on the
    # first `report` row rather than recording it.
    reach_status=0
    prefix_reaches "$shell_path" "$suffix" || reach_status=$?
    case "$reach_status" in
      0) expected=quiet ;;
      1) expected=report ;;
      *) failures="$failures
  out=\$(false) $suffix    UNPARSEABLE under $shell_path, so nothing was measured"
         continue ;;
    esac
    prefix_verdict "$suffix"
    [ "$expected" = "$PREFIX_VERDICT" ] || failures="$failures
  out=\$(false) $suffix    shell: $expected    gate: $PREFIX_VERDICT"
  done 9<<'MATRIX'
> log true
>> log true
2> log true
2>&1 true
>& log true
&> log true
&>> log true
< log true
FOO=1 true
FOO=1 BAR=2 true
FOO=1 > log true
> log FOO=1 true
> "my log" true
> log#x true
> 'my log' true
FOO="a b" true
>| log true
>| log
FOO=$(true) true
true
> log
2>&1
FOO=1
> "my log"
&> log
>& log
> >(cat >/dev/null) true
< <(echo x) true
> >(cat >/dev/null)
> >(echo "$(true)" >/dev/null)
FOO=$(true)
> "$(echo ab)"
> $(echo ab)
> log$(echo x)
> '$(echo ab)'
MATRIX
  [ -z "$failures" ] || {
    printf 'prefix matrix disagreements:%s\n' "$failures"
    return 1
  }
}

# --- a backslash continuation is followed on every surface ------------------
#
# Measured: this gate reports an instance whose assignment spans a continuation,
# and does NOT report one inside a heredoc body, which it swallows as data on
# every surface by design. Only the reported direction is demanded here.

@test "a continued assignment is followed on every surface" {
  run_case 'follows a continued assignment in a tracked script' case_follows_a_continued_assignment_in_a_tracked_script
  run_case 'follows a continued assignment in a git hook' case_follows_a_continued_assignment_in_a_git_hook
  run_case 'follows a continued assignment in a workflow run: body' case_follows_a_continued_assignment_in_a_workflow_run_body
  run_case 'follows a continued assignment in a bats test body' case_follows_a_continued_assignment_in_a_bats_test_body
}

# --- the suppression pragma, honored in *.bats and nowhere else -------------
#
# The pragma is written into fixture bodies below rather than into this file, so
# none of it is live here. Every one names this gate by its own script basename;
# the token resolves against the REAL .gaia/scripts beside the gate, which is
# what lets these fixture repos carry no .gaia/scripts of their own.

@test "pragma suppression and unused/honored-nowhere reporting" {
  run_case 'a pragma naming this gate suppresses the instance below it' case_a_pragma_naming_this_gate_suppresses_the_instance
  run_case 'the token resolves from a fixture repo carrying no .gaia/scripts of its own' case_the_token_resolves_from_a_fixture_repo_without_gaia_scripts
  run_case 'a pragma whose target carries no instance is reported as unused' case_a_pragma_with_no_instance_is_reported_unused
  run_case 'a wrapped reason continues the pragma rather than ending it' case_a_wrapped_reason_continues_the_pragma
  run_case 'an ordinary prose comment does not interrupt a pragma block' case_an_ordinary_prose_comment_does_not_interrupt_a_pragma_block
  run_case 'a blank line terminates the block, leaving the pragma unused' case_a_blank_line_terminates_the_block_leaving_the_pragma_unused
  run_case 'stacked pragmas both apply to the same target' case_stacked_pragmas_both_apply_to_the_same_target
  run_case 'an orphaned guard token draws no malformed error from this gate' case_an_orphaned_guard_token_draws_no_malformed_error
  run_case 'a pragma with no reason draws no malformed error from this gate either' case_a_pragma_with_no_reason_draws_no_malformed_error
  run_case 'a pragma above an instance in a tracked script waives nothing and says so' case_a_pragma_above_an_instance_in_a_tracked_script_waives_nothing
  run_case 'the same in a git hook' case_the_same_in_a_git_hook
  run_case 'the same in a workflow run: body' case_the_same_in_a_workflow_run_body
  run_case 'the honored-nowhere finding fires above a line carrying no instance' case_the_honored_nowhere_finding_fires_above_a_line_with_no_instance
}
