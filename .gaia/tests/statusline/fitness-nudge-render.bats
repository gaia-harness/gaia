#!/usr/bin/env bats

# The /gaia-fitness nudge on the statusline's right side. The render path reads
# only the cached fitness fields: these cases hand-write the cache the
# refresher would produce and pin which reason arms, the Large form each reason
# draws, the color, the exact widths where the nudge steps down through its
# smaller forms, and where it sits beside its neighbours.
#
# Fixture mirrors cache-single-read.bats: a MAIN git checkout with setup marked
# complete and HOME pointing at an empty dir, so the left side resolves to the
# "Claude Code" fallback (11 columns). Every width below is 4 more than the
# line it renders (see nudge-width-tiers.bats).
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/statusline/fitness-nudge-render.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  command -v jq >/dev/null 2>&1 || skip "jq required"

  MAIN=$(mktemp -d -t gaia-fitness-render-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared" "$MAIN/.gaia/local/debt"
  cp "$STATUSLINE_SOURCE/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  cp "$STATUSLINE_SOURCE/gaia-statusline-right.sh" "$MAIN/.gaia/statusline/gaia-statusline-right.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  TEMPORARY_HOME=$(mktemp -d -t gaia-fitness-render-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Sets $output, $stderr, $status, $plain (ANSI stripped) and $right (plain with
# the left side and the padding before the nudges removed).
render_with_cache() {
  local cache_json="$1" columns="${2:-400}" json
  printf '%s' "$cache_json" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run --separate-stderr env HOME="$TEMPORARY_HOME" COLUMNS="$columns" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  right=$(printf '%s' "$plain" | sed -E 's/^Claude Code +//')
}

assert_renders() {
  render_with_cache "$1"
  [ "$status" -eq 0 ]
  grep -qF -- "$2" <<<"$plain"
}

assert_no_fitness() {
  render_with_cache "$1"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  grep -qF -- '/gaia-fitness' <<<"$plain" && return 1
  true
}

@test "a commit count at the default threshold arms the nudge in its Large form" {
  assert_renders '{"fitnessCommitCount":15}' '💪 /gaia-fitness (15 harness commits)'
}

@test "a commit count under the default threshold arms nothing" {
  assert_no_fitness '{"fitnessCommitCount":14}'
}

@test "the cached threshold replaces the default" {
  assert_no_fitness '{"fitnessCommitCount":20,"fitnessCommitThreshold":25}'
  assert_renders '{"fitnessCommitCount":25,"fitnessCommitThreshold":25}' '(25 harness commits)'
}

@test "a threshold that is zero, not a number or absent falls back to the default" {
  assert_renders '{"fitnessCommitCount":15,"fitnessCommitThreshold":0}' '(15 harness commits)'
  assert_renders '{"fitnessCommitCount":15,"fitnessCommitThreshold":"abc"}' '(15 harness commits)'
  assert_renders '{"fitnessCommitCount":15}' '(15 harness commits)'
  assert_no_fitness '{"fitnessCommitCount":14,"fitnessCommitThreshold":0}'
}

@test "a single commit reads in the singular" {
  assert_renders '{"fitnessCommitCount":1,"fitnessCommitThreshold":1}' '(1 harness commit)'
  grep -qF -- '(1 harness commits)' <<<"$plain" && return 1
  true
}

@test "a blended-file count arms the nudge, singular for one" {
  assert_renders '{"fitnessBlendCount":3}' '💪 /gaia-fitness (3 blended files)'
  assert_renders '{"fitnessBlendCount":1}' '(1 blended file)'
  grep -qF -- '(1 blended files)' <<<"$plain" && return 1
  true
}

@test "a cached grade arms the nudge" {
  assert_renders '{"fitnessGrade":"B+"}' '💪 /gaia-fitness (grade B+)'
  assert_renders '{"fitnessGrade":"A"}' '(grade A)'
  assert_renders '{"fitnessGrade":"F"}' '(grade F)'
  assert_renders '{"fitnessGrade":"D-"}' '(grade D-)'
}

@test "the grade outranks blended files and commits, and blended files outrank commits" {
  assert_renders '{"fitnessGrade":"B+","fitnessBlendCount":3,"fitnessCommitCount":20}' '(grade B+)'
  grep -qF -- 'blended' <<<"$plain" && return 1
  grep -qF -- 'harness commit' <<<"$plain" && return 1
  assert_renders '{"fitnessBlendCount":3,"fitnessCommitCount":20}' '(3 blended files)'
  grep -qF -- 'harness commit' <<<"$plain" && return 1
  true
}

@test "an invalid or missing field arms nothing and writes nothing to stderr" {
  assert_no_fitness '{"fitnessGrade":"Z"}'
  assert_no_fitness '{"fitnessGrade":""}'
  assert_no_fitness '{"fitnessBlendCount":-1}'
  assert_no_fitness '{"fitnessBlendCount":"3"}'
  assert_no_fitness '{"fitnessCommitCount":"20"}'
  assert_no_fitness '{"fitnessBlendCount":0,"fitnessCommitCount":0}'
  assert_no_fitness '{"outdatedCount":3}'
}

@test "an armed nudge is drawn in bright blue" {
  render_with_cache '{"fitnessCommitCount":15}'
  [ "$status" -eq 0 ]
  grep -qF -- $'\033[01;94m💪 /gaia-fitness' <<<"$output"
}

# The nudge alone on the right side, so each step is the nudge's own form
# rather than a neighbour's. Boundaries measured once and pinned: the first
# width at a form, and the width one narrower.
@test "a commit count steps down Large, Medium, Small, icon, then folds into +1" {
  render_with_cache '{"fitnessCommitCount":17}' 54
  [ "$right" = '💪 /gaia-fitness (17 harness commits)' ]
  render_with_cache '{"fitnessCommitCount":17}' 53
  [ "$right" = '💪 /gaia-fitness (17)' ]
  render_with_cache '{"fitnessCommitCount":17}' 38
  [ "$right" = '💪 /gaia-fitness (17)' ]
  render_with_cache '{"fitnessCommitCount":17}' 37
  [ "$right" = '💪 /gaia-fitness' ]
  render_with_cache '{"fitnessCommitCount":17}' 33
  [ "$right" = '💪 /gaia-fitness' ]
  render_with_cache '{"fitnessCommitCount":17}' 32
  [ "$right" = '💪 17' ]
  render_with_cache '{"fitnessCommitCount":17}' 22
  [ "$right" = '💪 17' ]
  render_with_cache '{"fitnessCommitCount":17}' 21
  [ "$right" = '+1' ]
}

@test "a grade steps down Large, Medium, Small, a bare icon, then folds into +1" {
  render_with_cache '{"fitnessGrade":"B+"}' 44
  [ "$right" = '💪 /gaia-fitness (grade B+)' ]
  render_with_cache '{"fitnessGrade":"B+"}' 43
  [ "$right" = '💪 /gaia-fitness (B+)' ]
  render_with_cache '{"fitnessGrade":"B+"}' 38
  [ "$right" = '💪 /gaia-fitness (B+)' ]
  render_with_cache '{"fitnessGrade":"B+"}' 37
  [ "$right" = '💪 /gaia-fitness' ]
  render_with_cache '{"fitnessGrade":"B+"}' 33
  [ "$right" = '💪 /gaia-fitness' ]
  render_with_cache '{"fitnessGrade":"B+"}' 32
  [ "$right" = '💪' ]
  render_with_cache '{"fitnessGrade":"B+"}' 19
  [ "$right" = '💪' ]
  render_with_cache '{"fitnessGrade":"B+"}' 18
  [ "$right" = '+1' ]
}

@test "a lower-priority nudge shrinks before the fitness nudge does" {
  printf '{"openCount":1}' > "$MAIN/.gaia/local/debt/count.json"
  render_with_cache '{"fitnessCommitCount":17}' 58
  [ "$right" = '💪 /gaia-fitness (17) │ 🐛 /gaia-debt (1)' ]
  render_with_cache '{"fitnessCommitCount":17}' 57
  [ "$right" = '💪 /gaia-fitness (17) │ 🐛 /gaia-debt' ]
  render_with_cache '{"fitnessCommitCount":17}' 48
  [ "$right" = '💪 /gaia-fitness │ 🐛 1' ]
  render_with_cache '{"fitnessCommitCount":17}' 25
  [ "$right" = '💪 17 +1' ]
}

# The size step a nudge shows in a rendered line: 0 Large, 1 Medium, 2 Small,
# 3 icon, 4 folded away. $1 name, $2 icon, $3 line, $4 the step a bare name
# stands for (a nudge with no Medium form shows its Small text at Medium).
size_step() {
  local name="$1" icon="$2" line="$3" bare_step="${4:-2}"
  if grep -qE -- "${name} \\([0-9]+\\)" <<<"$line"; then
    echo 1
  elif grep -qF -- "${name} (" <<<"$line"; then
    echo 0
  elif grep -qF -- "$name" <<<"$line"; then
    echo "$bare_step"
  elif grep -qF -- "$icon" <<<"$line"; then
    echo 3
  else
    echo 4
  fi
}

ORDER_CACHE='{"cleanseNudge":true,"cleanseNudgeReason":"stale","fitnessCommitCount":17,"codifyNudgeReason":"2 recurring patterns","codifyCandidateCount":2}'

@test "the nudge sits after /gaia-cleanse and before /gaia-codify" {
  render_with_cache "$ORDER_CACHE"
  [ "$status" -eq 0 ]
  before_cleanse="${plain%%/gaia-cleanse*}"
  before_fitness="${plain%%/gaia-fitness*}"
  before_codify="${plain%%/gaia-codify*}"
  [ "${#before_cleanse}" -lt "${#before_fitness}" ]
  [ "${#before_fitness}" -lt "${#before_codify}" ]
}

@test "codify is never at a smaller form than fitness, nor fitness than cleanse" {
  local width codify_step fitness_step cleanse_step codify_ahead=0 fitness_ahead=0
  for width in $(seq 120 -1 20); do
    render_with_cache "$ORDER_CACHE" "$width"
    codify_step=$(size_step '/gaia-codify' '🔨' "$right")
    fitness_step=$(size_step '/gaia-fitness' '💪' "$right")
    cleanse_step=$(size_step '/gaia-cleanse' '🔎' "$right" 1)
    [ "$codify_step" -ge "$fitness_step" ] || { echo "width $width: codify $codify_step < fitness $fitness_step" >&2; return 1; }
    [ "$fitness_step" -ge "$cleanse_step" ] || { echo "width $width: fitness $fitness_step < cleanse $cleanse_step" >&2; return 1; }
    [ "$codify_step" -gt "$fitness_step" ] && codify_ahead=$((codify_ahead + 1))
    [ "$fitness_step" -gt "$cleanse_step" ] && fitness_ahead=$((fitness_ahead + 1))
  done
  [ "$codify_ahead" -gt 0 ]
  [ "$fitness_ahead" -gt 0 ]
}
