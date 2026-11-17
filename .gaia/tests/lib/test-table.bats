#!/usr/bin/env bats
# Refusal guards of the test-design table library: verify, approve,
# record-security, amend and the requirement-key enumerator.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TABLE_CLI="$REPO_ROOT/.gaia/scripts/test-design/test-table.mjs"
  REPLANNED_CLI="$REPO_ROOT/.gaia/scripts/test-design/replanned-rows.mjs"
  KEYS_SCRIPT="$REPO_ROOT/.gaia/scripts/spec/requirement-keys.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  KEYS="$BATS_TEST_TMPDIR/keys.txt"
  MUTATE="$BATS_TEST_TMPDIR/mutate.mjs"
  mkdir -p "$PLAN"
  cat >"$MUTATE" <<'EOF'
import {readFileSync, writeFileSync} from 'node:fs';
const [file, body] = process.argv.slice(2);
const table = JSON.parse(readFileSync(file, 'utf8'));
new Function('t', body)(table);
writeFileSync(file, JSON.stringify(table, null, 2) + '\n');
EOF
}

mutate_table() {
  node "$MUTATE" "$PLAN/tests.json" "$1"
}

write_verify_fixture() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "flow:alpha", "case": "alpha works", "file": "src/alpha.test.ts", "title": "alpha works", "layer": "unit", "task": "task-one", "action": "new", "security": "none"},
  {"id": "T2", "source": "success_criteria:0", "case": "beta refuses", "file": "src/beta.test.ts", "title": "beta refuses", "layer": "route", "task": "task-two", "action": "new", "security": "access"}
]}
EOF
  printf 'flow:alpha\nsuccess_criteria:0\n' >"$KEYS"
  printf 'schema: 1\n' >"$PLAN/TEST-DESIGN"
  printf '# one\n\n- Test: src/alpha.test.ts \xe2\x80\xba alpha works\n- Pin update: src/pinned.test.ts\n' >"$PLAN/task-one.md"
  printf '# two\n\n- Test: src/beta.test.ts \xe2\x80\xba beta refuses\n- Flow test (f): .playwright/flows/beta.spec.ts\n' >"$PLAN/task-two.md"
}

run_verify() {
  run node "$TABLE_CLI" verify --plan-dir "$PLAN" --keys "$KEYS"
}

# One verify refusal: build the fixture, break it with $1 (a shell snippet),
# and require exit 1 with $2 in the stderr.
expect_verify_refusal() {
  rm -rf "$PLAN"
  mkdir -p "$PLAN"
  write_verify_fixture
  eval "$1"
  run_verify
  if [ "$status" -ne 1 ]; then
    echo "case '$1': expected exit 1, got $status: $output" >&2
    return 1
  fi
  if ! grep -qF -- "$2" <<<"$output"; then
    echo "case '$1': stderr lacks '$2': $output" >&2
    return 1
  fi
}

@test "verify passes a complete table; a Pin update line needs no row" {
  write_verify_fixture
  run_verify
  [ "$status" -eq 0 ]
}

@test "verify refuses a missing or unparseable table" {
  expect_verify_refusal 'rm "$PLAN/tests.json"' 'tests.json is missing'
  expect_verify_refusal 'printf "{nope" >"$PLAN/tests.json"' 'not valid JSON'
}

@test "verify refuses a row missing each required field" {
  local field
  for field in id source case file title layer task action security; do
    expect_verify_refusal "mutate_table 'delete t.rows[0].$field'" "missing required field \"$field\""
  done
}

@test "verify refuses an illegal layer, action or security value" {
  expect_verify_refusal "mutate_table 't.rows[0].layer = \"mobile\"'" 'illegal layer'
  expect_verify_refusal "mutate_table 't.rows[0].action = \"rewrite\"'" 'illegal action'
  expect_verify_refusal "mutate_table 't.rows[0].security = \"high\"'" 'illegal security'
}

@test "verify refuses duplicate ids, shared tests without caseKeys and an extend row with no caseKey" {
  expect_verify_refusal "mutate_table 't.rows[1].id = \"T1\"'" 'duplicate id T1'
  expect_verify_refusal "mutate_table 't.rows[1].file = t.rows[0].file; t.rows[1].title = t.rows[0].title'" 'without distinct caseKeys'
  expect_verify_refusal "mutate_table 't.rows[0].action = \"extend\"'" 'an extend row needs a caseKey'
}

@test "verify refuses key and row source mismatches" {
  expect_verify_refusal 'printf "flow:gamma\n" >>"$KEYS"' 'requirement key flow:gamma has no row'
  expect_verify_refusal "mutate_table 't.rows[0].source = \"flow:stray\"'" 'unknown source flow:stray'
}

@test "verify counts a coveredFlows entry as citing its flow key; without it the key has no row" {
  write_verify_fixture
  printf 'flow:gamma\n' >>"$KEYS"
  mutate_table 't.coveredFlows = [{source: "flow:gamma", rows: ["T2"]}]'
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  mutate_table 'delete t.coveredFlows'
  run_verify
  [ "$status" -eq 1 ]
  grep -qF 'requirement key flow:gamma has no row' <<<"$output"
}

@test "sole-rows lists exactly the rows whose removal verify refuses for a key with no row, coveredFlows included" {
  write_verify_fixture
  # T3 shares T2's key, so neither is alone on it, and T3 alone covers flow:gamma.
  printf 'flow:gamma\n' >>"$KEYS"
  mutate_table 't.rows.push({id: "T3", source: "success_criteria:0", case: "beta also refuses", file: "src/beta.test.ts", title: "beta also refuses", layer: "route", task: "task-two", action: "new", security: "none"}); t.coveredFlows = [{source: "flow:gamma", rows: ["T3"]}]'
  printf -- '- Test: src/beta.test.ts \xe2\x80\xba beta also refuses\n' >>"$PLAN/task-two.md"
  run_verify
  [ "$status" -eq 0 ] || { echo "baseline: $output" >&2; return 1; }

  run node "$TABLE_CLI" sole-rows --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 0 ] || { echo "sole-rows: $output" >&2; return 1; }
  sole="$output"
  [ "$sole" = "$(printf 'T1 flow:alpha\nT3 flow:gamma')" ] || { echo "sole-rows printed: $sole" >&2; return 1; }

  cp -R "$PLAN" "$BATS_TEST_TMPDIR/pristine"
  for pair in 'T1:alpha works' 'T2:beta refuses' 'T3:beta also refuses'; do
    id="${pair%%:*}" title="${pair#*:}"
    rm -rf "$PLAN" && cp -R "$BATS_TEST_TMPDIR/pristine" "$PLAN"
    mutate_table "t.rows = t.rows.filter((row) => row.id !== '$id')"
    for doc in "$PLAN"/task-*.md; do
      grep -vF -- "› $title" "$doc" >"$doc.next" || true
      mv "$doc.next" "$doc"
    done
    run_verify
    if grep -q "^$id " <<<"$sole"; then
      [ "$status" -eq 1 ] && grep -qF 'has no row' <<<"$output" ||
        { echo "$id is sole but its removal gave $status: $output" >&2; return 1; }
    else
      [ "$status" -eq 0 ] || { echo "$id is not sole but its removal gave $status: $output" >&2; return 1; }
    fi
  done
}

@test "sole-rows run again after one of a key's two rows is removed lists the other" {
  write_verify_fixture
  mutate_table 't.rows.push({id: "T3", source: "success_criteria:0", case: "beta also refuses", file: "src/beta.test.ts", title: "beta also refuses", layer: "route", task: "task-two", action: "new", security: "none"})'
  run node "$TABLE_CLI" sole-rows --plan-dir "$PLAN" --keys "$KEYS"
  [ "$output" = 'T1 flow:alpha' ] || { echo "before: $output" >&2; return 1; }
  mutate_table "t.rows = t.rows.filter((row) => row.id !== 'T3')"
  run node "$TABLE_CLI" sole-rows --plan-dir "$PLAN" --keys "$KEYS"
  [ "$output" = "$(printf 'T1 flow:alpha\nT2 success_criteria:0')" ] || { echo "after: $output" >&2; return 1; }
}

@test "sole-rows refuses a missing table or keys file" {
  run node "$TABLE_CLI" sole-rows --plan-dir "$PLAN" --keys "$KEYS"
  [ "$status" -eq 1 ]
  grep -qF 'tests.json is missing' <<<"$output"
  write_verify_fixture
  run node "$TABLE_CLI" sole-rows --plan-dir "$PLAN" --keys "$BATS_TEST_TMPDIR/absent.txt"
  [ "$status" -eq 1 ]
  grep -qF 'cannot read keys file' <<<"$output"
}

@test "flag-candidates lists an unflagged retire or change row that shares file and source with a flagged row" {
  write_verify_fixture
  # T2 is access on src/beta.test.ts for success_criteria:0. Listed: T3 retire
  # and T4 change, unflagged, same file and source. Not listed: T5 another
  # source, T6 already flagged, T7 a new row, T8 another file.
  mutate_table '
    const row = (id, extra) => ({id, source: "success_criteria:0", case: id, file: "src/beta.test.ts", title: id, layer: "route", task: "task-two", action: "retire", security: "none", ...extra});
    t.rows.push(
      row("T3"),
      row("T4", {action: "change"}),
      row("T5", {source: "flow:alpha"}),
      row("T6", {security: "secret"}),
      row("T7", {action: "new"}),
      row("T8", {file: "src/other.test.ts"}),
    )'
  run node "$TABLE_CLI" flag-candidates --plan-dir "$PLAN"
  [ "$status" -eq 0 ] || { echo "flag-candidates: $output" >&2; return 1; }
  [ "$output" = "$(printf 'T3 access secret\nT4 access secret')" ] || { echo "printed: $output" >&2; return 1; }
}

@test "flag-candidates prints nothing for a table with no such row and refuses a missing table" {
  run node "$TABLE_CLI" flag-candidates --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qF 'tests.json is missing' <<<"$output"
  write_verify_fixture
  run node "$TABLE_CLI" flag-candidates --plan-dir "$PLAN"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$status: $output" >&2; return 1; }
}

@test "replanned-rows lists each regenerated row no snapshot row matches, with its prior form's id when it kept id, file and title" {
  write_verify_fixture
  mutate_table '
    t.rows.push(
      {id: "T3", source: "directive:1", case: "low, normal, urgent -> Low, Normal, Urgent", file: "src/page.test.ts", title: "maps priority", layer: "route", task: "task-two", action: "new", security: "none"},
      {id: "T4", source: "directive:2", case: "unknown status -> every row", file: "src/list.test.ts", title: "unknown filter", layer: "route", task: "task-two", action: "new", security: "none"},
      {id: "T5", source: "directive:3", case: "old case", file: "src/gone.test.ts", title: "gone", layer: "route", task: "task-two", action: "new", security: "none"},
    )'
  cp "$PLAN/tests.json" "$BATS_TEST_TMPDIR/before.json"
  # Unchanged: T1, T2. Changed: T3 case cut to a sample, T4 flagged. New: T6.
  # T5 renumbered as T7 under another title reads as new, not as T5 changed.
  mutate_table '
    t.rows[2].case = "urgent -> Urgent";
    t.rows[3].security = "forgery";
    t.rows.splice(4, 1);
    t.rows.push(
      {id: "T6", source: "success_criteria:0", case: "urgent -> Urgent", file: "src/display.test.ts", title: "display helper", layer: "unit", task: "task-two", action: "new", security: "none"},
      {id: "T7", source: "directive:3", case: "old case", file: "src/gone.test.ts", title: "renamed", layer: "route", task: "task-two", action: "new", security: "none"},
    )'
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 0 ] || { echo "replanned-rows: $output" >&2; return 1; }
  [ "$output" = "$(printf 'T3 T3\nT4 T4\nT6\nT7')" ] || { echo "printed: $output" >&2; return 1; }
}

@test "replanned-rows lists a row moved to another task and a duplicate of an existing row" {
  write_verify_fixture
  cp "$PLAN/tests.json" "$BATS_TEST_TMPDIR/before.json"
  mutate_table '
    t.rows[1].task = "task-one";
    t.rows.push({...t.rows[0], id: "T3", caseKey: "second"})'
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 0 ] || { echo "replanned-rows: $output" >&2; return 1; }
  [ "$output" = "$(printf 'T2 T2\nT3')" ] || { echo "printed: $output" >&2; return 1; }
  cp "$PLAN/tests.json" "$BATS_TEST_TMPDIR/before.json"
  mutate_table 't.rows.push({...t.rows[0], id: "T4"})'
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 0 ] || { echo "replanned-rows: $output" >&2; return 1; }
  [ "$output" = "T4" ] || { echo "printed: $output" >&2; return 1; }
}

@test "replanned-rows prints nothing for an unchanged table and refuses a missing table or flag" {
  write_verify_fixture
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 1 ]
  grep -qF 'replanned-rows: cannot read' <<<"$output"
  cp "$PLAN/tests.json" "$BATS_TEST_TMPDIR/before.json"
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json" --after "$PLAN/tests.json"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$status: $output" >&2; return 1; }
  run node "$REPLANNED_CLI" --before "$BATS_TEST_TMPDIR/before.json"
  [ "$status" -eq 2 ]
}

@test "verify refuses each malformed coveredFlows entry" {
  local record='printf "flow:gamma\n" >>"$KEYS"; mutate_table'
  expect_verify_refusal "$record 't.coveredFlows = {}'" 'coveredFlows is not an array'
  expect_verify_refusal "$record 't.coveredFlows = [{source: \"success_criteria:0\", rows: [\"T2\"]}]'" 'source is not a flow:<slug> key'
  expect_verify_refusal "$record 't.coveredFlows = [{source: \"flow:stray\", rows: [\"T2\"]}]'" 'coveredFlows cites unknown source flow:stray'
  expect_verify_refusal "$record 't.coveredFlows = [{source: \"flow:gamma\", rows: [\"T2\"]}, {source: \"flow:gamma\", rows: [\"T2\"]}]'" 'coveredFlows names flow:gamma twice'
  expect_verify_refusal "$record 't.coveredFlows = [{source: \"flow:gamma\", rows: []}]'" 'coveredFlows flow:gamma names no rows'
  expect_verify_refusal "$record 't.coveredFlows = [{source: \"flow:gamma\", rows: [\"T9\"]}]'" 'names row T9, which the table lacks'
  expect_verify_refusal "$record 't.rows[1].layer = \"flow\"; t.coveredFlows = [{source: \"flow:gamma\", rows: [\"T2\"]}]'" 'names flow-layer row T2'
  expect_verify_refusal "$record 't.rows[0].layer = \"flow\"; t.coveredFlows = [{source: \"flow:alpha\", rows: [\"T2\"]}]'" 'row T1 is a flow-layer row for flow:alpha'
}

@test "verify counts an instructionKeys entry as covering a builder-directing scope boundary or directive key; without it the key has no row" {
  write_verify_fixture
  printf 'scope_boundaries:ask_first:0\ndirective:7\n' >>"$KEYS"
  mutate_table 't.instructionKeys = [{source: "scope_boundaries:ask_first:0", reason: "asks the builder before adding a dependency"}, {source: "directive:7", reason: "renames a setting everywhere it appears"}]'
  run_verify
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  mutate_table 'delete t.instructionKeys'
  run_verify
  [ "$status" -eq 1 ]
  grep -qF 'requirement key scope_boundaries:ask_first:0 has no row' <<<"$output"
  grep -qF 'requirement key directive:7 has no row' <<<"$output"
}

@test "verify refuses each malformed instructionKeys entry and a key both recorded and a row's source" {
  local record='printf "scope_boundaries:never:0\n" >>"$KEYS"; mutate_table'
  expect_verify_refusal "$record 't.instructionKeys = {}'" 'instructionKeys is not an array'
  expect_verify_refusal "$record 't.instructionKeys = [{reason: \"x\"}]'" 'instructionKeys entry #1: source is not a key'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"scope_boundaries:never:9\", reason: \"x\"}]'" 'instructionKeys cites unknown source scope_boundaries:never:9'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"success_criteria:0\", reason: \"x\"}]; t.rows = t.rows.filter((row) => row.source !== \"success_criteria:0\")'" 'instructionKeys success_criteria:0 is not a scope boundary or directive key'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"scope_boundaries:never:0\", reason: \"x\"}, {source: \"scope_boundaries:never:0\", reason: \"y\"}]'" 'instructionKeys names scope_boundaries:never:0 twice'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"scope_boundaries:never:0\", reason: \" \"}]'" 'instructionKeys scope_boundaries:never:0 has no reason'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"scope_boundaries:never:0\"}]'" 'instructionKeys scope_boundaries:never:0 has no reason'
  expect_verify_refusal "$record 't.instructionKeys = [{source: \"scope_boundaries:never:0\", reason: \"x\"}]; t.rows[1].source = \"scope_boundaries:never:0\"'" 'row T2 cites scope_boundaries:never:0, which instructionKeys records as naming no behavior'
}

@test "covered-flows prints each valid entry, prints nothing for a plan with no table, and exits 1 on a broken entry" {
  write_verify_fixture
  mutate_table 't.coveredFlows = [{source: "flow:gamma", rows: ["T1", "T2"]}, {source: "flow:delta", rows: ["T9"]}]'
  run node "$TABLE_CLI" covered-flows --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qxF 'flow:gamma' <<<"$output"
  grep -qF 'flow:delta' <<<"$(grep -vF 'test-table:' <<<"$output")" && return 1
  grep -qF 'test-table: coveredFlows flow:delta names row T9' <<<"$output"
  rm "$PLAN/tests.json"
  run node "$TABLE_CLI" covered-flows --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "covered-flows refuses a retired or held row as the covering row" {
  write_verify_fixture
  mutate_table 't.rows[1].action = "retire"; t.coveredFlows = [{source: "flow:gamma", rows: ["T2"]}]'
  run node "$TABLE_CLI" covered-flows --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qF 'names row T2, which is retired' <<<"$output"
  grep -qxF 'flow:gamma' <<<"$output" && return 1
  mutate_table 't.rows[1].action = "new"; t.rows[1].held = "auto-mode"'
  run node "$TABLE_CLI" covered-flows --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qF 'names row T2, which is held' <<<"$output"
  true
}

@test "covered-flows reads the approved copy once it exists, so a later tests.json edit records nothing" {
  write_verify_fixture
  node "$TABLE_CLI" approve --plan-dir "$PLAN"
  mutate_table 't.coveredFlows = [{source: "flow:alpha", rows: ["T2"]}]'
  run node "$TABLE_CLI" covered-flows --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify refuses task-doc and table disagreements" {
  expect_verify_refusal 'printf -- "- Test: src/ghost.test.ts \xe2\x80\xba ghost\n" >>"$PLAN/task-one.md"' 'Test line has no row'
  expect_verify_refusal 'printf "# one\n" >"$PLAN/task-one.md"' 'has no Test line'
  expect_verify_refusal 'printf -- "see src/other.test.ts for more\n" >>"$PLAN/task-one.md"' 'outside a Test, Flow test or Pin update line'
}

# One amend fixture: an approved table with two security rows on distinct
# keys plus one plain row; the current table starts equal to it.
write_amend_fixture() {
  cat >"$PLAN/tests.json" <<'EOF'
{"schema": 1, "rows": [
  {"id": "T1", "source": "flow:alpha", "case": "a", "file": "a.test.ts", "title": "a", "layer": "route", "task": "task-one", "action": "new", "security": "access"},
  {"id": "T2", "source": "success_criteria:0", "case": "b", "file": "b.test.ts", "title": "b", "layer": "route", "task": "task-one", "action": "new", "security": "forgery"},
  {"id": "T3", "source": "success_criteria:1", "case": "c", "file": "c.test.ts", "title": "c", "layer": "unit", "task": "task-one", "action": "new", "security": "none"}
]}
EOF
  cp "$PLAN/tests.json" "$PLAN/tests.approved.json"
  AMEND_BEFORE="$(cat "$PLAN/tests.json")"
}

run_amend() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/changes.json"
  run node "$TABLE_CLI" amend --plan-dir "$PLAN" --root "$BATS_TEST_TMPDIR" --changes "$BATS_TEST_TMPDIR/changes.json"
}

@test "amend refuses a security fold that loses a key and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"remove":["T2"]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'checkpoint: success_criteria:0' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend refuses a dropped security flag and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"replace":[{"id":"T1","source":"flow:alpha","case":"a","file":"a.test.ts","title":"a","layer":"route","task":"task-one","action":"new","security":"none"}]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'security flag dropped on T1' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend refuses a changed security kind and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"replace":[{"id":"T1","source":"flow:alpha","case":"a","file":"a.test.ts","title":"a","layer":"route","task":"task-one","action":"new","security":"secret"}]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'security kind changed on T1' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend refuses a changed action on an approved security row and leaves the file unchanged" {
  write_amend_fixture
  run_amend '{"replace":[{"id":"T1","source":"flow:alpha","case":"a","file":"a.test.ts","title":"a","layer":"route","task":"task-one","action":"retire","security":"access"}]}'
  [ "$status" -eq 1 ]
  grep -qF -- 'security action changed on T1' <<<"$output"
  [ "$(cat "$PLAN/tests.json")" = "$AMEND_BEFORE" ]
}

@test "amend accepts a non-security fold and a security fold that keeps every key" {
  write_amend_fixture
  run_amend '{"remove":["T3"],"add":[{"id":"T4","source":"success_criteria:1","case":"c2","file":"c2.test.ts","title":"c2","layer":"unit","task":"task-one","action":"new","security":"none"}]}'
  [ "$status" -eq 0 ]
  grep -qF '"T4"' "$PLAN/tests.json"
  grep -qF '"T3"' "$PLAN/tests.json" && return 1

  write_amend_fixture
  run_amend '{"remove":["T1","T2"],"add":[{"id":"T5","source":"flow:alpha","case":"a2","file":"a2.test.ts","title":"a2","layer":"route","task":"task-one","action":"new","security":"access"},{"id":"T6","source":"success_criteria:0","case":"b2","file":"b2.test.ts","title":"b2","layer":"route","task":"task-one","action":"new","security":"forgery"}]}'
  [ "$status" -eq 0 ]
  grep -qF '"T5"' "$PLAN/tests.json"
  grep -qF '"T6"' "$PLAN/tests.json"
  true
}

@test "approve writes a byte-equal approved copy and a marker hash, then refuses a second approval" {
  write_verify_fixture
  run node "$TABLE_CLI" approve --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  cmp -s "$PLAN/tests.json" "$PLAN/tests.approved.json"
  local expected
  expected="$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$PLAN/tests.approved.json")"
  grep -qxF "approved_sha256: $expected" "$PLAN/TEST-DESIGN"
  run node "$TABLE_CLI" approve --plan-dir "$PLAN"
  [ "$status" -eq 1 ]
  grep -qF 'already exists' <<<"$output"
}

approved_held() {
  node -e 'const t=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(t.rows.map((r)=>r.held??"-").join(","))' "$PLAN/tests.approved.json"
}

@test "approve --auto holds every security retire row, deleted code included, and not a non-security one" {
  write_verify_fixture
  mutate_table 't.rows[0].action = "retire"; t.rows[1].action = "retire"; t.rows[1].deletes = ["src/beta.ts"]'
  printf -- '- Delete: src/beta.ts\n' >>"$PLAN/task-two.md"
  run node "$TABLE_CLI" approve --plan-dir "$PLAN" --auto
  [ "$status" -eq 0 ]
  [ "$output" = "held T2" ]
  [ "$(approved_held)" = "-,auto-mode" ]
  cmp -s "$PLAN/tests.json" "$PLAN/tests.approved.json"
}

@test "approve approves a security retire row whose deleted code a Delete line names and holds every other as kept code" {
  write_verify_fixture
  # T2 deletes its code; T3 names no deletes; T4 names a path no Delete line
  # names; T5's deletes is empty; T6's deletes names a test path.
  mutate_table 't.rows[0].action = "retire"; t.rows[1].action = "retire"; t.rows[1].deletes = ["src/beta.ts"];
    const kept = ({deletes, ...row}, id, title, extra) => ({...row, id, title, ...extra});
    t.rows.push(kept(t.rows[1], "T3", "beta kept", {}));
    t.rows.push(kept(t.rows[1], "T4", "beta unnamed", {deletes: ["src/gamma.ts"]}));
    t.rows.push(kept(t.rows[1], "T5", "beta empty", {deletes: []}));
    t.rows.push(kept(t.rows[1], "T6", "beta test path", {deletes: ["src/beta.test.ts"]}))'
  printf -- '- Delete: src/beta.ts\n- Delete: src/beta.test.ts\n' >>"$PLAN/task-two.md"
  run node "$TABLE_CLI" approve --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'held T3\nheld T4\nheld T5\nheld T6')" ]
  [ "$(approved_held)" = "-,-,kept-code,kept-code,kept-code,kept-code" ]
}

@test "verify refuses a misplaced deletes, a deletes path no Delete line names, and a Delete line naming a test" {
  expect_verify_refusal "mutate_table 't.rows[0].deletes = [\"src/alpha.ts\"]'; printf -- '- Delete: src/alpha.ts\n' >>\"\$PLAN/task-one.md\"" 'deletes is only for a security retire row'
  expect_verify_refusal "mutate_table 't.rows[1].action = \"retire\"; t.rows[1].deletes = [\"src/beta.ts\"]'" "deletes src/beta.ts, which no task doc's Delete line names"
  expect_verify_refusal "printf -- '- Delete: src/beta.test.ts\n' >>\"\$PLAN/task-two.md\"" 'Delete line names a test path'
  expect_verify_refusal "mutate_table 't.rows[1].action = \"retire\"; t.rows[1].deletes = [\"src/beta.test.ts\"]'" 'deletes names a test path'
  expect_verify_refusal "mutate_table 't.rows[1].action = \"retire\"; t.rows[1].deletes = [\"../beta.ts\"]'" 'deletes is not a plain repo-relative path'
  expect_verify_refusal "mutate_table 't.rows[1].action = \"retire\"; t.rows[1].deletes = [\"/abs/beta.ts\"]'" 'deletes is not a plain repo-relative path'
}

@test "verify passes a security retire row whose deletes path a Delete line names" {
  write_verify_fixture
  mutate_table 't.rows[1].action = "retire"; t.rows[1].deletes = ["src/beta.ts"]'
  printf -- '- Delete: src/beta.ts\n' >>"$PLAN/task-two.md"
  run_verify
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "record-security refuses an absent test and records the signal of a present one" {
  . "$REPO_ROOT/.gaia/tests/hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT"
  write_verify_fixture
  local tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/src"
  run node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$tree" --row T2
  [ "$status" -eq 1 ]
  grep -qF 'absent' <<<"$output"
  [ ! -e "$PLAN/security-tests.jsonl" ]

  cat >"$tree/src/beta.test.ts" <<'EOF'
import {expect, test} from 'vitest';

test('beta refuses', () => {
  expect(1).toBe(1);
});
EOF
  run node "$TABLE_CLI" record-security --plan-dir "$PLAN" --root "$tree" --row T2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$PLAN/security-tests.jsonl" | tr -d ' ')" = "1" ]
  grep -qE '^\{"row":"T2","file":"src/beta.test.ts","title":"beta refuses","signal":"sha256:[0-9a-f]{64}"\}$' "$PLAN/security-tests.jsonl"
}

@test "requirement-keys prints the sorted key list for a SPEC and audit" {
  local spec="$BATS_TEST_TMPDIR/SPEC.md" audit="$BATS_TEST_TMPDIR/AUDIT.md"
  cat >"$spec" <<'EOF'
---
spec_id: SPEC-900
success_criteria:
  - first criterion
  - second criterion
    continued here
flows:
  - flow_id: FLOW-001
    slug: sign-in
    name: A user signs in.
    why: Sign-in gates the app.
    test_path: tests/sign-in.bats
scope_boundaries:
  always:
    - do the thing
  ask_first:
    - ask about the thing
  never:
    - never one
    - never two
clarifications:
  answered:
    - q: question one
      a: answer one
    - q: question two
      a: answer two
---
Body.
EOF
  cat >"$audit" <<'EOF'
# Audit

## Plan-time directives (no SPEC change)

1. First directive.
2. Second directive.

## Other section

3. Not a directive.
EOF
  run bash "$KEYS_SCRIPT" --spec "$spec" --audit "$audit"
  [ "$status" -eq 0 ]
  [ "$output" = "clarifications:0
clarifications:1
directive:1
directive:2
flow:sign-in
scope_boundaries:always:0
scope_boundaries:ask_first:0
scope_boundaries:never:0
scope_boundaries:never:1
success_criteria:0
success_criteria:1" ]

  printf 'no frontmatter\n' >"$BATS_TEST_TMPDIR/bare.md"
  run bash "$KEYS_SCRIPT" --spec "$BATS_TEST_TMPDIR/bare.md"
  [ "$status" -eq 2 ]

  run bash "$KEYS_SCRIPT" --description
  [ "$status" -eq 0 ]
  [ "$output" = "description" ]
}
