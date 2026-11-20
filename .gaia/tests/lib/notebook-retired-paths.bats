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
}

# bats test_tags=whole-tree
@test "the real tree passes with the committed allowlist" {
  run notebook_retired_paths_check "$REAL_ROOT" "$REAL_ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
