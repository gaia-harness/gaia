#!/usr/bin/env bats
#
# Suite for .gaia/scripts/worthiness-step.sh: routing, recording, settling,
# the filer finding and pruning for the pre-audit worthiness step.
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

WIDGET="frontend/app/components/Widget/widget.test.tsx"
MARKER_STORY="frontend/app/components/Marker/marker.stories.tsx"
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

  mkdir -p "$REPO/frontend/app/components/Widget" "$REPO/frontend/app/components/Marker"
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
  for library in gaia-packages.sh red-ledger.sh worthiness-ledger.sh worthiness-selection.sh audit-base-provenance.sh; do
    ln -sfn "$HOME_ROOT/.claude/hooks/lib/$library" "$REPO/.claude/hooks/lib/$library"
  done
  for library in branch-authorship-lib.sh main-root-lib.sh audit-ledger red-ledger classifier; do
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
  (cd "$REPO" && node "$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs" "$1") |
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

@test "keep at the current signal is keep, at a stale signal is evaluate, with no line is evaluate" {
  commit_widget_edits
  seed "$WIDGET" "second" keep
  seed "$WIDGET" "third" keep "sha256:stale"
  run_route
  [ "$status" -eq 0 ]
  [ "$(field "$WIDGET" second .route)" = keep ]
  [ "$(field "$WIDGET" third .route)" = evaluate ]
  [ "$(field "$WIDGET" first .route)" = evaluate ]
}

@test "a fix on a test edited mid-body routes fix and authored" {
  commit_widget_edits
  seed "$WIDGET" "first" fix
  run_route
  [ "$(field "$WIDGET" first .route)" = fix ]
  [ "$(field "$WIDGET" first .authored)" = true ]
  [ "$(field "$WIDGET" first .artifact)" = "an artifact" ]
}

@test "a fix on an untouched test in an edited file routes file, a delete on it routes delete" {
  commit_widget_edits
  seed "$WIDGET" "second" fix
  seed "$WIDGET" "first" delete
  run_route
  [ "$(field "$WIDGET" second .route)" = file ]
  [ "$(field "$WIDGET" second .authored)" = false ]
  [ "$(field "$WIDGET" first .route)" = delete ]
}

@test "a delete on an untouched test routes delete" {
  commit_widget_edits
  seed "$WIDGET" "second" delete
  run_route
  [ "$(field "$WIDGET" second .route)" = delete ]
  [ "$(field "$WIDGET" second .authored)" = false ]
}

@test "a test whose only edited line is its last line is authored" {
  commit_widget_edits
  run_route
  [ "$(field "$WIDGET" third .authored)" = true ]
  [ "$(field "$WIDGET" second .authored)" = false ]
}

@test "a base-story-only edit makes that story and its tests authored and not an unrelated story" {
  edit_story_alpha_declaration
  commit_paths "$MARKER_STORY"
  run_route
  [ "$status" -eq 0 ]
  [ "$(field "$MARKER_STORY" "Alpha   base story" .authored)" = true ]
  [ "$(field "$MARKER_STORY" "Alpha   shows alpha" .authored)" = true ]
  [ "$(field "$MARKER_STORY" "Beta   base story" .authored)" = false ]
  [ "$(field "$MARKER_STORY" "Beta   shows beta" .authored)" = false ]
}

@test "a meta-only edit makes every story in the file authored" {
  edit_story_meta
  commit_paths "$MARKER_STORY"
  run_route
  [ "$(field "$MARKER_STORY" "Alpha   base story" .authored)" = true ]
  [ "$(field "$MARKER_STORY" "Alpha   shows alpha" .authored)" = true ]
  [ "$(field "$MARKER_STORY" "Beta   base story" .authored)" = true ]
  [ "$(field "$MARKER_STORY" "Beta   shows beta" .authored)" = true ]
}

@test "keep then fix at one signal routes fix, fix then keep routes keep" {
  commit_widget_edits
  seed "$WIDGET" "first" keep
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "third" fix
  seed "$WIDGET" "third" keep
  run_route
  [ "$(field "$WIDGET" first .route)" = fix ]
  [ "$(field "$WIDGET" third .route)" = keep ]
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

@test "a missing classifier exits 3 with the reason on stderr and never an empty list" {
  commit_widget_edits
  rm -f "$REPO/.gaia/scripts/classifier"
  run_route
  [ "$status" -eq 3 ]
  grep -qF -- "classifier" <<<"$stderr"
  [ "$output" != "[]" ]
}

@test "a package load failure exits 3 and never prints an empty list" {
  commit_widget_edits
  printf 'not json\n' >"$REPO/.gaia/packages.json"
  run_route
  [ "$status" -eq 3 ]
  [ -n "$stderr" ]
  [ "$output" != "[]" ]
}

@test "an extractor refusal exits 3 with the reason on stderr and never an empty list" {
  cp "$HOME_ROOT/.gaia/tests/hooks/fixtures/red-ledger/csf3-old-format.stories.tsx" "$REPO/frontend/app/components/Marker/old.stories.tsx"
  commit_paths frontend/app/components/Marker/old.stories.tsx
  run_route
  [ "$status" -eq 3 ]
  grep -qF -- "old-format" <<<"$stderr"
  [ "$output" != "[]" ]
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

@test "a fixed settlement at a fix line's signal routes residual, a stale fixed row changes nothing" {
  commit_widget_edits
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "third" fix
  settle "$WIDGET" first fixed
  settle "$WIDGET" third fixed "sha256:stale"
  run_route
  [ "$(field "$WIDGET" first .route)" = residual ]
  [ "$(field "$WIDGET" third .route)" = fix ]
}

@test "a fixed settlement alone does not settle a test with no stored fix" {
  commit_widget_edits
  settle "$WIDGET" second fixed
  run_route
  [ "$(field "$WIDGET" second .route)" = evaluate ]
}

@test "residual and refused settlements route settled and lapse when the test is edited" {
  commit_widget_edits
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "second" fix
  settle "$WIDGET" first residual
  settle "$WIDGET" second refused
  run_route
  [ "$(field "$WIDGET" first .route)" = settled ]
  [ "$(field "$WIDGET" second .route)" = settled ]

  sed -i.bak 's/expect(2).toBe(2);/expect(2).toBeTruthy();/;s/expect(value).toBeTruthy();/expect(value).toBeDefined();/' "$REPO/$WIDGET"
  rm -f "$REPO/$WIDGET.bak"
  commit_paths "$WIDGET"
  seed "$WIDGET" "first" fix
  seed "$WIDGET" "second" keep
  run_route
  [ "$(field "$WIDGET" first .route)" = fix ]
  [ "$(field "$WIDGET" second .route)" = keep ]
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

@test "settle as residual needs a first line and a reason" {
  run bash "$STEP" settle --run-folder "$RUN_FOLDER" --file f --full-name n --signal s --as residual --reason r
  [ "$status" -eq 2 ]
  run bash "$STEP" settle --run-folder "$RUN_FOLDER" --file f --full-name n --signal s --as residual --first-line 3
  [ "$status" -eq 2 ]
  [ ! -e "$RUN_FOLDER/recorded-residuals.jsonl" ]
}

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

@test "record refuses a fix verdict with no artifact and appends nothing" {
  jq -nc --arg f "$WIDGET" '[{file: $f, fullName: "second", verdict: "keep"}, {file: $f, fullName: "first", verdict: "fix"}]' >"$BATS_TEST_TMPDIR/verdicts.json"
  run bash "$STEP" record --root "$REPO" --verdicts "$BATS_TEST_TMPDIR/verdicts.json"
  [ "$status" -ne 0 ]
  [ ! -s "$LEDGER" ]
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
    jq -nc '{source: "filing-replay", member: "code-audit-frontend", finding_class: "rule/x", path: "frontend/a.ts", line: 0, reason: "r"}'
  } >"$RUN_FOLDER/recorded-residuals.jsonl"
  run bash "$STEP" prune --root "$REPO" --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$RUN_FOLDER/recorded-residuals.jsonl" | tr -d ' ')" = 2 ]
  [ "$(jq -r '.fullName // .source' "$RUN_FOLDER/recorded-residuals.jsonl" | tr '\n' ' ')" = "second filing-replay " ]
}
