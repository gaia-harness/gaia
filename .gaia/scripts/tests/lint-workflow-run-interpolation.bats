#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-workflow-run-interpolation.sh: the static gate
# that flags a `${{ }}` expression inside a workflow `run:` body, where Actions
# substitutes it into the script text before bash parses it.
#
# Two jobs, the same pair the sibling diff-quoting suite carries: prove the
# detector fires on a known-bad fixture and stays quiet on every legitimate
# shape (`env:`, `with:`, `if:`, `name:`, and a run body that only references
# shell variables), and assert the real scanned tree is clean so a regression
# fails CI.
#
# One test is load-bearing beyond coverage. A gate written for a class must red
# against that class's historical form, or it asserts nothing about the class it
# was written for: "reds against the pre-fix forensics-triage handler shape"
# carries a verbatim copy of a real pre-fix handler step, so it proves the
# detector reaches the shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-workflow-run-interpolation.sh"
  TEMPORARY_DIRECTORY=""
}

teardown() {
  [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# fixture_repo: an initialized git repo in $TEMPORARY_DIRECTORY with no files yet.
fixture_repo() {
  TEMPORARY_DIRECTORY="$(mktemp -d -t run-interp-lint-XXXXXX)"
  git -C "$TEMPORARY_DIRECTORY" init -q .
}

# fixture_workflow <name> <body>: write <body> to $TEMPORARY_DIRECTORY/.github/workflows/<name>
# and track it. Call fixture_repo first.
fixture_workflow() {
  mkdir -p "$TEMPORARY_DIRECTORY/.github/workflows"
  printf '%s\n' "$2" > "$TEMPORARY_DIRECTORY/.github/workflows/$1"
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
}

# surface_has_workflow_and_action <repo> <lib>: the `workflows` set, as <lib>
# resolves it inside <repo>, holds at least one workflow and one composite
# action. A set pointing at a directory that no longer exists would answer from
# the other half alone and still look populated.
surface_has_workflow_and_action() {
  run bash -c "cd '$1' && . '$2' && gaia_guard_scan_files probe workflows && printf '%s\n' \"\${GAIA_GUARD_SCAN_FILES[@]}\""
  [ "$status" -eq 0 ] || return 1
  grep -qE -- '^\.github/workflows/[^/]+\.ya?ml$' <<<"$output" || return 1
  grep -qE -- '^\.github/actions/[^/]+/action\.ya?ml$' <<<"$output" || return 1
}

# bats test_tags=protected
@test "reds against the pre-fix forensics-triage handler shape" {
  fixture_repo
  fixture_workflow triage.yml 'jobs:
  t:
    steps:
      - name: Handle malformed body
        run: |
          set -eu
          "$FORENSICS_DIR/handlers/handle-malformed-body.sh" \
            "$ISSUE_NUMBER" \
            "${{ steps.parse.outputs.parsed_file }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "triage.yml:9:" <<<"$output"
  grep -qF -- "env: block" <<<"$output"
}

@test "greens on the env: indirection that replaces it" {
  fixture_repo
  fixture_workflow triage.yml 'jobs:
  t:
    steps:
      - name: Handle malformed body
        env:
          PARSED_FILE: ${{ steps.parse.outputs.parsed_file }}
        run: |
          set -eu
          "$FORENSICS_DIR/handlers/handle-malformed-body.sh" \
            "$ISSUE_NUMBER" \
            "$PARSED_FILE"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "ignores expressions in with:, if:, name: and job-level env:" {
  fixture_repo
  fixture_workflow other.yml 'name: X
on: push
env:
  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
jobs:
  t:
    if: ${{ github.event_name == "push" }}
    steps:
      - name: Run ${{ github.actor }}
        uses: some/action@v1
        with:
          prompt: ${{ steps.render.outputs.body }}'
  run_linter
  [ "$status" -eq 0 ]
}

@test "flags an expression inside a comment in a run body" {
  fixture_repo
  fixture_workflow commented.yml 'jobs:
  t:
    steps:
      - run: |
          # value was ${{ steps.x.outputs.y }}
          echo hi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "commented.yml:5:" <<<"$output"
}

# reset_workflows: drops every tracked workflow of the fixture repo so one repo
# serves each case of a table.
reset_workflows() {
  rm -rf "$TEMPORARY_DIRECTORY/.github"
  git -C "$TEMPORARY_DIRECTORY" add -A
}

# Each header shape is legal YAML whose body Actions runs. A block-scalar
# header the pattern misses goes down the inline arm and leaves its body
# unscanned: a fail-open on a real shape, not a declared blind spot.
@test "a run: body is scanned whatever shape its header takes" {
  local -a names=(inline commented-header indicator-order folded)
  local -a bodies=(
    'jobs:
  t:
    steps:
      - run: ./script.sh "${{ steps.x.outputs.y }}"'
    'jobs:
  t:
    steps:
      - run: | # note
          echo "${{ steps.x.outputs.y }}"'
    'jobs:
  t:
    steps:
      - name: A
        run: |2-
          echo "${{ steps.x.outputs.y }}"
      - name: B
        run: |-2
          echo "${{ steps.a.outputs.b }}"'
    'jobs:
  t:
    steps:
      - run: >- # folded
          echo "${{ steps.x.outputs.y }}"'
  )
  # These line numbers overlap that list by coincidence; the check has no marker for an unrelated overlap.
  # subset of .gaia/scripts/tests/debt-batch-budget.bats#numbers
  local -a first_lines=(4 5 6 5)
  local -a second_lines=("" "" 9 "")
  local index name
  fixture_repo
  for index in 0 1 2 3; do
    name="${names[$index]}"
    reset_workflows
    fixture_workflow "$name.yml" "${bodies[$index]}"
    run_linter
    [ "$status" -eq 1 ] || { echo "case $name: status $status"; return 1; }
    grep -qF -- "$name.yml:${first_lines[$index]}:" <<<"$output" || { echo "case $name: line ${first_lines[$index]} not reported"; return 1; }
    if [ -n "${second_lines[$index]}" ]; then
      grep -qF -- "$name.yml:${second_lines[$index]}:" <<<"$output" || { echo "case $name: line ${second_lines[$index]} not reported"; return 1; }
    fi
  done
}

@test "a run: body ends where its block ends, resumes after it, and spans blank lines" {
  fixture_repo
  fixture_workflow boundary.yml 'jobs:
  t:
    steps:
      - name: First
        run: |
          echo hi
      - name: Second
        env:
          V: ${{ steps.x.outputs.y }}
        run: |
          echo "$V"'
  run_linter
  [ "$status" -eq 0 ] || { echo "case no leak past the end: status $status"; return 1; }

  reset_workflows
  fixture_workflow second.yml 'jobs:
  t:
    steps:
      - name: First
        run: |
          echo hi
      - name: Second
        run: |
          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ] || { echo "case scanning after a block ends: status $status"; return 1; }
  grep -qF -- "second.yml:9:" <<<"$output" || { echo "case scanning after a block ends: line 9 not reported"; return 1; }

  reset_workflows
  fixture_workflow blanks.yml 'jobs:
  t:
    steps:
      - run: |
          echo one

          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ] || { echo "case blank lines: status $status"; return 1; }
  grep -qF -- "blanks.yml:7:" <<<"$output" || { echo "case blank lines: line 7 not reported"; return 1; }
}

# The gate scans composite actions too: workflows here invoke them, so stopping
# at the first `uses:` hop would enforce the class only on the callers.

@test "flags an expression in a composite action run body" {
  fixture_repo
  mkdir -p "$TEMPORARY_DIRECTORY/.github/actions/thing"
  printf '%s\n' 'runs:
  using: composite
  steps:
    - shell: bash
      run: |
        echo "${{ steps.x.outputs.y }}"' > "$TEMPORARY_DIRECTORY/.github/actions/thing/action.yml"
  git -C "$TEMPORARY_DIRECTORY" add -A
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "action.yml:6:" <<<"$output"
}

@test "errors rather than greening when nothing is scanned" {
  fixture_repo
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output" || return 1
  grep -qF -- "the scan surface (workflows)" <<<"$output"
}

# The `|| exit $?` on the discovery call is the whole mechanism here. `|| exit 1`
# folds a discovery that never ran into the status the test above uses for a
# surface this gate read and found nothing in, and an operator handed that would
# go looking at the tree. Run outside any repository, so `git ls-files` fails
# rather than answering empty; that is the one discovery failure a fixture can
# produce without a stub.
@test "a discovery that never ran exits distinctly from a surface that came back empty" {
  TEMPORARY_DIRECTORY="$(mktemp -d -t run-interp-lint-XXXXXX)"
  run bash -c "cd '$TEMPORARY_DIRECTORY' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- "discovery failed" <<<"$output" || return 1
  grep -qF -- "nothing was scanned" <<<"$output"
}

# --- no phantom coverage ----------------------------------------------------

@test "the real scan surface holds a workflow and a composite action" {
  surface_has_workflow_and_action "$REPO_ROOT" "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh"
}

