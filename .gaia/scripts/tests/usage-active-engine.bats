#!/usr/bin/env bats
#
# The active-time engine in usage-active-lib.sh (usage_active_index,
# usage_active_pieces, usage_active_union, usage_active_figure) over
# hand-written ledger rows whose `act` facts objects are spelled literally in
# the encoding the flusher writes: `b` in epoch milliseconds, every other time
# a whole-second offset from it, openers delta encoded, chunks and waits as
# [start, length], turn lengths as [end, seconds]. Every program is prefixed by
# exactly the defs the record readout compiles with.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-active-engine.bats < /dev/null

# shellcheck disable=SC2016  # jq programs and child-shell scripts; no shell expansion
bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ACTIVE_LIB="$SCRIPTS/usage-active-lib.sh"
  ENGINE_LIB="$ACTIVE_LIB"
  LEDGER="$BATS_TEST_TMPDIR/usage.jsonl"
  : >"$LEDGER"
}

# ---------- rows ----------

DAY=2026-10-20

# iso <hh:mm:ss[.fff]>: the UTC stamp of that time on the fixture day.
iso() { printf '%sT%sZ' "$DAY" "$1"; }

# epoch_ms <hh:mm:ss[.fff]>: the stamp in epoch milliseconds, as `b` holds it.
epoch_ms() {
  jq -n --arg stamp "$(iso "$1")" '(($stamp[0:19] + "Z") | fromdateiso8601) * 1000
    + (if ($stamp | length) > 20 then ("0" + $stamp[19:-1] | tonumber) * 1000 | round else 0 end)'
}

# facts <b hh:mm:ss[.fff]> <members>: a facts object, `b` from the time and the
# rest of its members literal.
facts() { printf '{"b":%s,%s}' "$(epoch_ms "$1")" "$2"; }

# segment <session> <first> <last> [<agent_id or ->] [<act json or ->]: no act
# argument writes a segment in the shape spend recorded before facts has.
segment() {
  local agent_fields="" act_field=""
  if [ -n "${4:-}" ] && [ "$4" != - ]; then agent_fields=',"agent_type":"general-purpose","agent_id":"'"$4"'"'; else agent_fields=',"agent_type":"main"'; fi
  if [ -n "${5:-}" ] && [ "$5" != - ]; then act_field=',"act":'"$5"; fi
  printf '{"schema_version":1,"kind":"segment","key":"session:%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"by_model":{}%s%s}\n' \
    "$1" "$1" "$(iso "$2")" "$(iso "$3")" "$agent_fields" "$act_field" >>"$LEDGER"
}

# cursor_facts <session> <act json>: a cursor row carrying facts, as a re-read
# of a relocated copy writes it.
cursor_facts() {
  printf '{"schema_version":1,"kind":"cursor","act":%s,"session_id":"%s","role":"main","path":"/relocated/%s.jsonl","offset":0,"size":0,"hw_ts":null,"hw_ids":[],"ts":"%s"}\n' \
    "$2" "$1" "$1" "$(iso 23:00:00)" >>"$LEDGER"
}

# activity <session> <cover from> <cover to> <act json>: a backfill row.
activity() {
  printf '{"schema_version":1,"kind":"activity","session_id":"%s","cover":["%s","%s"],"act":%s}\n' \
    "$1" "$(iso "$2")" "$(iso "$3")" "$4" >>"$LEDGER"
}

close_binding() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"command:gaia-spec-1","workflow":"gaia-spec","source":"record-command"}\n' \
    "$1" "$(iso "$2")" >>"$LEDGER"
}

start_binding() {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"gaia-plan","source":"transcript"}\n' \
    "$1" "$(iso "$2")" >>"$LEDGER"
}

# ---------- the engine ----------

# Binds $rows, $segments (resolved, as the readouts resolve them) and $index
# over the ledger, plus at(<iso>), group_of(<session>) and span_figure(<group>):
# the figure of a group clipped to its first spend to its last.
PRELUDE='
usage_rows($ledger) as $rows
| [$rows[] | select(.kind == "binding")] as $bindings
| usage_resolve_t([$rows[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings)) as $segments
| usage_active_index($rows; $segments) as $index
| def at($stamp): $stamp | usage_epoch;
  def group_of($session): [$segments[] | select(.session_id == $session)];
  def span_figure($group):
    usage_active_figure($index; $group; ($group | map(._t) | min); ($group | map(.last_ts | usage_epoch) | max));
'

# engine <expression>: the expression's compact output over $LEDGER, with the
# libraries sourced in a fresh shell and $ENGINE_LIB as the active lib.
engine() {
  bash -c '. "$1/usage-lib.sh" && . "$1/usage-resolve-lib.sh" && . "$2" || exit 9
    jq -nc --rawfile ledger "$3" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_ACTIVE_JQ$4"' \
    _ "$SCRIPTS" "$ENGINE_LIB" "$LEDGER" "$PRELUDE$1"
}

figure_of() { engine "span_figure(group_of(\"$1\"))"; }

seconds_of() { engine "span_figure(group_of(\"$1\")) | .active_seconds"; }

# compile_prefix <lib> <body>: runs the record readout's prefix with <lib> as
# the active lib and <body> after it. jq 1.7.1 resolves a name only inside a
# def the program reaches, so a body of ` 1` alone never sees a bad call in a
# def body; REACHING_BODY calls every entry point.
compile_prefix() {
  bash -c '. "$1/usage-lib.sh" && . "$1/usage-resolve-lib.sh" && . "$2" || exit 9
    jq -n "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_ACTIVE_JQ$3"' _ "$SCRIPTS" "$1" "$2"
}

REACHING_BODY='
[usage_active_figure(usage_active_index([]; []); []; 0; 1), usage_active_union([]; 0; 1), usage_active_pieces({segments: {}}; [])] | 1'

# ---------- scenarios shared with the guard-red cases ----------

# A main turn 10:00 to 10:05 and two sidecars it launched, each 10:00:30 to 10:04:30.
write_overlap_ledger() {
  segment s-overlap 10:00:00 10:05:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,300]],"d":[[300,300]]')"
  segment s-overlap 10:00:30 10:04:30 agent-one 0
  segment s-overlap 10:00:30 10:04:30 agent-two 0
}

# Work 10:00 to 10:10 with no recorded wait and a 240 s turn length.
write_binding_cap_ledger() {
  segment s-cap 10:00:00 10:10:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,600]],"d":[[600,240]]')"
}

# ---------- main-thread turns ----------

@test "two closed turns two hours apart count their two minutes of work, not the idle span between them" {
  segment s-two 10:00:00 12:01:00 - "$(facts 10:00:00 '"e":"cli","o":[0,7200],"c":[[0,60],[7200,60]],"d":[[60,60],[7260,60]]')"
  [ "$(figure_of s-two)" = '{"active_seconds":120,"active_lower_bound":false}' ]
}

@test "a seven-minute tool call that writes no entry counts in full, though a flush split the turn around it" {
  segment s-tool 10:00:00 10:01:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,60]]')"
  segment s-tool 10:08:00 10:09:00 - "$(facts 10:08:00 '"e":"cli","c":[[0,60]],"d":[[60,540]]')"
  [ "$(seconds_of s-tool)" = 540 ]
}

@test "a wait on the maintainer split across two facts objects is subtracted from the turn" {
  segment s-wait 10:00:00 10:02:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,120]],"q":[["ask-1",120]]')"
  segment s-wait 10:08:00 10:10:00 - "$(facts 10:08:00 '"e":"cli","c":[[0,120]],"r":[["ask-1",0]]')"
  [ "$(seconds_of s-wait)" = 240 ]
}

@test "a turn length shorter than the reconstructed work caps the turn at the recorded length" {
  write_binding_cap_ledger
  [ "$(seconds_of s-cap)" = 240 ]
}

@test "of two turn lengths ending in one turn, the smaller caps it" {
  segment s-two-caps 10:00:00 10:10:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,600]],"d":[[600,300],[600,240]]')"
  [ "$(seconds_of s-two-caps)" = 240 ]
}

@test "an open wait with no result yet is subtracted from its start to the turn's latest work" {
  segment s-open 10:00:00 10:05:00 - "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,300]],"q":[["ask-9",120]]')"
  [ "$(seconds_of s-open)" = 120 ]
}

@test "a notification turn whose turn length reaches back past the previous prompt counts only from its own opener to its last work" {
  segment s-note 10:00:00 10:06:00 - "$(facts 10:00:00 '"e":"cli","o":[0,240],"c":[[0,60],[240,120]],"d":[[60,60],[360,360]]')"
  [ "$(seconds_of s-note)" = 180 ]
  [ "$(engine "usage_active_union(usage_active_pieces(\$index; group_of(\"s-note\")); at(\"$(iso 10:02:00)\"); at(\"$(iso 10:10:00)\"))")" = 120 ]
}

@test "an interrupted turn with no turn length counts from its opener to its last work and leaves the row unmarked" {
  segment s-interrupt 10:00:00 11:01:00 - "$(facts 10:00:00 '"e":"cli","o":[0,3600],"c":[[0,150],[3600,60]],"d":[[3660,60]]')"
  [ "$(figure_of s-interrupt)" = '{"active_seconds":210,"active_lower_bound":false}' ]
  [ "$(engine "usage_active_union(usage_active_pieces(\$index; group_of(\"s-interrupt\")); at(\"$(iso 10:00:00)\"); at(\"$(iso 10:30:00)\"))")" = 150 ]
}

@test "openers decode as a running sum of their gaps" {
  segment s-delta 10:00:00 10:21:00 - "$(facts 10:00:00 '"e":"cli","o":[0,600,600],"c":[[0,60],[600,60],[1200,60]]')"
  [ "$(seconds_of s-delta)" = 180 ]
}

@test "work before the first opener of a range gets an opener at its own first stamp" {
  segment s-implicit 10:00:00 10:03:00 - "$(facts 10:00:00 '"e":"cli","c":[[0,60]]')"
  segment s-implicit 10:02:00 10:03:00 - "$(facts 10:02:00 '"e":"cli","o":[0],"c":[[0,60]]')"
  [ "$(seconds_of s-implicit)" = 120 ]
}

# ---------- headless and sidecar sources ----------

@test "a headless session counts its first to last work as one window, and its interactive twin counts its turns" {
  segment s-headless 10:00:00 10:20:00 - "$(facts 10:00:00 '"e":"sdk-cli","o":[0,900],"c":[[0,300],[900,300]]')"
  segment s-twin 10:00:00 10:20:00 - "$(facts 10:00:00 '"e":"cli","o":[0,900],"c":[[0,300],[900,300]]')"
  [ "$(seconds_of s-headless)" = 1200 ]
  [ "$(seconds_of s-twin)" = 600 ]
}

@test "overlapping sidecars and the main turn that launched them count once, never as their sum" {
  write_overlap_ledger
  [ "$(figure_of s-overlap)" = '{"active_seconds":300,"active_lower_bound":false}' ]
}

@test "five overlapping sidecars give their union, which never exceeds the clip span" {
  segment s-five 10:00:00 10:04:00 agent-one 0
  segment s-five 10:01:00 10:05:00 agent-two 0
  segment s-five 10:02:00 10:06:00 agent-three 0
  segment s-five 10:03:00 10:07:00 agent-four 0
  segment s-five 10:04:00 10:08:00 agent-five 0
  [ "$(seconds_of s-five)" = 480 ]
  [ "$(engine "span_figure(group_of(\"s-five\")).active_seconds <= at(\"$(iso 10:08:00)\") - at(\"$(iso 10:00:00)\")")" = true ]
}

@test "a sidecar window past the clip span is clipped to it" {
  segment s-clip 10:30:00 10:40:00 agent-late 0
  [ "$(engine "usage_active_figure(\$index; group_of(\"s-clip\"); at(\"$(iso 10:00:00)\"); at(\"$(iso 10:31:00)\"))")" = '{"active_seconds":60,"active_lower_bound":false}' ]
}

@test "fractional windows are summed before the one floor" {
  segment s-fraction 10:00:00.000 10:01:00.714 agent-one 0
  segment s-fraction 11:00:00.000 11:01:00.714 agent-two 0
  [ "$(seconds_of s-fraction)" = 121 ]
}

@test "millisecond pieces that sum to whole seconds floor to those seconds, though their doubles sum just below" {
  segment s-whole-seconds 10:00:00.002 10:01:00.004 agent-one 0
  segment s-whole-seconds 11:00:00.002 11:01:00.000 agent-two 0
  [ "$(engine 'usage_active_union(usage_active_pieces($index; $segments); 0; infinite) < 120')" = true ]
  [ "$(seconds_of s-whole-seconds)" = 120 ]
}

# ---------- idempotence ----------

@test "facts appended twice, and one turn split differently across facts objects, give identical figures" {
  local whole_turn first_half second_half figure
  whole_turn="$(facts 12:00:00 '"e":"cli","o":[0],"c":[[0,60]]')"
  first_half="$(facts 12:00:00 '"e":"cli","o":[0],"c":[[0,30]]')"
  second_half="$(facts 12:00:30.500 '"e":"cli","c":[[0,30]]')"

  segment s-whole 12:00:00 12:01:00 - "$whole_turn"
  figure="$(figure_of s-whole)"
  [ "$figure" = '{"active_seconds":60,"active_lower_bound":false}' ]
  cursor_facts s-whole "$whole_turn"
  [ "$(figure_of s-whole)" = "$figure" ]

  : >"$LEDGER"
  segment s-whole 12:00:00 12:00:30 - "$first_half"
  segment s-whole 12:00:30.500 12:01:00 - "$second_half"
  [ "$(figure_of s-whole)" = "$figure" ]
  cursor_facts s-whole "$first_half"
  cursor_facts s-whole "$second_half"
  [ "$(figure_of s-whole)" = "$figure" ]
}

# ---------- attribution ----------

@test "a turn straddling a close and the next start splits at the latest split stamp, and the pieces sum to the turn" {
  segment s-straddle 10:28:00 10:29:50 - "$(facts 10:28:00 '"e":"cli","o":[0],"c":[[0,360]]')"
  close_binding s-straddle 10:30:00
  start_binding s-straddle 10:32:00
  segment s-straddle 10:32:10 10:34:00 - 0
  [ "$(engine "[\$segments[] | usage_active_pieces(\$index; [.])]
    == [[[at(\"$(iso 10:28:00)\"), at(\"$(iso 10:32:00)\")]], [[at(\"$(iso 10:32:00)\"), at(\"$(iso 10:34:00)\")]]]")" = true ]
  [ "$(engine '[usage_active_pieces($index; $segments)[] | .[1] - .[0]] | add')" = 360 ]
}

@test "a fractional split stamp is the territory boundary to the millisecond" {
  segment s-boundary 10:29:00.000 10:30:00.250 - "$(facts 10:29:00 '"e":"cli","o":[0],"c":[[0,120]]')"
  close_binding s-boundary 10:30:00.500
  segment s-boundary 10:30:00.750 10:31:00.000 - 0
  [ "$(engine '[$segments[] | usage_active_pieces($index; [.]) | map(map(. * 1000 | round))]')" = \
    "[[[$(epoch_ms 10:29:00),$(epoch_ms 10:30:00.500)]],[[$(epoch_ms 10:30:00.500),$(epoch_ms 10:31:00)]]]" ]
  [ "$(engine '[$segments[] | [usage_active_pieces($index; [.])[] | .[1] - .[0]] | add | . * 1000 | round]')" = '[60500,59500]' ]
}

# ---------- coverage ----------

@test "a group of fact-less segments has no figure and no lower bound" {
  segment s-legacy 09:00:00 09:05:00
  segment s-legacy 09:06:00 09:10:00
  [ "$(figure_of s-legacy)" = '{"active_seconds":null,"active_lower_bound":false}' ]
}

@test "one covered and one uncovered segment of a session give the covered figure as a lower bound, whatever their dates" {
  segment s-mixed 10:00:00 10:05:00 - "$(facts 10:00:00 '"e":"cli","o":[0,600],"c":[[0,300],[600,300]]')"
  segment s-mixed 10:10:00 10:15:00
  [ "$(figure_of s-mixed)" = '{"active_seconds":300,"active_lower_bound":true}' ]
  [ "$(engine '[$segments[] | usage_active_pieces($index; [.]) | length]')" = '[1,0]' ]
}

@test "an appended activity row covering a fact-less segment gives an exact, unmarked figure and leaves earlier lines byte-identical" {
  local original="$BATS_TEST_TMPDIR/original.jsonl" line_count
  segment s-backfill 10:00:00 10:05:00
  [ "$(figure_of s-backfill)" = '{"active_seconds":null,"active_lower_bound":false}' ]
  cp "$LEDGER" "$original"
  line_count="$(wc -l <"$original")"
  activity s-backfill 09:59:00 10:06:00 "$(facts 10:00:00 '"e":"cli","o":[0],"c":[[0,300]]')"
  [ "$(wc -l <"$LEDGER")" -eq $((line_count + 1)) ]
  head -n "$line_count" "$LEDGER" | cmp -s - "$original"
  [ "$(figure_of s-backfill)" = '{"active_seconds":300,"active_lower_bound":false}' ]
}

@test "rows holding only segments and bindings, or no rows at all, still give figures from the segments' own facts" {
  segment s-bare 10:00:00 12:01:00 - "$(facts 10:00:00 '"e":"cli","o":[0,7200],"c":[[0,60],[7200,60]]')"
  close_binding s-bare 12:30:00
  [ "$(engine '
    def figure_over($rows): usage_active_figure(usage_active_index($rows; $segments); $segments;
      ($segments | map(._t) | min); ($segments | map(.last_ts | usage_epoch) | max)) | .active_seconds;
    [figure_over([$rows[] | select(.kind == "segment" or .kind == "binding")]), figure_over([])]')" = '[120,120]' ]
}

# ---------- the prefix and def names ----------

@test "the lib compiles in the record readout's prefix and runs every entry point there, and a call into the pricing defs breaks that compile" {
  local mutant="$BATS_TEST_TMPDIR/usage-active-lib.sh"
  run compile_prefix "$ACTIVE_LIB" ' 1'
  [ "$status" -eq 0 ]
  run compile_prefix "$ACTIVE_LIB" "$REACHING_BODY"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  sed 's/^def usage_active_union(\$pieces; \$from; \$to):$/&\
  usage_sum([]) as $unreachable_pricing |/' "$ACTIVE_LIB" >"$mutant"
  cmp -s "$mutant" "$ACTIVE_LIB" && return 1
  run compile_prefix "$mutant" "$REACHING_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage_sum/1 is not defined"* ]]
}

# def_name_violations <lib>: each def the lib's GAIA_USAGE_ACTIVE_JQ declares
# that is neither a public engine name nor _usage_active_ prefixed, or that
# another usage script or the pricing lib declares too. The other scripts are
# the real tree's, less the real active lib, which <lib> stands in for.
def_name_violations() {
  local lib="$1" name other_file
  local -a names=() other_files=()
  while IFS= read -r name; do names[${#names[@]}]="$name"; done < <(
    bash -c '. "$1" && printf "%s\n" "$GAIA_USAGE_ACTIVE_JQ"' _ "$lib" |
      grep -oE '(^|[^A-Za-z0-9_])def [A-Za-z_][A-Za-z0-9_]*' | sed 's/.*def //' | sort -u)
  # gaia-lint-ignore whole-tree-mark-guard: the one test that reaches this helper carries the per-test mark
  for other_file in "$SCRIPTS"/usage*.sh "$SCRIPTS/token-pricing-lib.sh"; do
    [ "$other_file" = "$ACTIVE_LIB" ] || other_files[${#other_files[@]}]="$other_file"
  done
  for name in "${names[@]}"; do
    case "$name" in
      usage_active_index | usage_active_pieces | usage_active_union | usage_active_figure | _usage_active_*) ;;
      *) printf 'name %s\n' "$name" ;;
    esac
    grep -lE "def ${name}[:(;]" "${other_files[@]}" | sed "s|^|$name declared in |"
  done
  printf 'scanned %s defs over %s other files\n' "${#names[@]}" "${#other_files[@]}"
}

# bats test_tags=whole-tree
@test "every def the lib declares is a public engine name or _usage_active_ prefixed and declared nowhere else, and a shadowing def is caught" {
  local mutant="$BATS_TEST_TMPDIR/usage-active-lib.sh" report
  report="$(def_name_violations "$ACTIVE_LIB")"
  [ "$(printf '%s\n' "$report" | grep -cv '^scanned ')" -eq 0 ]
  printf '%s\n' "$report" | grep -qE '^scanned [1-9][0-9]* defs over [1-9][0-9]* other files$'
  for name in usage_active_index usage_active_pieces usage_active_union usage_active_figure; do
    bash -c '. "$1" && printf "%s\n" "$GAIA_USAGE_ACTIVE_JQ"' _ "$ACTIVE_LIB" | grep -qE "def ${name}\(" || return 1
  done
  grep -qE 'def usage_epoch[:(;]' "$SCRIPTS/usage-resolve-lib.sh"

  sed "s/^GAIA_USAGE_ACTIVE_JQ='\$/&\\
def usage_epoch: 0;/" "$ACTIVE_LIB" >"$mutant"
  cmp -s "$mutant" "$ACTIVE_LIB" && return 1
  report="$(def_name_violations "$mutant")"
  printf '%s\n' "$report" | grep -qx 'name usage_epoch'
  printf '%s\n' "$report" | grep -qx "usage_epoch declared in $SCRIPTS/usage-resolve-lib.sh"
}

# ---------- guard red: the union and the cap ----------

@test "a plain sum in place of the union fails the overlap case, and a lib without the cap fails the binding-cap case" {
  local summing="$BATS_TEST_TMPDIR/summing-lib.sh" uncapped="$BATS_TEST_TMPDIR/uncapped-lib.sh"
  sed 's/elif \$piece\[0\] <= \.end then \.end = (\[\.end, \$piece\[1\]\] | max)/elif false then ./' "$ACTIVE_LIB" >"$summing"
  sed 's/_usage_active_trim(\$pieces; \$cap)/$pieces/' "$ACTIVE_LIB" >"$uncapped"
  cmp -s "$summing" "$ACTIVE_LIB" && return 1
  cmp -s "$uncapped" "$ACTIVE_LIB" && return 1

  write_overlap_ledger
  [ "$(seconds_of s-overlap)" = 300 ]
  ENGINE_LIB="$summing"
  [ "$(seconds_of s-overlap)" = 780 ]

  : >"$LEDGER"
  write_binding_cap_ledger
  ENGINE_LIB="$ACTIVE_LIB"
  [ "$(seconds_of s-cap)" = 240 ]
  ENGINE_LIB="$uncapped"
  [ "$(seconds_of s-cap)" = 600 ]
}
