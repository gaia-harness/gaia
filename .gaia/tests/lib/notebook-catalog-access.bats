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

# bats file_tags=whole-tree

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
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
}

# A temp git repo holding a copy of the library-or-move set plus one innocent
# script, so a clean scan has something to scan.
_fixture_repository() {
  local source_path relative
  mkdir -p "$FIXTURE/.gaia/scripts/notebook" "$FIXTURE/.claude/hooks"
  git -C "$FIXTURE" init --quiet --initial-branch=main
  git -C "$FIXTURE" config user.email test@example.com
  git -C "$FIXTURE" config user.name Test
  git -C "$FIXTURE" config commit.gpgsign false
  for source_path in "$REAL_ROOT"/.gaia/scripts/notebook/*.sh; do
    relative=".gaia/scripts/notebook/$(basename "$source_path")"
    _in_library_set "$relative" || continue
    cp "$source_path" "$FIXTURE/$relative"
  done
  printf '#!/usr/bin/env bash\necho innocent\n' > "$FIXTURE/.gaia/scripts/innocent.sh"
}

_commit_fixture() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit --quiet -m fixture
}

_plant() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" > "$FIXTURE/$1"
}

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

@test "a library-set file is skipped by path: a planted copy of the catalog name in it does not trip the scan" {
  _fixture_repository
  _plant .gaia/scripts/notebook/notebook-lib-extra.sh 'catalog_file="catalog.json"'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 0 ]
  grep -qF "CATALOG-ACCESS" <<<"$output" && return 1
  true
}

@test "a script naming the catalog file fails with its file and line" {
  _fixture_repository
  _plant .gaia/scripts/planted.sh 'echo start
cat "$main/.notebook/catalog.json"'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF 'CATALOG-ACCESS .gaia/scripts/planted.sh:2: ' <<<"$output"
}

@test "a script listing a kind folder fails" {
  _fixture_repository
  _plant .gaia/scripts/planted.sh 'ls "$main/.notebook/research"'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF 'CATALOG-ACCESS .gaia/scripts/planted.sh:1: ' <<<"$output"
}

@test "a hook naming a kind folder fails" {
  _fixture_repository
  _plant .claude/hooks/planted.sh 'case "$path" in */.notebook/specs/*) exit 2 ;; esac'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF 'CATALOG-ACCESS .claude/hooks/planted.sh:1: ' <<<"$output"
}

@test "a comment naming the catalog file fails: the scan reads every line" {
  _fixture_repository
  _plant .gaia/scripts/planted.sh '# the catalog.json file holds the rows'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF 'CATALOG-ACCESS .gaia/scripts/planted.sh:1: ' <<<"$output"
}

@test "a test or fixture directory under the scripts is out of scope" {
  _fixture_repository
  _plant .gaia/scripts/tests/planted.bats 'cat catalog.json'
  _plant .gaia/scripts/tests/fixtures/planted.txt 'x/.notebook/plans/y'
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "an empty scan set fails instead of reporting clean" {
  _fixture_repository
  rm "$FIXTURE/.gaia/scripts/innocent.sh"
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 2 ]
  [ "$output" = "EMPTY-SCAN-SET" ]
}

@test "a library set none of whose files spells the pattern fails the self-check" {
  _fixture_repository
  for library_file in "$FIXTURE"/.gaia/scripts/notebook/*.sh; do
    sed -i.bak -E -e 's/catalog\.json/catalog-file/g' -e 's#\.notebook/(specs|plans|research)#.notebook-kind#g' "$library_file"
    rm "$library_file.bak"
  done
  _commit_fixture
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF 'SELF-CHECK' <<<"$output"
}

@test "a root that is not a repository fails" {
  mkdir -p "$FIXTURE"
  run notebook_catalog_access_check "$FIXTURE"
  [ "$status" -eq 2 ]
  grep -qF 'NOT-A-REPOSITORY' <<<"$output"
}
