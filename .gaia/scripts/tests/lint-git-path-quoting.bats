#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-git-path-quoting.sh: the static gate that flags
# an executed `git diff --name-only` or `git ls-files` which omits `-z`, so
# git's default `core.quotePath` cannot C-quote a path the caller then parses.
#
# Two jobs, the same pair the sibling array-guard suite carries: prove the
# detector fires on a known-bad fixture in each file type the guard's two
# discoveries reach, and stays quiet on every
# legitimate shape (a `-z` call, a comment, a markdown code span, unfenced
# markdown prose, a string constant, an untracked file), and assert the real
# scanned tree is clean so a regression fails CI.
#
# Two groups of tests are load-bearing beyond coverage, and both exist because a
# guard that has never been shown to red against a real historical instance has
# asserted nothing about the class it was written for.
#
#   `#1229` makes that binding for the `diff --name-only` half: "reds against
#   the pre-fix worthiness-presence-check.sh derivation" is that test.
#
#   `#1389` makes it binding for the `ls-files` half, and names five discovery
#   call sites the extended guard must red against in their PRE-FIX form. The
#   five `@test`s under "the five pre-fix ls-files discovery sites" are that
#   requirement, one per site. Their point is the fixture BODY, which is the
#   literal pre-fix line copied from each site; the paths are the real ones so a
#   reader can trace a failing test back to what it was written for.
#
#   `#1392` makes it binding for the `diff` half's option spellings: a fixed
#   substring match could not see `--cached` or `--staged`, so the group under
#   "3a. The diff option region" pairs two pre-fix site fixtures with the
#   negative controls that keep the widened match from claiming a diff call
#   which prints no paths at all.
#
#   `#1400` makes it binding for the markdown half, and names three executed
#   documentation snippets the widened guard must red against in their PRE-FIX
#   form. The three `@test`s under "3c. The markdown half" are that requirement,
#   one per site, paired with the controls that keep the fence rule from
#   claiming the illustrative mentions that surround them.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. That is also
# what pins the untracked-file test below: an untracked script is not scanned.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_repo: an initialized git repo in $TEMPORARY_DIRECTORY, seeded with one benign tracked
# file of each kind the guard's two discoveries hard-error on when empty: a
# non-bats file for the original scan_files check, and a clean `*.bats` suite
# for gaia_guard_bats_files. A test that only cares about one surface would
# otherwise red on the OTHER surface's now-mandatory non-emptiness.
fixture_repo() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t git-path-quoting-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
  fixture_file seed.bats $'@test "seed" {\n  true\n}'
}

# fixture_repo_bare: like fixture_repo, but seeds nothing. For the tests that
# assert on an EMPTY scan surface itself.
fixture_repo_bare() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t git-path-quoting-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
}

# fixture_file <relative_path> <body>: write <body> to $TEMPORARY_DIRECTORY/<relative_path> and track it.
# Call fixture_repo or fixture_repo_bare first.
fixture_file() {
  mkdir -p "$TEMPORARY_DIRECTORY/$(dirname "$1")"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/$1"
  git -C "$TEMPORARY_DIRECTORY" add -f -- "$1"
}

# run_linter: run the gate from the fixture root, where its cwd-relative
# `git ls-files` resolves.
run_linter() {
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER'"
}

# 2. The detector fires, once per scanned file type

@test "flags an unquoted diff --name-only / --cached / ls-files call in a script, git hook or workflow, in each form" {
  case_label="flags an unquoted diff --name-only in a shell script"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "-z" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="flags an unquoted diff --name-only in a git hook"
  fixture_repo
  fixture_file .githooks/pre-commit $'#!/usr/bin/env sh\nchanged=$(git diff --name-only HEAD~1...HEAD)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".githooks/pre-commit:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="flags an unquoted diff --name-only in a workflow YAML run block"
  fixture_repo
  fixture_file .github/workflows/ci.yml $'jobs:\n  a:\n    steps:\n      - run: |\n          changed=$(git diff --name-only "${BASE}...HEAD")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".github/workflows/ci.yml:5" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="flags every unquoted call on a line, not only the first"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\na=$(git diff --name-only "$X") ; b=$(git diff --name-only "$Y")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  [ "$(grep -cF -- "probe.sh:2" <<<"$output")" -eq 2 ] || { echo "case $case_label: wrong count, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a git -C form missing -z is flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only "${base}...HEAD")"'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A legacy backtick command substitution is textually identical to a markdown
  # code span, and reading it as prose is a fail-OPEN miss. A backtick opening in
  # command position (after `=` or `(`) is substitution, not prose.
  case_label="a backtick command substitution in assignment position is flagged"
  fixture_repo
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          changed=`git diff --name-only "${BASE}...HEAD"`'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".github/workflows/ci.yml:5" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a backtick command substitution in subshell position is flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(`git diff --name-only "$B"`)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # `-z` is accepted anywhere in the option region and nowhere after it. The walk
  # terminates at the first non-option token, which is exactly where a pathspec
  # begins, so a pathspec carrying the token cannot vouch for a call that still
  # quotes.
  case_label="a -z appearing later in the call does not vouch for it"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" -- "docs/a -z b.md")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # `x="$(...)"` is the spelling most calls in this tree are actually written in,
  # and it is the one where the option region ends in `)"` rather than `)`. A walk
  # that strips every trailing character except the quote is blind to exactly that
  # form: the first of these reds on the pre-widening detector and must keep
  # reding, and the second is a compliant call that must never be reported.
  case_label="a quoted substitution closing against --name-only is still flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nb="$(git diff --name-only)"'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a quoted --cached substitution closing against --name-only is flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nc="$(git diff --cached --name-only)"'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A quoted pathspec must not vouch for the call just because the strip reaches
  # its closing quote: `"-z"` still begins with a quote afterwards, so the walk
  # terminates on it as a non-option rather than reading it as the flag.
  case_label="a quoted -z pathspec does not vouch for the call"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only -- "-z")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a -z inside an ls-files pathspec does not vouch for the call"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfiles=$(git ls-files -- "docs/a -z b.md")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an unquoted ls-files is reported as ls-files and hinted with its own idiom"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfor f in $(git ls-files); do :; done'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "ls-files without -z" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "read -r -d" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# The binding test. `#1229`'s Suggested fix: whichever guard lands must be shown
# to red against at least one of the historical sites in its pre-fix form.
# This is .claude/hooks/worthiness-presence-check.sh:169 as it stood before
# PR #1227 fixed it.
@test "reds against the pre-fix worthiness-presence-check.sh derivation" {
  fixture_repo
  fixture_file .claude/hooks/worthiness-presence-check.sh \
    $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/worthiness-presence-check.sh:2" <<<"$output"
}

# 3. Legitimate shapes are NOT flagged

@test "a -z call passes" {
  case_label="a call carrying -z passes"
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nchanged="$(git diff --name-only -z "${base}...HEAD" 2>/dev/null | tr \'\\0\' \'\\n\' || true)"'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a git --no-pager form carrying -z passes"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git --no-pager diff --name-only -z "$B" | tr \'\\0\' \'\\n\')'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a --cached call carrying -z passes"
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nstaged=$(git diff --cached --name-only -z --diff-filter=ACM | tr \'\\0\' \'\\n\')'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The option-region walk, in both directions. `ls-files` carries its selectors
  # before `-z`, so the anchored rule the `diff --name-only` half uses would
  # reject every real call; terminating the walk at the first non-option is what
  # keeps a pathspec from vouching in its place.
  case_label="a quoted substitution closing against ls-files -z passes"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\ne="$(git ls-files -z)"'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an ls-files call carrying -z passes"
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nwhile IFS= read -r -d \'\' f; do :; done < <(git ls-files -z \'*.sh\')'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an ls-files call whose -z follows selector options passes"
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nn=$(git ls-files --others --exclude-standard -z | tr \'\\0\' \'\\n\' | wc -l)'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a fenced call carrying -z passes"
  fixture_repo
  fixture_file docs/guide.md $'```bash\ngit ls-files -z \'*.sh\' | tr \'\\0\' \'\\n\'\n```'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A command substitution closing against its last option yields `-z)`, which is
  # neither the option the walk looks for nor a pathspec that should terminate it.
  case_label="an ls-files call whose -z closes the substitution passes"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfiles=$(git ls-files -z)'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}
@test "git invocation forms are recognized (-C, --no-pager, diff-tree, diff-files)" {
  case_label="a git -C form is recognized as an invocation and still checked"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only -z "${base}...HEAD" | tr \'\\0\' \'\\n\')"'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The `invoked` prefix must admit any git global option, not a hand-named pair.
  case_label="a git --no-pager form is recognized as an invocation"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git --no-pager diff --name-only "$B")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # Matching the bare `diff` reaches every `diff-*` plumbing spelling, whose tail
  # is itself dash-led so the walk continues into the real options. The demand is
  # correct there (each quotes exactly as `git diff` does), and the header says
  # so; these pin the behavior the header describes, on two different tails so
  # the claim is about the mechanism rather than about one command.
  case_label="a diff-tree --name-only call is reached and flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfiles=$(git diff-tree --no-commit-id --name-only -r HEAD)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a diff-files --name-only call is reached and flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfiles=$(git diff-files --name-only)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}
@test "a call that is not an invocation or is off the surface is skipped" {
  case_label="a full-line comment is skipped"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\n# changed=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The false positive that would otherwise fire on a workflow step where an
  # agent prompt names the command inside a markdown code span.
  case_label="a call inside a markdown code span is prose, not an invocation"
  fixture_repo
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          echo "1. Run `git diff --name-only origin/main...HEAD` first."'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The false positive that would otherwise fire on the GAIA_AUDIT_DIFF_CALL
  # assignment in .gaia/scripts/check-audit-base-derivation.sh, where the call is
  # the VALUE of a fixed-string variable rather than an invocation.
  case_label="a string constant that is not a git invocation is skipped"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nGAIA_AUDIT_DIFF_CALL=\'diff --name-only\''
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # Widening the match from `diff --name-only` to `diff` puts every diff call in
  # front of the scanner, so the walk is the only thing keeping the surface where
  # it was declared. Both of these are real shapes in this tree and neither
  # produces path output at all.
  case_label="a diff call with no --name-only is off the surface"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nif ! git diff --quiet; then git add -u; fi'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a diff --name-status call is off the surface"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --cached --name-status "${base}...HEAD")'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an untracked script is not scanned"
  fixture_repo
  # A tracked file is required, else the empty-scan-set guard below fires and
  # this test would pass for the wrong reason.
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  printf '%s\n' $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")' > "$TEMPORARY_DIRECTORY/untracked.sh"
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an ls-files call inside a markdown code span is prose, not an invocation"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          echo "Walk `git ls-files` first."'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a call outside a fence is prose, not an invocation"
  fixture_repo
  fixture_file docs/guide.md \
    $'Run git diff --name-only "$B...HEAD" to list the changed files.'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The toggle has to close as well as open, or every line after the first fenced
  # block on a page reads as fenced and the prose half of the rule stops existing.
  case_label="a call between two fenced blocks is outside the fence"
  fixture_repo
  fixture_file docs/guide.md \
    $'```bash\necho one\n```\n\nThen git ls-files lists them.\n\n```bash\necho two\n```'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # `--error-unmatch` makes the call an existence assertion whose contract is its
  # exit status; git documents it that way and every such call in this tree
  # discards stdout. Demanding `-z` there would be a change with no failure mode.
  case_label="an --error-unmatch existence assertion is exempt"
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\ngit -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# 3a. The diff option region: every spelling, not one fixed string
#
# `#1392` makes the option-region walk binding for the `diff` half, the way
# `#1229` and `#1389` are binding for the two halves' first shapes: a detector
# that matched `diff --name-only` as a fixed substring could not see a selector
# written between the two words, so `--cached` and `--staged` went unchecked.
# The two fixtures below are the literal pre-fix lines from the sites the
# widened walk reaches, so a green here means the guard reds where the hole
# actually was rather than where it was convenient to demonstrate. The first is
# the only site of the eight that failed OPEN.

@test "reds against the pre-fix commit-gate hook --cached derivation" {
  fixture_repo
  fixture_file .claude/hooks/commit-gate-fixture.sh \
    $'#!/usr/bin/env bash\nstaged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/commit-gate-fixture.sh:2" <<<"$output"
}

@test "reds against the pre-fix forensics-triage.yml --staged derivation" {
  fixture_repo
  fixture_file .github/workflows/forensics-triage.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          git diff --staged --name-only > "$touched_file"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/forensics-triage.yml:5" <<<"$output"
}

# The report names the surface, not the matched text. `diff` alone is what the
# scanner finds; `--name-only` is what the walk finds in the option region, and
# a reader given only the former could not tell which call was meant.
@test "a --cached hit is reported against the diff --name-only surface" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nstaged=$(git diff --cached --name-only)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "diff --name-only without -z" <<<"$output"
}

@test "documented blind spots stay fail-open or fail-closed as designed" {
  # The fail-OPEN limit the blind-spot block states: a positional revision written
  # before `--name-only` terminates the walk, because a revision is exactly what a
  # non-option token looks like. Pinned rather than left as prose, the same way the
  # backtick rule's two error directions are, so the day it stops being true is a
  # red test rather than a silently stale paragraph.
  case_label="a --name-only after a positional revision is missed, fail-open by design"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff HEAD --name-only)'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The command-position test recognizes `=` and `(` and nothing else. Both error
  # directions are pinned here so neither can drift unnoticed: parenthetical prose
  # is flagged (fail-closed, the repair is to reword), and a substitution opening
  # after a quote is missed (fail-open, tokenizer-bound). The docblock states this
  # as a rule; these two tests are that rule's oracle.
  case_label="parenthetical prose before a backtick is flagged, fail-closed by design"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\necho "Step 1 (`git diff --name-only origin/main...HEAD`) lists the files."'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a substitution opening after a quote is missed, fail-open by design"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nif [ -n "`git diff --name-only $B`" ]; then :; fi'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# The scanner walks every occurrence of the matched text on a line, and
# `--diff-filter` contains one. Only the first is in command position, so the
# `invoked` test is what stops the same call being reported twice.
@test "a --diff-filter option does not produce a second report for one call" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nstaged=$(git diff --cached --name-only --diff-filter=ACM)'
  run_linter
  [ "$status" -eq 1 ]
  [ "$(grep -cF -- "probe.sh:2" <<<"$output")" -eq 1 ]
}

@test "an empty scan set is a hard error, not a clean tree" {
  # An empty scan set means the discovery is wrong, never that the tree is clean.
  # Without this the gate prints `clean` and exits 0 having scanned nothing, which
  # is the lie-green failure it exists to stop elsewhere.
  case_label="an empty scan set is a hard error, not a clean tree"
  fixture_repo
  # A plain text file is off every half of the surface, so the scan set is empty
  # with the repository still non-empty. Markdown cannot play this part: its
  # fenced blocks are scanned, so a tracked `.md` makes the set non-empty.
  fixture_file notes.txt $'nothing scannable here'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "nothing was scanned" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "clean" <<<"$output" && { echo "case $case_label: unexpected text, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The `*.bats` discovery hard-errors independently of the `*.sh`/md/YAML
  # discovery: a repo carrying a tracked shell script and no tracked bats suite
  # must not print clean having scanned zero suites. `fixture_repo_bare` because
  # `fixture_repo`'s own seed would otherwise satisfy the very condition this
  # test exists to red on.
  case_label="an empty bats scan set is a hard error, not a clean tree"
  fixture_repo_bare
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "no tracked bats suites matched" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "clean" <<<"$output" && { echo "case $case_label: unexpected text, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# `*.bats` is on the scan surface now, through guard-awk-lib.sh's shared
# fixture-versus-execution discriminator: an executed call inside a `@test`
# body is shell like any other, and this pins that it is reported rather than
# exempted by file extension.
@test "an executed call inside a bats @test body is flagged" {
  fixture_repo
  # A tracked, scannable, clean file so the empty-scan-set guard cannot make
  # this pass for the wrong reason.
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  quoted="$(git diff --name-only "${base}...HEAD")"\n}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.bats:2" <<<"$output"
}

# 3b. The ls-files half of the class

# The five pre-fix discovery sites `#1389` names. Each fixture body is that
# site's literal pre-fix line, so a green here means the guard would have caught
# the class where it actually recurred, not merely where it was convenient to
# demonstrate. The last two are the irony that made the issue concrete: both
# guards for this class were themselves instances of it.

@test "reds against the pre-fix shell-lint.sh *.sh discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'*.sh\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against the pre-fix shell-lint.sh *.bats discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'*.bats\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against the pre-fix shell-lint.sh husky-hook discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'.husky/*\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against this guard's own pre-fix discovery" {
  fixture_repo
  fixture_file .gaia/scripts/lint-git-path-quoting.sh \
    $'#!/usr/bin/env bash\ndone < <(git ls-files \'*.sh\' \'.husky/*\' \'.github/workflows/*.yml\' | LC_ALL=C sort)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/lint-git-path-quoting.sh:2" <<<"$output"
}

@test "reds against the pre-fix lint-workflow-run-interpolation.sh discovery" {
  fixture_repo
  fixture_file .gaia/scripts/lint-workflow-run-interpolation.sh \
    $'#!/usr/bin/env bash\ndone < <(git ls-files \'.github/workflows/*.yml\' \'.github/workflows/*.yaml\' \\\n           | LC_ALL=C sort)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/lint-workflow-run-interpolation.sh:2" <<<"$output"
}

# 3c. The markdown half: an executed snippet on a documentation page

# The sites `#1400` names, each in its PRE-FIX form, one per test. Their
# point is the fixture BODY, the literal pre-fix line copied from the page; the
# paths are the real ones so a reader can trace a failing test back to what it
# was written for. The first of them was repaired by hand before any check
# could see it, so its fixture is the only remaining record that the widened
# detector would have caught it.

@test "reds against the pre-fix Quality Gate.md staged-file skip check" {
  fixture_repo
  fixture_file 'wiki/decisions/Quality Gate.md' \
    $'# Quality Gate\n\nQuick check:\n\n```bash\ngit diff --cached --name-only | grep -E \'\\.(ts|tsx)$\'\n```'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "wiki/decisions/Quality Gate.md:6" <<<"$output"
}

@test "reds against the pre-fix wiki-sync added-page count" {
  fixture_repo
  fixture_file .claude/skills/gaia/references/wiki/sync.md \
    $'### 9b. Count added pages per domain\n\n```bash\ngit diff --name-only --diff-filter=A "$CONSOLIDATED_SHA"..HEAD -- \\\n  wiki/decisions/ wiki/concepts/\n```'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/skills/gaia/references/wiki/sync.md:4" <<<"$output"
}

@test "reds against the pre-fix runbook staging discovery" {
  fixture_repo
  fixture_file .gaia/cli/fixture/runbook.md \
    $'```bash\nALL_TRACKED="/tmp/gaia-audit-all"\ngit ls-files > "$ALL_TRACKED"\n```'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/cli/fixture/runbook.md:3" <<<"$output"
}

# The fence rule in both directions. Outside a fence nothing is scanned, which
# is what keeps every prose mention of a path-listing command across this
# repository's markdown from becoming a finding; inside one nothing is prose.

@test "markdown fence tracking" {
  case_label="a tilde fence is tracked like a backtick fence"
  fixture_repo
  fixture_file docs/guide.md $'~~~bash\ngit ls-files > list.txt\n~~~'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The three shapes a delimiter that is merely COUNTED gets wrong. The first is
  # the one no parity check over the page can find: the inner opener and the outer
  # closer leave the page balanced, so the region reads as prose while the page
  # stays well-formed for its reader. `.github/forensics/prompt.md` carries it.
  case_label="a fenced block nested inside a longer fence is still scanned"
  fixture_repo
  fixture_file docs/guide.md \
    $'````markdown\n```bash\ngit ls-files > list.txt\n```\n````'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The same-run-length nesting shape, which the length rule alone cannot see: an
  # info string is what makes a ```bash line inside a ```markdown block an opener
  # rather than the close. This page renders as one well-formed block, so nothing
  # about it looks wrong to a reader either.
  case_label="a nested opener of equal run length does not close the fence"
  fixture_repo
  fixture_file docs/guide.md \
    $'```markdown\n```bash\ngit ls-files > list.txt\n```\n```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a delimiter of the other character does not close a fence"
  fixture_repo
  fixture_file docs/guide.md \
    $'```bash\n~~~\ngit ls-files > list.txt\n```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A blockquoted fence is how a page quotes a prompt an agent is told to run
  # verbatim, so it is executed instruction rather than illustration by
  # construction. `.claude/skills/gaia/references/cleanse.md` carries it.
  case_label="a fence carrying a blockquote prefix is entered"
  fixture_repo
  fixture_file docs/guide.md \
    $'  > ```bash\n  > git ls-files > list.txt\n  > ```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A code span cannot nest inside a fence, so the in-span test is switched off
  # there. This exact shape is the fail-OPEN miss the shell half still carries
  # ("a substitution opening after a quote is missed"): inside a fence the odd
  # backtick count is a legacy substitution rather than prose, and it is caught.
  case_label="a backtick substitution inside a fence is not read as a code span"
  fixture_repo
  fixture_file docs/guide.md $'```bash\nfiles="`git ls-files`"\n```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# 4. Reporting contract

@test "clean run reports clean and the report names the fix idiom" {
  case_label="a clean tree reports clean and exits 0"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\necho hello'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "clean" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="the report names the fix idiom"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "tr " <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# 5. `*.bats` on the scan surface
#
# guard-awk-lib.sh's shared discriminator tells a fixture literal, written
# through a recognized helper, from executed shell a suite runs through
# `bash -c` or `eval`. Everything below is against a REAL `.bats` fixture file,
# through the two-pass `scan_bats_file` invocation.

# 5a. The pragma

@test "pragma suppression and hygiene reporting" {
  case_label="an unused pragma above a clean bats line is reported"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: nothing to suppress here\n  echo hello\n}'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.bats:2: unused gaia-lint-ignore for lint-git-path-quoting" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a pragma naming an unresolvable guard token is reported as malformed"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore not-a-real-guard: reason given\n  echo hello\n}'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.bats:2: malformed gaia-lint-ignore: not-a-real-guard does not resolve to .gaia/scripts/not-a-real-guard.sh" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  [ "$(grep -cF -- "malformed gaia-lint-ignore" <<<"$output")" -eq 1 ] || { echo "case $case_label: wrong count, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a pragma with a resolving token and no reason is reported as malformed"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting:\n  echo hello\n}'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.bats:2: malformed gaia-lint-ignore for lint-git-path-quoting: no reason given" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  [ "$(grep -cF -- "malformed gaia-lint-ignore" <<<"$output")" -eq 1 ] || { echo "case $case_label: wrong count, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # This also pins the scripts_directory contract (README C1.3): the fixture repo
  # carries no .gaia/scripts/ of its own, so a token resolved cwd-relative would
  # read "lint-git-path-quoting" as orphaned. Resolution against the guard's OWN
  # directory is what lets a well-formed token here succeed.
  case_label="a pragma naming this guard suppresses a genuine instance, resolved against the guard's own directory"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: the unquoted call IS the point of this test\n  changed=$(git diff --name-only "${base}...HEAD")\n}'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The off-surface message names the TARGET line (where gaia_scan_pragma_here
  # answers 1), not the pragma comment's own line.
  case_label="a pragma above a genuine instance in a tracked .sh file is honored nowhere"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\n# gaia-lint-ignore lint-git-path-quoting: pretending to waive this\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "probe.sh:3: gaia-lint-ignore is honored only in *.bats" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a pragma above a genuine instance in a git hook is honored nowhere"
  fixture_repo
  fixture_file .githooks/pre-commit $'#!/usr/bin/env sh\n# gaia-lint-ignore lint-git-path-quoting: pretending to waive this\nchanged=$(git diff --name-only HEAD~1...HEAD)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".githooks/pre-commit:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- ".githooks/pre-commit:3: gaia-lint-ignore is honored only in *.bats" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A tilde fence rather than a backtick fence: guard-awk-lib.sh's legacy-
  # command-substitution backtick counter is not markdown-fence-aware, so an odd
  # run of backticks (a ```lang opener) leaves its tracker mid-span for the
  # comment lines that follow, and the pragma head is read as literal span data
  # rather than as a comment. A tilde fence carries no backtick at all, so the
  # pragma is read normally; see Notes for orchestrator for the backtick case.
  case_label="a pragma above a genuine instance in a markdown fence is honored nowhere"
  fixture_repo
  fixture_file docs/guide.md \
    $'~~~bash\n# gaia-lint-ignore lint-git-path-quoting: pretending to waive this\ngit ls-files > list.txt\n~~~'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3: gaia-lint-ignore is honored only in *.bats" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The off-surface finding fires whether or not its target carries an instance;
  # reading it only at the detector's print point would leave it silently inert
  # on every pragma above a clean line, which is most of them.
  case_label="a pragma above a clean line on a scanned .sh surface is still honored nowhere"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\n# gaia-lint-ignore lint-git-path-quoting: nothing below needs waiving\necho hello'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:3: gaia-lint-ignore is honored only in *.bats" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # The guard's own pathspec never reaches a composite action's action.yml, so a
  # pragma there is inert on both halves: no instance is claimed and no
  # honored-nowhere finding fires either, because the file is never scanned.
  case_label="a pragma on an unscanned surface (.github/actions) is inert"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file .github/actions/probe/action.yml \
    $'runs:\n  using: composite\n  steps:\n    - run: |\n        # gaia-lint-ignore lint-git-path-quoting: not on this surface\n        changed=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a wrapped pragma reason across multiple comment lines still suppresses"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: the unquoted call IS\n  # the point of this test, wrapped across two comment lines\n  changed=$(git diff --name-only "${base}...HEAD")\n}'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a stacked second pragma applies to the same target as the first"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: suppress this one\n  # gaia-lint-ignore not-a-real-guard: a second, stacked pragma\n  changed=$(git diff --name-only "${base}...HEAD")\n}'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "diff --name-only without -z" <<<"$output" && { echo "case $case_label: unexpected text, output: $output"; return 1; }
  grep -qF -- "malformed gaia-lint-ignore: not-a-real-guard" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="a blank line terminates a pragma block, leaving it unused"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: interrupted by a blank line\n\n  changed=$(git diff --name-only "${base}...HEAD")\n}'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.bats:2: unused gaia-lint-ignore for lint-git-path-quoting" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  grep -qF -- "diff --name-only without -z" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  # A wrapped reason is textually an ordinary comment line, and the two cannot be
  # told apart, so an ordinary prose comment between the pragma head and its
  # target does not interrupt the block either.
  case_label="an ordinary comment line between the pragma and its target does not interrupt it"
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  # gaia-lint-ignore lint-git-path-quoting: the unquoted call IS the point\n  # an unrelated prose comment sits here\n  changed=$(git diff --name-only "${base}...HEAD")\n}'
  run_linter
  [ "$status" -eq 0 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# 5b. The argument-region rule: the binding case (UAT-014) and its neighbors

# The binding test the whole SPEC exists for: a variable bound to a multi-line
# shell body, run through `bash -c`, whose interior line carries an unquoted
# call. `body` appears in an execution position, so the assignment arm of the
# argument-region rule never applies to it, and the interior line is reported
# like any other executed shell.
@test "an interior line of a bash -c body assigned to a variable is flagged (UAT-014)" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats "$(cat <<'EOF'
@test "runs a shell body" {
  local body
  body='set -e
for f in $(git ls-files); do :; done'
  bash -c "$body"
}
EOF
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.bats:4" <<<"$output"
  grep -qF -- "ls-files without -z" <<<"$output"
}

@test "an interior line of a directly-opened bash -c body is flagged" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats "$(cat <<'EOF'
@test "runs inline" {
  bash -c '
set -e
for f in $(git ls-files); do :; done
'
}
EOF
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ls-files without -z" <<<"$output"
}

# Pins the NR-to-FNR conversion (README C2, DP-001): under the two-pass
# invocation, pass 2's NR is `file_length + FNR`. This file is long enough that
# the two numbers cannot be mistaken for each other.
@test "the reported line number is FNR, not the two-pass NR (README C2)" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats "$(cat <<'EOF'
@test "padded" {
  true
  true
  true
  true
  true
  true
  true
  true
  true
  changed=$(git diff --name-only "${base}...HEAD")
}
EOF
)"
  run_linter
  [ "$status" -eq 1 ]
  # 12 lines total; a missed NR-to-FNR conversion would report line 23
  # (file_length 12 + FNR 11) rather than the call's real line, 11.
  grep -qF -- "probe.bats:11" <<<"$output"
  grep -qF -- "probe.bats:23" <<<"$output" && return 1
  true
}

# UAT-015: a fixture written through a helper the recognized set does not name
# is not data. The set names shapes, never files, so an unlisted helper fails
# closed rather than silently joining the idiom.
@test "a fixture written through an unrecognized helper is reported (UAT-015)" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats "$(cat <<'EOF'
@test "x" {
  write_custom_fixture probe.sh "changed=$(git diff --name-only "${base}...HEAD")"
}
EOF
)"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "diff --name-only without -z" <<<"$output"
}

# 5c. UAT-016: the non-bats surfaces keep exactly today's coverage
#
# Measured per guard (README, "What each guard reports today"): this guard
# reports BOTH a heredoc-body instance and a backslash-continuation instance on
# `*.sh`, git hooks and markdown. These pin that the `*.bats` fixture-region skip
# did not leak onto the surfaces it must never touch.

@test "an instance inside a heredoc body or on a continuation line is still flagged" {
  case_label="an instance inside a heredoc body in a shell script is still flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\ncat <<EOF\nchanged=$(git diff --name-only "${base}...HEAD")\nEOF'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an instance inside a heredoc body in a git hook is still flagged"
  fixture_repo
  fixture_file .githooks/pre-commit $'#!/usr/bin/env sh\ncat <<EOF\nchanged=$(git diff --name-only "${base}...HEAD")\nEOF'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".githooks/pre-commit:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an instance inside a heredoc body in a markdown fence is still flagged"
  fixture_repo
  fixture_file docs/guide.md $'```bash\ncat <<EOF\nchanged=$(git diff --name-only "${base}...HEAD")\nEOF\n```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:3" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an instance on a backslash-continuation line in a shell script is still flagged"
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only \\\n  -z "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "probe.sh:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an instance on a backslash-continuation line in a git hook is still flagged"
  fixture_repo
  fixture_file .githooks/pre-commit $'#!/usr/bin/env sh\nchanged=$(git diff --name-only \\\n  -z HEAD~1...HEAD)'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- ".githooks/pre-commit:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"

  case_label="an instance on a backslash-continuation line in a markdown fence is still flagged"
  fixture_repo
  fixture_file docs/guide.md $'```bash\nchanged=$(git diff --name-only \\\n  -z "${base}...HEAD")\n```'
  run_linter
  [ "$status" -eq 1 ] || { echo "case $case_label: status $status, output: $output"; return 1; }
  grep -qF -- "docs/guide.md:2" <<<"$output" || { echo "case $case_label: expected text missing, output: $output"; return 1; }
  rm -rf "$TEMPORARY_DIRECTORY"
}

# 5d. The desync verdict (UAT-018)

@test "a bats fixture ending inside an open quote produces the desync ERROR (UAT-018)" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  body=\'unterminated'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.bats: ERROR: the scan lost track of shell state" <<<"$output"
}

# The class-remedy footer names the -z repair, which fixes a class hit and
# nothing else. A run reddened only by pragma hygiene printed it anyway, sending
# the operator to a repair that has nothing to do with what went red. Both
# directions are pinned, because a gate that never prints the footer would
# satisfy the first assertion alone.
@test "the -z remedy footer is withheld on a run whose findings are all pragma hygiene" {
  fixture_repo
  # A clean non-bats file, because the guard hard-errors on an empty scan
  # surface and this test is about the footer, not about that error.
  fixture_file clean.sh $'#!/usr/bin/env bash\ntrue'
  fixture_file hygiene.bats $'@test "a" {\n  # gaia-lint-ignore lint-git-path-quoting: nothing here to suppress\n  true\n}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "unused gaia-lint-ignore" <<<"$output"
  grep -qF -- "Fix a diff hit:" <<<"$output" && return 1
  grep -qF -- "Fix an ls-files hit:" <<<"$output" && return 1
  true
}

@test "the -z remedy footer still prints when a real class hit is reported" {
  fixture_repo
  fixture_file clean.sh $'#!/usr/bin/env bash\ntrue'
  fixture_file hit.bats $'@test "a" {\n  out="$(git ls-files "*.sh")"\n}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "Fix a diff hit:" <<<"$output"
  grep -qF -- "Fix an ls-files hit:" <<<"$output"
}

# --- delta mode -------------------------------------------------------------

# run_linter_delta <path>...: run the gate with GAIA_GUARD_DELTA_FILE naming a
# NUL-delimited delta of <path>..., written outside the fixture repo so the
# delta file is never part of the tracked surface.
run_linter_delta() {
  printf '%s\0' "$@" > "$BATS_TEST_TMPDIR/delta"
  run bash -c "cd '$TEMPORARY_DIRECTORY' && GAIA_GUARD_DELTA_FILE='$BATS_TEST_TMPDIR/delta' bash '$LINTER' 2>&1"
}

# The violation sits outside the delta, so the clean exit also proves it is
# not scanned.
@test "delta mode: a delta holding none of the surface skips each set and exits 0" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter_delta notes.txt
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF -- 'the delta holds no shell, git hook, workflow or Markdown file; skipped' <<<"$output"
  grep -qF -- 'the delta holds no *.bats file; skipped' <<<"$output"
}

@test "delta mode: an empty surface before the intersection or an unreadable delta file exits non-zero" {
  fixture_repo_bare
  fixture_file notes.txt 'notes'
  run_linter_delta notes.txt
  [ "$status" -ne 0 ] || { echo "empty surface: $output"; return 1; }
  grep -qF -- 'nothing was scanned' <<<"$output"
  rm -rf "$TEMPORARY_DIRECTORY"

  fixture_repo
  fixture_file clean.sh $'#!/usr/bin/env bash\ntrue'
  run bash -c "cd '$TEMPORARY_DIRECTORY' && GAIA_GUARD_DELTA_FILE='$BATS_TEST_TMPDIR/missing' bash '$LINTER' 2>&1"
  [ "$status" -ne 0 ] || { echo "unreadable delta: $output"; return 1; }
  grep -qF -- 'could not be read; nothing was scanned' <<<"$output"
}

@test "delta mode: a delta holding one violating file reds and reports only it" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  fixture_file other.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only HEAD~1...HEAD)'
  run_linter_delta probe.sh
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -qF -- 'probe.sh:2' <<<"$output"
  grep -qF -- 'other.sh:' <<<"$output" && return 1
  true
}
