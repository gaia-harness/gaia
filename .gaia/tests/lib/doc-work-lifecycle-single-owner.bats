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
#   1. the reference carries every phrase, the heading exactly once, and a full
#      statement of cleanup, worktree removal and the continuation prompt (the
#      merge-wait fence is owned by the merge workflow page, so the reference
#      names the command in prose only);
#   2. outside the reference, no file carries a full statement of cleanup,
#      worktree removal or the continuation heading;
#   3. outside the reference, a fence holding the merge-wait phrase appears only
#      in the merge workflow page. Exemption: a fence that carries a
#      `gaia:orchestrator-step` sentinel line (the plan reference's post-merge
#      close template block is such a fence and must stay byte-identical);
#   4. every file under `.claude/skills` or `.claude/rules` that mentions any
#      signature phrase, in prose or in a fence, names `work-lifecycle.md`.
#      Naming the merge workflow page does not satisfy it. The exemptions are in
#      one array below. Pages under `wiki/concepts` are held to checks 2 and 3
#      only.
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
  # Exempt from check 4: always loaded and naming the merge workflow itself,
  # the reference, and the merge owner (outside check 4's scope in any case).
  CHECK_4_EXEMPT=(.claude/rules/pr-merge.md "$REFERENCE" "$MERGE_WORKFLOW")
  PHRASE_MERGE_WAIT='pr-wait-merge.sh --pr'
  PHRASE_CLEANUP='fetch --prune'
  PHRASE_REMOVE='ExitWorktree'
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

# list_carriers <root> <phrase>: prints the files in scope carrying the phrase.
list_carriers() {
  local root="$1" phrase="$2" relative
  while IFS= read -r relative; do
    file_mentions "$root/$relative" "$phrase" && printf '%s\n' "$relative"
  done < <(scope_files "$root")
  return 0
}

# check_1 <root>: the reference holds every phrase and a full statement of three.
check_1() {
  local root="$1" file="$1/$REFERENCE" failed=0 phrase
  if [ ! -f "$file" ]; then
    printf 'check1: %s missing\n' "$REFERENCE"
    return 1
  fi
  for phrase in "$PHRASE_MERGE_WAIT" "$PHRASE_CLEANUP" "$PHRASE_REMOVE" "$HEADING_CONTINUATION"; do
    if ! file_mentions "$file" "$phrase"; then
      printf 'check1: %s lacks "%s"\n' "$REFERENCE" "$phrase"
      failed=1
    fi
  done
  if [ "$(grep -cxF -- "$HEADING_CONTINUATION" "$file")" -ne 1 ]; then
    printf 'check1: %s must carry the heading "%s" exactly once\n' "$REFERENCE" "$HEADING_CONTINUATION"
    failed=1
  fi
  if [ "$(fence_hits "$file" "$PHRASE_CLEANUP" 0)" -lt 1 ]; then
    printf 'check1: %s has no fence holding "%s"\n' "$REFERENCE" "$PHRASE_CLEANUP"
    failed=1
  fi
  if ! file_mentions "$file" "$CALL_REMOVE"; then
    printf 'check1: %s lacks the call literal %s\n' "$REFERENCE" "$CALL_REMOVE"
    failed=1
  fi
  return "$failed"
}

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

# check_4 <root>: every skill or rule file mentioning a phrase names work-lifecycle.md.
check_4() {
  local root="$1" failed=0 relative exempt skip phrase mentioned
  while IFS= read -r relative; do
    case "$relative" in .claude/skills/* | .claude/rules/*) ;; *) continue ;; esac
    skip=0
    for exempt in "${CHECK_4_EXEMPT[@]}"; do
      [ "$relative" = "$exempt" ] && skip=1
    done
    [ "$skip" -eq 1 ] && continue
    mentioned=''
    for phrase in "$PHRASE_MERGE_WAIT" "$PHRASE_CLEANUP" "$PHRASE_REMOVE" "$HEADING_CONTINUATION"; do
      file_mentions "$root/$relative" "$phrase" && mentioned="$mentioned [$phrase]"
    done
    [ -n "$mentioned" ] || continue
    if ! file_mentions "$root/$relative" 'work-lifecycle.md'; then
      printf 'check4: %s mentions%s without naming work-lifecycle.md\n' "$relative" "$mentioned"
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

@test "carriers: each phrase is listed with the files that carry it" {
  local phrase
  for phrase in "$PHRASE_MERGE_WAIT" "$PHRASE_CLEANUP" "$PHRASE_REMOVE" "$HEADING_CONTINUATION"; do
    printf 'phrase "%s" is carried by:\n' "$phrase"
    list_carriers "$DOC_ROOT" "$phrase" | sed 's/^/  /'
  done
  list_carriers "$DOC_ROOT" "$PHRASE_CLEANUP" | grep -qxF -- "$REFERENCE"
}

# --- the four checks on the real tree -------------------------------------

@test "check 1: the reference carries every phrase and a full statement of each owned step" {
  run check_1 "$DOC_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

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

@test "check 4: every skill or rule file mentioning a phrase names work-lifecycle.md" {
  run check_4 "$DOC_ROOT"
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

@test "red twin: deleting the continuation heading from the reference turns check 1 red" {
  local copy
  copy="$(scratch_copy)"
  run check_1 "$copy"
  [ "$status" -eq 0 ]
  grep -vxF -- "$HEADING_CONTINUATION" "$copy/$REFERENCE" >"$copy/reference.tmp"
  mv "$copy/reference.tmp" "$copy/$REFERENCE"
  run check_1 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "$HEADING_CONTINUATION"
}

@test "red twin: a cleanup mention in residue.md with every work-lifecycle.md mention stripped turns check 4 red" {
  local copy residue='.claude/skills/gaia/references/residue.md'
  copy="$(scratch_copy)"
  run check_4 "$copy"
  if printf '%s\n' "$output" | grep -qF -- "check4: $residue "; then return 1; fi
  printf '\nRun git fetch --prune origin afterwards.\n' >>"$copy/$residue"
  sed 's/work-lifecycle\.md/the lifecycle reference/g' "$copy/$residue" >"$copy/residue.tmp"
  mv "$copy/residue.tmp" "$copy/$residue"
  grep -qF -- 'PR Merge Workflow.md' "$copy/$residue"
  run check_4 "$copy"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- "check4: $residue "
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
