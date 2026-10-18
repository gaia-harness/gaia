#!/usr/bin/env bats
# The execution agent's instructions for /update-gaia: merge-execution.md and
# its sibling merge-generated.md. The adopter-actions block runs against a
# fixture project; the rest pins prose the agent must follow: it downloads
# nothing and writes no version, manifest or ping, reads migration notes only
# from the verified bundle, names no retired artifact and asks the user
# nothing, and names the contract calls it owes the orchestrator. Every pin has
# a red twin: a scratch copy carrying the forbidden content, or missing the
# required content, fails the same check.
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
  MERGE_REPORT="$REFERENCES/merge-report.md"
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

@test "adopter actions: a block reading the bundle's CHANGELOG is reported" {
  actions_setup
  write_range
  local copy="$BATS_TEST_TMPDIR/merge-execution-bundle-changelog.md"
  # shellcheck disable=SC2016  # the replacement is literal block text
  sed 's|"\$CHANGELOG_RANGE"|"$LATEST_DIR/CHANGELOG.md"|g' "$MERGE_EXECUTION" > "$copy"
  grep -qF 'LATEST_DIR/CHANGELOG.md' "$copy"
  run_actions "$copy"
  printf '%s\n' "$output" | grep -qxF -- '- dropped `pnpm remove left-pad`' && return 1
  true
}

@test "adopter actions: a missing saved range is announced, not read as an empty range" {
  actions_setup
  run_actions "$MERGE_EXECUTION"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGELOG_RANGE_UNAVAILABLE'
}

# --- Merge only: no download, version, manifest or ping -----------------------

# 0 when instructions copy `$1` holds none of the orchestrator's writes.
merge_execution_is_merge_only() {
  grep -qF 'gh release download' "$1" && return 1
  grep -qE '>[[:space:]]*\.gaia/VERSION' "$1" && return 1
  grep -qF 'GAIA_MANIFEST_WRITE=release cp' "$1" && return 1
  grep -qF 'ping --event update' "$1" && return 1
  return 0
}

@test "merge only: neither instructions file downloads, writes the version, copies the manifest or pings" {
  local file copy line
  for file in "$MERGE_EXECUTION" "$MERGE_GENERATED"; do
    merge_execution_is_merge_only "$file" || { echo "orchestrator write in $file" >&2; return 1; }
    copy="$BATS_TEST_TMPDIR/$(basename "$file" .md)-readded.md"
    for line in 'gh release download "$tag" --repo gaia-react/gaia' 'echo "$LATEST" > .gaia/VERSION' \
      'GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json' \
      '.gaia/cli/gaia ping --event update --from "$BASELINE" --to "$LATEST" || true'; do
      { cat "$file"; printf '%s\n' "$line"; } > "$copy"
      merge_execution_is_merge_only "$copy" && { echo "not reported in $(basename "$file"): $line" >&2; return 1; }
    done
  done
  true
}

# --- Bundle root: migration notes only from the verified bundle ---------------

# Prints every line of the given files naming .gaia/migrations/ other than
# through the target bundle (`<LATEST_DIR>/` or `$LATEST_DIR/`).
bare_migration_paths() {
  sed -e 's|<LATEST_DIR>/\.gaia/migrations/||g' \
    -e 's|\$LATEST_DIR/\.gaia/migrations/||g' "$@" |
    grep -F '.gaia/migrations/' || true
}

@test "bundle root: neither instructions file names a migration note outside the verified bundle" {
  [ -z "$(bare_migration_paths "$MERGE_EXECUTION" "$MERGE_GENERATED")" ]
  local file copy
  for file in "$MERGE_EXECUTION" "$MERGE_GENERATED"; do
    copy="$BATS_TEST_TMPDIR/$(basename "$file" .md)-bare.md"
    { cat "$file"; printf '%s\n' 'cat .gaia/migrations/2.1.0.md'; } > "$copy"
    [ -n "$(bare_migration_paths "$copy")" ] || { echo "not reported in $(basename "$file")" >&2; return 1; }
  done
}

# --- No retired artifact, no question to the user -----------------------------

# Prints every line of the given files naming the retired patch directory or
# report type, or telling the agent to ask the user.
retired_or_asking_lines() {
  grep -nE 'gaia-merge|UpdateMergeReport|walk the user|ask the user' "$@" || true
}

@test "retired: no instructions file names the patch directory or old report type, or asks the user" {
  [ -z "$(retired_or_asking_lines "$MERGE_EXECUTION" "$MERGE_GENERATED" "$MERGE_REPORT")" ]
  local file copy line
  for file in "$MERGE_EXECUTION" "$MERGE_GENERATED" "$MERGE_REPORT"; do
    copy="$BATS_TEST_TMPDIR/$(basename "$file" .md)-retired.md"
    for line in 'diff -u A L > .gaia-merge/x.patch' 'Return the UpdateMergeReport.' \
      'walk the user through each conflict' 'ask the user before removing'; do
      { cat "$file"; printf '%s\n' "$line"; } > "$copy"
      [ -n "$(retired_or_asking_lines "$copy")" ] || { echo "not reported in $(basename "$file"): $line" >&2; return 1; }
    done
  done
}

# --- The contract calls merge-execution.md owes the orchestrator ---------------

# shellcheck disable=SC2016  # literal prose needles, nothing expands
CONTRACT_NEEDLES=(
  'git merge-file -p "<A>" "<B>" "<L>" > "$WORK_DIR/<path>.merged"'
  'never into A'
  'Independent concerns, clean text merge'
  'Same concern, GAIA'"'"'s covers it'
  'Same concern, the adopter'"'"'s covers something GAIA'"'"'s misses'
  '| Contradictory |'
  '`auto-merged`'
  'candidates/<path>.auto'
  '"$LATEST_DIR/.gaia/cli/gaia" update merge-package'
  '`merge-workspace` serves'
  '`merge-audit-ci` serves'
  '--deferred-baseline <key>=<EXTRA_DIR path>/<path>'
  'bash .gaia/scripts/update-gaia-report.sh references --tree'
  'bash .gaia/scripts/update-decisions.sh context --file'
  'EARLIER <tag> <decision>'
  'goes through Bash'
  'keys(baseline manifest `.files`) ∪ keys(latest manifest `.files`) ∪ the path of every `deferred` decision-log entry'
  '`pending-judgment`'
  'bash .gaia/scripts/update-gaia-report.sh validate'
)

# Prints each contract needle missing from file `$1`.
missing_contract_needles() {
  local needle
  for needle in "${CONTRACT_NEEDLES[@]}"; do
    grep -qF -- "$needle" "$1" || printf '%s\n' "$needle"
  done
}

@test "contract: merge-execution.md names every call and rule it owes the orchestrator" {
  [ "${#CONTRACT_NEEDLES[@]}" -eq 19 ]
  [ -z "$(missing_contract_needles "$MERGE_EXECUTION")" ]
  local copy="$BATS_TEST_TMPDIR/merge-execution-missing.md" needle
  for needle in "${CONTRACT_NEEDLES[@]}"; do
    grep -vF -- "$needle" "$MERGE_EXECUTION" > "$copy"
    [ -n "$(missing_contract_needles "$copy")" ] || { echo "not reported: $needle" >&2; return 1; }
  done
}

@test "contract: merge-generated.md carries both release-resolved region calls" {
  local needle copy="$BATS_TEST_TMPDIR/merge-generated-missing.md"
  for needle in '"$LATEST_DIR/.gaia/cli/gaia" update merge-region' '"$LATEST_DIR/.gaia/cli/gaia" update regen-regions'; do
    grep -qF -- "$needle" "$MERGE_GENERATED" || { echo "missing: $needle" >&2; return 1; }
    grep -vF -- "$needle" "$MERGE_GENERATED" > "$copy"
    grep -qF -- "$needle" "$copy" && return 1
  done
  true
}
