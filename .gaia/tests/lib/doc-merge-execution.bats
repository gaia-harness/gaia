#!/usr/bin/env bats
# The execution agent's instructions for /update-gaia: merge-execution.md and
# its sibling merge-generated.md. The adopter-actions block runs against a
# fixture project, and so does the service-layer sentinel block.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  REFERENCES="$REPO_ROOT/.claude/skills/update-gaia/references"
  MERGE_EXECUTION="$REFERENCES/merge-execution.md"
  MERGE_GENERATED="$REFERENCES/merge-generated.md"
}

# The fenced bash block that follows the first line starting with `$2` in
# file `$1`.
block_after_heading() {
  awk -v heading="$2" '
    index($0, heading) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

# Runs block text `$2` with `$1` as its working directory. Extra arguments are
# NAME=value pairs exported into the block's environment.
run_block_in() {
  local directory="$1" block="$2"
  shift 2
  run env "$@" bash -c 'cd "$1" || exit 99; eval "$2"' _ "$directory" "$block"
}

# --- Adopter actions read the saved CHANGELOG range --------------------------

ACTIONS_HEADING='**Adopter actions from the saved CHANGELOG range.**'

# A project with a verified-cache tree for v2.1.0 and, beside it, the range
# file the orchestrator saves.
actions_setup() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE=".gaia/local/cache/shared/update-gaia/v2.1.0"
  mkdir -p "$PROJECT/$CACHE/tree"
  RANGE="$CACHE/changelog-range.md"
}

write_range() {
  printf '%s\n' '## [2.1.0]' '' '### Removed' '' '- dropped `pnpm remove left-pad`' > "$PROJECT/$RANGE"
}

# Runs the adopter-actions block of instructions file `$1`.
run_actions() {
  local block
  block="$(block_after_heading "$1" "$ACTIONS_HEADING")"
  [ -n "$block" ] || { echo "no adopter-actions block in $1" >&2; return 1; }
  run_block_in "$PROJECT" "$block" CHANGELOG_RANGE="$RANGE" \
    LATEST_DIR="$CACHE/tree" BASELINE=2.0.0 LATEST=2.1.0
}

@test "adopter actions read the range the orchestrator saved, never a CHANGELOG inside the bundle" {
  actions_setup
  write_range
  run_actions "$MERGE_EXECUTION"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF -- '- dropped `pnpm remove left-pad`'
  grep -qF 'LATEST_DIR/CHANGELOG.md' "$MERGE_EXECUTION" "$MERGE_GENERATED" && return 1
  true
}

@test "adopter actions: a missing saved range is announced, not read as an empty range" {
  actions_setup
  run_actions "$MERGE_EXECUTION"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGELOG_RANGE_UNAVAILABLE'
}

# --- Service-layer sentinel: a renamed sample layer is never re-created -------

SERVICE_LAYER_HEADING='**Service-layer sentinel (runs first).**'
SERVICE_LAYER='apps/web/app/services'

# A project, a baseline release and a latest release, manifests only. Both list
# the sample layer's api.ts and the latest adds client.ts: paths that would
# otherwise take a `removed` row and an `add` that re-creates the folder.
service_layer_setup() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  BASELINE_RELEASE="$BATS_TEST_TMPDIR/baseline"
  LATEST_RELEASE="$BATS_TEST_TMPDIR/latest"
  mkdir -p "$PROJECT/.gaia/scripts" "$BASELINE_RELEASE/.gaia" "$LATEST_RELEASE/.gaia"
  cp "$REPO_ROOT/.gaia/scripts/update-gaia-report.sh" "$PROJECT/.gaia/scripts/"
  printf '{"files":{"%s":"owned","README.md":"owned"}}\n' "$SERVICE_LAYER/gaia/api.ts" \
    > "$BASELINE_RELEASE/.gaia/manifest.json"
  printf '{"files":{"%s":"owned","%s":"owned","README.md":"owned"}}\n' \
    "$SERVICE_LAYER/gaia/api.ts" "$SERVICE_LAYER/gaia/client.ts" > "$LATEST_RELEASE/.gaia/manifest.json"
}

# Prints the SERVICE_LAYER_SKIPS the sentinel block of file `$1` computes for
# the project.
run_service_layer_sentinel() {
  local block
  block="$(block_after_heading "$1" "$SERVICE_LAYER_HEADING")"
  [ -n "$block" ] || { echo "no service-layer sentinel block in $1" >&2; return 1; }
  run_block_in "$PROJECT" "$block"'; printf "%s\n" "$SERVICE_LAYER_SKIPS"' \
    BASELINE_DIR="$BASELINE_RELEASE" LATEST_DIR="$LATEST_RELEASE" DECISIONS=''
}

@test "service-layer sentinel: a renamed layer skips every sample-layer path, a kept layer skips none" {
  service_layer_setup
  mkdir -p "$PROJECT/$SERVICE_LAYER/acme"
  run_service_layer_sentinel "$MERGE_EXECUTION"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$SERVICE_LAYER/gaia/api.ts" "$SERVICE_LAYER/gaia/client.ts")" ]
  mkdir -p "$PROJECT/$SERVICE_LAYER/gaia"
  run_service_layer_sentinel "$MERGE_EXECUTION"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "service-layer sentinel: an unreadable manifest stops the walk instead of skipping nothing" {
  service_layer_setup
  rm "$LATEST_RELEASE/.gaia/manifest.json"
  run_service_layer_sentinel "$MERGE_EXECUTION"
  [ "$status" -ne 0 ]
}
