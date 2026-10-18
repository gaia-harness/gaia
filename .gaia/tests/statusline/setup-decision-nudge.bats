#!/usr/bin/env bats

# The statusline's post-completion setup nudge: once setup is complete, a
# machine-scope setup choice the shipped list holds and this machine has not
# decided arms a `⚙️ /setup-gaia (<N> choice[s] pending)` segment at the
# highest priority. Project-scope ids never arm it, the incomplete-setup
# `⚙️ /setup-gaia (Required)` segment is untouched, and a linked worktree
# stays dark because the nudge is a main-checkout task like the rest.
#
# The fixture is a MAIN git checkout holding copies of the statusline and the
# main-root resolver (without the resolver a linked worktree never reads as
# one), a linked worktree off it, and HOME pointing at an empty directory so the
# left side is inert. Decisions are recorded through the real CLI bundle run
# from the fixture checkout, so the file shape the nudge reads is the shape the
# recorder writes.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  GAIA_COMMAND="$(cd "$BATS_TEST_DIRNAME/../../cli" && pwd)/gaia"

  MAIN=$(mktemp -d -t gaia-sl-setup-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local/cache/shared" "$MAIN/.gaia/local/debt"
  cp "$STATUSLINE_SOURCE/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  cp "$SCRIPTS_SOURCE/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  echo "x" > "$MAIN/README.md"
  write_features alpha beta gamma
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"

  write_setup_state '"2026-01-01T00:00:00Z"'

  WORKTREE="${MAIN}-wt"
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature

  TEMPORARY_HOME=$(mktemp -d -t gaia-sl-setup-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Write the fixture list: alpha and beta are machine scope, gamma is project
# scope. Each argument names which of the three to include, in list order.
write_features() {
  local entries="" id scope
  for id in "$@"; do
    case "$id" in
      gamma) scope="project" ;;
      *) scope="machine" ;;
    esac
    [ -n "$entries" ] && entries="${entries},"
    entries="${entries}{\"id\":\"${id}\",\"scope\":\"${scope}\",\"required\":false,\"admin\":false,\"standalone\":false,\"reference\":\"README.md\"}"
  done
  printf '{"version":1,"description":"Fixture list for the statusline setup nudge.","features":[%s]}\n' "$entries" > "$MAIN/.gaia/setup-features.json"
}

# Write main's setup-state with the given JSON value for completed_at. It
# carries the fields the real recorder requires, so `gaia setup record` accepts
# it.
write_setup_state() {
  printf '{"version":1,"started_at":"2026-01-01T00:00:00Z","completed_at":%s,"completed_steps":[]}\n' "$1" > "$MAIN/.gaia/local/setup-state.json"
}

record_decision() {
  (cd "$MAIN" && "$GAIA_COMMAND" setup record "$1" "$2") > /dev/null
}

arm_other_nudges() {
  printf '{"gaiaHasUpdate":true,"gaiaLatest":"9.9.9","outdatedCount":3}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  printf '{"openCount":5}' > "$MAIN/.gaia/local/debt/count.json"
}

status_payload() {
  jq -n --arg current_directory "$1" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}'
}

# Render MAIN's statusline from session directory $1 at width $2, with the
# colors stripped so assertions read plain text. HOME is empty so the left side
# is inert.
render() {
  local json
  json=$(status_payload "$1")
  run env HOME="$TEMPORARY_HOME" COLUMNS="${2:-400}" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh' | sed \$'s/\\x1b\\\\[[0-9;]*m//g'"
}

@test "two pending machine choices nudge, and recording them clears the nudge one by one" {
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  record_decision alpha applied
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (1 choice pending)" <<<"$output"

  record_decision beta applied
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "declined and not-applicable clear the nudge exactly as applied does" {
  render "$MAIN"
  grep -qF -- "(2 choices pending)" <<<"$output"

  record_decision alpha declined
  render "$MAIN"
  grep -qF -- "(1 choice pending)" <<<"$output"

  record_decision beta not-applicable
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "a project-scope id never arms the nudge" {
  # Positive control: with a machine id pending the slot renders.
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"

  write_features gamma
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "the other nudges keep rendering, after the setup nudge, in their existing order" {
  arm_other_nudges
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qE -- "⚙️ /setup-gaia \(2 choices pending\) │ 🚀 /update-gaia .* │ 📦 /update-deps .* │ 🐛 /gaia-debt " <<<"$output"
}

@test "the setup nudge is the last to shrink and has its own Medium and icon forms" {
  arm_other_nudges

  # Medium for setup while every lower-priority nudge is already at Small.
  render "$MAIN" 90
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2)" <<<"$output"
  grep -qF -- "🚀 /update-gaia" <<<"$output"
  grep -qF -- "9.9.9" <<<"$output" && return 1

  # Small for setup while lower-priority nudges have reached icons.
  render "$MAIN" 60
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  grep -qF -- "⚙️ /setup-gaia (" <<<"$output" && return 1
  grep -qF -- "📦 3" <<<"$output"

  # Icon form last, with the count.
  render "$MAIN" 30
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ 2" <<<"$output"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1
  return 0
}

@test "no list renders no setup slot and leaves the rest of the render unchanged" {
  arm_other_nudges
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  with_list="$output"

  rm -f "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  grep -qF -- "🚀 /update-gaia (9.9.9)" <<<"$output"
  grep -qF -- "📦 /update-deps (3 outdated)" <<<"$output"
  grep -qF -- "🐛 /gaia-debt (5 issues)" <<<"$output"
  [ "${output//[[:space:]]/}" = "$(sed -E 's/⚙️ \/setup-gaia \(2 choices pending\) │ //' <<<"$with_list" | tr -d '[:space:]')" ]
}

@test "a malformed list renders no setup slot, no Required segment, and exits 0" {
  arm_other_nudges
  printf '{' > "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  # The shared read still reported completion, so the other nudges render.
  grep -qF -- "📦 /update-deps" <<<"$output"
}

@test "a list with a non-array features value renders no setup slot and exits 0" {
  printf '{"version":1,"description":"x","features":"nope"}\n' > "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "an incomplete setup still renders ⚙️ /setup-gaia (Required) alone" {
  arm_other_nudges
  write_setup_state null
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (Required)" <<<"$output"
  grep -qF -- "setup choice" <<<"$output" && return 1
  grep -qF -- "🔧" <<<"$output" && return 1
  grep -qF -- "+" <<<"$output" && return 1
  grep -qF -- "🚀 /update-gaia" <<<"$output" && return 1
  return 0
}

@test "with no jq the render exits 0 and shows no setup choice slot" {
  local bin_directory="$BATS_TEST_TMPDIR/nojq-bin" command_name json
  mkdir -p "$bin_directory"
  for command_name in bash cat dirname git sed awk grep tr uname head mktemp rm env sh; do
    command -v "$command_name" > /dev/null && ln -sf "$(command -v "$command_name")" "$bin_directory/$command_name"
  done
  [ ! -e "$bin_directory/jq" ]

  json=$(status_payload "$MAIN")
  run env -i HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$bin_directory" "$bin_directory/bash" -c "printf '%s' '$json' | '$bin_directory/bash' '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "setup choice" <<<"$output" && return 1
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1

  # Positive control: the same fixture renders the slot once jq is on PATH.
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"
}

@test "a linked worktree shows no setup choice nudge, the main checkout does" {
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  render "$WORKTREE"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "the incomplete-setup segment still renders from a linked worktree" {
  write_setup_state null
  render "$WORKTREE"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (Required)" <<<"$output"
}

@test "the list adds no jq process to a render" {
  local shim_directory="$BATS_TEST_TMPDIR/shim-bin" log_file="$BATS_TEST_TMPDIR/jq-calls" real_jq json
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/bash\necho x >> "%s"\nexec "%s" "$@"\n' "$log_file" "$real_jq" > "$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  arm_other_nudges
  json=$(status_payload "$MAIN")

  : > "$log_file"
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$shim_directory:$PATH" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  calls_with_list=$(wc -l < "$log_file" | tr -d ' ')

  rm -f "$MAIN/.gaia/setup-features.json"
  : > "$log_file"
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$shim_directory:$PATH" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1
  calls_without_list=$(wc -l < "$log_file" | tr -d ' ')

  # The shim logged something, so an inert shim cannot pass this.
  [ "$calls_without_list" -gt 0 ]
  [ "$calls_with_list" -eq "$calls_without_list" ]
}
