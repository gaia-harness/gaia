#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-jq-as-binding.sh: the static gate that flags a
# jq `as` binding with an unparenthesized operator to its left, the shape jq 1.7
# and jq 1.8 parse differently.
#
# The two "reds against the pre-fix ..." tests carry verbatim copies of the two
# lines that shipped broken under jq 1.8, so the gate is proven against the
# shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-jq-as-binding.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_repo: an initialized git repo in $TEMPORARY_DIRECTORY with no files yet.
fixture_repo() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t jq-as-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
}

# fixture_file <path> <body>: write <body> to $TEMPORARY_DIRECTORY/<path> and
# track it. Call fixture_repo first.
fixture_file() {
  mkdir -p "$(dirname "$TEMPORARY_DIRECTORY/$1")"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/$1"
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
}

# lint_program <jq program>: lint one jq program wrapped as `jq -n '<program>'`
# in a fresh fixture script.
lint_program() {
  fixture_repo
  fixture_file probe.sh "#!/usr/bin/env bash
jq -n '$1'"
  run_linter
}

@test "reds against the pre-fix usage join-binding shape" {
  fixture_repo
  fixture_file lib.sh "#!/usr/bin/env bash
binding=\$(jq -c '
          (if any(\$rows[]; .kind == \"segment\" and (.first_ts | usage_epoch) as \$t | \$t != null and \$t < \$origin_t) then \$now else \$origin_ts end) as \$ts
' <<<\"\$rows\")"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "lib.sh:3:" <<<"$output" || return 1
  grep -qF -- "and" <<<"$output"
}

@test "reds against the pre-fix update-check reasons shape" {
  fixture_repo
  fixture_file check.sh "#!/usr/bin/env bash
jq -c '
        ((.reasons // []) | if type == \"array\" then map(select(type == \"string\" and . as \$token | allowed | index(\$token))) | join(\",\") else \"\" end) as \$reasons
' <<<\"\$cache\""
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "greens on both parenthesized replacements" {
  fixture_repo
  fixture_file fixed.sh "#!/usr/bin/env bash
jq -c '
          (if any(\$rows[]; .kind == \"segment\" and ((.first_ts | usage_epoch) as \$t | \$t != null and \$t < \$origin_t)) then \$now else \$origin_ts end) as \$ts
        | ((.reasons // []) | if type == \"array\" then map(select(type == \"string\" and (. as \$token | allowed | index(\$token)))) | join(\",\") else \"\" end) as \$reasons
        | [\$ts, \$reasons]
' <<<\"\$rows\""
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# Every operator here was probed against jq 1.7.1 and 1.8.2 and gives a
# different result under each when it sits unparenthesized left of `as`. `//`
# and the assignment family are in the list because they changed too, though
# they are the operators a reader is least likely to suspect.
@test "flags every binary, assignment and unary operator left of as" {
  local operator
  for operator in and or '==' '!=' '<' '<=' '>' '>=' '+' '-' '*' '/' '%' '//' \
    '=' '|=' '+=' '-=' '*=' '/=' '%=' '//='; do
    lint_program ".a $operator .b as \$v | \$v"
    [ "$status" -eq 1 ] || { echo "operator $operator: status $status, output: $output"; return 1; }
    grep -qF -- "probe.sh:2:" <<<"$output" || { echo "operator $operator: no file:line in: $output"; return 1; }
    rm -rf "$TEMPORARY_DIRECTORY"
  done
  lint_program "- 1 as \$v | \$v"
  [ "$status" -eq 1 ] || { echo "unary minus: status $status"; return 1; }
}

@test "flags destructuring patterns as well as plain variables" {
  local pattern
  for pattern in '[$first, $second]' '{a: $first}' '{$first}'; do
    lint_program ".a and .b as $pattern | 1"
    [ "$status" -eq 1 ] || { echo "pattern $pattern: status $status, output: $output"; return 1; }
    rm -rf "$TEMPORARY_DIRECTORY"
  done
}

# Each boundary below ends the expression `as` can reach, so an operator beyond
# it is outside the binding and both versions agree. The comma case is the one
# that looks most like a hit and is not one: probed identical under both.
@test "stays quiet when a boundary separates the operator from as" {
  local program
  for program in \
    '.a + .b | .c as $v | $v' \
    '[.a + .b, .c as $v | $v]' \
    'def f: .a + 1; .c as $v | $v' \
    'def f: .c as $v | $v; .a + f' \
    'f(.a + 1; .c as $v | $v)' \
    '.a + (.c as $v | $v)' \
    '.a + [.c as $v | $v]' \
    'if .a == 1 then .c as $v | $v else 0 end' \
    'if .a then 0 elif .b == 1 then .c as $v | $v else 0 end' \
    'if .a then 0 else .c as $v | $v end' \
    'reduce .[] as $x (0; . + $x)' \
    'foreach .[] as $x (0; . + $x)' \
    'try .c as $v | $v catch 0' \
    '.c as $v | $v'; do
    lint_program "$program"
    [ "$status" -eq 0 ] || { echo "program $program: status $status, output: $output"; return 1; }
    rm -rf "$TEMPORARY_DIRECTORY"
  done
}

@test "treats a balanced group left of as as one operand and keeps walking" {
  lint_program '.a and (.b | f) as $v | $v'
  [ "$status" -eq 1 ] || return 1
  rm -rf "$TEMPORARY_DIRECTORY"
  lint_program '(.a and .b) as $v | $v'
  [ "$status" -eq 0 ]
}

@test "does not read operators inside a string, a field name or a variable" {
  local program
  for program in \
    '"a + b // c" as $v | $v' \
    '.and as $v | $v' \
    '.or as $v | $v' \
    '$and as $v | $v' \
    '@base64 as $v | $v' \
    '. as [$a] ?// $a | $a'; do
    lint_program "$program"
    [ "$status" -eq 0 ] || { echo "program $program: status $status, output: $output"; return 1; }
    rm -rf "$TEMPORARY_DIRECTORY"
  done
}

@test "reports the as line of a program that spans lines" {
  fixture_repo
  fixture_file multi.sh "#!/usr/bin/env bash
jq -n '
  .a
  + .b
  as \$v
  | \$v'"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "multi.sh:5:" <<<"$output"
}

@test "skips full-line comments" {
  fixture_repo
  fixture_file commented.sh "#!/usr/bin/env bash
# jq 1.7 reads \`.a + 1 as \$r | body\` as \`.a + (1 as \$r | body)\`.
jq -n '.c as \$v | \$v'"
  run_linter
  [ "$status" -eq 0 ]
}

@test "flags a hit in a workflow run body" {
  fixture_repo
  fixture_file .github/workflows/ci.yml "jobs:
  t:
    steps:
      - run: |
          jq -n '.a // .b as \$v | \$v'"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ci.yml:5:" <<<"$output"
}

@test "flags a hit in an extensionless git hook" {
  fixture_repo
  fixture_file .githooks/pre-commit "#!/usr/bin/env bash
jq -n '.a + .b as \$v | \$v'"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".githooks/pre-commit:2:" <<<"$output"
}

@test "errors rather than greening when nothing is scanned" {
  fixture_repo
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
}

@test "a discovery that never ran exits distinctly from a surface that came back empty" {
  TEMPORARY_DIRECTORY="$(mktemp -d -t jq-as-lint-XXXXXX)"
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- "discovery failed" <<<"$output"
}

# bats test_tags=whole-tree
@test "the real repository tree is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}
