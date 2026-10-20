#!/usr/bin/env bats
# Whole-tree guard: no tracked file outside an enumerated allowlist names the
# retired .gaia/local/specs, .gaia/local/plans or .gaia/local/research roots.
# The notebook replaced them, so a skill, rule, script or doc that still says
# "save to .gaia/local/specs/..." points at nothing. The allowlist
# (.gaia/tests/fixtures/notebook-retired-paths-allowlist.tsv) names the files
# that spell the old roots on purpose, each with its reason; a live-prose row
# also carries a line pattern, so a new line in that file naming an old root
# as a live location still fails.
#
# Checker output: RETIRED <file>:<line>: <text> for a hit with no allowance,
# STALE-ALLOW <file> for a row whose file has no hit, BAD-ALLOW <line>: <why>
# for a malformed row, EMPTY-SCAN-SET when nothing is tracked. A scan of
# nothing never reports clean. Modeled on .gaia/scripts/check-retired-paths.sh.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

RETIRED_ROOTS_PATTERN='\.gaia/local/(specs|plans|research)([^[:alnum:]_]|$)'

# This suite and the allowlist spell the pattern by design.
SUITE_PATH='.gaia/tests/lib/notebook-retired-paths.bats'
ALLOWLIST_PATH='.gaia/tests/fixtures/notebook-retired-paths-allowlist.tsv'

# Exit 0 clean, 1 on a hit or a bad or stale row, 2 on an unlistable root or an
# empty scan set.
notebook_retired_paths_check() {
  local root="$1" allowlist="$2"
  local failed=0 tracked_count hits_file grep_status
  local row_count=0 row_number=0 line row_file row_reason row_pattern remainder
  local row_files=() row_patterns=() row_seen=()
  local hit_file hit_line hit_text index allowed tab=$'\t'

  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "NOT-A-REPOSITORY $root"
    return 2
  fi
  tracked_count="$(git -C "$root" ls-files -z | tr -cd '\0' | wc -c | tr -d ' ')"
  if [ "$tracked_count" -eq 0 ]; then
    echo "EMPTY-SCAN-SET"
    return 2
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    row_number=$((row_number + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    row_file="${line%%"$tab"*}"
    row_reason=""
    row_pattern=""
    if [ "$row_file" != "$line" ]; then
      remainder="${line#*"$tab"}"
      row_reason="${remainder%%"$tab"*}"
      if [ "$row_reason" != "$remainder" ]; then
        row_pattern="${remainder#*"$tab"}"
      fi
    fi
    if [ -z "$row_file" ] || [ -z "$row_reason" ]; then
      echo "BAD-ALLOW ${row_number}: a row needs a file and a reason"
      failed=1
      continue
    fi
    row_files[row_count]="$row_file"
    row_patterns[row_count]="$row_pattern"
    row_seen[row_count]=0
    row_count=$((row_count + 1))
  done < "$allowlist"

  hits_file="$(mktemp)"
  git -C "$root" grep -I -n -z -E -e "$RETIRED_ROOTS_PATTERN" -- . \
    ":(exclude)${SUITE_PATH}" ":(exclude)${ALLOWLIST_PATH}" > "$hits_file" || grep_status=$?
  if [ "${grep_status:-0}" -gt 1 ]; then
    rm -f "$hits_file"
    echo "UNLISTABLE $root"
    return 2
  fi

  while IFS= read -r -d '' hit_file && IFS= read -r -d '' hit_line && IFS= read -r hit_text; do
    allowed=0
    index=0
    while [ "$index" -lt "$row_count" ]; do
      if [ "${row_files[index]}" = "$hit_file" ]; then
        row_seen[index]=1
        if [ -z "${row_patterns[index]}" ] || grep -qE -e "${row_patterns[index]}" <<<"$hit_text"; then
          allowed=1
        fi
      fi
      index=$((index + 1))
    done
    if [ "$allowed" -eq 0 ]; then
      echo "RETIRED ${hit_file}:${hit_line}: ${hit_text}"
      failed=1
    fi
  done < "$hits_file"
  rm -f "$hits_file"

  index=0
  while [ "$index" -lt "$row_count" ]; do
    if [ "${row_seen[index]}" -eq 0 ]; then
      echo "STALE-ALLOW ${row_files[index]}"
      failed=1
    fi
    index=$((index + 1))
  done

  return "$failed"
}

setup() {
  REAL_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  REAL_ALLOWLIST="$BATS_TEST_DIRNAME/../fixtures/notebook-retired-paths-allowlist.tsv"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  ALLOWLIST="$BATS_TEST_TMPDIR/allowlist.tsv"
}

# A temp git repo with one innocent tracked file, so a clean scan has a scan set.
_fixture_repository() {
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init --quiet --initial-branch=main
  git -C "$FIXTURE" config user.email test@example.com
  git -C "$FIXTURE" config user.name Test
  git -C "$FIXTURE" config commit.gpgsign false
  printf 'innocent\n' > "$FIXTURE/README.md"
}

_plant() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" > "$FIXTURE/$1"
}

_commit_fixture() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit --quiet -m fixture
}

_write_allowlist() {
  printf '%s\n' "$@" > "$ALLOWLIST"
}

# bats test_tags=whole-tree
@test "the real tree passes with the committed allowlist" {
  run notebook_retired_paths_check "$REAL_ROOT" "$REAL_ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=whole-tree
@test "the real scan is armed: an empty allowlist reports hits in the history ledger and the migration prompt" {
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$REAL_ROOT" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qE '^RETIRED CHANGELOG\.md:[0-9]+: ' <<<"$output"
  grep -qE '^RETIRED \.gaia/migrations/2\.0\.0\.md:[0-9]+: ' <<<"$output"
}

# bats test_tags=whole-tree
@test "every allowlist row names a tracked file, and each live-prose row carries a line pattern" {
  row_count=0
  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    row_count=$((row_count + 1))
    row_file="${line%%$'\t'*}"
    [ -n "$(git -C "$REAL_ROOT" ls-files -z -- "$row_file" | tr '\0' '\n')" ] || { echo "untracked row: $row_file" >&2; return 1; }
    case "$row_file" in
      wiki/concepts/Notebook.md | "wiki/concepts/Local Working State.md" | .gaia/release-scrub.yml)
        pattern="$(printf '%s' "$line" | awk -F '\t' '{print $3}')"
        [ -n "$pattern" ] || { echo "live prose row without a line pattern: $row_file" >&2; return 1; }
        ;;
    esac
  done < "$REAL_ALLOWLIST"
  [ "$row_count" -gt 0 ]
}

@test "a planted skill file telling the reader to save under an old root fails naming that file" {
  _fixture_repository
  _plant .claude/skills/x/SKILL.md 'Save the result to `.gaia/local/specs/SPEC-NNN/`.'
  _commit_fixture
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  [ "$output" = 'RETIRED .claude/skills/x/SKILL.md:1: Save the result to `.gaia/local/specs/SPEC-NNN/`.' ]
}

@test "each of the three old roots is caught" {
  _fixture_repository
  _plant a.md 'see .gaia/local/specs/x'
  _plant b.md 'see .gaia/local/plans/x'
  _plant c.md 'see .gaia/local/research/x'
  _commit_fixture
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qF 'RETIRED a.md:1: ' <<<"$output"
  grep -qF 'RETIRED b.md:1: ' <<<"$output"
  grep -qF 'RETIRED c.md:1: ' <<<"$output"
}

@test "a name that only extends an old-root word is not a hit" {
  _fixture_repository
  _plant a.md 'see .gaia/local/specsfoo/x and .gaia/local/runs/y'
  _commit_fixture
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 0 ]
}

@test "the same file allowlisted without a line pattern passes" {
  _fixture_repository
  _plant .claude/skills/x/SKILL.md 'Save the result to `.gaia/local/specs/SPEC-NNN/`.'
  _commit_fixture
  _write_allowlist $'.claude/skills/x/SKILL.md\ttest allowance'
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an allowlist row whose file has no hit fails as stale, and so does a row for a missing file" {
  _fixture_repository
  _commit_fixture
  _write_allowlist $'README.md\tno hit in this file' $'gone.md\tfile does not exist'
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qxF 'STALE-ALLOW README.md' <<<"$output"
  grep -qxF 'STALE-ALLOW gone.md' <<<"$output"
}

@test "an allowlist row without a reason fails as malformed" {
  _fixture_repository
  _plant a.md 'see .gaia/local/specs/x'
  _commit_fixture
  _write_allowlist 'a.md' $'a.md\t'
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qF 'BAD-ALLOW 1:' <<<"$output"
  grep -qF 'BAD-ALLOW 2:' <<<"$output"
  grep -qF 'RETIRED a.md:1: ' <<<"$output"
}

@test "a row with a line pattern allows the matching line and still fails a line naming an old root as live" {
  _fixture_repository
  _plant wiki/concepts/Notebook.md 'Old machines hold 1.x-era folders under .gaia/local/specs/.
Write each new spec to .gaia/local/specs/SPEC-NNN/ when you start.'
  _commit_fixture
  _write_allowlist $'wiki/concepts/Notebook.md\tlive prose describing the old roots as old\t1\\.x-era folders under'
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qF 'RETIRED wiki/concepts/Notebook.md:2: ' <<<"$output"
  grep -qF 'wiki/concepts/Notebook.md:1: ' <<<"$output" && return 1
  true
}

@test "a row with a line pattern passes when every hit line matches it" {
  _fixture_repository
  _plant wiki/concepts/Notebook.md 'Old machines hold 1.x-era folders under .gaia/local/specs/.'
  _commit_fixture
  _write_allowlist $'wiki/concepts/Notebook.md\tlive prose describing the old roots as old\t1\\.x-era folders under'
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 0 ]
}

@test "this suite and the allowlist are exempt by path, a copy elsewhere is not" {
  _fixture_repository
  _plant "$SUITE_PATH" 'RETIRED_ROOTS_PATTERN=.gaia/local/specs'
  _plant "$ALLOWLIST_PATH" '.gaia/local/plans'
  _commit_fixture
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 0 ]
  _plant copy/notebook-retired-paths.bats 'RETIRED_ROOTS_PATTERN=.gaia/local/specs'
  git -C "$FIXTURE" add -A
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 1 ]
  grep -qF 'RETIRED copy/notebook-retired-paths.bats:1: ' <<<"$output"
}

@test "an untracked file naming an old root is outside the scan" {
  _fixture_repository
  _commit_fixture
  _plant untracked.md 'see .gaia/local/specs/x'
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 0 ]
}

@test "an empty tracked set fails instead of reporting clean" {
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init --quiet --initial-branch=main
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 2 ]
  [ "$output" = "EMPTY-SCAN-SET" ]
}

@test "a root that is not a repository fails" {
  mkdir -p "$FIXTURE"
  : > "$ALLOWLIST"
  run notebook_retired_paths_check "$FIXTURE" "$ALLOWLIST"
  [ "$status" -eq 2 ]
  grep -qF 'NOT-A-REPOSITORY' <<<"$output"
}
