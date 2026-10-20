#!/usr/bin/env bats

# Suite for .gaia/tests/whole-tree-mark-guard.sh, the guard that flags a bats
# test enumerating the tracked tree through a recognized idiom without the
# whole-tree mark. Only the test that runs the guard over the real tracked tree
# carries the mark; every other test reads fixtures under $BATS_TEST_TMPDIR or
# named files.
#
# Fixture suites live under $BATS_TEST_TMPDIR. Every tag line and waiver line a
# fixture needs is assembled at run time (write_mark, write_test_mark,
# write_waiver, printf), so the tag line sits at column 0 in this file only
# where this suite's own mark does, neither discovery nor bats tags the
# fixtures' text, and no waiver in a fixture is live in this file.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUARD="$REPO_ROOT/.gaia/tests/whole-tree-mark-guard.sh"
  FIXTURE_DIRECTORY="$BATS_TEST_TMPDIR/fixture-suites"
  mkdir -p "$FIXTURE_DIRECTORY"
}

write_mark() {
  printf '# bats %s\n' 'file_tags=whole-tree'
}

write_test_mark() {
  printf '# bats %s\n' 'test_tags=whole-tree'
}

# write_waiver <indent> <reason line> [<continuation line>...]: a waiver whose
# reason may wrap onto further comment lines.
write_waiver() {
  local indent="$1" continuation
  printf '%s# %s %s\n' "$indent" gaia-lint-ignore "whole-tree-mark-guard: $2"
  shift 2
  for continuation in "$@"; do
    printf '%s# %s\n' "$indent" "$continuation"
  done
}

# write_seed <kind>: the real-root assignment, per rooting shape.
write_seed() {
  case "$1" in
    dirname)
      printf '%s\n' 'ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
      ;;
    filename)
      printf '%s\n' 'ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"'
      ;;
    second-assignment)
      printf '%s\n' 'THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"'
      printf '%s\n' 'ROOT="$THIS_DIRECTORY/../.."'
      ;;
  esac
}

# write_idiom <idiom>: one test body line enumerating under $ROOT.
write_idiom() {
  case "$1" in
    git-ls-files)
      printf '%s\n' '  run git -C "$ROOT" ls-'files
      ;;
    git-grep)
      printf '%s\n' '  run git -C "$ROOT" grep -l needle -- .'
      ;;
    find)
      printf '%s\n' '  run find "$ROOT/.claude" -name "*.md"'
      ;;
    glob-loop)
      printf '%s\n' '  for agent in "$ROOT"/.claude/agents/*.md; do [ -f "$agent" ]; done'
      ;;
  esac
}

# write_fixture <path> <seed> <idiom> <yes | no | tag list>
write_fixture() {
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' '# header comment'
    printf '\n'
    if [ "$4" = yes ]; then
      write_mark
      printf '\n'
    elif [ "$4" != no ]; then
      printf '# bats file_tags=%s\n\n' "$4"
    fi
    printf '%s\n' 'setup() {'
    write_seed "$2" | sed 's/^/  /'
    printf '%s\n' '}'
    printf '\n'
    printf '%s\n' '@test "fixture" {'
    write_idiom "$3"
    printf '%s\n' '}'
  } >"$1"
}

IDIOMS="git-ls-files git-grep find glob-loop"
SEEDS="dirname filename second-assignment"

# bats test_tags=whole-tree
@test "the guard passes over the real tracked tree" {
  run bash "$GUARD" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "every idiom under every rooting shape, unmarked, is flagged with the suite file, the test and the mark to add" {
  local seed idiom suite
  for seed in $SEEDS; do
    for idiom in $IDIOMS; do
      suite="$FIXTURE_DIRECTORY/unmarked-$seed-$idiom.bats"
      write_fixture "$suite" "$seed" "$idiom" no
      run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
      if [ "$status" -ne 1 ]; then
        echo "expected exit 1 for $seed/$idiom, got $status: $output" >&2
        return 1
      fi
      case "$output" in
        *"unmarked-$seed-$idiom.bats: test \"fixture\" enumerates the tracked tree ("*"without the whole-tree mark; add '# bats test_tags=whole-tree' on the line above it"*) ;;
        *)
          echo "no mark-to-add line for $seed/$idiom: $output" >&2
          return 1
          ;;
      esac
    done
  done
}

@test "the same fixtures carrying the mark pass" {
  local seed idiom suite
  for seed in $SEEDS; do
    for idiom in $IDIOMS; do
      suite="$FIXTURE_DIRECTORY/marked-$seed-$idiom.bats"
      write_fixture "$suite" "$seed" "$idiom" yes
      run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
      if [ "$status" -ne 0 ]; then
        echo "expected exit 0 for $seed/$idiom, got $status: $output" >&2
        return 1
      fi
    done
  done
}

@test "a mark joined into a comma list of tags counts" {
  local suite="$FIXTURE_DIRECTORY/tag-list.bats"
  write_fixture "$suite" dirname find other,whole-tree
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
  write_fixture "$suite" dirname find other,unrelated
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
}

@test "every idiom against a fixture repository under the test temp directory is not flagged" {
  local suite="$FIXTURE_DIRECTORY/fixture-repo-only.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '  . "$ROOT/.gaia/scripts/lib.sh"'
    printf '%s\n' '  FIXTURE_REPO="$BATS_TEST_TMPDIR/repo"'
    printf '%s\n' '  FIXTURE_COPY="$FIXTURE_REPO/copy"'
    printf '%s\n' '}'
    printf '%s\n' '@test "fixture only" {'
    printf '%s\n' '  run git -C "$FIXTURE_REPO" ls-'files
    printf '%s\n' '  run git -C "$FIXTURE_COPY" -c core.quotepath=off grep -l needle'
    printf '%s\n' '  run find "$FIXTURE_REPO/.claude" -name "*.md"'
    printf '%s\n' '  for agent in "$FIXTURE_REPO"/.claude/agents/*.md; do :; done'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
}

@test "a root under a fixtures directory is not flagged" {
  local suite="$FIXTURE_DIRECTORY/fixtures-root.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '  CORPUS="$ROOT/.gaia/tests/fixtures/corpus"'
    printf '%s\n' '  REPORTS="$BATS_TEST_DIRNAME/fixtures/reports"'
    printf '%s\n' '}'
    printf '%s\n' '@test "fixtures only" {'
    printf '%s\n' '  for case_directory in "$CORPUS"/*/; do :; done'
    printf '%s\n' '  for report in "$REPORTS"/*.json; do :; done'
    printf '%s\n' '  run find "$ROOT/.gaia/tests/fixtures/binding" -type f'
    printf '%s\n' '  for entry in "$ROOT"/tests/fixtures/*.json; do :; done'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a listing that names literal paths is not flagged" {
  local suite="$FIXTURE_DIRECTORY/named-paths.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' '@test "named" {'
    printf '%s\n' '  done < <(git -C "$ROOT" ls-files -z -- frontend/.dockerignore frontend/Dockerfile)'
    printf '%s\n' '  run git -C "$ROOT" ls-files -s -z .githooks/pre-commit'
    printf '%s\n' '  git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a listing of a tracked directory, a root-level path, a glob, a magic pathspec or a variable is still flagged" {
  local repository="$BATS_TEST_TMPDIR/repository" suite operand
  mkdir -p "$repository/.claude/agents"
  printf 'agent\n' >"$repository/.claude/agents/a.md"
  git -C "$repository" init -q
  git -C "$repository" add -A
  for operand in '-- .claude/agents' '-z -- .dockerignore Dockerfile' "-z '*.sh'" '-- "$directory"' '-z -- ":(glob)frontend/x"'; do
    suite="$repository/listing.bats"
    {
      printf '%s\n' '#!/usr/bin/env bats'
      printf '%s\n' 'setup() {'
      printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
      printf '%s\n' '}'
      printf '%s\n' '@test "lists" {'
      printf '  run git -C "$ROOT" ls-%s %s\n' files "$operand"
      printf '%s\n' '}'
    } >"$suite"
    run bash "$GUARD" --root "$repository" "$suite"
    if [ "$status" -ne 1 ]; then
      echo "expected exit 1 for operand $operand, got $status: $output" >&2
      return 1
    fi
  done
}

@test "a suite that only calls a script that lists tracked files is not flagged, and the guard states that limit" {
  local suite="$FIXTURE_DIRECTORY/delegated.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' '@test "delegates" {'
    printf '%s\n' '  run bash "$ROOT/.gaia/scripts/lint-everything.sh"'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
  case "$output" in
    *"outside this guard's claim"*) ;;
    *) echo "pass output omits the delegation limit: $output" >&2; return 1 ;;
  esac
  local header_text
  header_text="$(awk '!/^#/ { exit } { print }' "$GUARD")"
  case "$header_text" in
    *"delegated to a script the suite calls"*) ;;
    *) echo "header omits the delegation limit" >&2; return 1 ;;
  esac
}

@test "the failure output ends by stating the recognized idioms and the delegation limit" {
  local suite="$FIXTURE_DIRECTORY/unmarked-limit.bats"
  write_fixture "$suite" dirname git-ls-files no
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
  local last_line
  last_line="$(printf '%s\n' "$output" | tail -n 1)"
  case "$last_line" in
    *"Only the idioms in this script's header are recognized"*"delegated to a script the suite calls is outside this guard's claim"*) ;;
    *) echo "last line omits the claim: $last_line" >&2; return 1 ;;
  esac
}

# The source suite enumerates the tracked tree inside a test body. Whichever
# spelling marks it (file tag or test tags), stripping every mark line from a
# copy has to leave the copy flagged.
@test "a copy of a real marked suite with every whole-tree mark stripped is flagged" {
  local source_suite="$REPO_ROOT/.gaia/scripts/tests/check-hook-scope-manifest.bats"
  local copy="$FIXTURE_DIRECTORY/check-hook-scope-manifest.bats"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh"
  # shellcheck disable=SC2154 # assigned by the sourced bats lib
  grep -qE "$verify_whole_tree_mark_pattern" "$source_suite"
  grep -vE "$verify_whole_tree_mark_pattern" "$source_suite" >"$copy"
  grep -qE "$verify_whole_tree_mark_pattern" "$copy" && return 1
  run bash "$GUARD" --root "$REPO_ROOT" "$copy"
  [ "$status" -eq 1 ]
  case "$output" in
    *"$copy: "*"enumerates the tracked tree"*) ;;
    *) echo "copy not named: $output" >&2; return 1 ;;
  esac
}

# ---- per-test attribution --------------------------------------------------

# write_two_tests <path> <first-marked: yes | no> <second-marked: yes | no>:
# two tests whose bodies both enumerate the tracked tree, no file mark.
write_two_tests() {
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    [ "$2" = yes ] && write_test_mark
    printf '%s\n' '@test "carries the mark" {'
    printf '%s\n' '  run git -C "$ROOT" ls-'files
    printf '%s\n' '}'
    [ "$3" = yes ] && write_test_mark
    printf '%s\n' '@test "lacks the mark" {'
    printf '%s\n' '  run find "$ROOT/.claude" -name "*.md"'
    printf '%s\n' '}'
  } >"$1"
}

@test "a marked test and an unmarked enumerating test: only the unmarked test is named" {
  local suite="$FIXTURE_DIRECTORY/per-test.bats"
  write_two_tests "$suite" yes no
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  case "$output" in
    *"per-test.bats: test \"lacks the mark\" enumerates the tracked tree (find <root>, line 10)"*) ;;
    *) echo "unmarked test not named: $output" >&2; return 1 ;;
  esac
  grep -qF -- '"carries the mark"' <<<"$output" && return 1
  true
}

@test "two unmarked enumerating tests are both named, not only the first" {
  local suite="$FIXTURE_DIRECTORY/both-unmarked.bats"
  write_two_tests "$suite" no no
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
  grep -qF -- 'both-unmarked.bats: test "carries the mark" enumerates the tracked tree (git -C <root> ls-''files, line 6)' <<<"$output" || return 1
  grep -qF -- 'both-unmarked.bats: test "lacks the mark" enumerates the tracked tree (find <root>, line 9)' <<<"$output"
}

@test "both tests carrying the test mark pass" {
  local suite="$FIXTURE_DIRECTORY/both-marked.bats"
  write_two_tests "$suite" yes yes
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a test tag list carrying whole-tree beside another tag counts" {
  local suite="$FIXTURE_DIRECTORY/tag-list-test.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '# bats %s\n' 'test_tags=slow,whole-tree'
    printf '%s\n' '@test "slow and whole-tree" {'
    printf '%s\n' '  run git -C "$ROOT" grep -l needle -- .'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---- outside any test body ---------------------------------------------------

# write_scoped <path> <setup | setup_file | helper> <none | file | every-test | waiver>:
# the idiom sits outside every test body, in the named scope, and the suite
# carries the named remedy.
write_scoped() {
  local scope="$2" remedy="$3"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    [ "$remedy" = file ] && write_mark
    printf '%s\n' 'ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    case "$scope" in
      setup | setup_file) printf '%s() {\n' "$scope" ;;
      helper) printf '%s\n' 'list_tracked() {' ;;
    esac
    [ "$remedy" = waiver ] && write_waiver '  ' 'every test that depends on this listing carries the test mark'
    printf '%s\n' '  git -C "$ROOT" ls-files -z >/dev/null'
    printf '%s\n' '}'
    [ "$remedy" = every-test ] && write_test_mark
    printf '%s\n' '@test "first" {'
    printf '%s\n' '  run true'
    printf '%s\n' '}'
    [ "$remedy" = every-test ] && write_test_mark
    printf '%s\n' '@test "second" {'
    [ "$scope" = helper ] && printf '%s\n' '  list_tracked'
    printf '%s\n' '  run true'
    printf '%s\n' '}'
  } >"$1"
}

@test "an idiom in setup, setup_file or a helper, with no remedy, needs the file-level mark" {
  local scope suite
  for scope in setup setup_file helper; do
    suite="$FIXTURE_DIRECTORY/scoped-$scope.bats"
    write_scoped "$suite" "$scope" none
    run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
    [ "$status" -eq 1 ] || { echo "expected exit 1 for $scope, got $status: $output" >&2; return 1; }
    case "$output" in
      *"scoped-$scope.bats: enumerates the tracked tree outside any test body (git -C <root> ls-""files, line 4) without the file-level whole-tree mark"*) ;;
      *) echo "no outside-body finding for $scope: $output" >&2; return 1 ;;
    esac
  done
}

@test "an idiom outside every test body passes under the file mark, every test marked, or a waiver" {
  local scope remedy suite
  for scope in setup setup_file helper; do
    for remedy in file every-test waiver; do
      suite="$FIXTURE_DIRECTORY/scoped-$scope-$remedy.bats"
      write_scoped "$suite" "$scope" "$remedy"
      run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
      [ "$status" -eq 0 ] || { echo "expected exit 0 for $scope/$remedy, got $status: $output" >&2; return 1; }
    done
  done
}

@test "one test marked out of two does not cover an idiom outside every test body" {
  local suite="$FIXTURE_DIRECTORY/scoped-half.bats"
  write_scoped "$suite" setup every-test
  # Drop the first of the two test marks: the second test alone is marked.
  awk -v mark="$(write_test_mark)" '$0 == mark && !dropped { dropped = 1; next } { print }' "$suite" >"$suite.half"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite.half"
  [ "$status" -eq 1 ]
}

# ---- waivers over a continued statement --------------------------------------

# write_continued <path> <with | without | misplaced>: a helper holding the two
# real continued shapes, a listing piped on the next physical line and a read
# loop fed from a listing on its terminator, each under a waiver whose reason
# wraps onto a second comment line. `misplaced` moves both waivers onto lines
# holding no idiom.
write_continued() {
  local placement="$2"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' 'count_shell() {'
    printf '%s\n' '  local count=0 path'
    [ "$placement" = misplaced ] && write_waiver '  ' 'the operand is not the tracked tree'
    printf '%s\n' '  : start'
    [ "$placement" = with ] && write_waiver '  ' 'every test that calls this helper carries' 'the test mark'
    printf '%s\n' '  git -C "$ROOT" ls-files -z -- '"'"'*.sh'"'"' \'
    printf '%s\n' '    | tr '"'"'\0'"'"' '"'"'\n'"'"' >/dev/null'
    printf '%s\n' '  while IFS= read -r -d '"''"' path; do'
    printf '%s\n' '    count=$((count + 1))'
    [ "$placement" = with ] && write_waiver '  ' 'every test that calls this helper carries' 'the test mark'
    printf '%s\n' '  done < <(git -C "$ROOT" -c core.quotepath=off ls-files -z '"'"'*.sh'"'"')'
    printf '%s\n' '  echo "$count"'
    printf '%s\n' '}'
    printf '%s\n' '@test "counts" {'
    printf '%s\n' '  run count_shell'
    printf '%s\n' '}'
  } >"$1"
}

@test "a waiver with a wrapped reason above a continued idiom in a helper passes" {
  local suite="$FIXTURE_DIRECTORY/continued.bats"
  write_continued "$suite" with
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "the same suite without its waivers is flagged at both statements" {
  local suite="$FIXTURE_DIRECTORY/continued-bare.bats"
  write_continued "$suite" with
  grep -q 'gaia-lint-ignore' "$suite"
  grep -v -e 'gaia-lint-ignore' -e '# the test mark' "$suite" >"$suite.bare"
  grep -q 'gaia-lint-ignore' "$suite.bare" && return 1
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite.bare"
  [ "$status" -eq 1 ]
  grep -qF -- 'outside any test body (git -C <root> ls-''files, line 8)' <<<"$output" || return 1
  grep -qF -- 'outside any test body (git -C <root> ls-''files, line 12)' <<<"$output"
}

@test "a waiver above a line holding no idiom waives nothing and is reported unused" {
  local suite="$FIXTURE_DIRECTORY/continued-misplaced.bats"
  write_continued "$suite" misplaced
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
  grep -qF -- 'continued-misplaced.bats:7: unused gaia-lint-ignore for whole-tree-mark-guard' <<<"$output"
}

@test "a waiver above an in-body idiom is honored" {
  local suite="$FIXTURE_DIRECTORY/in-body-waiver.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' '@test "lists a fixture copy" {'
    write_waiver '  ' 'the operand is not the tracked tree'
    printf '%s\n' '  run git -C "$ROOT" ls-'files
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---- mark spelling and placement ---------------------------------------------

# write_tag_case <path> <case>: a suite with no idiom whose one defect is the
# named tag line; the defect is reported on the line write_tag_case_line names.
write_tag_case() {
  local case_name="$2"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    case "$case_name" in
      indented) printf '  # bats %s\n' 'test_tags=whole-tree' ;;
      spaced-after-hash) printf '#  bats %s\n' 'test_tags=whole-tree' ;;
      no-space-after-hash) printf '#bats %s\n' 'test_tags=whole-tree' ;;
      trailing-blank) printf '# bats %s \n' 'test_tags=whole-tree' ;;
      space-after-equals) printf '# bats %s\n' 'test_tags= whole-tree' ;;
      space-after-comma) printf '# bats %s\n' 'test_tags=slow, whole-tree' ;;
      file-overridden) write_mark; printf '# bats %s\n' 'file_tags=other' ;;
      test-overridden) write_test_mark; printf '# bats %s\n' 'test_tags=other' ;;
    esac
    printf '%s\n' '@test "one" {'
    printf '%s\n' '  true'
    printf '%s\n' '}'
    case "$case_name" in
      file-after-test) write_mark ;;
      dangling) write_test_mark ;;
    esac
  } >"$1"
}

write_tag_case_line() {
  case "$1" in
    file-after-test | dangling) echo 5 ;;
    *) echo 2 ;;
  esac
}

@test "a whole-tree tag bats applies or the runner discovers, in a spelling or place they disagree on, is flagged with its line" {
  local case_name suite line_number
  for case_name in indented spaced-after-hash no-space-after-hash trailing-blank space-after-equals \
    space-after-comma file-after-test file-overridden test-overridden dangling; do
    suite="$FIXTURE_DIRECTORY/tag-$case_name.bats"
    write_tag_case "$suite" "$case_name"
    line_number="$(write_tag_case_line "$case_name")"
    run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
    [ "$status" -eq 1 ] || { echo "expected exit 1 for $case_name, got $status: $output" >&2; return 1; }
    grep -qF -- "tag-$case_name.bats:$line_number: " <<<"$output" \
      || { echo "no line-$line_number finding for $case_name: $output" >&2; return 1; }
  done
}

@test "canonical test and file marks in their places raise no spelling finding" {
  local suite="$FIXTURE_DIRECTORY/tag-canonical.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    write_mark
    write_test_mark
    printf '%s\n' '@test "one" {'
    printf '%s\n' '  true'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "no line of the guard or this suite restates the mark pattern" {
  local file
  for file in "$GUARD" "$BATS_TEST_FILENAME"; do
    grep -qF -- '([^,]*,)*whole''-tree' "$file" && { echo "$file restates the mark pattern" >&2; return 1; }
  done
  true
}

@test "a root with no tracked suite exits 2, not 0" {
  local empty_repo="$BATS_TEST_TMPDIR/empty-repo"
  mkdir -p "$empty_repo"
  git -C "$empty_repo" init -q
  run bash "$GUARD" --root "$empty_repo"
  [ "$status" -eq 2 ]
}

@test "a usage error exits 2" {
  run bash "$GUARD" --no-such-flag
  [ "$status" -eq 2 ]
  run bash "$GUARD" --root
  [ "$status" -eq 2 ]
}

@test "a missing suite operand exits 2" {
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$FIXTURE_DIRECTORY/absent.bats"
  [ "$status" -eq 2 ]
}
