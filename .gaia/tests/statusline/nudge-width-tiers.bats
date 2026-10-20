#!/usr/bin/env bats

# The statusline's right side is a task queue that fits itself to COLUMNS - 4,
# the row Claude Code draws the statusline in, so every width pinned below is 4
# more than the line it renders.
# Each nudge sizes independently through Large, Medium, Small, icon, then a
# trailing `+N`: the lowest-priority nudge still at its current size shrinks
# first, so a higher-priority nudge is never at a later size step than a
# lower-priority one (a nudge with no Medium form, such as /gaia-cleanse,
# shows its Small text at that step). This suite pins the exact boundaries
# and the priority order
# (update-gaia, serena-sync, update-deps, cleanse, fitness, codify, debt, residue, wiki)
# against exact widths, so a regression in the arithmetic reds here rather
# than silently shifting a boundary.
#
# Fixture mirrors segment-command-uniqueness.bats: a MAIN git checkout with
# setup marked complete, HOME pointing at an empty dir (left resolves to the
# "Claude Code" fallback, 11 columns), and a cache that arms every right-side
# nudge except /gaia-fitness at once (its order and shrink coverage live in
# fitness-nudge-render.bats), at the widths the issue table names: update-gaia 9.9.9,
# serena missing go+rust (2 languages), 28 outdated deps, a cleanse reason,
# a codify reason with 6 candidates, 1 open debt issue, 15 residuals.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-tiers-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared"
  cp "$STATUSLINE_SOURCE/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  cp "$STATUSLINE_SOURCE/gaia-statusline-right.sh" "$MAIN/.gaia/statusline/gaia-statusline-right.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  cat > "$MAIN/.gaia/local/cache/shared/update-check.json" <<'JSON'
{
  "gaiaHasUpdate": true,
  "gaiaLatest": "9.9.9",
  "outdatedCount": 28,
  "codifyNudgeReason": "1 new pattern, dangling-reference rising",
  "codifyCandidateCount": 6,
  "codifyUnclassifiedCount": 1,
  "residueCandidateCount": 15,
  "cleanseNudge": true,
  "cleanseNudgeReason": "34 days since review",
  "serenaLangDrift": ["go", "rust"]
}
JSON
  mkdir -p "$MAIN/.gaia/local/debt"
  printf '{"openCount":1}' > "$MAIN/.gaia/local/debt/count.json"

  TEMPORARY_HOME=$(mktemp -d -t gaia-sl-tiers-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Renders at the given COLUMNS. Sets $output/$status (bats `run` convention)
# and $plain (the same output with ANSI color codes stripped).
render_at() {
  local columns="$1"
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS="$columns" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

# Terminal columns of a plain render, counted the way the statusline measures
# its left side: a 4-byte sequence (an emoji) is 2 columns, any other character
# is 1. `${#plain}` would count an emoji as 1, or as 4 in the C locale.
visual_width() {
  printf '%s' "$1" | LC_ALL=C awk '{wide = gsub(/[\360-\364]/, "&"); gsub(/[\200-\277]/, ""); print length + wide}'
}

@test "every nudge renders Large, in priority order, when the line fits" {
  render_at 278
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern, dangling-reference rising) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
  [ "$plain" = "$expected" ]

  render_at 277
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac

  render_at 404
  [ "$status" -eq 0 ]
  order=$(grep -oE '/(update|gaia)-[a-z0-9-]*' <<<"$plain")
  expected_order=$(printf '%s\n' \
    "/update-gaia" \
    "/gaia-serena-sync" \
    "/update-deps" \
    "/gaia-cleanse" \
    "/gaia-codify" \
    "/gaia-debt" \
    "/gaia-residue")
  [ "$order" = "$expected_order" ]
}

@test "the line stops 4 columns short of COLUMNS, where Claude Code's statusline row ends" {
  render_at 278
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern, dangling-reference rising) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
  [ "$plain" = "$expected" ]
  [ "$(visual_width "$plain")" -eq 274 ]

  render_at 277
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac
  [ "$(visual_width "$plain")" -le 273 ]
}

@test "Large shrinks to Medium bottom-up, leaving mixed sizes at one width" {
  render_at 223
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (6) │ 🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)"
  [ "$plain" = "$expected" ]

  render_at 222
  [ "$status" -eq 0 ]
  grep -qF -- "📦 /update-deps (28 outdated)" <<<"$plain"
  grep -qF -- "🔎 /gaia-cleanse │ 🔨 /gaia-codify (6)" <<<"$plain"

  render_at 268
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac

  render_at 267
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac
}

@test "cleanse has no Medium: it goes straight to its bare command" {
  render_at 200
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify (6) │ 🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)"
  [ "$plain" = "$expected" ]
  grep -qF -- "🔎 /gaia-cleanse (" <<<"$plain" && return 1

  render_at 175
  [ "$status" -eq 0 ]
  grep -qF -- "🔎 /gaia-cleanse (" <<<"$plain" && return 1
  true
}

@test "Medium forms carry the number: serena its language count; update-gaia has none, its Large is already the version" {
  render_at 191
  [ "$status" -eq 0 ]
  grep -qF -- "🔭 /gaia-serena-sync (missing: go, rust)" <<<"$plain"

  render_at 190
  [ "$status" -eq 0 ]
  grep -qF -- "🔭 /gaia-serena-sync (2)" <<<"$plain"

  render_at 174
  [ "$status" -eq 0 ]
  grep -qF -- "🚀 /update-gaia │ 🔭 /gaia-serena-sync (2)" <<<"$plain"

  render_at 175
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (2) │ 📦 /update-deps (28) │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify (6) │ 🐛 /gaia-debt (1) │ 🧹 /gaia-residue (15)"
  [ "$plain" = "$expected" ]
}

@test "Medium shrinks to Small bottom-up after every nudge reached Medium" {
  render_at 166
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🐛 /gaia-debt (1) │ 🧹 /gaia-residue") ;;
    *) return 1 ;;
  esac

  render_at 149
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia │ 🔭 /gaia-serena-sync (2) │ 📦 /update-deps │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify │ 🐛 /gaia-debt │ 🧹 /gaia-residue"
  [ "$plain" = "$expected" ]

  render_at 148
  [ "$status" -eq 0 ]
  expected="Claude Code     🚀 /update-gaia │ 🔭 /gaia-serena-sync │ 📦 /update-deps │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify │ 🐛 /gaia-debt │ 🧹 /gaia-residue"
  [ "$plain" = "$expected" ]

  render_at 145
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia │ 🔭 /gaia-serena-sync │ 📦 /update-deps │ 🔎 /gaia-cleanse │ 🔨 /gaia-codify │ 🐛 /gaia-debt │ 🧹 /gaia-residue"
  [ "$plain" = "$expected" ]

  render_at 144
  [ "$status" -eq 0 ]
  grep -qF -- "🧹 15" <<<"$plain"
  grep -qF -- "🧹 /gaia-residue" <<<"$plain" && return 1
  true
}

@test "icons carry their Medium number: codify and serena gain counts, update-gaia and cleanse stay bare" {
  render_at 90
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia │ 🔭 /gaia-serena-sync │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
  [ "$plain" = "$expected" ]

  render_at 74
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 /update-gaia │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
  [ "$plain" = "$expected" ]

  render_at 73
  [ "$status" -eq 0 ]
  expected="Claude Code              🚀 │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
  [ "$plain" = "$expected" ]

  render_at 61
  [ "$status" -eq 0 ]
  expected="Claude Code  🚀 │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
  [ "$plain" = "$expected" ]

  render_at 65
  [ "$status" -eq 0 ]
  expected="Claude Code      🚀 │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 │ 🧹 15"
  [ "$plain" = "$expected" ]
}

@test "+N names how many icons were dropped and never vanishes" {
  render_at 60
  [ "$status" -eq 0 ]
  expected="Claude Code      🚀 │ 🔭 2 │ 📦 28 │ 🔎 │ 🔨 6 │ 🐛 1 +1"
  [ "$plain" = "$expected" ]

  render_at 22
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🚀 +6") ;;
    *) return 1 ;;
  esac

  render_at 21
  [ "$status" -eq 0 ]
  case "$plain" in
    *"+7") ;;
    *) return 1 ;;
  esac

  render_at 9
  [ "$status" -eq 0 ]
  [ -n "$plain" ]
  case "$plain" in
    *"+7") ;;
    *) return 1 ;;
  esac
  grep -qF -- "gaia-status" <<<"$plain" && return 1
  true
}

@test "a block-character left side is measured in characters, not bytes" {
  mkdir -p "$TEMPORARY_HOME/.claude"
  cat > "$TEMPORARY_HOME/.claude/settings.json" <<'JSON'
{"statusLine": {"command": "printf '▓▓░░░░░░░░'"}}
JSON
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')

  run env HOME="$TEMPORARY_HOME" LC_ALL=C.UTF-8 COLUMNS=277 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  expected="▓▓░░░░░░░░  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern, dangling-reference rising) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
  [ "$plain" = "$expected" ]

  run env HOME="$TEMPORARY_HOME" LC_ALL=C.UTF-8 COLUMNS=276 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac
}

@test "an emoji in the left side is measured as two columns, not one" {
  mkdir -p "$TEMPORARY_HOME/.claude"
  cat > "$TEMPORARY_HOME/.claude/settings.json" <<'JSON'
{"statusLine": {"command": "printf '🚀'"}}
JSON
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')

  run env HOME="$TEMPORARY_HOME" LC_ALL=C.UTF-8 COLUMNS=269 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  expected="🚀  🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern, dangling-reference rising) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
  [ "$plain" = "$expected" ]

  run env HOME="$TEMPORARY_HOME" LC_ALL=C.UTF-8 COLUMNS=268 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac
}

@test "a two-line left sizes the right side against the last line's width" {
  mkdir -p "$TEMPORARY_HOME/.claude"
  cat > "$TEMPORARY_HOME/.claude/settings.json" <<'JSON'
{"statusLine": {"command": "printf 'line one\\n%s' \"$(printf '%052d' 0 | tr 0 x)\""}}
JSON
  local json last_line_x
  last_line_x=$(printf '%052d' 0 | tr 0 x)
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')

  run env HOME="$TEMPORARY_HOME" COLUMNS=319 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  last_line="${plain##*$'\n'}"
  expected_right="🚀 /update-gaia (9.9.9) │ 🔭 /gaia-serena-sync (missing: go, rust) │ 📦 /update-deps (28 outdated) │ 🔎 /gaia-cleanse (34 days since review) │ 🔨 /gaia-codify (1 new pattern, dangling-reference rising) │ 🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15 residuals)"
  [ "$last_line" = "${last_line_x}  ${expected_right}" ]

  run env HOME="$TEMPORARY_HOME" COLUMNS=318 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  last_line="${plain##*$'\n'}"
  case "$last_line" in
    *"🐛 /gaia-debt (1 issue) │ 🧹 /gaia-residue (15)") ;;
    *) return 1 ;;
  esac
}

@test "codify with no candidates has no Medium and a bare icon" {
  cat > "$MAIN/.gaia/local/cache/shared/update-check.json" <<'JSON'
{
  "gaiaHasUpdate": true,
  "gaiaLatest": "9.9.9",
  "outdatedCount": 28,
  "codifyNudgeReason": "unclassified rising",
  "codifyCandidateCount": 0,
  "codifyUnclassifiedCount": 1,
  "residueCandidateCount": 15,
  "cleanseNudge": true,
  "cleanseNudgeReason": "34 days since review",
  "serenaLangDrift": ["go", "rust"]
}
JSON

  render_at 240
  [ "$status" -eq 0 ]
  grep -qF -- "🔨 /gaia-codify" <<<"$plain"
  grep -qF -- "🔨 /gaia-codify (" <<<"$plain" && return 1

  render_at 64
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🔎 │ 🔨 │ 🐛 1"*) ;;
    *) return 1 ;;
  esac
}

@test "a lone nudge steps through Large, Medium, Small, icon, +N" {
  printf '{"outdatedCount":28}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  rm -f "$MAIN/.gaia/local/debt/count.json"

  render_at 46
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (28 outdated)") ;;
    *) return 1 ;;
  esac

  render_at 45
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (28)") ;;
    *) return 1 ;;
  esac

  render_at 37
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (28)") ;;
    *) return 1 ;;
  esac

  render_at 36
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps") ;;
    *) return 1 ;;
  esac
  grep -qF -- "(" <<<"$plain" && return 1

  render_at 32
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps") ;;
    *) return 1 ;;
  esac
  grep -qF -- "(" <<<"$plain" && return 1

  render_at 31
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 28") ;;
    *) return 1 ;;
  esac
  grep -qF -- "/update-deps" <<<"$plain" && return 1

  render_at 22
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 28") ;;
    *) return 1 ;;
  esac
  grep -qF -- "/update-deps" <<<"$plain" && return 1

  render_at 21
  [ "$status" -eq 0 ]
  case "$plain" in
    *"+1") ;;
    *) return 1 ;;
  esac
  grep -qF -- "📦" <<<"$plain" && return 1
  true
}

@test "text forms keep their color, icons and +N render uncolored; setup-gaia renders alone" {
  render_at 175
  [ "$status" -eq 0 ]
  grep -qF -- $'\033[01;34m🐛 /gaia-debt (1)\033[00m' <<<"$output"
  grep -qF -- $'\033[01;36m🚀 /update-gaia (9.9.9)\033[00m' <<<"$output"

  render_at 61
  [ "$status" -eq 0 ]
  after_left="${output#*Claude Code}"
  grep -qF -- $'\033' <<<"$after_left" && return 1

  render_at 21
  [ "$status" -eq 0 ]
  after_left="${output#*Claude Code}"
  grep -qF -- $'\033' <<<"$after_left" && return 1

  rm -f "$MAIN/.gaia/local/setup-state.json"
  render_at 24
  [ "$status" -eq 0 ]
  case "$plain" in
    *"⚙️ /setup-gaia (Required)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "🚀" <<<"$plain" && return 1
  grep -qF -- "🔭" <<<"$plain" && return 1
  grep -qF -- "+" <<<"$plain" && return 1
  true
}

# The /gaia-wiki nudge is the lowest-priority slot, so it is the first to give
# up width. Its Medium is the commit count, its icon is the brain.
arm_wiki_nudge() {
  local cache="$MAIN/.gaia/local/cache/shared/update-check.json"
  jq --argjson drift "$1" '. + {wikiDriftCount: $drift}' "$cache" > "$cache.tmp"
  mv "$cache.tmp" "$cache"
}

@test "wiki renders last at Large and is the first nudge to shrink" {
  arm_wiki_nudge 20

  render_at 307
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧹 /gaia-residue (15 residuals) │ 🧠 /gaia-wiki (20 commits)") ;;
    *) return 1 ;;
  esac

  render_at 306
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧹 /gaia-residue (15 residuals) │ 🧠 /gaia-wiki (20)") ;;
    *) return 1 ;;
  esac
}

@test "a lone wiki nudge steps through Large, Medium, Small, icon, +N" {
  printf '{"wikiDriftCount":20}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  rm -f "$MAIN/.gaia/local/debt/count.json"

  render_at 43
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki (20 commits)") ;;
    *) return 1 ;;
  esac

  render_at 42
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki (20)") ;;
    *) return 1 ;;
  esac

  render_at 35
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki (20)") ;;
    *) return 1 ;;
  esac

  render_at 34
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki") ;;
    *) return 1 ;;
  esac

  render_at 33
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki") ;;
    *) return 1 ;;
  esac

  render_at 30
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 /gaia-wiki") ;;
    *) return 1 ;;
  esac

  render_at 29
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 20") ;;
    *) return 1 ;;
  esac
  grep -qF -- "/gaia-wiki" <<<"$plain" && return 1

  render_at 22
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🧠 20") ;;
    *) return 1 ;;
  esac

  render_at 21
  [ "$status" -eq 0 ]
  case "$plain" in
    *"+1") ;;
    *) return 1 ;;
  esac
  grep -qF -- "🧠" <<<"$plain" && return 1
  true
}

@test "the wiki text form carries its own color and the icon renders uncolored" {
  printf '{"wikiDriftCount":20}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  rm -f "$MAIN/.gaia/local/debt/count.json"

  render_at 304
  [ "$status" -eq 0 ]
  grep -qF -- $'\033[01;96m🧠 /gaia-wiki (20 commits)\033[00m' <<<"$output"

  render_at 24
  [ "$status" -eq 0 ]
  after_left="${output#*Claude Code}"
  grep -qF -- $'\033' <<<"$after_left" && return 1
  true
}

# Writes a cache holding only the update-deps counts, so the lone nudge steps
# through every tier at the widths below: Large "📦 /update-deps (3 outdated,
# 2 security)" is 40 columns, Medium "📦 /update-deps (5)" is 19, Small is 15,
# and the left side plus the 2-column gap adds 13.
write_lone_deps_cache() {
  printf '%s' "$1" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  rm -f "$MAIN/.gaia/local/debt/count.json"
}

@test "UAT-028: outdated plus security steps Large, Medium sum, Small, icon sum at the boundaries" {
  write_lone_deps_cache '{"outdatedCount":3,"securityCount":2,"securitySource":"dependabot"}'

  render_at 57
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (3 outdated, 2 security)") ;;
    *) return 1 ;;
  esac

  render_at 56
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (5)") ;;
    *) return 1 ;;
  esac

  render_at 36
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (5)") ;;
    *) return 1 ;;
  esac

  render_at 35
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps") ;;
    *) return 1 ;;
  esac

  render_at 31
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 5") ;;
    *) return 1 ;;
  esac
}

@test "UAT-028: security only renders its own count at Medium and icon" {
  write_lone_deps_cache '{"outdatedCount":0,"securityCount":2,"securitySource":"dependabot"}'

  render_at 204
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (2 security)") ;;
    *) return 1 ;;
  esac

  render_at 36
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (2)") ;;
    *) return 1 ;;
  esac

  render_at 31
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 2") ;;
    *) return 1 ;;
  esac
}

@test "UAT-028: an unavailable security count adds nothing at Medium and icon" {
  write_lone_deps_cache '{"outdatedCount":3,"securityCount":null,"securitySource":"unavailable"}'

  render_at 36
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 /update-deps (3)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "null" <<<"$plain" && return 1

  render_at 31
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦 3") ;;
    *) return 1 ;;
  esac
  grep -qF -- "security" <<<"$plain" && return 1
  true
}
