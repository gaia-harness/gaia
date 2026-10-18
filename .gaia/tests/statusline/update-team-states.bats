#!/usr/bin/env bats

# The update nudge (slot 1) resolves to one of four states from the cache and
# the live local version file: a checkout behind origin ("pull"), a teammate's
# live update claim ("in progress"), the reader's own claim ("resume"), or a
# plain available update. The in-progress nudge names a
# teammate and a version and carries no command, so it never shrinks past its
# Medium form: the loop keeps shrinking every other nudge and, when even that
# does not fit, the line renders past the available width with the `+N`.
#
# Fixture mirrors nudge-width-tiers.bats: a MAIN git checkout with setup
# complete and HOME pointing at an empty dir (left resolves to the "Claude
# Code" fallback). Widths below are COLUMNS values.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/update-team-states.bats < /dev/null

# A render that fails to terminate must fail the test, not hang the suite.
export BATS_TEST_TIMEOUT=60

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"

  MAIN=$(mktemp -d -t gaia-sl-team-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared" "$MAIN/.gaia/local/debt"
  cp "$REPO_ROOT/.gaia/statusline/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"
  CACHE_FILE="$MAIN/.gaia/local/cache/shared/update-check.json"
  SCRIPT="$MAIN/.gaia/statusline/gaia-statusline.sh"

  TEMPORARY_HOME=$(mktemp -d -t gaia-sl-team-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Teammate claim `octo-cat` on 2.0.4, reader `me`, update 2.0.5 available, and
# every other right-side nudge armed.
write_busy_cache() {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","outdatedCount":28,"codifyNudgeReason":"1 new pattern","codifyCandidateCount":6,"residueCandidateCount":15,"cleanseNudge":true,"cleanseNudgeReason":"34 days since review","serenaLangDrift":["go","rust"],"ghLogin":"me","gaiaUpdateClaims":[{"number":7,"headRefName":"update/v2.0.4-x","tag":"v2.0.4","authorLogin":"octo-cat","createdAt":"2026-10-18T00:00:00Z"}]}' > "$CACHE_FILE"
  printf '{"openCount":1}' > "$MAIN/.gaia/local/debt/count.json"
}

# Sets $output/$status and $plain (SGR codes stripped) from the script at
# $SCRIPT at the given COLUMNS.
render_at() {
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS="$1" bash -c "printf '%s' '$json' | bash '$SCRIPT'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  right_side=$(printf '%s' "$plain" | sed 's/^Claude Code *//')
}

@test "in-progress nudge keeps its Medium form while every other nudge shrinks then hides" {
  write_busy_cache
  declare -a widths=(300 260 240 200 150 120 100 90 80 70 60 50)
  declare -a expected=(
    "⌛️ GAIA 2.0.4 in progress (@octo-cat) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
    "⌛️ GAIA 2.0.4 in progress (@octo-cat) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)"
    "⌛️ GAIA 2.0.4 in progress (@octo-cat) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (6) │ 🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)"
    "⌛️ GAIA 2.0.4 in progress (@octo-cat) │ 🔭 /gaia-serena-sync (2) │ 📦 /update-deps (28) │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify (6) │ 🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 /gaia-serena-sync │ 📦 /update-deps │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify │ 🐛 /gaia-debt │ 🧹 15"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 /gaia-serena-sync │ 📦 /update-deps │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 /gaia-serena-sync │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 +1"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 2 │ 📦 28 │ 🔎 +3"
    "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 2 │ 📦 28 +4"
    "⌛️ GAIA 2.0.4 (@octo-cat) +6"
  )
  local row
  for row in "${!widths[@]}"; do
    render_at "${widths[$row]}"
    [ "$status" -eq 0 ]
    [ "$right_side" = "${expected[$row]}" ] || {
      echo "width ${widths[$row]}: got [$right_side]" >&2
      return 1
    }
    case "$plain" in *"/update-gaia"*) return 1 ;; esac
    case "$plain" in *"🚀"*) return 1 ;; esac
  done
}

@test "the in-progress nudge never takes a bare icon form or counts itself in the +N" {
  write_busy_cache
  local width
  for width in 300 200 150 100 80 60 50 40 30 20; do
    render_at "$width"
    [ "$status" -eq 0 ]
    case "$right_side" in *"⌛️ GAIA 2.0.4 (@octo-cat)"*|*"⌛️ GAIA 2.0.4 in progress (@octo-cat)"*) ;; *) return 1 ;; esac
    case "$right_side" in *"⌛️ │"*|*"⌛️ +"*|*"⌛️") return 1 ;; esac
    case "$right_side" in *"+7"*) return 1 ;; esac
  done
}

@test "too narrow for the floor with every other nudge hidden, the floor renders past the width with the +N" {
  write_busy_cache
  render_at 20
  [ "$status" -eq 0 ]
  [ "$right_side" = "⌛️ GAIA 2.0.4 (@octo-cat) +6" ]
}

@test "a floor of one nudge alone renders its Medium form past the width with no +N" {
  printf '%s' '{"ghLogin":"me","gaiaUpdateClaims":[{"number":7,"tag":"v2.0.4","authorLogin":"octo-cat"}]}' > "$CACHE_FILE"
  render_at 20
  [ "$status" -eq 0 ]
  [ "$right_side" = "⌛️ GAIA 2.0.4 (@octo-cat)" ]
}

@test "without the floor check the same narrow widths shrink the progress nudge, so the table fails" {
  write_busy_cache
  sed 's/^\( *\)if \[ -z "${dense_floor\[$shrink_target\]}" \].*; then$/\1if true; then/' "$SCRIPT" > "$BATS_TEST_TMPDIR/no-floor.sh"
  cmp -s "$SCRIPT" "$BATS_TEST_TMPDIR/no-floor.sh" && return 1
  cp "$BATS_TEST_TMPDIR/no-floor.sh" "$MAIN/.gaia/statusline/no-floor.sh"
  SCRIPT="$MAIN/.gaia/statusline/no-floor.sh"
  render_at 100
  [ "$status" -eq 0 ]
  [ "$right_side" != "⌛️ GAIA 2.0.4 (@octo-cat) │ 🔭 /gaia-serena-sync │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15" ]
  render_at 20
  [ "$right_side" != "⌛️ GAIA 2.0.4 (@octo-cat) +6" ]
}

@test "the reader's own claim renders resume at full width and the bare command at Small" {
  printf '%s' '{"ghLogin":"me","gaiaUpdateClaims":[{"number":7,"tag":"v2.0.4","authorLogin":"me"}]}' > "$CACHE_FILE"
  render_at 120
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia (resume 2.0.4)" ]
  render_at 40
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia" ]
}

@test "a teammate's claim outranks the reader's own, and the lowest number wins" {
  printf '%s' '{"ghLogin":"me","gaiaUpdateClaims":[{"number":3,"tag":"v2.0.3","authorLogin":"me"},{"number":9,"tag":"v2.0.9","authorLogin":"zed"},{"number":8,"tag":"v2.0.8","authorLogin":"amy"}]}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.8 in progress (@amy)" ]
}

@test "a cache holding an origin version and no claim renders today's update nudge" {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","gaiaOriginVersion":"9.9.9"}' > "$CACHE_FILE"
  render_at 120
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]
}

@test "an empty ghLogin hides progress and resume and the update renders as today" {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","ghLogin":"","gaiaUpdateClaims":[{"number":7,"tag":"v2.0.4","authorLogin":"octo-cat"},{"number":8,"tag":"v2.0.4","authorLogin":"me"}]}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]
}

@test "a claim whose login or tag is out of set renders no progress and no control byte" {
  local bad_claims
  bad_claims='[{"number":1,"tag":"v2.0.4","authorLogin":"evil\u001b[31mcat"},{"number":2,"tag":"v2.0.4","authorLogin":"line\nbreak"},{"number":3,"tag":"v2.0.4\n","authorLogin":"octo-cat"},{"number":4,"tag":"v2.0.4\u001b[2J","authorLogin":"octo-cat"},{"number":5,"tag":"v2.0.4","authorLogin":"trailing\n"},{"number":6,"tag":"2.0.4","authorLogin":"octo-cat"},{"number":7,"tag":"v2.0.4","authorLogin":"-bad"}]'
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","ghLogin":"me","gaiaUpdateClaims":'"$bad_claims"'}' > "$CACHE_FILE"
  render_at 120
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]
  case "$plain" in *"⌛"*) return 1 ;; esac
  stray=$(printf '%s' "$plain" | LC_ALL=C tr -d '\040-\176\200-\377' | wc -c | tr -d ' ')
  [ "$stray" -eq 0 ]

  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","ghLogin":"me\u001b[31m","gaiaUpdateClaims":[{"number":1,"tag":"v2.0.4","authorLogin":"octo-cat"}]}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]
}

@test "a valid claim after invalid lower-numbered ones still wins" {
  printf '%s' '{"ghLogin":"me","gaiaUpdateClaims":[{"number":1,"tag":"v9","authorLogin":"octo-cat"},{"number":2,"tag":"v2.0.4","authorLogin":"amy"}]}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.4 in progress (@amy)" ]
}

@test "a cache with only today's fields renders the update nudge byte for byte as before" {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","outdatedCount":0}' > "$CACHE_FILE"
  render_at 120
  [ "$status" -eq 0 ]
  expected_nudge=$'\033[01;36m🚀 /update-gaia (2.0.5)\033[00m'
  case "$output" in *"$expected_nudge") ;; *) return 1 ;; esac
}

@test "malformed claim fields render the plain update nudge" {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","gaiaUpdateClaims":"nope","ghLogin":12}' > "$CACHE_FILE"
  render_at 120
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]

  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","gaiaUpdateClaims":[1,"x",null,{"number":"7","tag":"v2.0.4","authorLogin":"octo-cat"}],"ghLogin":"me"}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (2.0.5)" ]
}

@test "rendering never calls gh" {
  write_busy_cache
  mkdir -p "$MAIN/.gaia/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$REPO_ROOT/.gaia/scripts/check-updates.sh" "$MAIN/.gaia/scripts/check-updates.sh"
  printf '#!/bin/bash\necho "$@" >> "%s/gh.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  : > "$BATS_TEST_TMPDIR/gh.log"
  jq --argjson now "$(date +%s)" '. + {checkedAt: $now, securitySource: "unavailable"}' "$CACHE_FILE" > "$CACHE_FILE.next"
  mv "$CACHE_FILE.next" "$CACHE_FILE"
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$TEMPORARY_HOME" COLUMNS=200 bash -c "printf '%s' '$json' | bash '$SCRIPT'" < /dev/null > /dev/null
  sleep 2
  [ ! -s "$BATS_TEST_TMPDIR/gh.log" ]
}

# Origin ahead of the checkout's own version file, with a teammate's live claim
# and a plain update both cached underneath.
write_pull_cache() {
  printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","gaiaOriginVersion":"'"${1:-2.0.4}"'","ghLogin":"me","gaiaUpdateClaims":[{"number":7,"tag":"v2.0.4","authorLogin":"octo-cat"}]}' > "$CACHE_FILE"
}

@test "origin ahead of the live local version renders the pull nudge, with or without a teammate's claim" {
  printf '2.0.3\n' > "$MAIN/.gaia/VERSION"
  write_pull_cache
  render_at 120
  [ "$status" -eq 0 ]
  [ "$right_side" = "🚀 /update-gaia (pull 2.0.4)" ]
  render_at 40
  [ "$right_side" = "🚀 /update-gaia" ]
  printf '%s' '{"gaiaOriginVersion":"2.0.4"}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (pull 2.0.4)" ]
}

@test "the pull nudge keeps its slot at every width and never shows progress or resume text" {
  printf '2.0.3' > "$MAIN/.gaia/VERSION"
  printf '%s' '{"gaiaOriginVersion":"2.0.4","ghLogin":"me","gaiaUpdateClaims":[{"number":7,"tag":"v2.0.4","authorLogin":"octo-cat"},{"number":9,"tag":"v2.0.4","authorLogin":"me"}],"outdatedCount":28,"codifyNudgeReason":"1 new pattern","codifyCandidateCount":6,"residueCandidateCount":15,"cleanseNudge":true,"cleanseNudgeReason":"34 days since review"}' > "$CACHE_FILE"
  printf '{"openCount":1}' > "$MAIN/.gaia/local/debt/count.json"
  local width
  for width in 300 200 150 120 100 80 60 50 40 30; do
    render_at "$width"
    [ "$status" -eq 0 ]
    case "$right_side" in *"in progress"*|*"resume"*|*"⌛"*) return 1 ;; esac
    case "$right_side" in "🚀 "*) ;; *) echo "width $width: got [$right_side]" >&2; return 1 ;; esac
  done
  render_at 300
  case "$right_side" in "🚀 /update-gaia (pull 2.0.4) │ "*) ;; *) return 1 ;; esac
}

@test "the local version is read live: bumping only the version file removes pull" {
  printf '2.0.3\n' > "$MAIN/.gaia/VERSION"
  write_pull_cache
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (pull 2.0.4)" ]
  printf '2.0.4\n' > "$MAIN/.gaia/VERSION"
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.4 in progress (@octo-cat)" ]
}

@test "a missing or non-version local file renders no pull" {
  write_pull_cache
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.4 in progress (@octo-cat)" ]
  printf 'garbage\n' > "$MAIN/.gaia/VERSION"
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.4 in progress (@octo-cat)" ]
  : > "$MAIN/.gaia/VERSION"
  render_at 120
  [ "$right_side" = "⌛️ GAIA 2.0.4 in progress (@octo-cat)" ]
}

@test "a non-version origin value renders no pull" {
  printf '2.0.3\n' > "$MAIN/.gaia/VERSION"
  local origin
  for origin in '"latest"' '7' 'null' '"2.0"' '"v2.0.4"' '"2.0.4\n"'; do
    printf '%s' '{"gaiaHasUpdate":true,"gaiaLatest":"2.0.5","gaiaOriginVersion":'"$origin"'}' > "$CACHE_FILE"
    render_at 120
    [ "$right_side" = "🚀 /update-gaia (2.0.5)" ] || {
      echo "origin $origin: got [$right_side]" >&2
      return 1
    }
  done
}

@test "versions compare by their numeric core, so 2.0.10 is ahead of 2.0.9 and a prerelease does not outrank its release" {
  printf '2.0.9\n' > "$MAIN/.gaia/VERSION"
  printf '%s' '{"gaiaOriginVersion":"2.0.10"}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (pull 2.0.10)" ]
  printf '2.0.4\n' > "$MAIN/.gaia/VERSION"
  printf '%s' '{"gaiaOriginVersion":"2.0.4-rc.1"}' > "$CACHE_FILE"
  render_at 120
  [ -z "$right_side" ]
}

@test "the pull state arms without gh on the render path" {
  printf '2.0.3\n' > "$MAIN/.gaia/VERSION"
  write_pull_cache
  mkdir -p "$MAIN/.gaia/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$REPO_ROOT/.gaia/scripts/check-updates.sh" "$MAIN/.gaia/scripts/check-updates.sh"
  printf '#!/bin/bash\necho "$@" >> "%s/gh.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  : > "$BATS_TEST_TMPDIR/gh.log"
  jq --argjson now "$(date +%s)" '. + {checkedAt: $now, securitySource: "unavailable"}' "$CACHE_FILE" > "$CACHE_FILE.next"
  mv "$CACHE_FILE.next" "$CACHE_FILE"
  local json rendered
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  rendered=$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$TEMPORARY_HOME" COLUMNS=200 bash -c "printf '%s' '$json' | bash '$SCRIPT'" < /dev/null)
  case "$rendered" in *"pull 2.0.4"*) ;; *) return 1 ;; esac
  sleep 2
  [ ! -s "$BATS_TEST_TMPDIR/gh.log" ]
}

@test "an inverted version comparison renders pull for a local version ahead of origin, so the pull assertions fail on it" {
  sed 's/\$origin_core > \$local_core/$origin_core < $local_core/' "$SCRIPT" > "$BATS_TEST_TMPDIR/inverted.sh"
  cmp -s "$SCRIPT" "$BATS_TEST_TMPDIR/inverted.sh" && return 1
  cp "$BATS_TEST_TMPDIR/inverted.sh" "$MAIN/.gaia/statusline/inverted.sh"
  SCRIPT="$MAIN/.gaia/statusline/inverted.sh"
  printf '2.0.4\n' > "$MAIN/.gaia/VERSION"
  printf '%s' '{"gaiaOriginVersion":"2.0.3"}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" = "🚀 /update-gaia (pull 2.0.3)" ]
  printf '2.0.3\n' > "$MAIN/.gaia/VERSION"
  printf '%s' '{"gaiaOriginVersion":"2.0.4"}' > "$CACHE_FILE"
  render_at 120
  [ "$right_side" != "🚀 /update-gaia (pull 2.0.4)" ]
}
