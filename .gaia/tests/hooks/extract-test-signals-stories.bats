#!/usr/bin/env bats

# The test-identity extractor over the committed CSF4 fixture stories: which
# entries it emits, which edits move an entry's signal, and which files it
# refuses. The comparison with Storybook's own reporter, which needs Chromium,
# lives in extract-test-signals-stories-reporter.bats.
#
# The fixtures are two files because a meta-level play is inherited by every
# story in its file: the render-only stories cannot share a file with it.

# bats file_tags=installed-dependencies

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  SHAPES_PATH="frontend/app/utils/tests/csf-shapes.stories.tsx"
  META_PLAY_PATH="frontend/app/utils/tests/csf-meta-play.stories.tsx"
  CSF3_PATH=".gaia/tests/hooks/fixtures/red-ledger/csf3-old-format.stories.tsx"
  CSF2_PATH=".gaia/tests/hooks/fixtures/red-ledger/csf2-old-format.stories.tsx"
  MIGRATE_LINE_SUFFIX="is an old-format story file; migrate it with: .gaia/cli/gaia migrate-csf4"
}

# Extractor output for a repo-relative path read from the checkout.
signals_of_path() {
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "$1" )
}

# Extractor output for edited source fed on stdin under the original path, so
# an edit on a scratch copy is judged as an edit to the real file.
signals_of_source() {
  local relative_path="$1" source_file="$2"
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "$relative_path" --stdin < "$source_file" )
}

# Runs the extractor on stdin source under a given path, capturing stderr.
run_extractor_on_source() {
  local relative_path="$1" source_file="$2"
  run bash -c 'cd "$1" && node "$2" "$3" --stdin < "$4" 2>"$5"' _ "$HOME_ROOT" "$EXTRACTOR" "$relative_path" "$source_file" "$BATS_TEST_TMPDIR/stderr.txt"
}

# The signal recorded for one fullName in an NDJSON stream.
signal_for() {
  local ndjson="$1" full_name="$2"
  jq -r --arg n "$full_name" 'select(.fullName == $n) | .signal' <<<"$ndjson"
}

# A scratch copy of the shapes fixture with the first occurrence of OLD
# replaced by NEW; fails when OLD is absent, so a rotation case cannot pass on
# an edit that never happened.
edited_shapes_copy() {
  local old="$1" new="$2" source edited copy="$BATS_TEST_TMPDIR/edited-shapes.stories.tsx"
  source=$(cat "$HOME_ROOT/$SHAPES_PATH")
  [[ "$source" == *"$old"* ]] || { echo "fixture no longer contains: $old" >&2; return 1; }
  edited="${source/"$old"/"$new"}"
  printf '%s\n' "$edited" > "$copy"
  printf '%s' "$copy"
}

# Every fullName the shapes fixture yields, in emission order.
SHAPES_NAMES=(
  "Play With Tests   base story"
  "Play With Tests   shows the marker"
  "Play With Tests   runs the play first"
  "Render With Test   base story"
  "Render With Test   shows the marker"
  "Play Only"
  "Extended Play"
  "Custom Display Name"
  "Extended Named"
)

# The entries a play-body edit to Play With Tests must rotate.
PLAY_SOURCE_NAMES=(
  "Play With Tests   base story"
  "Play With Tests   shows the marker"
  "Play With Tests   runs the play first"
  "Extended Play"
)

# The entries of stories other than Play With Tests and its extend story.
SIBLING_NAMES=(
  "Render With Test   base story"
  "Render With Test   shows the marker"
  "Play Only"
  "Custom Display Name"
  "Extended Named"
)

@test "the shapes fixture yields base story plus each test for test-carrying stories, the plain name for play-only and extend stories, and nothing for the render-only story" {
  local output_ndjson actual expected
  output_ndjson=$(signals_of_path "$SHAPES_PATH")
  actual=$(jq -r '.fullName' <<<"$output_ndjson")
  expected=$(printf '%s\n' "${SHAPES_NAMES[@]}")
  [ "$actual" = "$expected" ] || { printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2; return 1; }

  for absent in "Render Only" "Named Source"; do
    grep -qF -- "$absent" <<<"$actual" && { echo "unexpected entry for $absent" >&2; return 1; }
  done
  [ "$(jq -s 'map(select((.signal | test("^sha256:[0-9a-f]{64}$")) and .kind == "runtime")) | length' <<<"$output_ndjson")" -eq "${#SHAPES_NAMES[@]}" ]
}

@test "an extend story from a named source is emitted under its own export name, never the source's name" {
  local output_ndjson
  output_ndjson=$(signals_of_path "$SHAPES_PATH")
  grep -qF -- "name: 'Custom Display Name'" "$HOME_ROOT/$SHAPES_PATH"
  [ -n "$(signal_for "$output_ndjson" "Extended Named")" ]
  [ "$(jq -s 'map(select(.fullName == "Custom Display Name")) | length' <<<"$output_ndjson")" -eq 1 ]
}

@test "the meta-play fixture yields the inherited-play story and the test-carrying story under it" {
  local actual
  actual=$(signals_of_path "$META_PLAY_PATH" | jq -r '.fullName')
  [ "$actual" = "$(printf '%s\n' "Inherits Meta Play" "Inherits Meta Play With Test   base story" "Inherits Meta Play With Test   runs the meta play first")" ]
}

@test "source fed on stdin under the original path reproduces the file's signals (the rotation cases compare like with like)" {
  local from_path from_stdin
  from_path=$(signals_of_path "$SHAPES_PATH")
  from_stdin=$(signals_of_source "$SHAPES_PATH" "$HOME_ROOT/$SHAPES_PATH")
  [ "$from_path" = "$from_stdin" ]
}

@test "editing the source story's play rotates its base story, each of its tests and the extend story inheriting it, and no sibling" {
  local before after copy full_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy "canvasElement.dataset.played = 'play with tests';" "canvasElement.dataset.played = 'edited play';")
  after=$(signals_of_source "$SHAPES_PATH" "$copy")
  [ "$(grep -c . <<<"$after")" -eq "${#SHAPES_NAMES[@]}" ]

  for full_name in "${PLAY_SOURCE_NAMES[@]}"; do
    [ -n "$(signal_for "$before" "$full_name")" ] || { echo "no entry for $full_name" >&2; return 1; }
    [ "$(signal_for "$before" "$full_name")" != "$(signal_for "$after" "$full_name")" ] || { echo "signal unchanged for $full_name" >&2; return 1; }
  done
  for full_name in "${SIBLING_NAMES[@]}"; do
    [ "$(signal_for "$before" "$full_name")" = "$(signal_for "$after" "$full_name")" ] || { echo "signal moved for $full_name" >&2; return 1; }
  done
}

@test "editing a sibling story leaves the source story's and its extend story's signals unchanged" {
  local before after copy full_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy "args: {text: 'play only marker'}," "args: {text: 'edited play only marker'},")
  after=$(signals_of_source "$SHAPES_PATH" "$copy")

  [ "$(signal_for "$before" "Play Only")" != "$(signal_for "$after" "Play Only")" ]
  for full_name in "${PLAY_SOURCE_NAMES[@]}"; do
    [ -n "$(signal_for "$before" "$full_name")" ] || { echo "no entry for $full_name" >&2; return 1; }
    [ "$(signal_for "$before" "$full_name")" = "$(signal_for "$after" "$full_name")" ] || { echo "signal moved for $full_name" >&2; return 1; }
  done
}

@test "editing one test's body rotates only that test's signal" {
  local before after copy full_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy "await expect(canvas.getByText('play marker')).toBeVisible();" "await expect(canvas.getByText('play marker')).toBeInTheDocument();")
  after=$(signals_of_source "$SHAPES_PATH" "$copy")

  [ "$(signal_for "$before" "Play With Tests   shows the marker")" != "$(signal_for "$after" "Play With Tests   shows the marker")" ]
  for full_name in "${SHAPES_NAMES[@]}"; do
    [ "$full_name" = "Play With Tests   shows the marker" ] && continue
    [ "$(signal_for "$before" "$full_name")" = "$(signal_for "$after" "$full_name")" ] || { echo "signal moved for $full_name" >&2; return 1; }
  done
}

@test "the CSF3 refusal fixture exits 8 with the migration line and no stdout" {
  grep -qF 'export default meta;' "$HOME_ROOT/$CSF3_PATH"
  run_extractor_on_source "$CSF3_PATH" "$HOME_ROOT/$CSF3_PATH"
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  grep -qxF -- "extract-test-signals: $CSF3_PATH $MIGRATE_LINE_SUFFIX" "$BATS_TEST_TMPDIR/stderr.txt"
  [ "$(grep -c . "$BATS_TEST_TMPDIR/stderr.txt")" -eq 1 ]
}

@test "the CSF2 refusal fixture exits 8 with the migration line and no stdout" {
  grep -qF 'Template.bind({})' "$HOME_ROOT/$CSF2_PATH"
  run_extractor_on_source "$CSF2_PATH" "$HOME_ROOT/$CSF2_PATH"
  [ "$status" -eq 8 ]
  [ -z "$output" ]
  grep -qxF -- "extract-test-signals: $CSF2_PATH $MIGRATE_LINE_SUFFIX" "$BATS_TEST_TMPDIR/stderr.txt"
  [ "$(grep -c . "$BATS_TEST_TMPDIR/stderr.txt")" -eq 1 ]
}

@test "a CSF4 file whose play is an imported identifier exits 7, not 8, with the refusal line and no stdout" {
  local source="$BATS_TEST_TMPDIR/imported.stories.tsx"
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "import {sharedPlay} from './shared-play';" \
    "const meta = preview.meta({title: 'Internal/Imported'});" \
    "export const UsesImportedPlay = meta.story({play: sharedPlay});" > "$source"
  run_extractor_on_source "frontend/app/utils/tests/imported.stories.tsx" "$source"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  grep -qF -- "unsupported story shape in frontend/app/utils/tests/imported.stories.tsx: UsesImportedPlay" "$BATS_TEST_TMPDIR/stderr.txt"
}

@test "a CSF4 file importing the preview by a relative .storybook/preview path is parsed, not refused" {
  local source="$BATS_TEST_TMPDIR/relative.stories.tsx"
  printf '%s\n' \
    "import preview from '../../.storybook/preview';" \
    "const meta = preview.meta({title: 'Internal/Relative'});" \
    "export const Relative = meta.story({play: async () => {}});" > "$source"
  run_extractor_on_source "frontend/app/utils/tests/relative.stories.tsx" "$source"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fullName' <<<"$output")" = "Relative" ]
}

@test "a file with an object-literal named export beside preview.meta is unknown and exits 7, not 8" {
  local source="$BATS_TEST_TMPDIR/unknown.stories.tsx"
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "const meta = preview.meta({title: 'Internal/Unknown'});" \
    "export const Leftover = {args: {text: 'left over'}};" > "$source"
  run_extractor_on_source "frontend/app/utils/tests/unknown.stories.tsx" "$source"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  grep -qF -- "unsupported story shape in frontend/app/utils/tests/unknown.stories.tsx: default: the file is not a CSF4 story file" "$BATS_TEST_TMPDIR/stderr.txt"
}
