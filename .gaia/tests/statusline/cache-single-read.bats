#!/usr/bin/env bats

# The statusline reads the update-check cache in one jq call and splits the
# result on a control character. These cases pin that split: every cached
# field still reaches its own nudge, a string value holding a control
# character (the delimiter included) cannot shift the fields after it, and a
# broken cache degrades to no nudges.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/cache-single-read.bats < /dev/null

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEMPORARY_HOME=$(mktemp -d -t gaia-cache-read-home-XXXXXX)
  FIXTURE=$(mktemp -d -t gaia-cache-read-fix-XXXXXX)
  git -C "$FIXTURE" init --quiet --initial-branch=main
  git -C "$FIXTURE" config user.email "test@example.com"
  git -C "$FIXTURE" config user.name "Test"
  git -C "$FIXTURE" config commit.gpgsign false
  mkdir -p "$FIXTURE/.gaia/statusline" "$FIXTURE/.gaia/local/cache/shared"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline.sh" "$FIXTURE/.gaia/statusline/gaia-statusline.sh"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline-right.sh" "$FIXTURE/.gaia/statusline/gaia-statusline-right.sh"
  echo "x" > "$FIXTURE/README.md"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$FIXTURE/.gaia/local/setup-state.json"
  CACHE_FILE="$FIXTURE/.gaia/local/cache/shared/update-check.json"
}

teardown() {
  [ -n "${FIXTURE:-}" ] && rm -rf "$FIXTURE" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Sets $output, $status, and $plain (ANSI stripped). COLUMNS=400 keeps every
# nudge Large.
render_with_cache() {
  local json
  printf '%s' "$1" > "$CACHE_FILE"
  json=$(jq -n --arg current_directory "$FIXTURE" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 bash -c "printf '%s' '$json' | bash '$FIXTURE/.gaia/statusline/gaia-statusline.sh'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

@test "every cached field reaches its own nudge" {
  render_with_cache '{"outdatedCount":3,"securityCount":2,"gaiaHasUpdate":true,"gaiaLatest":"v9.9.9","codifyCandidateCount":4,"codifyNudgeReason":"4 recurring patterns","cleanseNudge":true,"cleanseNudgeReason":"memory grew","residueCandidateCount":6,"wikiDriftCount":25,"fitnessGrade":"B+","fitnessBlendCount":3,"fitnessCommitCount":20,"fitnessCommitThreshold":18}'
  [ "$status" -eq 0 ]
  grep -qF '/update-gaia (v9.9.9)' <<<"$plain"
  grep -qF '/update-deps (3 outdated, 2 security)' <<<"$plain"
  grep -qF '/gaia-codify (4 recurring patterns)' <<<"$plain"
  grep -qF '/gaia-cleanse (memory grew)' <<<"$plain"
  grep -qF '/gaia-residue (6 residuals)' <<<"$plain"
  grep -qF '/gaia-wiki (25 commits)' <<<"$plain"
  grep -qF '/gaia-fitness (grade B+)' <<<"$plain"
}

@test "a control character in a cached reason cannot shift the fields after it" {
  render_with_cache '{"cleanseNudge":true,"cleanseNudgeReason":"memory\u001fgrew\nfast","residueCandidateCount":6,"wikiDriftCount":25,"fitnessGrade":"Q\u001fX"}'
  [ "$status" -eq 0 ]
  grep -qF '/gaia-fitness' <<<"$plain" && return 1
  grep -qF '/gaia-cleanse (memorygrewfast)' <<<"$plain"
  grep -qF '/gaia-residue (6 residuals)' <<<"$plain"
  grep -qF '/gaia-wiki (25 commits)' <<<"$plain"
}

@test "a cache without codifyNudgeReason still composes the codify fallback" {
  render_with_cache '{"codifyCandidateCount":1,"codifyUnclassifiedCount":2,"wikiDriftCount":25}'
  [ "$status" -eq 0 ]
  grep -qF '/gaia-codify (1 recurring pattern, 2 unclassified)' <<<"$plain"
  grep -qF '/gaia-wiki (25 commits)' <<<"$plain"
}

@test "an unparseable cache renders no cache nudges and no error" {
  render_with_cache '{not json'
  [ "$status" -eq 0 ]
  grep -qF '/gaia-wiki' <<<"$plain" && return 1
  grep -qF '/update-deps' <<<"$plain" && return 1
  true
}
