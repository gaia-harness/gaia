#!/usr/bin/env bats
#
# Suite for the offer mode of .gaia/scripts/debt-batch-budget.sh, the linear
# first-fit walk behind the /gaia-debt budget batch. The backlog is a kept
# ordered array in the ordering query's shape, the report is always produced by
# the real debt-backlog.sh over it, and the probe report is hand-written except
# in the one test that runs the real debt-path-probe.sh.
#
# The script is resolved from DEBT_BATCH_BUDGET_SCRIPT when set, so a mutated
# scratch copy can be run through the same assertions to prove they can fail.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-batch-budget-offer.bats

bats_require_minimum_version 1.5.0

# The 300-issue walks are the slowest cases; a runaway loop fails the suite
# instead of hanging it.
export BATS_TEST_TIMEOUT=60

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_SCRIPT="$SCRIPTS_DIRECTORY/debt-batch-budget.sh"
  SCRIPT="${DEBT_BATCH_BUDGET_SCRIPT:-$REAL_SCRIPT}"
  BACKLOG_SCRIPT="$SCRIPTS_DIRECTORY/debt-backlog.sh"
  PROBE_SCRIPT="$SCRIPTS_DIRECTORY/debt-path-probe.sh"
  BACKLOG="$BATS_TEST_TMPDIR/backlog.json"
  REPORT="$BATS_TEST_TMPDIR/report.json"
  PROBE="$BATS_TEST_TMPDIR/probe.json"
  export SCRIPT
}

# fixture <file>: reads one issue per line from stdin and writes the kept array
# in one jq call. A line is `number difficulty footprint path class [sev]`,
# with `-` for a null difficulty, footprint or path; sev defaults to 1.
fixture() {
  jq -Rn '[inputs | select(length > 0) | split(" ") as $f
    | {number: ($f[0] | tonumber), sev: (if $f[5] == null then 1 else ($f[5] | tonumber) end),
       difficulty: (if $f[1] == "-" then null else $f[1] end),
       footprint: (if $f[2] == "-" then null else $f[2] end),
       labels: [],
       key: (if $f[3] == "-" then null else {class: $f[4], path: $f[3], line: 1} end),
       body: "no path cited here"}]' >"$1"
}

# make_report: the real backlog pass over $BACKLOG, written to $REPORT.
make_report() {
  bash "$BACKLOG_SCRIPT" --backlog "$BACKLOG" >"$REPORT"
}

# offer [args...]: offer mode over $BACKLOG and $REPORT, no withheld numbers.
offer() {
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "" "$@"
}

# offer_members: the member list of $output as a space-joined string.
offer_members() {
  printf '%s' "$output" | jq -r '.members | map(tostring) | join(" ")'
}

# numbered_lines <count> <body...>: `<n> <body>` lines for 1..count, for the
# large fixtures.
numbered_lines() {
  local count="$1"
  shift
  awk -v count="$count" -v body="$*" 'BEGIN { for (n = 1; n <= count; n++) { line = body; gsub(/@/, n, line); print n " " line } }'
}

# True when the offer program of a script calls the subset enumeration.
offer_program_calls_fitting() {
  awk '/^offer_program=/ { inside = 1 } /^# run_offer/ { inside = 0 } inside' "$1" >"$BATS_TEST_TMPDIR/offer-region.txt"
  [ -s "$BATS_TEST_TMPDIR/offer-region.txt" ] || return 2
  grep -q 'fitting' "$BATS_TEST_TMPDIR/offer-region.txt"
}

# twelve_issues: the walk fixture. Parts in order: a five-member cluster worth
# 13, a wide easy singleton, another, a hard singleton, a two-member cluster of
# narrow easy issues, then two hard singletons.
twelve_issues() {
  fixture "$BACKLOG" <<'EOF'
1 medium narrow src/a/x.ts class-a
2 easy wide src/b/one.ts class-b
3 medium narrow src/a/x.ts class-a
4 medium narrow src/a/x.ts class-a
5 easy narrow src/a/x.ts class-a
6 easy wide src/c/two.ts class-c
7 easy narrow src/a/x.ts class-a
8 hard narrow src/e/three.ts class-e
9 easy narrow src/d/y.ts class-d
10 easy narrow src/d/y.ts class-d
11 hard narrow src/f/four.ts class-f
12 hard narrow src/g/five.ts class-g
EOF
  make_report
}

# three_singletons: three eligible parts that fit together, for the refusals.
three_singletons() {
  fixture "$BACKLOG" <<'EOF'
1 easy narrow src/a/one.ts class-a
2 easy narrow src/b/two.ts class-b
3 easy narrow src/c/three.ts class-c
EOF
  make_report
}

# --- the walk

@test "the twelve-issue walk skips the over-budget cluster whole and continues" {
  twelve_issues
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "2 6 9 10" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
  [ "$(printf '%s' "$output" | jq -r '.budget')" = "12" ]
  [ "$(printf '%s' "$output" | jq -c '.parts')" = "[[2],[6],[9,10]]" ]
}

@test "the skipped cluster really costs more than the budget on the named path" {
  twelve_issues
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" 1 3 4 5 7
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "13" ]
}

@test "the mixed fixture offers exactly the three eligible issues in backlog order" {
  fixture "$BACKLOG" <<'EOF'
1 medium narrow src/a/one.ts class-a
2 hard narrow src/b/two.ts class-b
3 medium narrow src/c/three.ts class-c
4 easy spec src/d/four.ts class-d
5 medium narrow src/e/five.ts class-e 2
6 easy narrow src/f/six.ts class-f 3
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 3" ]
}

@test "the mixed fixture with a third eligible issue prints all three, total 9" {
  fixture "$BACKLOG" <<'EOF'
1 medium narrow src/a/one.ts class-a
2 hard narrow src/b/two.ts class-b
3 medium narrow src/c/three.ts class-c
4 easy spec src/d/four.ts class-d
5 medium narrow src/e/five.ts class-e 2
6 medium narrow src/f/six.ts class-f
7 easy narrow src/g/seven.ts class-g 3
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 3 6" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "9" ]
}

# --- one ineligibility kind at a time: a cluster of two where one member
# carries the kind, plus two eligible singletons.

cluster_with_one_ineligible() {
  # $1 is the second member's `difficulty footprint sev` triple.
  local difficulty footprint sev
  read -r difficulty footprint sev <<<"$1"
  fixture "$BACKLOG" <<EOF
1 easy narrow src/a/x.ts class-a
2 $difficulty $footprint src/a/x.ts class-a $sev
3 easy narrow src/b/two.ts class-b
4 easy narrow src/c/three.ts class-c
EOF
  make_report
}

assert_cluster_dropped_singletons_kept() {
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "3 4" ]
}

@test "a severity:major cluster member drops the whole cluster" {
  cluster_with_one_ineligible "easy narrow 2"
  offer
  assert_cluster_dropped_singletons_kept
}

@test "a severity:critical cluster member drops the whole cluster" {
  cluster_with_one_ineligible "easy narrow 3"
  offer
  assert_cluster_dropped_singletons_kept
}

@test "a difficulty:hard cluster member drops the whole cluster" {
  cluster_with_one_ineligible "hard narrow 1"
  offer
  assert_cluster_dropped_singletons_kept
}

@test "a footprint:spec cluster member drops the whole cluster" {
  cluster_with_one_ineligible "easy spec 1"
  offer
  assert_cluster_dropped_singletons_kept
}

@test "a gone-path cluster member drops the whole cluster" {
  cluster_with_one_ineligible "easy narrow 1"
  printf '[{"number":1,"path":"src/a/x.ts","status":"tracked"},{"number":2,"path":"src/a/x.ts","status":"gone"}]' >"$PROBE"
  offer --probe-report "$PROBE"
  assert_cluster_dropped_singletons_kept
}

@test "a withheld cluster member drops the whole cluster" {
  cluster_with_one_ineligible "easy narrow 1"
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "2"
  assert_cluster_dropped_singletons_kept
}

@test "the cluster fixture keeps all four when nothing is ineligible" {
  cluster_with_one_ineligible "easy narrow 1"
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4" ]
}

# --- empty results

@test "a single eligible cluster is one part and prints an empty list" {
  fixture "$BACKLOG" <<'EOF'
1 easy narrow src/a/x.ts class-a
2 easy narrow src/a/x.ts class-a
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '{members, parts, total}')" = '{"members":[],"parts":[],"total":0}' ]
}

@test "two clusters of seven points each fit one at a time and print an empty list" {
  fixture "$BACKLOG" <<'EOF'
1 medium narrow src/a/x.ts class-a
2 easy narrow src/a/x.ts class-a
3 easy narrow src/a/x.ts class-a
4 medium narrow src/b/y.ts class-b
5 easy narrow src/b/y.ts class-b
6 easy narrow src/b/y.ts class-b
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.members')" = "[]" ]
}

@test "a thirteen-point cluster beside one singleton prints an empty list" {
  fixture "$BACKLOG" <<'EOF'
1 medium narrow src/a/x.ts class-a
2 medium narrow src/a/x.ts class-a
3 medium narrow src/a/x.ts class-a
4 easy narrow src/a/x.ts class-a
5 easy narrow src/a/x.ts class-a
6 easy narrow src/b/one.ts class-b
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.members')" = "[]" ]
}

@test "a backlog with no eligible issue prints an empty list" {
  fixture "$BACKLOG" <<'EOF'
1 hard narrow src/a/one.ts class-a
2 easy spec src/b/two.ts class-b
3 easy narrow src/c/three.ts class-c 2
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.members')" = "[]" ]
}

@test "an empty backlog prints an empty list" {
  printf '[]' >"$BACKLOG"
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.members')" = "[]" ]
}

# --- one scoring authority

@test "six easy wide issues in one directory fit with waivers, and the named path agrees" {
  fixture "$BACKLOG" <<'EOF'
1 easy wide src/w/a.ts class-1
2 easy wide src/w/b.ts class-2
3 easy wide src/w/c.ts class-3
4 easy wide src/w/d.ts class-4
5 easy wide src/w/e.ts class-5
6 easy wide src/w/f.ts class-6
EOF
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4 5 6" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" 1 2 3 4 5 6
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
  [ "$(printf '%s' "$output" | jq -r '.verdict')" = "fits" ]
}

@test "a lowered limit and a raised easy cost each shift the walk by that one edit" {
  fixture "$BACKLOG" <<'EOF'
1 easy wide src/w/a.ts class-1
2 easy wide src/w/b.ts class-2
3 easy wide src/w/c.ts class-3
4 easy wide src/w/d.ts class-4
5 easy wide src/w/e.ts class-5
6 easy wide src/w/f.ts class-6
EOF
  make_report
  local lowered="$BATS_TEST_TMPDIR/lowered.sh" raised="$BATS_TEST_TMPDIR/raised.sh"
  sed 's/^DEBT_BUDGET_LIMIT=12/DEBT_BUDGET_LIMIT=8/' "$REAL_SCRIPT" >"$lowered"
  sed 's/^DEBT_BUDGET_COST_EASY=2/DEBT_BUDGET_COST_EASY=3/' "$REAL_SCRIPT" >"$raised"
  [ "$(diff "$REAL_SCRIPT" "$lowered" | grep -c '^[<>]')" -eq 2 ]
  [ "$(diff "$REAL_SCRIPT" "$raised" | grep -c '^[<>]')" -eq 2 ]

  run --separate-stderr bash "$lowered" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "8" ]

  run --separate-stderr bash "$raised" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
}

# --- a long backlog

@test "a 300-issue backlog walks to the first four" {
  numbered_lines 300 'medium narrow src/d@/file.ts class-@' | fixture "$BACKLOG"
  [ "$(jq 'length' "$BACKLOG")" -eq 300 ]
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
}

@test "a 300-issue variant skips 4 to 299 and still reaches the last" {
  {
    numbered_lines 3 'medium narrow src/d@/file.ts class-@'
    numbered_lines 296 'medium wide src/e@/file.ts class-e@' | awk '{ $1 = $1 + 3; print }'
    echo "300 medium narrow src/z/file.ts class-z"
  } | fixture "$BACKLOG"
  [ "$(jq 'length' "$BACKLOG")" -eq 300 ]
  make_report
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 300" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
}

# --- the withheld input

@test "no --withheld exits non-zero with empty stdout" {
  three_singletons
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an explicitly empty --withheld keeps the issue and its number withheld removes it" {
  three_singletons
  offer
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3" ]
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "2"
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 3" ]
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "1,3"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.members')" = "[]" ]
}

# --- the probe report

@test "a gone path removes its issue, and no probe report equals an all-tracked one" {
  three_singletons
  printf '[{"number":1,"path":"src/a/one.ts","status":"tracked"},{"number":2,"path":"src/b/two.ts","status":"gone"},{"number":3,"path":"src/c/three.ts","status":"tracked"}]' >"$PROBE"
  offer --probe-report "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 3" ]

  printf '[{"number":1,"path":"src/a/one.ts","status":"tracked"},{"number":2,"path":"src/b/two.ts","status":"tracked"},{"number":3,"path":"src/c/three.ts","status":"tracked"}]' >"$PROBE"
  offer --probe-report "$PROBE"
  local tracked="$output"
  [ "$status" -eq 0 ]
  offer
  [ "$status" -eq 0 ]
  [ "$output" = "$tracked" ]
  [ "$(offer_members)" = "1 2 3" ]
}

@test "the real path probe's report drives the scorer" {
  local repository="$BATS_TEST_TMPDIR/repository"
  mkdir -p "$repository/src"
  git -C "$repository" init -q
  printf 'x' >"$repository/src/a.ts"
  printf 'x' >"$repository/src/c.ts"
  git -C "$repository" add src/a.ts src/c.ts
  fixture "$BACKLOG" <<'EOF'
1 easy narrow src/a.ts class-a
2 easy narrow src/gone.ts class-b
3 easy narrow src/c.ts class-c
EOF
  make_report
  (cd "$repository" && bash "$PROBE_SCRIPT" <"$BACKLOG" >"$PROBE")
  [ "$(jq -r '[.[] | select(.status == "gone") | .number] | join(",")' "$PROBE")" = "2" ]
  offer --probe-report "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 3" ]
}

# --- output shape

@test "a success document holds exactly members, total, budget and parts, with no stderr" {
  twelve_issues
  offer
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["budget","members","parts","total"]' ]
  [ -z "$stderr" ]
}

@test "an empty result has the same four keys" {
  printf '[]' >"$BACKLOG"
  make_report
  offer
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["budget","members","parts","total"]' ]
  [ -z "$stderr" ]
}

# --- refusals: exit 2 with empty stdout

assert_refused() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  case "$stderr" in "debt-batch-budget: "*) ;; *) return 1 ;; esac
}

@test "a positional issue number with --offer is refused" {
  three_singletons
  offer 1
  assert_refused
}

@test "each offer-only flag without --offer is refused" {
  three_singletons
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" --report "$REPORT" 1
  assert_refused
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" --withheld "" 1
  assert_refused
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" --probe-report "$PROBE" 1
  assert_refused
}

@test "offer mode without --backlog or --report is refused" {
  three_singletons
  run --separate-stderr bash "$SCRIPT" --offer --report "$REPORT" --withheld ""
  assert_refused
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --withheld ""
  assert_refused
}

@test "malformed withheld numbers are refused" {
  three_singletons
  local bad
  for bad in abc 01 0 -1 "1,,2" "1," ",1" "," "1 2" "1.5"; do
    run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "$bad"
    assert_refused
  done
}

@test "a repeated withheld number is refused" {
  three_singletons
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "1,2,1"
  assert_refused
}

@test "a withheld number not in the backlog is refused" {
  three_singletons
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "99"
  assert_refused
}

@test "a cluster member absent from the candidates is refused" {
  three_singletons
  printf '{"candidates":[1,2,3],"excluded":{},"clusters":[{"members":[1,9],"paths":["x"],"signal":"path"}],"spec_class":[]}' >"$REPORT"
  offer
  assert_refused
}

@test "a candidate absent from the backlog is refused" {
  three_singletons
  printf '{"candidates":[1,2,3,99],"excluded":{},"clusters":[],"spec_class":[]}' >"$REPORT"
  offer
  assert_refused
}

@test "a candidate without a numeric sev is refused" {
  three_singletons
  jq '(.[1].sev) = "high"' "$BACKLOG" >"$BACKLOG.next" && mv "$BACKLOG.next" "$BACKLOG"
  make_report
  offer
  assert_refused
}

@test "correct JSON of the wrong shape is refused, not unreadable" {
  three_singletons
  printf '{}' >"$BACKLOG"
  run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  assert_refused
  three_singletons
  printf '[]' >"$REPORT"
  offer
  assert_refused
  three_singletons
  printf '{}' >"$PROBE"
  offer --probe-report "$PROBE"
  assert_refused
}

# --- unreadable input: exit 3 with empty stdout

assert_unreadable() {
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "a missing, empty or non-JSON named file is unreadable" {
  three_singletons
  local file_flag state
  for file_flag in backlog report probe; do
    for state in missing empty whitespace not-json; do
      local target="$BATS_TEST_TMPDIR/$file_flag-$state.json"
      case "$state" in
        missing) ;;
        empty) : >"$target" ;;
        whitespace) printf '  \n' >"$target" ;;
        not-json) printf 'not json {' >"$target" ;;
      esac
      case "$file_flag" in
        backlog) run --separate-stderr bash "$SCRIPT" --offer --backlog "$target" --report "$REPORT" --withheld "" ;;
        report) run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$target" --withheld "" ;;
        probe) run --separate-stderr bash "$SCRIPT" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld "" --probe-report "$target" ;;
      esac
      assert_unreadable
    done
  done
}

# --- data, not command text

@test "a hostile key path is carried as data and never executed" {
  local canary="$BATS_TEST_TMPDIR/canary" hostile
  hostile="src/\$(touch $canary)/\`touch $canary\`/\"x\"'y'.ts"
  jq -n --arg hostile "$hostile" '[
    {number: 1, sev: 1, difficulty: "easy", footprint: "narrow", labels: [],
     key: {class: "holistic/unclassified", path: $hostile, line: 1}, body: "b"},
    {number: 2, sev: 1, difficulty: "easy", footprint: "narrow", labels: [],
     key: {class: "holistic/unclassified", path: $hostile, line: 2}, body: "b"},
    {number: 3, sev: 1, difficulty: "easy", footprint: "narrow", labels: [],
     key: {class: "c3", path: "src/c.ts", line: 1}, body: "b"},
    {number: 4, sev: 1, difficulty: "easy", footprint: "narrow", labels: [],
     key: {class: "c4", path: "src/d.ts", line: 1}, body: "b"}]' >"$BACKLOG"
  make_report
  [ "$(jq -c '.clusters | map(.members)' "$REPORT")" = "[[1,2]]" ]
  jq -n --arg hostile "$hostile" '[{number: 1, path: $hostile, status: "tracked"},
    {number: 2, path: $hostile, status: "tracked"}]' >"$PROBE"
  offer --probe-report "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(offer_members)" = "1 2 3 4" ]
  [ ! -e "$canary" ]
}

# --- structure

@test "the offer program does not call the subset enumeration" {
  run offer_program_calls_fitting "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the structure check goes red on a copy seeded with the call" {
  local seeded="$BATS_TEST_TMPDIR/seeded.sh"
  sed 's/^def run:$/def run: fitting(0; {}) | /' "$REAL_SCRIPT" >"$seeded"
  [ "$(diff "$REAL_SCRIPT" "$seeded" | grep -c '^[<>]')" -eq 2 ]
  run offer_program_calls_fitting "$seeded"
  [ "$status" -eq 0 ]
}

# --- guards must fail: each mutated copy loses a UAT

@test "the eligibility filter can fail: dropping the severity test admits a major cluster member" {
  local mutated="$BATS_TEST_TMPDIR/mutated-eligibility.sh"
  sed 's/\$issue\.sev == 1/true/' "$REAL_SCRIPT" >"$mutated"
  [ "$(diff "$REAL_SCRIPT" "$mutated" | grep -c '^[<>]')" -eq 2 ]
  cluster_with_one_ineligible "easy narrow 2"
  DEBT_BATCH_BUDGET_SCRIPT="$mutated" run --separate-stderr bash "$mutated" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  [ "$(offer_members)" != "3 4" ]
}

@test "the whole-or-nothing rule can fail: admitting a part with any eligible member keeps the cluster" {
  local mutated="$BATS_TEST_TMPDIR/mutated-cluster.sh"
  sed 's/map(select(all(\.\[\]; eligible(\.))))/map(select(any(.[]; eligible(.))))/' "$REAL_SCRIPT" >"$mutated"
  [ "$(diff "$REAL_SCRIPT" "$mutated" | grep -c '^[<>]')" -eq 2 ]
  cluster_with_one_ineligible "hard narrow 1"
  run --separate-stderr bash "$mutated" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  [ "$(offer_members)" != "3 4" ]
}

@test "the continue-past-a-skip rule can fail: stopping at the first skip loses the later parts" {
  local mutated="$BATS_TEST_TMPDIR/mutated-walk.sh"
  sed -e 's/if total_of(\$trial;/if (.halted | not) and total_of($trial;/' \
    -e 's/else \. end)) as \$walk/else . + {halted: true} end)) as $walk/' "$REAL_SCRIPT" >"$mutated"
  [ "$(diff "$REAL_SCRIPT" "$mutated" | grep -c '^[<>]')" -eq 4 ]
  twelve_issues
  run --separate-stderr bash "$mutated" --offer --backlog "$BACKLOG" --report "$REPORT" --withheld ""
  [ "$(offer_members)" != "2 6 9 10" ]
}
