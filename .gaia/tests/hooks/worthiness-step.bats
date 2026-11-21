#!/usr/bin/env bats
#
# Suite for .gaia/scripts/worthiness-step.sh: routing, recording, settling,
# the filer finding and pruning for the worthiness step.
#
# Every case builds a fixture repo with a real merge base. The script under
# test is copied into the fixture's own .gaia/scripts, so the tree holding the
# script is the fixture, and WORTHINESS_STEP_SOURCE points the suite at a
# mutated copy, which is how a mutant is run against it without touching the
# real file. The ledger is a fixture file reached through the writer's own
# WORTHINESS_LEDGER_PATH seam.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/worthiness-step.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

WIDGET="apps/web/app/components/Widget/widget.test.tsx"
MARKER_STORY="apps/web/app/components/Marker/marker.stories.tsx"
EMERGENT_GLOBS='["app/components/**/*.test.tsx",".playwright/**/*.spec.ts","app/**/*.stories.tsx"]'

setup() {
  HOME_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$HOME_ROOT/.gaia/tests/hooks/helpers/package-fixture.sh"
  . "$HOME_ROOT/.gaia/tests/hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  STEP_SOURCE="${WORTHINESS_STEP_SOURCE:-$HOME_ROOT/.gaia/scripts/worthiness-step.sh}"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE

  REPO="$BATS_TEST_TMPDIR/repo"
  RUN_FOLDER="$BATS_TEST_TMPDIR/run"
  LEDGER="$BATS_TEST_TMPDIR/ledger/worthiness.jsonl"
  export WORTHINESS_LEDGER_PATH="$LEDGER"
  mkdir -p "$REPO" "$RUN_FOLDER" "$(dirname "$LEDGER")"
  git -C "$REPO" init -q -b main
  write_builtin_descriptor "$REPO" '' '' "$EMERGENT_GLOBS"
  install_harness

  mkdir -p "$REPO/apps/web/app/components/Widget" "$REPO/apps/web/app/components/Marker"
  widget_source >"$REPO/$WIDGET"
  story_source >"$REPO/$MARKER_STORY"
  printf '# readme\n' >"$REPO/README.md"
  git -C "$REPO" add README.md "$WIDGET" "$MARKER_STORY"
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b feature
  STEP="$REPO/.gaia/scripts/worthiness-step.sh"
}

# The fixture tree mirrors the repo-relative layout the script derives from its
# own location. Directories the extractor and classifier live in are linked so
# `typescript` resolves from the real checkout's dependencies.
install_harness() {
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  local library
  for library in gaia-packages.sh test-signals.sh worthiness-ledger.sh worthiness-selection.sh audit-base-provenance.sh; do
    ln -sfn "$HOME_ROOT/.claude/hooks/lib/$library" "$REPO/.claude/hooks/lib/$library"
  done
  for library in branch-authorship-lib.sh main-root-lib.sh machine-local-ref-lib.sh audit-ledger test-signals classifier spec; do
    ln -sfn "$HOME_ROOT/.gaia/scripts/$library" "$REPO/.gaia/scripts/$library"
  done
  cp "$STEP_SOURCE" "$REPO/.gaia/scripts/worthiness-step.sh"
}

widget_source() {
  printf '%s\n' \
    "import {expect, test} from 'vitest';" \
    "" \
    "test('first', () => {" \
    "  const value = 1;" \
    "  expect(value).toBe(1);" \
    "  expect(value).not.toBe(2);" \
    "});" \
    "" \
    "test('second', () => {" \
    "  expect(2).toBe(2);" \
    "});" \
    "" \
    "test('third', () => {" \
    "  expect(3).toBe(3);" \
    "});"
}

story_source() {
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "import {expect} from 'storybook/test';" \
    "" \
    "const Marker = () => <p>marker</p>;" \
    "" \
    "const meta = preview.meta({component: Marker, title: 'Internal/Marker'});" \
    "" \
    "export const Alpha = meta.story({});" \
    "" \
    "Alpha.test('shows alpha', async ({canvas}) => {" \
    "  await expect(canvas.getByText('marker')).toBeTruthy();" \
    "});" \
    "" \
    "export const Beta = meta.story({});" \
    "" \
    "Beta.test('shows beta', async ({canvas}) => {" \
    "  await expect(canvas.getByText('marker')).toBeTruthy();" \
    "});"
}

commit_paths() {
  git -C "$REPO" add "$@"
  git -C "$REPO" commit -q -m edit
}

# Edit the widget file in place: `first` mid-body, `third` on its last line only.
edit_widget_first_midbody() {
  sed -i.bak 's/expect(value).toBe(1);/expect(value).toBeTruthy();/' "$REPO/$WIDGET"
  rm -f "$REPO/$WIDGET.bak"
}
edit_widget_third_last_line() {
  sed -i.bak '$ s/^});$/}, 1000);/' "$REPO/$WIDGET"
  rm -f "$REPO/$WIDGET.bak"
}
edit_story_alpha_declaration() {
  sed -i.bak 's/^export const Alpha = meta.story({});$/export const Alpha = meta.story({args: {}});/' "$REPO/$MARKER_STORY"
  rm -f "$REPO/$MARKER_STORY.bak"
}
edit_story_meta() {
  sed -i.bak "s/title: 'Internal\/Marker'/title: 'Internal\/Marker2'/" "$REPO/$MARKER_STORY"
  rm -f "$REPO/$MARKER_STORY.bak"
}

commit_widget_edits() {
  edit_widget_first_midbody
  edit_widget_third_last_line
  commit_paths "$WIDGET"
}

run_route() {
  run --separate-stderr bash "$STEP" route --root "$REPO" --run-folder "$RUN_FOLDER"
}

# field <file> <fullName> <jq field>: read one element of the last route output.
field() {
  jq -r --arg f "$1" --arg n "$2" '.[] | select(.file == $f and .fullName == $n) | '"$3" <<<"$output"
}

signal_of() {
  (cd "$REPO" && node "$HOME_ROOT/.gaia/scripts/test-signals/extract-test-signals.mjs" "$1") |
    jq -r --arg n "$2" 'select(.fullName == $n) | .signal'
}

seed() {
  local file="$1" name="$2" verdict="$3" signal="${4:-}"
  [ -n "$signal" ] || signal="$(signal_of "$file" "$name")"
  jq -nc --arg f "$file" --arg n "$name" --arg s "$signal" --arg v "$verdict" \
    '{schema: 1, file: $f, fullName: $n, signal: $s, verdict: $v, auditedAt: "2026-01-01T00:00:00Z"}
     + (if $v == "keep" then {} else {artifact: "an artifact"} end)' >>"$LEDGER"
}

settle() {
  local file="$1" name="$2" kind="$3" signal="${4:-}"
  [ -n "$signal" ] || signal="$(signal_of "$file" "$name")"
  bash "$STEP" settle --run-folder "$RUN_FOLDER" --file "$file" --full-name "$name" --signal "$signal" --as "$kind" \
    --first-line 3 --reason "accepted"
}

state_checksum() {
  cat "$LEDGER" "$RUN_FOLDER"/worthiness-settlements.jsonl "$RUN_FOLDER"/recorded-residuals.jsonl 2>/dev/null | cksum
}

@test "no changed emergent test prints an empty list" {
  printf 'x\n' >"$REPO/other.txt"
  commit_paths other.txt
  run_route
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# expect_field <row> <file> <fullName> <jq field> <expected>: one check of the
# last route output, naming the row on failure.
expect_field() {
  local actual
  actual="$(field "$2" "$3" "$4")"
  [ "$actual" = "$5" ] || {
    printf 'row %s: %s / %s %s is "%s", expected "%s"\n' "$1" "$2" "$3" "$4" "$actual" "$5" >&2
    return 1
  }
}

# A row of a shared-fixture table starts from an empty ledger and run folder.
reset_verdict_state() {
  : >"$LEDGER"
  rm -rf "$RUN_FOLDER"
  mkdir -p "$RUN_FOLDER"
}

@test "routes by ledger line and signal: keep at the current signal, a stale or absent line evaluates, fix and delete by authorship, the last line at one signal wins" {
  commit_widget_edits

  reset_verdict_state
  seed "$WIDGET" "second" keep
  seed "$WIDGET" "third" keep "sha256:stale"
  run_route
  [ "$status" -eq 0 ] || { echo "row keep-stale-absent: status $status" >&2; return 1; }
  expect_field keep-stale-absent "$WIDGET" second .route keep
  expect_field keep-stale-absent "$WIDGET" third .route evaluate
  expect_field keep-stale-absent "$WIDGET" first .route evaluate

  reset_verdict_state
  seed "$WIDGET" "first" fix
  run_route
  expect_field fix-on-midbody-edit "$WIDGET" first .route fix
  expect_field fix-on-midbody-edit "$WIDGET" first .authored true
  expect_field fix-on-midbody-edit "$WIDGET" first .artifact "an artifact"

  reset_verdict_state
  seed "$WIDGET" "second" fix
  seed "$WIDGET" "first" delete
  run_route
  expect_field fix-untouched-delete-edited "$WIDGET" second .route file
  expect_field fix-untouched-delete-edited "$WIDGET" second .authored false
  expect_field fix-untouched-delete-edited "$WIDGET" first .route delete

  reset_verdict_state
  seed "$WIDGET" "second" delete
  run_route
  expect_field delete-untouched "$WIDGET" second .route delete
  expect_field delete-untouched "$WIDGET" second .authored false

  reset_verdict_state
  seed "$WIDGET" "first" keep
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "third" fix
  seed "$WIDGET" "third" keep
  run_route
  expect_field replay-order "$WIDGET" first .route fix
  expect_field replay-order "$WIDGET" third .route keep
}

# The rows edit cumulatively on one branch; the base-story row runs before the
# meta row because a meta edit makes Beta authored too.
@test "authored by edit position: a last-line-only edit, a base-story-only edit and not an unrelated story, a meta-only edit makes every story" {
  commit_widget_edits
  run_route
  expect_field last-line-edit "$WIDGET" third .authored true
  expect_field last-line-edit "$WIDGET" second .authored false

  edit_story_alpha_declaration
  commit_paths "$MARKER_STORY"
  run_route
  [ "$status" -eq 0 ] || { echo "row base-story-edit: status $status" >&2; return 1; }
  expect_field base-story-edit "$MARKER_STORY" "Alpha   base story" .authored true
  expect_field base-story-edit "$MARKER_STORY" "Alpha   shows alpha" .authored true
  expect_field base-story-edit "$MARKER_STORY" "Beta   base story" .authored false
  expect_field base-story-edit "$MARKER_STORY" "Beta   shows beta" .authored false

  edit_story_meta
  commit_paths "$MARKER_STORY"
  run_route
  expect_field meta-edit "$MARKER_STORY" "Alpha   base story" .authored true
  expect_field meta-edit "$MARKER_STORY" "Alpha   shows alpha" .authored true
  expect_field meta-edit "$MARKER_STORY" "Beta   base story" .authored true
  expect_field meta-edit "$MARKER_STORY" "Beta   shows beta" .authored true
}

@test "a base that does not resolve prints an empty list and exits 0" {
  commit_widget_edits
  git -C "$REPO" branch -m main trunk
  run_route
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a local default branch ahead of its remote selects the test and reads it as not authored" {
  commit_widget_edits
  local base
  base="$(git -C "$REPO" rev-parse main)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --ff-only feature
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  seed "$WIDGET" "first" fix
  run_route
  [ "$status" -eq 0 ]
  [ "$(field "$WIDGET" first .authored)" = false ]
  [ "$(field "$WIDGET" first .route)" = file ]
}

@test "an authorship answer of unknown reads as authored" {
  commit_widget_edits
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  local real_git
  real_git="$(command -v git)"
  printf '#!/bin/bash\ncase "$*" in *-U0*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real_git" >"$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  seed "$WIDGET" "second" fix
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_route
  [ "$status" -eq 0 ]
  [ "$(field "$WIDGET" second .authored)" = true ]
  [ "$(field "$WIDGET" second .route)" = fix ]
}

# One fixture serves every row: each broken input is restored before the next
# row, a clean flow route is proven before the uats row so its exit 3 comes from
# the SPEC, and the old-format story runs last because it stays committed.
@test "route fails closed, never an empty list: a missing classifier, a package load failure, one flow flag without the other, a SPEC carrying uats, an extractor refusal" {
  commit_widget_edits

  rm -f "$REPO/.gaia/scripts/classifier"
  run_route
  [ "$status" -eq 3 ] || { echo "row missing-classifier: status $status" >&2; return 1; }
  grep -qF -- "classifier" <<<"$stderr" || { echo "row missing-classifier: stderr lacks the reason: $stderr" >&2; return 1; }
  [ "$output" != "[]" ] || { echo "row missing-classifier: printed an empty list" >&2; return 1; }
  ln -sfn "$HOME_ROOT/.gaia/scripts/classifier" "$REPO/.gaia/scripts/classifier"

  [ -e "$REPO/.gaia/packages.json" ] && { echo "row package-load-failure: the fixture already has a registry" >&2; return 1; }
  printf 'not json\n' >"$REPO/.gaia/packages.json"
  run_route
  [ "$status" -eq 3 ] || { echo "row package-load-failure: status $status" >&2; return 1; }
  [ -n "$stderr" ] || { echo "row package-load-failure: empty stderr" >&2; return 1; }
  [ "$output" != "[]" ] || { echo "row package-load-failure: printed an empty list" >&2; return 1; }
  rm -f "$REPO/.gaia/packages.json"

  commit_flow_tests
  write_flows_spec
  run bash "$STEP" route --root "$REPO" --run-folder "$RUN_FOLDER" --flows-spec "$FLOWS_SPEC"
  [ "$status" -eq 2 ] || { echo "row flows-spec-only: status $status" >&2; return 1; }
  run bash "$STEP" route --root "$REPO" --run-folder "$RUN_FOLDER" --flow-tests "$FLOW_TESTS"
  [ "$status" -eq 2 ] || { echo "row flow-tests-only: status $status" >&2; return 1; }
  run_flow_route
  [ "$status" -eq 0 ] || { echo "row spec-carrying-uats: the restored fixture does not route cleanly: status $status: $stderr" >&2; return 1; }
  printf '%s\n' '---' 'spec_id: SPEC-900' 'uats:' '  - uat_id: UAT-001' '---' >"$FLOWS_SPEC"
  run_flow_route
  [ "$status" -eq 3 ] || { echo "row spec-carrying-uats: status $status" >&2; return 1; }
  [ -n "$stderr" ] || { echo "row spec-carrying-uats: empty stderr" >&2; return 1; }
  [ "$output" != "[]" ] || { echo "row spec-carrying-uats: printed an empty list" >&2; return 1; }

  cp "$HOME_ROOT/.gaia/tests/hooks/fixtures/test-signals/csf3-old-format.stories.tsx" "$REPO/apps/web/app/components/Marker/old.stories.tsx"
  commit_paths apps/web/app/components/Marker/old.stories.tsx
  run_route
  [ "$status" -eq 3 ] || { echo "row extractor-refusal: status $status" >&2; return 1; }
  grep -qF -- "old-format" <<<"$stderr" || { echo "row extractor-refusal: stderr lacks the reason: $stderr" >&2; return 1; }
  [ "$output" != "[]" ] || { echo "row extractor-refusal: printed an empty list" >&2; return 1; }
}

@test "record then route in one case reads the line record wrote through the ledger seam" {
  commit_widget_edits
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "second", verdict: "keep"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LEDGER" | tr -d ' ')" = 1 ]
  run_route
  [ "$(field "$WIDGET" second .route)" = keep ]
}

@test "settlement routes: a fixed settlement at a fix line's signal routes residual and a stale one changes nothing, a fixed settlement alone settles nothing, residual and refused route settled and lapse on an edit" {
  commit_widget_edits

  reset_verdict_state
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "third" fix
  settle "$WIDGET" first fixed
  settle "$WIDGET" third fixed "sha256:stale"
  run_route
  expect_field fixed-at-fix-signal "$WIDGET" first .route residual
  expect_field fixed-at-stale-signal "$WIDGET" third .route fix

  reset_verdict_state
  settle "$WIDGET" second fixed
  run_route
  expect_field fixed-without-stored-fix "$WIDGET" second .route evaluate

  reset_verdict_state
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "second" fix
  settle "$WIDGET" first residual
  settle "$WIDGET" second refused
  run_route
  expect_field residual-settles "$WIDGET" first .route settled
  expect_field refused-settles "$WIDGET" second .route settled

  sed -i.bak 's/expect(2).toBe(2);/expect(2).toBeTruthy();/;s/expect(value).toBeTruthy();/expect(value).toBeDefined();/' "$REPO/$WIDGET"
  rm -f "$REPO/$WIDGET.bak"
  commit_paths "$WIDGET"
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "second" keep
  run_route
  expect_field residual-lapses-on-edit "$WIDGET" first .route fix
  expect_field refused-lapses-on-edit "$WIDGET" second .route keep
}

@test "settling residual twice leaves one recorded row and route changes no file" {
  commit_widget_edits
  seed "$WIDGET" "first" fix
  settle "$WIDGET" first residual
  settle "$WIDGET" first residual
  [ "$(wc -l <"$RUN_FOLDER/recorded-residuals.jsonl" | tr -d ' ')" = 1 ]
  [ "$(wc -l <"$RUN_FOLDER/worthiness-settlements.jsonl" | tr -d ' ')" = 1 ]
  [ "$(jq -r '.finding_class + " " + .path + " " + (.line | tostring) + " " + .source' "$RUN_FOLDER/recorded-residuals.jsonl")" = "holistic/unclassified $WIDGET 3 worthiness" ]
  local before
  before="$(state_checksum)"
  run_route
  [ "$status" -eq 0 ]
  [ "$(state_checksum)" = "$before" ]
}

@test "settle and record validation refusals append nothing: settle as residual without a first line or a reason, a fix verdict with no artifact, a flow key missing undeclaredFolders" {
  run bash "$STEP" settle --run-folder "$RUN_FOLDER" --file f --full-name n --signal s --as residual --reason r
  [ "$status" -eq 2 ] || { echo "row settle-without-first-line: status $status" >&2; return 1; }
  run bash "$STEP" settle --run-folder "$RUN_FOLDER" --file f --full-name n --signal s --as residual --first-line 3
  [ "$status" -eq 2 ] || { echo "row settle-without-reason: status $status" >&2; return 1; }
  [ -e "$RUN_FOLDER/recorded-residuals.jsonl" ] && { echo "row settle: a residual was recorded" >&2; return 1; }

  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "second", verdict: "keep"}, {file: $f, fullName: "first", verdict: "fix"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -ne 0 ] || { echo "row fix-without-artifact: accepted" >&2; return 1; }
  [ -s "$LEDGER" ] && { echo "row fix-without-artifact: ledger appended" >&2; return 1; }

  commit_flow_tests
  flow_verdicts '{"flowId":"FLOW-002","missingOutcome":null}' fix
  run --separate-stderr bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 3 ] || { echo "row flow-key-without-undeclared-folders: status $status" >&2; return 1; }
  grep -qF -- "refuses bad input" <<<"$stderr" || { echo "row flow-key-without-undeclared-folders: stderr: $stderr" >&2; return 1; }
  [ -s "$LEDGER" ] && { echo "row flow-key-without-undeclared-folders: ledger appended" >&2; return 1; }
  true
}

# bats test_tags=protected
@test "record with a verdict missing for an evaluate test exits 1 naming it and appends nothing" {
  commit_widget_edits
  run_route
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/route.json"
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "first", verdict: "keep"}, {file: $f, fullName: "second", verdict: "keep"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json" --expect "$BATS_TEST_TMPDIR/route.json"
  [ "$status" -eq 1 ]
  grep -qF -- "third" <<<"$output"
  [ ! -s "$LEDGER" ]
}

@test "record with a complete verdict file appends one line per verdict and keeps the old line after a fix" {
  commit_widget_edits
  run_route
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/route.json"
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "first", verdict: "fix", artifact: "weak assertion"},
    {file: $f, fullName: "second", verdict: "keep"}, {file: $f, fullName: "third", verdict: "delete", artifact: "dup"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json" --expect "$BATS_TEST_TMPDIR/route.json"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LEDGER" | tr -d ' ')" = 3 ]
  [ "$(jq -r 'select(.fullName == "first") | .verdict' "$LEDGER")" = fix ]
  local old_signal
  old_signal="$(jq -r 'select(.fullName == "first") | .signal' "$LEDGER")"

  sed -i.bak 's/expect(value).toBeTruthy();/expect(value).toBeDefined();/' "$REPO/$WIDGET"
  rm -f "$REPO/$WIDGET.bak"
  commit_paths "$WIDGET"
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "first", verdict: "keep"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg s "$old_signal" 'select(.fullName == "first" and .signal == $s) | .verdict' "$LEDGER")" = fix ]
  [ "$(jq -r 'select(.fullName == "first") | .verdict' "$LEDGER" | tr '\n' ' ')" = "fix keep " ]
}

@test "record without expect on an uncommitted test appends at the working file's signal" {
  edit_widget_first_midbody
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "first", verdict: "keep"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.signal' "$LEDGER")" = "$(signal_of "$WIDGET" first)" ]
}

@test "finding output passes the filer screen as clear" {
  commit_widget_edits
  seed "$WIDGET" "second" fix
  run_route
  jq -c '.[] | select(.fullName == "second")' <<<"$output" >"$BATS_TEST_TMPDIR/entry.json"
  run bash "$STEP" finding --entry "$BATS_TEST_TMPDIR/entry.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/finding.json"
  [ "$(jq -r '.member + " " + .finding_class + " " + .path + " " + (.line | tostring)' "$BATS_TEST_TMPDIR/finding.json")" = "worthiness-evaluator holistic/unclassified $WIDGET 9" ]
  [ "$(jq -r '.failure_mode == .suggested_fix and .failure_mode == "an artifact"' "$BATS_TEST_TMPDIR/finding.json")" = true ]
  run bash "$HOME_ROOT/.gaia/scripts/file-tech-debt.sh" screen --finding "$BATS_TEST_TMPDIR/finding.json"
  [ "$status" -eq 0 ]
  [ "$output" = clear ]
}

@test "prune drops a worthiness row whose signal changed, keeps a current one and a replay row" {
  commit_widget_edits
  local current stale
  current="$(signal_of "$WIDGET" second)"
  stale="sha256:stale"
  {
    jq -nc --arg f "$WIDGET" --arg s "$current" '{source: "worthiness", member: "worthiness-evaluator", finding_class: "holistic/unclassified", path: $f, line: 9, reason: "r", file: $f, fullName: "second", signal: $s}'
    jq -nc --arg f "$WIDGET" --arg s "$stale" '{source: "worthiness", member: "worthiness-evaluator", finding_class: "holistic/unclassified", path: $f, line: 3, reason: "r", file: $f, fullName: "first", signal: $s}'
    jq -nc '{source: "filing-replay", member: "code-audit-frontend", finding_class: "rule/x", path: "apps/web/a.ts", line: 0, reason: "r"}'
  } >"$RUN_FOLDER/recorded-residuals.jsonl"
  run bash "$STEP" prune --root "$REPO" --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$RUN_FOLDER/recorded-residuals.jsonl" | tr -d ' ')" = 2 ]
  [ "$(jq -r '.fullName // .source' "$RUN_FOLDER/recorded-residuals.jsonl" | tr '\n' ' ')" = "second filing-replay " ]
}

ROUTE_TEST="apps/web/app/route-tests/orders/tests/refuses-anonymous.test.ts"

commit_route_test() {
  mkdir -p "$REPO/$(dirname "$ROUTE_TEST")"
  printf '%s\n' \
    "import {expect, test} from 'vitest';" \
    "" \
    "test('refuses an anonymous visitor', () => {" \
    "  expect(1 + 1).toBe(2);" \
    "});" >"$REPO/$ROUTE_TEST"
  commit_paths "$ROUTE_TEST"
}

@test "route lists a changed test by its classification: a route test, a strict util test and a test helper folder test" {
  write_builtin_descriptor "$REPO" '' '' '["app/route-tests/**/*.test.ts"]'
  commit_route_test
  run_route
  [ "$status" -eq 0 ] || { echo "row route-test: status $status" >&2; return 1; }
  expect_field route-test "$ROUTE_TEST" 'refuses an anonymous visitor' .route evaluate

  write_builtin_descriptor "$REPO" '' '' '["test/**/*.test.ts"]'
  mkdir -p "$REPO/apps/web/app/utils/x" "$REPO/apps/web/test"
  printf '%s\n' \
    "import {expect, test} from 'vitest';" \
    "" \
    "test('adds two numbers', () => {" \
    "  expect(1 + 1).toBe(2);" \
    "});" >"$REPO/apps/web/app/utils/x/index.test.ts"
  cp "$REPO/apps/web/app/utils/x/index.test.ts" "$REPO/apps/web/test/helper.test.ts"
  commit_paths apps/web/app/utils/x/index.test.ts apps/web/test/helper.test.ts
  run_route
  [ "$status" -eq 0 ] || { echo "row strict-util-and-helper: status $status" >&2; return 1; }
  expect_field strict-util apps/web/app/utils/x/index.test.ts 'adds two numbers' .route evaluate
  expect_field helper-folder apps/web/test/helper.test.ts 'adds two numbers' .route evaluate
}

FLOW_BATS=".gaia/tests/lib/refuses-bad-input.bats"
FLOW_WEB="apps/web/.playwright/flows/sign-in.spec.ts"

write_flows_spec() {
  FLOWS_SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  printf '%s\n' \
    '---' \
    'spec_id: SPEC-900' \
    'title: Sample' \
    'flows:' \
    '  - flow_id: FLOW-001' \
    '    slug: sign-in' \
    '    name: A returning user signs in' \
    '    why: Breaking it blocks the main task' \
    '    covers: [app/pages/sign-in, app/routes/drafts]' \
    '  - flow_id: FLOW-002' \
    '    slug: refuses-bad-input' \
    '    name: The command refuses bad input' \
    '    why: A silent pass would hide a broken gate' \
    "    test_path: $FLOW_BATS" \
    '---' \
    '' \
    '# Sample' >"$FLOWS_SPEC"
}

# A bats flow test the scope globs exclude, and a web flow spec they include;
# the flow-tests file lists both.
# shellcheck disable=SC2016
commit_flow_tests() {
  local AT=@
  mkdir -p "$REPO/$(dirname "$FLOW_BATS")" "$REPO/$(dirname "$FLOW_WEB")"
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    "${AT}test \"refuses bad input\" {" \
    '  run false' \
    '  [ "$status" -eq 1 ]' \
    '}' >"$REPO/$FLOW_BATS"
  printf '%s\n' \
    "import {expect, test} from '@playwright/test';" \
    "" \
    "test('signs in', async () => {" \
    "  expect(1).toBe(1);" \
    "});" >"$REPO/$FLOW_WEB"
  commit_paths "$FLOW_BATS" "$FLOW_WEB"
  FLOW_TESTS="$BATS_TEST_TMPDIR/flow-tests.tsv"
  printf 'FLOW-001\tsign-in\tweb\t%s\nFLOW-002\trefuses-bad-input\tcommand\t%s\n' "$FLOW_WEB" "$FLOW_BATS" >"$FLOW_TESTS"
}

run_flow_route() {
  run --separate-stderr bash "$STEP" route --root "$REPO" --run-folder "$RUN_FOLDER" --flows-spec "$FLOWS_SPEC" --flow-tests "$FLOW_TESTS"
}

@test "route with flow inputs tags flow tests: a bats flow test the globs exclude is selected with its flow, a web flow spec gets its covers from the SPEC" {
  commit_widget_edits
  commit_flow_tests
  write_flows_spec
  run_flow_route
  [ "$status" -eq 0 ] || { echo "status $status: $stderr" >&2; return 1; }
  expect_field bats-flow "$FLOW_BATS" 'refuses bad input' .route evaluate
  expect_field bats-flow "$FLOW_BATS" 'refuses bad input' .flow.name "The command refuses bad input"
  expect_field bats-flow "$FLOW_BATS" 'refuses bad input' .flow.why "A silent pass would hide a broken gate"
  expect_field bats-flow "$FLOW_BATS" 'refuses bad input' .flow.testPath "$FLOW_BATS"
  expect_field bats-flow "$FLOW_BATS" 'refuses bad input' .flow.covers null
  expect_field non-flow "$WIDGET" first 'has("flow")' false
  expect_field web-flow "$FLOW_WEB" 'signs in' .flow.flowId FLOW-001
  expect_field web-flow "$FLOW_WEB" 'signs in' '.flow.covers | join(",")' "app/pages/sign-in,app/routes/drafts"
  expect_field web-flow "$FLOW_WEB" 'signs in' .flow.testPath null
}

flow_verdicts() {
  jq -nc --arg f "$FLOW_BATS" --argjson flow "$1" --arg v "$2" \
    '[{file: $f, fullName: "refuses bad input", verdict: $v, flow: $flow} + (if $v == "keep" then {} else {artifact: "an artifact"} end)]' >"$BATS_TEST_TMPDIR/verdicts.json"
}

@test "record writes a flow key: keeps a well-formed one on a bats flow test's ledger line, and neither requires nor routes untestedErrorPaths" {
  commit_flow_tests
  flow_verdicts '{"flowId":"FLOW-002","missingOutcome":"never asserts the write took effect","undeclaredFolders":[]}' fix
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ] || { echo "row well-formed: status $status" >&2; return 1; }
  [ "$(jq -r '.flow.flowId' "$LEDGER")" = FLOW-002 ] || { echo "row well-formed: flowId" >&2; return 1; }
  [ "$(jq -r '.flow.missingOutcome' "$LEDGER")" = "never asserts the write took effect" ] || { echo "row well-formed: missingOutcome" >&2; return 1; }
  [ "$(jq -r '.signal' "$LEDGER")" = "$(signal_of "$FLOW_BATS" 'refuses bad input')" ] || { echo "row well-formed: signal" >&2; return 1; }

  reset_verdict_state
  flow_verdicts '{"flowId":"FLOW-002","untestedErrorPaths":[{"source":"a.sh:3","description":"d"}],"missingOutcome":null,"undeclaredFolders":[]}' keep
  run --separate-stderr bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ] || { echo "row with-untested-error-paths: status $status" >&2; return 1; }
  [ "$(jq -r '.verdict' "$LEDGER")" = keep ] || { echo "row with-untested-error-paths: verdict" >&2; return 1; }
  flow_verdicts '{"flowId":"FLOW-002","missingOutcome":null,"undeclaredFolders":[]}' keep
  run --separate-stderr bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -eq 0 ] || { echo "row without-untested-error-paths: status $status" >&2; return 1; }
}
