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
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/test-signals/extract-test-signals.mjs"
  SHAPES_PATH="apps/web/app/utils/tests/csf-shapes.stories.tsx"
  META_PLAY_PATH="apps/web/app/utils/tests/csf-meta-play.stories.tsx"
  CSF3_PATH=".gaia/tests/hooks/fixtures/test-signals/csf3-old-format.stories.tsx"
  CSF2_PATH=".gaia/tests/hooks/fixtures/test-signals/csf2-old-format.stories.tsx"
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

# Each row edits the shapes fixture once (OLD to NEW) and names the entries
# that edit must rotate, separated by ";"; every other shapes entry must keep
# its signal.
@test "editing one story or test rotates only the signals that depend on it: the source play, a sibling story, one test body" {
  local row label old new rotated_list before after copy full_name
  local -a rotated
  before=$(signals_of_path "$SHAPES_PATH")
  for full_name in "${SHAPES_NAMES[@]}"; do
    [ -n "$(signal_for "$before" "$full_name")" ] || { echo "no entry for $full_name" >&2; return 1; }
  done
  for row in \
    "source-play|canvasElement.dataset.played = 'play with tests';|canvasElement.dataset.played = 'edited play';|$(IFS=';'; printf '%s' "${PLAY_SOURCE_NAMES[*]}")" \
    "sibling-story|args: {text: 'play only marker'},|args: {text: 'edited play only marker'},|Play Only" \
    "test-body|await expect(canvas.getByText('play marker')).toBeVisible();|await expect(canvas.getByText('play marker')).toBeInTheDocument();|Play With Tests   shows the marker"; do
    IFS='|' read -r label old new rotated_list <<<"$row"
    IFS=';' read -r -a rotated <<<"$rotated_list"
    copy=$(edited_shapes_copy "$old" "$new") || { echo "case $label: edit not applied" >&2; return 1; }
    after=$(signals_of_source "$SHAPES_PATH" "$copy")
    [ "$(grep -c . <<<"$after")" -eq "${#SHAPES_NAMES[@]}" ] || { echo "case $label: entry count changed" >&2; return 1; }
    for full_name in "${SHAPES_NAMES[@]}"; do
      if printf '%s\n' "${rotated[@]}" | grep -qxF -- "$full_name"; then
        [ "$(signal_for "$before" "$full_name")" != "$(signal_for "$after" "$full_name")" ] || { echo "case $label: signal unchanged for $full_name" >&2; return 1; }
      else
        [ "$(signal_for "$before" "$full_name")" = "$(signal_for "$after" "$full_name")" ] || { echo "case $label: signal moved for $full_name" >&2; return 1; }
      fi
    done
  done
}

# Row columns: label, repo path the source is judged under, source file,
# expected exit, a marker the committed fixture must still contain ("-" for a
# scratch source), and the expected text. Exit 8 expects exactly the one
# migration line; exit 7 expects the refusal text; exit 0 expects the one
# parsed fullName on stdout.
@test "an unsupported story file exits 7 or 8 with the refusal line and no stdout; a CSF4 relative preview path is parsed" {
  local row label relative_path source_file expected_status marker expected
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "import {sharedPlay} from './shared-play';" \
    "const meta = preview.meta({title: 'Internal/Imported'});" \
    "export const UsesImportedPlay = meta.story({play: sharedPlay});" > "$BATS_TEST_TMPDIR/imported.stories.tsx"
  printf '%s\n' \
    "import preview from '../../.storybook/preview';" \
    "const meta = preview.meta({title: 'Internal/Relative'});" \
    "export const Relative = meta.story({play: async () => {}});" > "$BATS_TEST_TMPDIR/relative.stories.tsx"
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "const meta = preview.meta({title: 'Internal/Unknown'});" \
    "export const Leftover = {args: {text: 'left over'}};" > "$BATS_TEST_TMPDIR/unknown.stories.tsx"
  for row in \
    "csf3|$CSF3_PATH|$HOME_ROOT/$CSF3_PATH|8|export default meta;|extract-test-signals: $CSF3_PATH $MIGRATE_LINE_SUFFIX" \
    "csf2|$CSF2_PATH|$HOME_ROOT/$CSF2_PATH|8|Template.bind({})|extract-test-signals: $CSF2_PATH $MIGRATE_LINE_SUFFIX" \
    "imported-play|apps/web/app/utils/tests/imported.stories.tsx|$BATS_TEST_TMPDIR/imported.stories.tsx|7|-|unsupported story shape in apps/web/app/utils/tests/imported.stories.tsx: UsesImportedPlay" \
    "relative-preview|apps/web/app/utils/tests/relative.stories.tsx|$BATS_TEST_TMPDIR/relative.stories.tsx|0|-|Relative" \
    "object-literal-export|apps/web/app/utils/tests/unknown.stories.tsx|$BATS_TEST_TMPDIR/unknown.stories.tsx|7|-|unsupported story shape in apps/web/app/utils/tests/unknown.stories.tsx: default: the file is not a CSF4 story file"; do
    IFS='|' read -r label relative_path source_file expected_status marker expected <<<"$row"
    if [ "$marker" != "-" ]; then
      grep -qF -- "$marker" "$source_file" || { echo "case $label: fixture no longer contains $marker" >&2; return 1; }
    fi
    run_extractor_on_source "$relative_path" "$source_file"
    [ "$status" -eq "$expected_status" ] || { echo "case $label: status=$status" >&2; return 1; }
    case "$expected_status" in
      0)
        [ "$(jq -r '.fullName' <<<"$output")" = "$expected" ] || { echo "case $label: output=$output" >&2; return 1; } ;;
      7)
        [ -z "$output" ] || { echo "case $label: stdout=$output" >&2; return 1; }
        grep -qF -- "$expected" "$BATS_TEST_TMPDIR/stderr.txt" || { echo "case $label: stderr=$(cat "$BATS_TEST_TMPDIR/stderr.txt")" >&2; return 1; } ;;
      8)
        [ -z "$output" ] || { echo "case $label: stdout=$output" >&2; return 1; }
        grep -qxF -- "$expected" "$BATS_TEST_TMPDIR/stderr.txt" || { echo "case $label: stderr=$(cat "$BATS_TEST_TMPDIR/stderr.txt")" >&2; return 1; }
        [ "$(grep -c . "$BATS_TEST_TMPDIR/stderr.txt")" -eq 1 ] || { echo "case $label: stderr not one line" >&2; return 1; } ;;
    esac
  done
}
