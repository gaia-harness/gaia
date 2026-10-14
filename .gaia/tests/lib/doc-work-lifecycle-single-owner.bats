#!/usr/bin/env bats
#
# Doc-pin: the work lifecycle's shared steps have one owner.
#
# `.claude/skills/gaia/references/work-lifecycle.md` states the commit-to-cleanup
# lifecycle once. This suite counts the signature phrase of each shared step
# across every markdown file under `.claude/skills`, `.claude/rules` and
# `wiki/concepts`, and finds the full statement only in that reference:
#
#   merge wait        `pr-wait-merge.sh --pr`   full statement: a fence body holding it
#   cleanup           `fetch --prune`           full statement: a fence body holding it
#   worktree removal  `ExitWorktree`            full statement: the call literal
#                                               `ExitWorktree({action: "remove"` anywhere
#   sub-agent cleanup the continuation heading  full statement: that heading line
#
# Checks:
#   2. outside the reference, no file carries a full statement of cleanup,
#      worktree removal or the continuation heading;
#   3. outside the reference, a fence holding the merge-wait phrase appears only
#      in the merge workflow page. Exemption: a fence that carries a
#      `gaia:orchestrator-step` sentinel line (the plan reference's post-merge
#      close template block is such a fence and must stay byte-identical.
#
# Every check takes a root laid out like the repository and prints one offender
# line per violation, so the red twins run the same function against a mutated
# scratch copy and assert the mutated file is named.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC_ROOT="${DOC_ROOT:-$REPO_ROOT}"
  REFERENCE='.claude/skills/gaia/references/work-lifecycle.md'
  MERGE_WORKFLOW='wiki/concepts/PR Merge Workflow.md'
  DEBT='.claude/skills/gaia/references/debt.md'
  SCOPE_DIRS=(.claude/skills .claude/rules wiki/concepts)
  PHRASE_MERGE_WAIT='pr-wait-merge.sh --pr'
  PHRASE_CLEANUP='fetch --prune'
  CALL_REMOVE='ExitWorktree({action: "remove"'
  HEADING_CONTINUATION='### Sub-agent context: continuation prompt'
}

# scope_files <root>: relative paths of every markdown file in scope.
scope_files() {
  local root="$1" dir
  for dir in "${SCOPE_DIRS[@]}"; do
    [ -d "$root/$dir" ] || continue
    (cd "$root" && find "$dir" -type f -name '*.md')
  done | sort
}

# fence_hits <file> <phrase> <skip sentinel: 0|1>: prints the number of fences
# whose body holds the phrase. With skip set, a fence whose body holds a
# `gaia:orchestrator-step` sentinel line is not counted. A fence opens on any
# line starting with three backticks and closes on a bare three-backtick line.
fence_hits() {
  awk -v phrase="$2" -v skip="$3" '
    function flush() {
      if (index(body, phrase) > 0 && !(skip == 1 && index(body, "<!-- gaia:orchestrator-step ") > 0)) hits++
      body = ""
    }
    !open && /^[[:space:]]*```/ { open = 1; body = ""; next }
    open && /^[[:space:]]*```[[:space:]]*$/ { open = 0; flush(); next }
    open { body = body $0 "\n" }
    END { print hits + 0 }
  ' "$1"
}

file_mentions() { grep -qF -- "$2" "$1"; }

# check_2 <root>: no full statement of cleanup, removal or the heading outside the reference.
check_2() {
  local root="$1" failed=0 relative
  while IFS= read -r relative; do
    [ "$relative" = "$REFERENCE" ] && continue
    if [ "$(fence_hits "$root/$relative" "$PHRASE_CLEANUP" 0)" -gt 0 ]; then
      printf 'check2: %s holds a fence with "%s"\n' "$relative" "$PHRASE_CLEANUP"
      failed=1
    fi
    if file_mentions "$root/$relative" "$CALL_REMOVE"; then
      printf 'check2: %s holds the call literal %s\n' "$relative" "$CALL_REMOVE"
      failed=1
    fi
    if grep -qxF -- "$HEADING_CONTINUATION" "$root/$relative"; then
      printf 'check2: %s holds the heading line "%s"\n' "$relative" "$HEADING_CONTINUATION"
      failed=1
    fi
  done < <(scope_files "$root")
  return "$failed"
}

# check_3 <root>: a merge-wait fence appears only in the merge workflow page.
check_3() {
  local root="$1" failed=0 relative
  while IFS= read -r relative; do
    [ "$relative" = "$REFERENCE" ] && continue
    [ "$relative" = "$MERGE_WORKFLOW" ] && continue
    if [ "$(fence_hits "$root/$relative" "$PHRASE_MERGE_WAIT" 1)" -gt 0 ]; then
      printf 'check3: %s holds a fence with "%s"\n' "$relative" "$PHRASE_MERGE_WAIT"
      failed=1
    fi
  done < <(scope_files "$root")
  return "$failed"
}

# scratch_copy: copies the three scope directories into a scratch root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" dir
  rm -rf "$copy"
  for dir in "${SCOPE_DIRS[@]}"; do
    mkdir -p "$copy/$dir"
    cp -R "$DOC_ROOT/$dir/." "$copy/$dir/"
  done
  printf '%s\n' "$copy"
}

# --- scope ---------------------------------------------------------------

@test "scope: the file set is non-empty and holds the reference, the merge workflow page and debt.md" {
  local listing
  listing="$(scope_files "$DOC_ROOT")"
  [ -n "$listing" ]
  printf '%s\n' "$listing" | grep -qxF -- "$REFERENCE"
  printf '%s\n' "$listing" | grep -qxF -- "$MERGE_WORKFLOW"
  printf '%s\n' "$listing" | grep -qxF -- "$DEBT"
}

# --- the four checks on the real tree -------------------------------------

@test "check 2: no full statement of cleanup, worktree removal or the heading outside the reference" {
  run check_2 "$DOC_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "check 3: a merge-wait fence appears only in the merge workflow page, sentinel fences excepted" {
  run check_3 "$DOC_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# --- red twins -----------------------------------------------------------

@test "red twin: a cleanup fence appended to debt.md turns check 2 red and names debt.md" {
  local copy
  copy="$(scratch_copy)"
  run check_2 "$copy"
  if printf '%s\n' "$output" | grep -qF -- "check2: $DEBT "; then return 1; fi
  printf '\n```bash\ngit fetch --prune origin\n```\n' >>"$copy/$DEBT"
  run check_2 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "check2: $DEBT "
}

@test "red twin: a merge-wait fence appended to codify.md turns check 3 red and names codify.md" {
  local copy codify='.claude/skills/gaia/references/codify.md'
  copy="$(scratch_copy)"
  run check_3 "$copy"
  if printf '%s\n' "$output" | grep -qF -- "check3: $codify "; then return 1; fi
  printf '\n```bash\nbash .gaia/scripts/pr-wait-merge.sh --pr <N>\n```\n' >>"$copy/$codify"
  run check_3 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "check3: $codify "
}

@test "red twin: deleting the post-merge-close sentinel line from planner.md turns check 3 red" {
  local copy planner='.claude/skills/gaia/references/plan/planner.md'
  copy="$(scratch_copy)"
  run check_3 "$copy"
  if printf '%s\n' "$output" | grep -qF -- "check3: $planner "; then return 1; fi
  grep -vF -- '<!-- gaia:orchestrator-step post-merge-close -->' "$copy/$planner" >"$copy/planner.tmp"
  mv "$copy/planner.tmp" "$copy/$planner"
  run check_3 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "check3: $planner "
}
