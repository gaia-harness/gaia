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

@test "text: refuses SPEC, UAT and PLAN numbers and names each line and match" {
  write_lines "$WORK/text" 'implements SPEC-128 cleanly' 'nothing here' 'covers UAT-004 and PLAN-12'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: SPEC-128"* ]]
  [[ "$output" == *"line 3: UAT-004"* ]]
  [[ "$output" == *"line 3: PLAN-12"* ]]
  [[ "$output" != *"line 2"* ]]
}

@test "text: refuses a lowercase three-digit id, the branch and scope spelling" {
  write_lines "$WORK/text" 'feat(spec-034): add the roster'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: spec-034"* ]]
}

@test "text: passes placeholders, regex shapes, plan revision folders and issue numbers" {
  write_lines "$WORK/text" \
    'a SPEC-NNN id resolves to .notebook/specs/SPEC-NNN/SPEC.md' \
    'the bare form is exactly SPEC-\d+ and nothing else' \
    'a revision lands in plan-2, then plan-3' \
    'a concrete id is written UAT-<n> in examples' \
    'Closes #2894, see #12 and gaia-react/gaia#40' \
    'the respec-1 and subplan-9 fragments are not ids'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "text: refuses concrete notebook folders, dated or not" {
  write_lines "$WORK/text" \
    'state lives in .notebook/research/2026-10-07-holistic-review/STATE.md' \
    'see .notebook/research/oxlint-migration/README.md' \
    'the draft is .notebook/plans/cards/README.md'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: .notebook/research/2026-10-07-holistic-review/STATE.md"* ]]
  [[ "$output" == *"line 2: .notebook/research/oxlint-migration/README.md"* ]]
  [[ "$output" == *"line 3: .notebook/plans/cards/README.md"* ]]
}

@test "text: passes the generic notebook layout and placeholder folders" {
  write_lines "$WORK/text" \
    'research goes in .notebook/research/<date>-<topic>/' \
    'a SPEC folder is .notebook/specs/<SPEC-ID>/ and the catalog is .notebook/catalog.json' \
    'the whole tree is .notebook/ and .notebook/research/ holds folders' \
    'a resolved folder is .notebook/specs/$SPEC_ID/SPEC.md or .notebook/plans/{id}/'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "text: refuses a concrete run folder and a dated local artifact" {
  write_lines "$WORK/text" \
    'evidence is in .gaia/local/runs/feat/12-cards/STATE.md' \
    'the archive is .gaia/local/archive/2026-10-20.tar.gz.'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 1: .gaia/local/runs/feat/12-cards/STATE.md"* ]]
  [[ "$output" == *"line 2: .gaia/local/archive/2026-10-20.tar.gz"* ]]
  [[ "$output" == *"tar.gz."* ]] && return 1
  true
}

@test "text: passes the local state locations GAIA owns on every machine" {
  write_lines "$WORK/text" \
    'the run folder is .gaia/local/runs/<branch>/STATE.md' \
    'a detached HEAD uses .gaia/local/runs/session-$session_id/STATE.md' \
    'the residue drainer reads .gaia/local/runs/residue' \
    'the count is .gaia/local/debt/count.json' \
    'the gate cache is .gaia/local/cache/gate1-${SPEC_ID}.json' \
    'the migration cache is .gaia/local/cache/shared/migrate-2/v2.0.0/tree'
  run bash "$LIB" text "$WORK/text"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "text: exits 2 on an unreadable input" {
  run bash "$LIB" text "$WORK/missing"
  [ "$status" -eq 2 ]
}

@test "text: exits 2 on an unknown verb" {
  run bash "$LIB" sideways
  [ "$status" -eq 2 ]
}

@test "message: skips git comment lines and everything below the scissors line" {
  write_lines "$WORK/message" \
    'fix(hooks): refuse machine-local references' \
    '' \
    '# Please enter the commit message. SPEC-128 here is a comment.' \
    '# ------------------------ >8 ------------------------' \
    '+ a diff line naming SPEC-129'
  run bash "$LIB" message "$WORK/message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "message: refuses an id in the body and counts lines from the top" {
  write_lines "$WORK/message" 'fix: a thing' '' 'Implements SPEC-128.'
  run bash "$LIB" message "$WORK/message"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 3: SPEC-128"* ]]
}

@test "message: skips the subjects git writes for a merge and a revert" {
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
  [[ "$output" == *".claude/rules/working-doc-ids.md"* ]]
  [[ "$output" == *"write out"* ]]
}

@test "check: a hit prints the line and the explanation and exits 1" {
  write_lines "$WORK/message" 'fix: a thing' '' 'Implements SPEC-128.'
  run bash "$LIB" check message "$WORK/message"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 3: SPEC-128"* ]]
  [[ "$output" == *".claude/rules/working-doc-ids.md"* ]]
}

@test "check: a scan that cannot run exits 1, not 2, and says so" {
  run bash "$LIB" check message "$WORK/missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not scan"* ]]
}

@test "check: a clean message exits 0 silently" {
  write_lines "$WORK/message" 'fix: a thing'
  run bash "$LIB" check message "$WORK/message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A sandbox repository with one commit, for the staged verb.
make_repo() {
  REPO="$(cd "$(mktemp -d "$WORK/repo-XXXXXX")" && pwd -P)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/wiki" "$REPO/scripts"
  printf '# Page\n\nOld text citing SPEC-001 stays until edited.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  git -C "$REPO" commit --quiet -m init
}

@test "staged: refuses an added Markdown line and names path and line" {
  make_repo
  printf '# Page\n\nOld text citing SPEC-001 stays until edited.\n\nNew line naming PLAN-007.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wiki/page.md:5: PLAN-007"* ]]
  [[ "$output" == *"SPEC-001"* ]] && return 1
  true
}

@test "staged: scans a full-line code comment, not a code line" {
  make_repo
  printf '#!/usr/bin/env bash\n# Implements SPEC-128.\nid="SPEC-128"\n' > "$REPO/scripts/tool.sh"
  git -C "$REPO" add scripts/tool.sh
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/tool.sh:2: SPEC-128"* ]]
  [[ "$output" == *"scripts/tool.sh:3"* ]] && return 1
  true
}

@test "staged: leaves test files, fixtures and the maintainer test tree to data" {
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
}

@test "staged: passes a path whose name has a space" {
  make_repo
  printf '# Two Words\n\nPlain prose.\n' > "$REPO/wiki/Two Words.md"
  printf '# Other Page\n\nCites SPEC-130.\n' > "$REPO/wiki/Other Page.md"
  git -C "$REPO" add -A
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wiki/Other Page.md:3: SPEC-130"* ]]
}

@test "staged: a pure rename of a file already citing an id is clean" {
  make_repo
  git -C "$REPO" mv wiki/page.md wiki/renamed.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staged: a rename that appends an id reports only the appended line" {
  make_repo
  git -C "$REPO" mv wiki/page.md wiki/renamed.md
  printf 'Appended line naming PLAN-007.\n' >> "$REPO/wiki/renamed.md"
  git -C "$REPO" add wiki/renamed.md
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wiki/renamed.md:4: PLAN-007"* ]]
  [[ "$output" == *"SPEC-001"* ]] && return 1
  true
}

@test "staged: a rename to a name with a space stays clean" {
  make_repo
  git -C "$REPO" mv wiki/page.md "wiki/Two Words.md"
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staged: does not scan while a merge is being concluded" {
  make_repo
  printf 'Merged prose naming SPEC-131.\n' >> "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  git -C "$REPO" rev-parse HEAD > "$REPO/.git/MERGE_HEAD"
  run bash "$LIB" staged "$REPO"
  [ "$status" -eq 0 ]
}

@test "staged: exits 2 outside a repository" {
  run bash "$LIB" staged "$WORK"
  [ "$status" -eq 2 ]
}

# bats test_tags=whole-tree
@test "tracked: the real tree's prose and comments carry no machine-local reference" {
  run bash "$LIB" tracked "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
