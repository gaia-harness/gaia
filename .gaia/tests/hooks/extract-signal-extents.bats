#!/usr/bin/env bats

# The test-identity extractors' additive line extents: every NDJSON line gains
# firstLine and ranges after kind, while fullName, signal and kind stay
# byte-identical to what the extractor printed before the extents existed. The
# signal values below were computed once from the unmodified extractor and are
# hard-coded, so a change to what is hashed fails here.

# bats file_tags=installed-dependencies

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  TEST_SOURCE="$BATS_TEST_TMPDIR/sample.test.ts"
  STORY_SOURCE="$BATS_TEST_TMPDIR/sample.stories.tsx"
  cat >"$TEST_SOURCE" <<'EOF'
import {expect, test} from 'vitest';

// a comment above the first test
test('first multi-line', () => {
  const total = 1 + 1;
  expect(total).toBe(2);
});
test('adjacent', () => {
  expect(1).toBe(1);
});
EOF
  cat >"$STORY_SOURCE" <<'EOF'
import preview from '#.storybook/preview';

const Marker = () => <p>x</p>;

async function sharedPlay() {
  await Promise.resolve();
}

const meta = preview.meta({
  component: Marker,
  title: 'Sample',
});

export const WithTest = meta.story({
  play: async () => {
    await Promise.resolve();
  },
});

WithTest.test(
  'does a thing',
  async () => {
    await Promise.resolve();
  }
);

export const PlayOnly = meta.story({
  play: sharedPlay,
});

export const RenderOnly = meta.story({});
EOF
}

# Extractor NDJSON for a scratch source fed on stdin under a repo path.
extract() {
  local relative_path="$1" source_file="$2"
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "$relative_path" --stdin < "$source_file" )
}

# One entry of an NDJSON stream, selected by fullName.
entry() {
  local ndjson="$1" full_name="$2"
  jq -c --arg n "$full_name" 'select(.fullName == $n)' <<<"$ndjson"
}

@test "a test file keeps fullName, signal and kind byte-identical" {
  output=$(extract frontend/app/sample.test.ts "$TEST_SOURCE")
  expected_projection='{"fullName":"first multi-line","signal":"sha256:ffe25daf2b7ed23143321b331da08db81bab1afa5f4a5238fd196d1d31049f5f","kind":"runtime"}
{"fullName":"adjacent","signal":"sha256:7b686d8fbbd292925f21b8f16bffbdc28f2c1ce399776eacfd71b51bb23f72af","kind":"runtime"}'
  actual_projection=$(jq -c '{fullName, signal, kind}' <<<"$output")
  [ "$actual_projection" = "$expected_projection" ]
}

@test "a story file keeps fullName, signal and kind byte-identical" {
  output=$(extract frontend/app/sample.stories.tsx "$STORY_SOURCE")
  expected_projection='{"fullName":"With Test   base story","signal":"sha256:8755127f9efebc2c50764ca14697e521b24247ba623729551ae0f315b5e0ab04","kind":"runtime"}
{"fullName":"With Test   does a thing","signal":"sha256:4dc862fb51bf95b4320bd00d5d2c859347c281c5523d029160900fa29857584e","kind":"runtime"}
{"fullName":"Play Only","signal":"sha256:5762568c55fde342f7cbc42967c359f04dde7809379e81cfc93a538881bca52f","kind":"runtime"}'
  actual_projection=$(jq -c '{fullName, signal, kind}' <<<"$output")
  [ "$actual_projection" = "$expected_projection" ]
}

@test "the extent fields follow kind in key order" {
  output=$(extract frontend/app/sample.test.ts "$TEST_SOURCE")
  keys=$(head -n 1 <<<"$output" | jq -c 'keys_unsorted')
  [ "$keys" = '["fullName","signal","kind","firstLine","ranges"]' ]
}

@test "a multi-line test starts at its call line, ends at its close paren and excludes the comment above" {
  output=$(extract frontend/app/sample.test.ts "$TEST_SOURCE")
  first=$(entry "$output" "first multi-line")
  [ "$(jq -c '.firstLine' <<<"$first")" = "4" ]
  [ "$(jq -c '.ranges' <<<"$first")" = "[[4,7]]" ]
}

@test "an adjacent test's range does not overlap the first test's range" {
  output=$(extract frontend/app/sample.test.ts "$TEST_SOURCE")
  adjacent=$(entry "$output" "adjacent")
  [ "$(jq -c '.firstLine' <<<"$adjacent")" = "8" ]
  [ "$(jq -c '.ranges' <<<"$adjacent")" = "[[8,10]]" ]
}

@test "a base story lists its story, play and meta regions and no test statement" {
  output=$(extract frontend/app/sample.stories.tsx "$STORY_SOURCE")
  base=$(entry "$output" "With Test   base story")
  [ "$(jq -c '.firstLine' <<<"$base")" = "14" ]
  [ "$(jq -c '.ranges' <<<"$base")" = "[[14,18],[15,17],[9,12]]" ]
}

@test "a .test() entry adds its statement and starts at that statement" {
  output=$(extract frontend/app/sample.stories.tsx "$STORY_SOURCE")
  attached=$(entry "$output" "With Test   does a thing")
  [ "$(jq -c '.firstLine' <<<"$attached")" = "20" ]
  [ "$(jq -c '.ranges' <<<"$attached")" = "[[14,18],[15,17],[9,12],[20,25]]" ]
}

@test "a play-only story starts at its declaration and a play bound to a same-file declaration contributes that declaration" {
  output=$(extract frontend/app/sample.stories.tsx "$STORY_SOURCE")
  play_only=$(entry "$output" "Play Only")
  [ "$(jq -c '.firstLine' <<<"$play_only")" = "27" ]
  [ "$(jq -c '.ranges' <<<"$play_only")" = "[[27,29],[5,7],[9,12]]" ]
}
