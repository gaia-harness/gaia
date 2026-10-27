#!/usr/bin/env bats

# The extractor's test names against Storybook's own Vitest reporter. A name
# the extractor computes differently from the reporter would key a worthiness
# verdict to a test that no run ever reports, so this runs the real storybook
# project in Chromium over both CSF4 fixture files and compares: `base story`
# and `.test()` entries (three-space joined under the story name), the
# `.extend` stories, and a name override. A Storybook bump that changes any of
# that naming fails here.
#
# Needs the frontend workspace and Chromium, and fails rather than skips when
# either is missing: a skipped equality check reads as a pass. Kept apart from
# extract-test-signals-stories.bats so the browser install is owed only to the
# leg that holds this file.

# bats file_tags=installed-dependencies

setup_file() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  REPORT="$BATS_FILE_TMPDIR/reporter.json"
  RUN_OUTPUT="$BATS_FILE_TMPDIR/run-output.txt"
  export HOME_ROOT REPORT RUN_OUTPUT
  [ -d "$HOME_ROOT/frontend/node_modules" ] || return 0
  # The run's own exit status is not read: the verdict is the report below, and
  # a no-Chromium run writes one with zero tests next to a launch error.
  pnpm -C "$HOME_ROOT/frontend" exec vitest run --project storybook \
    app/utils/tests/csf-shapes.stories.tsx app/utils/tests/csf-meta-play.stories.tsx \
    --reporter=json --outputFile="$REPORT" < /dev/null > "$RUN_OUTPUT" 2>&1 || true
}

setup() {
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  if [ ! -d "$HOME_ROOT/frontend/node_modules" ]; then
    echo "the frontend workspace is not installed; run pnpm install" >&2
    return 1
  fi
  if ! jq -e '(.numTotalTests // 0) > 0' "$REPORT" >/dev/null 2>&1; then
    echo "the storybook project ran no stories, so Chromium is likely not installed; run pnpm install:browsers" >&2
    head -n 12 "$RUN_OUTPUT" >&2
    return 1
  fi
}

# The reporter's test fullNames for one fixture file, sorted.
reporter_names_for() {
  jq -r --arg suffix "$1" '.testResults[] | select(.name | endswith($suffix)) | .assertionResults[] | .fullName' "$REPORT" | LC_ALL=C sort
}

# The extractor's fullNames for one fixture file, sorted.
extractor_names_for() {
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "frontend/$1" | jq -r '.fullName' ) | LC_ALL=C sort
}

# The tests the reporter runs that the extractor must not emit: a render-only
# story with no tests (it has no play to sign). A `!test` story is never run.
SHAPES_RENDER_ONLY="Render Only"

@test "the shapes fixture's extractor names equal the reporter's names, bar the render-only story" {
  local reporter_names extractor_names expected
  reporter_names=$(reporter_names_for "app/utils/tests/csf-shapes.stories.tsx")
  extractor_names=$(extractor_names_for "app/utils/tests/csf-shapes.stories.tsx")
  [ -n "$extractor_names" ]

  grep -qxF -- "$SHAPES_RENDER_ONLY" <<<"$reporter_names" || { echo "reporter ran no render-only story" >&2; return 1; }
  grep -qxF -- "$SHAPES_RENDER_ONLY" <<<"$extractor_names" && { echo "extractor emitted the render-only story" >&2; return 1; }
  expected=$(grep -vxF -- "$SHAPES_RENDER_ONLY" <<<"$reporter_names")
  [ "$extractor_names" = "$expected" ] || { printf 'reporter:\n%s\nextractor:\n%s\n' "$expected" "$extractor_names" >&2; return 1; }
}

@test "the reporter names the base story, each .test() and both .extend stories exactly as the extractor does" {
  local reporter_names full_name
  reporter_names=$(reporter_names_for "app/utils/tests/csf-shapes.stories.tsx")
  for full_name in \
    "Play With Tests   base story" \
    "Play With Tests   shows the marker" \
    "Play With Tests   runs the play first" \
    "Render With Test   base story" \
    "Render With Test   shows the marker" \
    "Extended Play" \
    "Extended Named" \
    "Custom Display Name"; do
    grep -qxF -- "$full_name" <<<"$reporter_names" || { echo "reporter has no test named: $full_name" >&2; return 1; }
  done
}

@test "the meta-play fixture's extractor names equal the reporter's names" {
  local reporter_names extractor_names
  reporter_names=$(reporter_names_for "app/utils/tests/csf-meta-play.stories.tsx")
  extractor_names=$(extractor_names_for "app/utils/tests/csf-meta-play.stories.tsx")
  [ -n "$extractor_names" ]
  [ "$reporter_names" = "$extractor_names" ]
}

@test "both fixture files load and every fixture test passes in the browser" {
  # Judged per file, never by assertion count: a file that fails to import
  # reports no assertions while the other file's pass.
  jq -e '[.testResults[] | select(.status == "passed")] | length == 2' "$REPORT" >/dev/null || { echo "a fixture file did not load or failed" >&2; return 1; }
  jq -e '[.testResults[].assertionResults[] | select(.status != "passed")] | length == 0' "$REPORT" >/dev/null
}
