#!/usr/bin/env bats
# Whole-tree guard: only the notebook library opens the catalog file or lists a
# kind folder. Every other tracked script and hook reaches the notebook through
# the library's verbs or its path functions, so a later change to the layout
# touches one place. The checker scans tracked files only, every line, comments
# included: a comment that spells the catalog file or a kind folder is a second
# place that must change with the layout.
#
# Scan set: .gaia/scripts/** (not tests/ or fixtures/ directories) and
# .claude/hooks/**, minus the library-or-move set. A scan of nothing never
# reports clean, and neither does a library set that no longer spells the
# pattern (a pattern that matches nothing proves nothing). Modeled on
# .gaia/scripts/check-retired-paths.sh.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# What a line must not spell outside the library-or-move set.
CATALOG_ACCESS_PATTERN='catalog\.json|\.notebook/(specs|plans|research)([^[:alnum:]_]|$)'

# The library-or-move set, as shell globs relative to the repository root.
_library_set_globs() {
  printf '%s\n' \
    '.gaia/scripts/notebook/notebook-lib.sh' \
    '.gaia/scripts/notebook/notebook-lib-*.sh' \
    '.gaia/scripts/notebook/legacy-roots.sh' \
    '.gaia/scripts/notebook/move.sh'
}

_in_library_set() {
  local path="$1" glob
  while IFS= read -r glob; do
    # shellcheck disable=SC2254
    case "$path" in
      $glob) return 0 ;;
    esac
  done <<<"$(_library_set_globs)"
  return 1
}

# Tracked files the scan covers, NUL-separated, library set and test trees out.
_scan_set() {
  local root="$1" path
  while IFS= read -r -d '' path; do
    case "$path" in
      */tests/* | */fixtures/*) continue ;;
    esac
    _in_library_set "$path" && continue
    printf '%s\0' "$path"
  done < <(git -C "$root" ls-files -z -- .gaia/scripts .claude/hooks)
}

# Prints "CATALOG-ACCESS <file>:<line>: <text>" per hit and "scanned <n> files".
# Exit 0 clean, 1 on a hit or a failed self-check, 2 on an empty scan set or an
# unlistable root.
notebook_catalog_access_check() {
  local root="$1" path hit scanned=0 failed=0 library_matches=0

  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "NOT-A-REPOSITORY $root"
    return 2
  fi

  while IFS= read -r -d '' path; do
    scanned=$((scanned + 1))
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      echo "CATALOG-ACCESS ${path}:${hit%%:*}: ${hit#*:}"
      failed=1
    done <<<"$(grep -nIE -e "$CATALOG_ACCESS_PATTERN" "$root/$path" || true)"
  done < <(_scan_set "$root")

  if [ "$scanned" -eq 0 ]; then
    echo "EMPTY-SCAN-SET"
    return 2
  fi

  while IFS= read -r -d '' path; do
    _in_library_set "$path" || continue
    if grep -qIE -e "$CATALOG_ACCESS_PATTERN" "$root/$path"; then
      library_matches=$((library_matches + 1))
    fi
  done < <(git -C "$root" ls-files -z -- .gaia/scripts/notebook)

  if [ "$library_matches" -eq 0 ]; then
    echo "SELF-CHECK no library-set file spells the pattern, so the scan proves nothing"
    failed=1
  fi

  echo "scanned $scanned files"
  return "$failed"
}

setup() {
  REAL_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
}

# bats test_tags=whole-tree
@test "the real tree passes and scans exactly the tracked scripts and hooks outside the library set" {
  run notebook_catalog_access_check "$REAL_ROOT"
  [ "$status" -eq 0 ]
  expected="$(git -C "$REAL_ROOT" ls-files -z -- .gaia/scripts .claude/hooks \
    | grep -zvE '(^|/)(tests|fixtures)/' \
    | grep -zvE '^\.gaia/scripts/notebook/(notebook-lib\.sh|notebook-lib-[^/]*\.sh|legacy-roots\.sh|move\.sh)$' \
    | tr -cd '\0' | wc -c | tr -d ' ')"
  [ "$expected" -gt 0 ]
  [ "$output" = "scanned $expected files" ]
}
