#!/usr/bin/env bats

# Tests for .gaia/scripts/machine-local-ref-lib.sh, the one detector behind the
# commit-msg hook, the pre-commit staged scan and the UAT gate's Playwright
# scan.
#
# A machine-local reference names a document that exists on one machine only:
# a SPEC, UAT or plan number, or a concrete path under .notebook/ or
# .gaia/local/ that one machine generated. The fixtures pair every refused form
# with the placeholder or GAIA-owned spelling that must pass, so a pattern that
# widens into a placeholder fails here before it reaches a hook.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.
# Assertion style per .claude/rules/bats-assertions.md.

setup_file() {
  export TEMPLATE_REPO="$BATS_FILE_TMPDIR/template-repo"
  mkdir -p "$TEMPLATE_REPO/wiki" "$TEMPLATE_REPO/scripts"
  git -C "$TEMPLATE_REPO" init --quiet --initial-branch=main
  git -C "$TEMPLATE_REPO" config user.email test@example.com
  git -C "$TEMPLATE_REPO" config user.name Test
  git -C "$TEMPLATE_REPO" config commit.gpgsign false
  printf '# Page\n\nOld text citing SPEC-001 stays until edited.\n' > "$TEMPLATE_REPO/wiki/page.md"
  git -C "$TEMPLATE_REPO" add wiki/page.md
  git -C "$TEMPLATE_REPO" commit --quiet -m init
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REPO_ROOT/.gaia/scripts/machine-local-ref-lib.sh"
  WORK="$BATS_TEST_TMPDIR"
}

# Write the remaining arguments, one per line, to the file $1.
write_lines() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
}

# Scan the file $1 in strict mode, the way the Playwright tree is read.
strict_scan() {
  bash -c 'source "$1" && machine_local_ref_files 1 "$2"' _ "$LIB" "$1"
}

# expect_scan <text|strict> <status|-> <needle> <line>...: scan the lines and
# require the exit status ("-" skips it) and that the output names the needle,
# or is empty when the needle is empty.
expect_scan() {
  local mode="$1" expected_status="$2" needle="$3"
  shift 3
  write_lines "$WORK/text" "$@"
  if [ "$mode" = strict ]; then
    run strict_scan "$WORK/text"
  else
    run bash "$LIB" text "$WORK/text"
  fi
  if [ "$expected_status" != "-" ] && [ "$status" -ne "$expected_status" ]; then
    printf 'scan of %s: expected exit %s, got %s\n%s\n' "$mode" "$expected_status" "$status" "$output" >&2
    return 1
  fi
  if [ -z "$needle" ]; then
    [ -z "$output" ] || { printf 'scan of %s: expected no output:\n%s\n' "$*" "$output" >&2; return 1; }
  else
    output_names "$needle" || return 1
  fi
}

# output_names <needle>: the last run's output contains the needle.
output_names() {
  case "$output" in
    *"$1"*) return 0 ;;
  esac
  printf 'output does not name %s:\n%s\n' "$1" "$output" >&2
  return 1
}

# output_lacks <needle>: the last run's output does not contain the needle.
output_lacks() {
  case "$output" in
    *"$1"*) printf 'output names %s:\n%s\n' "$1" "$output" >&2; return 1 ;;
  esac
  return 0
}

# A sandbox repository with one commit, for the staged verb.
make_repo() {
  local parent
  parent="$(cd "$(mktemp -d "$WORK/repo-XXXXXX")" && pwd -P)"
  cp -R "$TEMPLATE_REPO/." "$parent/"
  REPO="$parent"
}

@test "the text and strict scan refuses SPEC, PLAN, FLOW and lowercase three-digit ids with the line and match, and passes dated flow file names, placeholders, regex shapes, plan revision folders, issue numbers and UAT numbers" {
  expect_scan text 1 "line 1: SPEC-128" 'implements SPEC-128 cleanly' 'nothing here' 'covers PLAN-12'
  output_names "line 3: PLAN-12" || return 1
  output_lacks "line 2" || return 1
  expect_scan text 1 "line 1: FLOW-001" 'implements FLOW-001 cleanly'
  expect_scan strict - "FLOW-001" 'implements FLOW-001 cleanly'
  expect_scan text 1 "line 1: flow-123" 'branch feat/flow-123-x'
  expect_scan text 1 "line 1: flow-004" 'see flow-004 here'
  expect_scan strict - "flow-004" 'see flow-004 here'
  expect_scan text 0 "" 'recorded login-flow-2024-01-15.webm'
  expect_scan strict 0 "" 'recorded login-flow-2024-01-15.webm'
  expect_scan text 0 "" 'a FLOW-NNN id names one flow'
  expect_scan text 0 "" 'covers UAT-004 today'
  expect_scan text 1 "line 1: spec-034" 'feat(spec-034): add the roster'
  expect_scan text 0 "" \
    'a SPEC-NNN id resolves to .notebook/specs/SPEC-NNN/SPEC.md' \
    'the bare form is exactly SPEC-\d+ and nothing else' \
    'a revision lands in plan-2, then plan-3' \
    'a concrete id is written UAT-<n> in examples' \
    'Closes #2894, see #12 and gaia-react/gaia#40' \
    'the respec-1 and subplan-9 fragments are not ids'
}

@test "the text scan refuses concrete .notebook and .gaia/local run, archive and research paths and passes the generic layout, placeholders and the GAIA-owned local state locations" {
  expect_scan text 1 "line 1: .notebook/research/2026-10-07-holistic-review/STATE.md" \
    'state lives in .notebook/research/2026-10-07-holistic-review/STATE.md' \
    'see .notebook/research/oxlint-migration/README.md' \
    'the draft is .notebook/plans/cards/README.md'
  output_names "line 2: .notebook/research/oxlint-migration/README.md" || return 1
  output_names "line 3: .notebook/plans/cards/README.md" || return 1
  expect_scan text 0 "" \
    'research goes in .notebook/research/<date>-<topic>/' \
    'a SPEC folder is .notebook/specs/<SPEC-ID>/ and the catalog is .notebook/catalog.json' \
    'the whole tree is .notebook/ and .notebook/research/ holds folders' \
    'a resolved folder is .notebook/specs/$SPEC_ID/SPEC.md or .notebook/plans/{id}/'
  expect_scan text 1 "line 1: .gaia/local/runs/feat/12-cards/STATE.md" \
    'evidence is in .gaia/local/runs/feat/12-cards/STATE.md' \
    'the archive is .gaia/local/archive/2026-10-20.tar.gz.'
  output_names "line 2: .gaia/local/archive/2026-10-20.tar.gz" || return 1
  output_lacks "tar.gz." || return 1
  expect_scan text 0 "" \
    'the run folder is .gaia/local/runs/<branch>/STATE.md' \
    'a detached HEAD uses .gaia/local/runs/session-$session_id/STATE.md' \
    'the residue drainer reads .gaia/local/runs/residue' \
    'the count is .gaia/local/debt/count.json' \
    'the gate cache is .gaia/local/cache/gate1-${SPEC_ID}.json' \
    'the migration cache is .gaia/local/cache/shared/migrate-2/v2.0.0/tree'
}

@test "the message verb skips git comment lines, the scissors tail and merge and revert subjects, and refuses an id in the body at its line from the top" {
  write_lines "$WORK/message" \
    'fix(hooks): refuse machine-local references' \
    '' \
    '# Please enter the commit message. SPEC-128 here is a comment.' \
    '# ------------------------ >8 ------------------------' \
    '+ a diff line naming SPEC-129'
  run bash "$LIB" message "$WORK/message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  write_lines "$WORK/message" 'fix: a thing' '' 'Implements SPEC-128.'
  run bash "$LIB" message "$WORK/message"
  [ "$status" -eq 1 ]
  output_names "line 3: SPEC-128" || return 1

  write_lines "$WORK/message" \
    "Merge branch 'main' into feat/spec-128-cards" \
    '' \
    'Revert "feat(spec-034): add the roster"' \
    '' \
    'This reverts commit 0123456789abcdef.'
  run bash "$LIB" message "$WORK/message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "explain: names the rule and says to write out what the reference means" {
  run bash "$LIB" explain
  [ "$status" -eq 0 ]
  output_names ".claude/rules/working-doc-ids.md" || return 1
  output_names "write out" || return 1
}

# bats test_tags=protected
@test "the check verb prints the line and the explanation and exits 1 on a hit, exits 1 saying it could not scan, and exits 0 silently when clean" {
  write_lines "$WORK/message" 'fix: a thing' '' 'Implements SPEC-128.'
  run bash "$LIB" check message "$WORK/message"
  [ "$status" -eq 1 ]
  output_names "line 3: SPEC-128" || return 1
  output_names ".claude/rules/working-doc-ids.md" || return 1

  run bash "$LIB" check message "$WORK/missing"
  [ "$status" -eq 1 ]
  output_names "could not scan" || return 1

  write_lines "$WORK/message" 'fix: a thing'
  run bash "$LIB" check message "$WORK/message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=protected
@test "the staged verb refuses an added id line (Markdown, FLOW, full-line code comment, appended rename line), names path and line, and passes test and fixture trees, a space in a path, a pure rename, and a merge in progress" {
  make_repo
  printf '# Page\n\nOld text citing SPEC-001 stays until edited.\n\nNew line naming PLAN-007.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  output_names "wiki/page.md:5: PLAN-007" || return 1
  output_lacks "SPEC-001" || return 1

  make_repo
  printf '# Page\n\nOld text citing SPEC-001 stays until edited.\n\nNew line naming FLOW-007.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  output_names "wiki/page.md:5: FLOW-007" || return 1

  make_repo
  printf '#!/usr/bin/env bash\n# Implements SPEC-128.\nid="SPEC-128"\n' > "$REPO/scripts/tool.sh"
  git -C "$REPO" add scripts/tool.sh
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  output_names "scripts/tool.sh:2: SPEC-128" || return 1
  output_lacks "scripts/tool.sh:3" || return 1

  make_repo
  mkdir -p "$REPO/scripts/tests/fixtures" "$REPO/.gaia/tests/lib" "$REPO/app/__tests__"
  printf '# SPEC-128 fixture\n' > "$REPO/scripts/tests/fixtures/notes.md"
  printf '# UAT-004 trace\n' > "$REPO/.gaia/tests/lib/trace.bats"
  printf '// PLAN-007 case\n' > "$REPO/app/__tests__/cards.test.ts"
  printf '# SPEC-129 suite\n' > "$REPO/scripts/tool.bats"
  git -C "$REPO" add -A
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  make_repo
  printf '# Two Words\n\nPlain prose.\n' > "$REPO/wiki/Two Words.md"
  printf '# Other Page\n\nCites SPEC-130.\n' > "$REPO/wiki/Other Page.md"
  git -C "$REPO" add -A
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  output_names "wiki/Other Page.md:3: SPEC-130" || return 1

  make_repo
  git -C "$REPO" mv wiki/page.md wiki/renamed.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  make_repo
  git -C "$REPO" mv wiki/page.md wiki/renamed.md
  printf 'Appended line naming PLAN-007.\n' >> "$REPO/wiki/renamed.md"
  git -C "$REPO" add wiki/renamed.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  output_names "wiki/renamed.md:4: PLAN-007" || return 1
  output_lacks "SPEC-001" || return 1

  make_repo
  git -C "$REPO" mv wiki/page.md "wiki/Two Words.md"
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  make_repo
  printf 'Merged prose naming SPEC-131.\n' >> "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  git -C "$REPO" rev-parse HEAD > "$REPO/.git/MERGE_HEAD"
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "tracked: the real tree's prose and comments carry no machine-local reference" {
  run bash "$LIB" tracked "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
