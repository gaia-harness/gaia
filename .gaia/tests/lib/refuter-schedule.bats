#!/usr/bin/env bats
# The refuter scheduler decides, as each lens finishes, which refuters start
# now, and must print the same dispatches and append the same coverage records
# for any finish order. Fixture findings carry neutral titles; only ids and
# severities matter.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is release-excluded.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/spec/refuter-schedule.mjs"
  [ -f "$SCRIPT" ] || return 1
  FINDINGS="$BATS_TEST_TMPDIR/findings"
  VERDICTS="$BATS_TEST_TMPDIR/verdicts"
  mkdir -p "$FINDINGS"
}

# make_lens <LENS> <material count> [minor count]: findings file LENS-001...
make_lens() {
  local lens="$1" material="$2" minor="${3:-0}" i severity entries=""
  for ((i = 1; i <= material; i++)); do
    severity=critical
    [ $((i % 2)) -eq 0 ] && severity=major
    entries+="$(printf '{"id":"%s-%03d","severity":"%s","title":"Neutral title"},' "$lens" "$i" "$severity")"
  done
  for ((i = 1; i <= minor; i++)); do
    entries+="$(printf '{"id":"%s-m%03d","severity":"minor","title":"Neutral title"},' "$lens" "$i")"
  done
  printf '{"dimension":"%s","findings":[%s]}\n' "$lens" "${entries%,}" >"$FINDINGS/$lens.json"
}

# finish <dir> <kind> <tier> <lenses> <lens>: one scheduler call in run dir <dir>.
finish() {
  local dir="$1"
  mkdir -p "$dir"
  touch "$dir/out.txt" "$dir/coverage.jsonl"
  node "$SCRIPT" finished --state "$dir/state.json" --kind "$2" --tier "$3" \
    --lenses "$4" --findings-dir "$FINDINGS" --verdicts-dir "$VERDICTS" \
    --coverage "$dir/coverage.jsonl" --lens "$5" >>"$dir/out.txt"
}

# run_order <dir> <kind> <tier> <lenses> <lens>...: finish the lenses in order.
run_order() {
  local dir="$1" kind="$2" tier="$3" lenses="$4" lens
  shift 4
  rm -rf "$dir"
  for lens in "$@"; do
    finish "$dir" "$kind" "$tier" "$lenses" "$lens" || return 1
  done
  sort "$dir/out.txt" >"$dir/out.sorted"
  sort "$dir/coverage.jsonl" >"$dir/coverage.sorted"
}

ids_of() {
  local lens="$1" from="$2" to="$3" i out=""
  for ((i = from; i <= to; i++)); do out+="$(printf '%s-%03d,' "$lens" "$i")"; done
  printf '%s' "${out%,}"
}

@test "dispatched refuter pairs and coverage records match the barrier run for every completion order" {
  local fixture tier first second third permutation records covered
  local -a orders=("FG TST COV" "FG COV TST" "TST FG COV" "TST COV FG" "COV FG TST" "COV TST FG")
  for fixture in "standard 2 2 2" "standard 9 8 8" "deep 3 3 2"; do
    read -r tier first second third <<<"$fixture"
    make_lens FG "$first" 1
    make_lens TST "$second" 1
    make_lens COV "$third" 1
    run_order "$BATS_TEST_TMPDIR/barrier" spec "$tier" FG,TST,COV FG TST COV || return 1
    [ -s "$BATS_TEST_TMPDIR/barrier/out.txt" ] || return 1
    for permutation in "${orders[@]}"; do
      # shellcheck disable=SC2086 # the order is a word list on purpose
      run_order "$BATS_TEST_TMPDIR/order" spec "$tier" FG,TST,COV $permutation || return 1
      diff "$BATS_TEST_TMPDIR/barrier/out.sorted" "$BATS_TEST_TMPDIR/order/out.sorted" || return 1
      diff "$BATS_TEST_TMPDIR/barrier/coverage.sorted" "$BATS_TEST_TMPDIR/order/coverage.sorted" || return 1
    done
    records=$(grep -c '"phase":"refuter"' "$BATS_TEST_TMPDIR/barrier/coverage.jsonl")
    covered=$(grep -c '"phase":"refuter".*"finding_ids":\["' "$BATS_TEST_TMPDIR/barrier/coverage.jsonl")
    [ "$records" -gt 0 ] || return 1
    [ "$records" -eq "$covered" ] || return 1
  done
}

@test "cap thresholds and the critic skip rule match the playbook" {
  local lens i count ids paths expected_lines expected_records dir

  # Standard 24: single per finding, 24 records
  make_lens FG 8; make_lens TST 8; make_lens COV 8
  run_order "$BATS_TEST_TMPDIR/s24" spec standard FG,TST,COV FG TST COV || return 1
  dir="$BATS_TEST_TMPDIR/s24"
  expected_lines=""; expected_records=""
  for lens in FG TST COV; do
    for ((i = 1; i <= 8; i++)); do
      expected_lines+="$(printf 'refuter\t%s\tsingle\t%s-%03d\t-\t%s/%s-%03d.json\n' "$lens" "$lens" "$i" "$VERDICTS" "$lens" "$i")"$'\n'
      expected_records+="$(printf '{"phase":"refuter","lens":"%s","disposition":"first_pass","finding_ids":["%s-%03d"]}\n' "$lens" "$lens" "$i")"$'\n'
    done
  done
  [ "$(printf '%s' "$expected_lines" | sort)" = "$(cat "$dir/out.sorted")" ] || return 1
  [ "$(printf '%s' "$expected_records" | sort)" = "$(cat "$dir/coverage.sorted")" ] || return 1

  # Standard 25: one batched per lens with a material finding
  make_lens FG 9; make_lens TST 8; make_lens COV 8
  run_order "$BATS_TEST_TMPDIR/s25" spec standard FG,TST,COV FG TST COV || return 1
  dir="$BATS_TEST_TMPDIR/s25"
  expected_lines=""; expected_records=""
  for lens in FG TST COV; do
    count=8
    [ "$lens" = FG ] && count=9
    ids=$(ids_of "$lens" 1 "$count")
    paths=""
    for ((i = 1; i <= count; i++)); do paths+="$(printf '%s/%s-%03d.json,' "$VERDICTS" "$lens" "$i")"; done
    expected_lines+="$(printf 'refuter\t%s\tbatched\t%s\t-\t%s\n' "$lens" "$ids" "${paths%,}")"$'\n'
    expected_records+="$(printf '{"phase":"refuter","lens":"%s","disposition":"first_pass","finding_ids":["%s"]}\n' "$lens" "${ids//,/\",\"}")"$'\n'
  done
  [ "$(printf '%s' "$expected_lines" | sort)" = "$(cat "$dir/out.sorted")" ] || return 1
  [ "$(printf '%s' "$expected_records" | sort)" = "$(cat "$dir/coverage.sorted")" ] || return 1

  # Deep 8: three per finding, 8 records, critic run
  make_lens FG 3; make_lens TST 3; make_lens COV 2
  run_order "$BATS_TEST_TMPDIR/d8" spec deep FG,TST,COV FG TST COV || return 1
  dir="$BATS_TEST_TMPDIR/d8"
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 24 ] || return 1
  [ "$(grep -c "	deep	" "$dir/out.txt")" -eq 24 ] || return 1
  [ "$(grep -c "^refuter	FG	deep	FG-001	correctness	$VERDICTS/FG-001-correctness.json\$" "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(grep -c "^refuter	FG	deep	FG-001	security/safety	$VERDICTS/FG-001-security-safety.json\$" "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(grep -c "^refuter	FG	deep	FG-001	reproduces-as-described	$VERDICTS/FG-001-reproduces-as-described.json\$" "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(wc -l <"$dir/coverage.jsonl" | tr -d ' ')" -eq 8 ] || return 1
  [ "$(grep -c '^critic run$' "$dir/out.txt")" -eq 1 ] || return 1
  grep -q 'critic skip' "$dir/out.txt" && return 1
  grep -q 'completeness' "$dir/coverage.jsonl" && return 1

  # Deep 9: one deep-batched per lens, critic skip with its record
  make_lens FG 3; make_lens TST 3; make_lens COV 3
  run_order "$BATS_TEST_TMPDIR/d9" spec deep FG,TST,COV FG TST COV || return 1
  dir="$BATS_TEST_TMPDIR/d9"
  [ "$(grep -c '^refuter	[A-Z]*	deep-batched	' "$dir/out.txt")" -eq 3 ] || return 1
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 3 ] || return 1
  [ "$(grep -c '^critic skip$' "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(grep -c '"phase":"refuter"' "$dir/coverage.jsonl")" -eq 3 ] || return 1
  [ "$(grep -c '^{"phase":"completeness","lens":"critic","disposition":"not_applicable"}$' "$dir/coverage.jsonl")" -eq 1 ] || return 1
  [ "$(grep -c '^{"phase":"refuter","lens":"FG","disposition":"first_pass","finding_ids":\["FG-001","FG-002","FG-003"\]}$' "$dir/coverage.jsonl")" -eq 1 ] || return 1

  # Plan with 24 TD material: single each; with 25: one batched, lens TD
  make_lens DP 1; make_lens CG 0 2; make_lens TD 24
  run_order "$BATS_TEST_TMPDIR/p24" plan standard DP,CG,TD DP CG TD || return 1
  dir="$BATS_TEST_TMPDIR/p24"
  [ "$(grep -c '^refuter	TD	single	' "$dir/out.txt")" -eq 24 ] || return 1
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 24 ] || return 1
  [ "$(grep -c '"lens":"TD","disposition":"first_pass","finding_ids":\["TD-0' "$dir/coverage.jsonl")" -eq 24 ] || return 1
  make_lens TD 25
  run_order "$BATS_TEST_TMPDIR/p25" plan standard DP,CG,TD DP CG TD || return 1
  dir="$BATS_TEST_TMPDIR/p25"
  [ "$(wc -l <"$dir/out.txt" | tr -d ' ')" -eq 1 ] || return 1
  [ "$(grep -c '^refuter	TD	batched	TD-001,' "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(wc -l <"$dir/coverage.jsonl" | tr -d ' ')" -eq 1 ] || return 1
  grep -q '"lens":"TD","disposition":"first_pass","finding_ids":\["TD-001",.*"TD-025"\]' "$dir/coverage.jsonl"
}

@test "a finished lens starts its refuters early only when the dispatch shape is already decided" {
  local dir

  # under the cap: nothing until the last lens finishes
  make_lens FG 2; make_lens TST 2; make_lens COV 2
  dir="$BATS_TEST_TMPDIR/under"
  finish "$dir" spec standard FG,TST,COV FG || return 1
  finish "$dir" spec standard FG,TST,COV TST || return 1
  [ ! -s "$dir/out.txt" ] || return 1
  [ ! -s "$dir/coverage.jsonl" ] || return 1
  finish "$dir" spec standard FG,TST,COV COV || return 1
  [ "$(grep -c '^refuter	.*	single	' "$dir/out.txt")" -eq 6 ] || return 1

  # first finished lens already over the cap: batched now, each later lens at its own finish
  make_lens FG 25; make_lens TST 1; make_lens COV 0 1
  dir="$BATS_TEST_TMPDIR/over"
  finish "$dir" spec standard FG,TST,COV FG || return 1
  [ "$(grep -c '^refuter	FG	batched	' "$dir/out.txt")" -eq 1 ] || return 1
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 1 ] || return 1
  finish "$dir" spec standard FG,TST,COV TST || return 1
  [ "$(grep -c '^refuter	TST	batched	TST-001	' "$dir/out.txt")" -eq 1 ] || return 1
  finish "$dir" spec standard FG,TST,COV COV || return 1
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 2 ] || return 1
  [ "$(wc -l <"$dir/coverage.jsonl" | tr -d ' ')" -eq 2 ] || return 1

  # plan: TD refuters start at the TD finish while DP and CG are unfinished
  make_lens TD 2
  dir="$BATS_TEST_TMPDIR/plan"
  finish "$dir" plan standard DP,CG,TD TD || return 1
  [ "$(grep -c '^refuter	TD	single	' "$dir/out.txt")" -eq 2 ] || return 1

  # a lens finished twice is refused and prints nothing more
  run node "$SCRIPT" finished --state "$dir/state.json" --kind plan --tier standard \
    --lenses DP,CG,TD --findings-dir "$FINDINGS" --verdicts-dir "$VERDICTS" \
    --coverage "$dir/coverage.jsonl" --lens TD
  [ "$status" -eq 1 ] || return 1
  [ "$(grep -c '^refuter' "$dir/out.txt")" -eq 2 ] || return 1
  [ "$(wc -l <"$dir/coverage.jsonl" | tr -d ' ')" -eq 2 ]
}
