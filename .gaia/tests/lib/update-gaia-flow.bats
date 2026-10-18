#!/usr/bin/env bats
# The /update-gaia orchestrator as SKILL.md writes it: the guard fence and its
# own-worktree prefix, every command block in the shape a worktree session
# admits, the run modes' classification of an earlier run's update branch
# (Step 3), the update worktree on Proceed (Step 4), the provisioning waits,
# the version written last (Step 9d), the cache bust, the draft PR (Step 11)
# and the deferred residue sweep (Step 12). The pre-merge blocks moved into
# .gaia/scripts/update-gaia-preflight.sh and the drift block into
# update-gaia-drift.sh; their behavior is driven by update-gaia-preflight.bats
# and update-gaia-drift.bats, so this suite pins the skill's calls and prose.
# Step 3's in-place block and Step 4's changelog call still run here, extracted
# by heading, against fixtures under $BATS_TEST_TMPDIR. Every pin has a red
# twin: a fixture copy carrying the forbidden content, or missing the
# required content.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md"
  MERGE_EXECUTION="$REPO_ROOT/.claude/skills/update-gaia/references/merge-execution.md"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
  SELECTOR="$REPO_ROOT/.gaia/scripts/select-migration-notes.sh"
  COMPARE_LIB="$REPO_ROOT/.gaia/scripts/lib/version-compare.awk"
  COPY="$BATS_TEST_TMPDIR/skill-copy.md"
}

STEP_3='## Step 3: Compare versions'
STEP_3_DEFAULT='### Step 3, default branch: classify the update branch'
STEP_3_WORKTREE='### Step 3, worktree run in place'
STEP_3_IN_PLACE="### Step 3, in place: an interrupted run's update branch"
STEP_3D='## Step 3d: Select migration notes'
STEP_4='## Step 4: Show the release notes and confirm'
STEP_4_WORKTREE='### Step 4, on Proceed: the update worktree'
STEP_9D='## Step 9d: Record the update'
STEP_10='## Step 10: Next steps for the user'
STEP_11='### Step 11: Open a pull request'
STEP_12='### Step 12: Offer the residue sweep'

CREATE_CALL='EnterWorktree({name: "<branch-name>"})'
WAIT_CALL='bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>'
PRUNE_CALL='bash .gaia/scripts/update-gaia-preflight.sh prune --baseline <BASELINE> --latest-tag <LATEST_TAG>'

# The fenced bash block that follows the heading line `$2` in file `$1`. The
# heading matches as a line prefix, so callers pass a full heading.
block_after_heading() {
  awk -v heading="$2" '
    index($0, heading) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

# The lines of the section headed `$2` in file `$1`, up to the next heading of
# level two or three.
section_of() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; print; next }
    inside && /^##+ / { exit }
    inside { print }
  ' "$1"
}

# Writes the section headed `$2` in file `$1` to a scratch file and prints its
# path; fails when the section is empty.
section_file() {
  local out
  out="$BATS_TEST_TMPDIR/section-$RANDOM.md"
  section_of "$1" "$2" > "$out"
  [ -s "$out" ] || { echo "no section: $2" >&2; return 1; }
  printf '%s\n' "$out"
}

# Runs block text `$2` with `$1` as its working directory. Extra arguments are
# NAME=value pairs exported into the block's environment.
run_block_in() {
  local directory="$1" block="$2"
  shift 2
  run env "$@" bash -c 'cd "$1" || exit 99; eval "$2"' _ "$directory" "$block"
}

# The first line number in file `$1` holding fixed string `$2`; empty if none.
first_line() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# 0 when the fixed strings `$2`, `$3`, ... first appear in file `$1` in that
# order, each present.
in_order() {
  local file="$1" previous=0 needle line
  shift
  for needle in "$@"; do
    line="$(first_line "$file" "$needle")"
    [ -n "$line" ] || { echo "missing: $needle" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { echo "out of order: $needle" >&2; return 1; }
    previous="$line"
  done
}

# Inserts line `$3` after the first line of file `$1` starting with `$2`,
# writing the result to $COPY.
insert_after() {
  awk -v anchor="$2" -v added="$3" '
    { print }
    !done && index($0, anchor) == 1 { print added; done = 1 }
  ' "$1" > "$COPY"
  grep -qxF -- "$3" "$COPY"
}

# --- Command shape ---------------------------------------------------------------

# Prints each line of a fenced bash block in file `$1` that a worktree session
# refuses: a command substitution, a backtick, a heredoc, or a shell variable.
# The block under Step 3's in-place heading is exempt: it runs only in the main
# checkout on a non-default branch, never inside a worktree session.
fence_violations() {
  awk -v exempt="$STEP_3_IN_PLACE" '
    !inside && /^#+ / { heading = $0; next }
    !inside && /^```bash$/ { inside = 1; next }
    inside && /^```$/ { inside = 0; next }
    inside && index(heading, exempt) != 1 {
      if (index($0, "$(") || index($0, "`") || index($0, "<<") || $0 ~ /\$[A-Za-z_{]/) print NR ": " $0
    }
  ' "$1"
}

@test "command shape: no bash block outside Step 3's in-place block substitutes, interpolates or uses a heredoc" {
  [ "$(grep -cxF '```bash' "$SKILL")" -gt 10 ]
  # The exemption covers one real block, so it widens nothing it does not name.
  block_after_heading "$SKILL" "$STEP_3_IN_PLACE" | grep -qF '$(git branch --show-current)'
  [ -z "$(fence_violations "$SKILL")" ]
  # Failing state: the old Step 11 capture reinserted as a block.
  awk -v anchor="$STEP_11" '
    { print }
    index($0, anchor) == 1 { print "```bash"; print "branch=\"$(git branch --show-current)\""; print "```" }
  ' "$SKILL" > "$COPY"
  [ -n "$(fence_violations "$COPY")" ]
  # Failing state: a shell variable in the guard block.
  insert_after "$SKILL" '. .gaia/scripts/update-state-line-lib.sh' 'cat "$HOME/.gaia/VERSION"'
  [ -n "$(fence_violations "$COPY")" ]
}

# 0 when file `$1` holds no branch-moving or worktree-adding git command.
no_branch_moves() {
  grep -qE 'git checkout -b|git switch|git worktree add' "$1" && return 1
  return 0
}

@test "no git checkout -b, git switch or git worktree add anywhere in SKILL.md" {
  no_branch_moves "$SKILL"
  insert_after "$SKILL" "$STEP_4_WORKTREE" 'git switch x'
  no_branch_moves "$COPY" && return 1
  true
}

# --- Pre-flight guard --------------------------------------------------------------

# 0 when SKILL.md copy `$1` sources the state-line library, defines no state
# line inline, and admits its own update/ worktree.
guard_holds() {
  local block
  block="$(block_after_heading "$1" '## Pre-flight: Worktree check')"
  printf '%s\n' "$block" | grep -qxF '. .gaia/scripts/main-only-lib.sh' || return 1
  printf '%s\n' "$block" | grep -qxF '. .gaia/scripts/update-state-line-lib.sh' || return 1
  printf '%s\n' "$block" | grep -qF 'gaia_update_gaia_state_line()' && return 1
  printf '%s\n' "$block" | grep -qxF 'gaia_refuse_if_worktree "/update-gaia" gaia_update_gaia_state_line "update/" || exit 1' || return 1
  return 0
}

@test "guard: the fence sources the state-line library, defines nothing inline, and passes update/" {
  guard_holds "$SKILL"
  grep -vxF '. .gaia/scripts/update-state-line-lib.sh' "$SKILL" > "$COPY"
  guard_holds "$COPY" && return 1
  insert_after "$SKILL" '. .gaia/scripts/main-only-lib.sh' 'gaia_update_gaia_state_line() {'
  guard_holds "$COPY" && return 1
  sed 's|gaia_update_gaia_state_line "update/" |gaia_update_gaia_state_line |' "$SKILL" > "$COPY"
  guard_holds "$COPY" && return 1
  true
}

# --- Step 3: classify by the branch's own state ----------------------------------

# The arm line of section text `$1` for outcome `$2`.
arm_line() {
  printf '%s\n' "$1" | grep -E '^- \*\*`'"$2"'[` ]'
}

# 0 when SKILL.md copy `$1` keeps the default-branch classification.
default_arm_holds() {
  local section outcome arm
  section="$(section_of "$1" "$STEP_3_DEFAULT")"
  printf '%s\n' "$section" | grep -qxF 'bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST>' || return 1
  for outcome in NONE RESUME_IN_WORKTREE RESUME_ADD_WORKTREE APPLIED_UNCOMMITTED COMMITTED; do
    [ -n "$(arm_line "$section" "$outcome")" ] || { echo "no arm: $outcome" >&2; return 1; }
  done
  for outcome in APPLIED_UNCOMMITTED COMMITTED; do
    arm="$(arm_line "$section" "$outcome")"
    printf '%s\n' "$arm" | grep -qF 'Exit' || return 1
    printf '%s\n' "$arm" | grep -qF 'Step 3b' && return 1
  done
  arm="$(arm_line "$section" COMMITTED)"
  printf '%s\n' "$arm" | grep -qF 'gh pr list --head <branch> --state all --json number,state,url' || return 1
  printf '%s\n' "$arm" | grep -qF "the PR's state" || return 1
  printf '%s\n' "$arm" | grep -qF 'the worktree path' || return 1
  printf '%s\n' "$arm" | grep -qF 'the removal commands' || return 1
  return 0
}

@test "Step 3, default branch: classify names all five outcomes and the applied and committed arms exit" {
  default_arm_holds "$SKILL"
  sed 's|inside it to open the PR. Exit. Never resume|inside it to open the PR. Continue to Step 3b. Never resume|' "$SKILL" > "$COPY"
  default_arm_holds "$COPY" && return 1
  sed 's|and the removal commands from the worktree notice|and nothing else|' "$SKILL" > "$COPY"
  default_arm_holds "$COPY" && return 1
  sed 's|`gh pr list --head <branch> --state all --json number,state,url`|the PR|' "$SKILL" > "$COPY"
  default_arm_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` routes a worktree run in place by its classification.
worktree_arm_holds() {
  local section
  section="$(section_of "$1" "$STEP_3_WORKTREE")"
  section_of "$1" "$STEP_3" | grep -qF 'In mode 1, run `### Step 3, worktree run in place` first' || return 1
  printf '%s\n' "$section" | grep -qF 'must start `update/<LATEST_TAG>-`; otherwise stop' || return 1
  printf '%s\n' "$section" | grep -qxF 'bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST> --branch <current branch>' || return 1
  arm_line "$section" RESUME_IN_WORKTREE | grep -qF 'Step 3b' || return 1
  arm_line "$section" APPLIED_UNCOMMITTED | grep -qF "Step 10's hand-off" || return 1
  arm_line "$section" APPLIED_UNCOMMITTED | grep -qF 'Step 3b' && return 1
  arm_line "$section" COMMITTED | grep -qF 'Step 11' || return 1
  return 0
}

@test "Step 3, worktree run in place: applied goes to Step 10, committed to Step 11, an older release stops" {
  worktree_arm_holds "$SKILL"
  sed "s|Go straight to Step 10's hand-off|Continue to Step 3b|" "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  sed 's|must start `update/<LATEST_TAG>-`; otherwise stop|may be any update branch|' "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  sed 's|- \*\*`COMMITTED`\*\*: go straight to Step 11|- **`COMMITTED`**: continue|' "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  true
}

# --- Step 3, in place: the interrupted run's update branch -------------------------

# A fixture git repository on main with one commit.
make_repository() {
  REPOSITORY="$BATS_TEST_TMPDIR/repository"
  rm -rf "$REPOSITORY"
  mkdir -p "$REPOSITORY"
  git -C "$REPOSITORY" init -q -b main
  git -C "$REPOSITORY" config user.email fixture@example.com
  git -C "$REPOSITORY" config user.name fixture
  git -C "$REPOSITORY" commit -q --allow-empty -m base
}

# Creates branch `$1` at a new commit dated `$2`.
branch_at_date() {
  git -C "$REPOSITORY" checkout -q -b "$1" main
  GIT_COMMITTER_DATE="$2" GIT_AUTHOR_DATE="$2" git -C "$REPOSITORY" commit -q --allow-empty -m "$1"
  git -C "$REPOSITORY" checkout -q main
}

@test "Step 3, in place: an interrupted run's update branch is found by its prefix" {
  make_repository
  git -C "$REPOSITORY" branch update/v2.1.0-2020-01-01-0000
  block="$(block_after_heading "$SKILL" "$STEP_3_IN_PLACE")"
  [ -n "$block" ]
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'RESUME update/v2.1.0-2020-01-01-0000'
  printf '%s\n' "$output" | grep -qxF 'RESUME_UPDATE=true'
}

@test "Step 3, in place: a branch for another tag is not a resume" {
  make_repository
  git -C "$REPOSITORY" branch update/v2.0.9-2020-01-01-0000
  block="$(block_after_heading "$SKILL" "$STEP_3_IN_PLACE")"
  [ -n "$block" ]
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF RESUME_UPDATE=false
  printf '%s\n' "$output" | grep -qE '^RESUME ' && return 1
  true
}

@test "Step 3, in place: with two matching branches the more recently committed one wins" {
  make_repository
  branch_at_date update/v2.1.0-2020-06-01-0000 '2021-01-01T00:00:00Z'
  branch_at_date update/v2.1.0-2020-01-01-0000 '2022-01-01T00:00:00Z'
  block="$(block_after_heading "$SKILL" "$STEP_3_IN_PLACE")"
  [ -n "$block" ]
  run_block_in "$REPOSITORY" "$block" LATEST_TAG=v2.1.0
  printf '%s\n' "$output" | grep -qxF 'RESUME update/v2.1.0-2020-01-01-0000'
}

# --- Step 4, on Proceed: the update worktree ---------------------------------------

# 0 when SKILL.md copy `$1` creates, re-enters or adds the update worktree in
# the documented order, and moves no branch in the main checkout.
worktree_subsection_holds() {
  local section
  section="$(section_file "$1" "$STEP_4_WORKTREE")" || return 1
  grep -qF 'Only when `SHOULD_CREATE_WORKTREE=true`' "$section" || return 1
  in_order "$section" 'bash .gaia/scripts/branch-name-lib.sh name update <LATEST_TAG>' "$CREATE_CALL" '`## Worktree creation`' || return 1
  grep -F '(`RESUME_IN_WORKTREE`)' "$section" | grep -qF '`### Resume`' || return 1
  in_order "$section" '(`RESUME_ADD_WORKTREE`)' 'bash .gaia/scripts/update-gaia-branch-state.sh add-worktree --branch <branch>' 'EnterWorktree({path: "<worktree path>"})' || return 1
  grep -F 'It prints `ADDED <absolute path>`' "$section" | grep -qF '`<main checkout path>/.gaia-backup/` holds that run'"'"'s backups and leave it in place' || return 1
  grep -qE 'git checkout|git switch' "$section" && return 1
  return 0
}

@test "Step 4: a fresh run mints, creates and renames; a resume re-enters or adds a worktree" {
  worktree_subsection_holds "$SKILL"
  grep -vF 'branch-name-lib.sh name update' "$SKILL" > "$COPY"
  worktree_subsection_holds "$COPY" && return 1
  insert_after "$SKILL" "$STEP_4_WORKTREE" 'git switch x'
  worktree_subsection_holds "$COPY" && return 1
  insert_after "$SKILL" "$STEP_4_WORKTREE" 'git checkout -b x'
  worktree_subsection_holds "$COPY" && return 1
  sed 's|and enter it with `EnterWorktree({path: "<worktree path>"})`|and enter it|' "$SKILL" > "$COPY"
  worktree_subsection_holds "$COPY" && return 1
  sed 's|`<main checkout path>/.gaia-backup/` holds|the backups hold|' "$SKILL" > "$COPY"
  worktree_subsection_holds "$COPY" && return 1
  sed 's|per `isolation.md` `### Resume`|by checking it out|' "$SKILL" > "$COPY"
  worktree_subsection_holds "$COPY" && return 1
  true
}

NOTICE_TEXT='Update worktree: <worktree path>
Branch: <branch>
To discard it, run from the main checkout (<main checkout path>):
  git worktree remove --force <worktree path>
  git branch -D <branch>
Warning: --force discards any uncommitted changes in the worktree.'

# 0 when SKILL.md copy `$1` prints the worktree notice after creation, names it
# in the stop rule, and prints it again after the draft PR opens.
notice_holds() {
  local section step_11 notice
  section="$(section_file "$1" "$STEP_4_WORKTREE")" || return 1
  notice="$(awk '/^```text$/ { inside = 1; next } inside && /^```$/ { exit } inside { print }' "$section")"
  [ "$notice" = "$NOTICE_TEXT" ] || return 1
  in_order "$section" "$CREATE_CALL" '**The worktree notice.**' 'Warning: --force discards' || return 1
  grep -F '**The stop rule.**' "$section" | grep -qF 'prints the worktree notice again' || return 1
  step_11="$(section_file "$1" "$STEP_11")" || return 1
  in_order "$step_11" 'gh pr create --draft' 'print the worktree notice' || return 1
  return 0
}

@test "the worktree notice: verbatim after creation, named by the stop rule and after the PR opens" {
  notice_holds "$SKILL"
  grep -vxF 'Warning: --force discards any uncommitted changes in the worktree.' "$SKILL" > "$COPY"
  notice_holds "$COPY" && return 1
  grep -vF '6. On a worktree run, print the worktree notice' "$SKILL" > "$COPY"
  notice_holds "$COPY" && return 1
  sed 's|and prints the worktree notice again|and says nothing|' "$SKILL" > "$COPY"
  notice_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` checks the fresh worktree's baseline after creation
# and skips the check on a resume.
baseline_check_holds() {
  local section line
  section="$(section_file "$1" "$STEP_4_WORKTREE")" || return 1
  in_order "$section" "$CREATE_CALL" '**Baseline check.**' || return 1
  line="$(grep -F '**Baseline check.**' "$section")"
  printf '%s\n' "$line" | grep -qF 'run `cat .gaia/VERSION` in the worktree' || return 1
  printf '%s\n' "$line" | grep -qF 'does not print `<BASELINE>`' || return 1
  printf '%s\n' "$line" | grep -qF 'Skip it on a resume' || return 1
  return 0
}

@test "Step 4: the baseline check follows creation and is skipped on a resume" {
  baseline_check_holds "$SKILL"
  grep -vF '**Baseline check.**' "$SKILL" > "$COPY"
  baseline_check_holds "$COPY" && return 1
  sed 's|Skip it on a resume: classification|Run it on a resume too: classification|' "$SKILL" > "$COPY"
  baseline_check_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` waits for provisioning after creation and before
# the Step 4b prune, stopping on a failed install only in a tree it created.
provisioning_wait_holds() {
  local section heading wait prune
  section="$(section_file "$1" "$STEP_4_WORKTREE")" || return 1
  in_order "$section" "$CREATE_CALL" "$WAIT_CALL" || return 1
  grep -qF '`INSTALL_FAILED` stops when `CREATED_WORKTREE=true`' "$section" || return 1
  heading="$(first_line "$1" "$STEP_4_WORKTREE")"
  wait="$(grep -nxF -- "$WAIT_CALL" "$1" | awk -F: -v after="$heading" '$1 > after { print $1; exit }')"
  prune="$(first_line "$1" "$PRUNE_CALL")"
  [ -n "$heading" ] && [ -n "$wait" ] && [ -n "$prune" ] || return 1
  [ "$wait" -lt "$prune" ] || return 1
  return 0
}

@test "Step 4: the provisioning wait follows creation and precedes the Step 4b prune" {
  provisioning_wait_holds "$SKILL"
  grep -vxF -- "$WAIT_CALL" "$SKILL" > "$COPY"
  provisioning_wait_holds "$COPY" && return 1
  sed 's|`INSTALL_FAILED` stops when `CREATED_WORKTREE=true`|`INSTALL_FAILED` stops|' "$SKILL" > "$COPY"
  provisioning_wait_holds "$COPY" && return 1
  true
}

# --- Step 10: the hand-off --------------------------------------------------------

# 0 when SKILL.md copy `$1` waits before any pnpm step of the hand-off and
# names the log path and the worktree in every step.
step_10_holds() {
  local section wait pnpm
  section="$(section_file "$1" "$STEP_10")" || return 1
  wait="$(grep -nxF -- "$WAIT_CALL" "$section" | head -n 1 | cut -d: -f1)"
  pnpm="$(grep -n 'pnpm' "$section" | head -n 1 | cut -d: -f1)"
  [ -n "$wait" ] && [ -n "$pnpm" ] || return 1
  [ "$wait" -lt "$pnpm" ] || return 1
  in_order "$section" "$WAIT_CALL" '1. Review any conflict patches' || return 1
  grep -qF '`INSTALL_FAILED` stops only when `CREATED_WORKTREE=true`' "$section" || return 1
  grep -qF 'naming the provisioning `Log:` path' "$section" || return 1
  grep -qF '`<worktree path>/.gaia-merge/`' "$section" || return 1
  grep -qF '`pnpm -C <worktree path> install`' "$section" || return 1
  grep -qF '`pnpm -C <worktree path> dedupe`' "$section" || return 1
  grep -qF '`git -C <worktree path> diff`' "$section" || return 1
  return 0
}

@test "Step 10: the wait precedes every pnpm step and the hand-off names the log and the worktree" {
  step_10_holds "$SKILL"
  insert_after "$SKILL" "$STEP_10" 'Run `pnpm install` first.'
  step_10_holds "$COPY" && return 1
  sed 's|naming the provisioning `Log:` path|naming nothing|' "$SKILL" > "$COPY"
  step_10_holds "$COPY" && return 1
  sed 's|`git -C <worktree path> diff`|`git diff`|' "$SKILL" > "$COPY"
  step_10_holds "$COPY" && return 1
  true
}

# --- Step 11: the draft PR ----------------------------------------------------------

# 0 when SKILL.md copy `$1` opens the PR with plain commands, verifying the
# commit is on the update branch before the push.
step_11_holds() {
  local section
  section="$(section_file "$1" "$STEP_11")" || return 1
  grep -qF '$(' "$section" && return 1
  # A repository whose default branch is master has no origin/main to fetch,
  # count against, or open a pull request into.
  grep -qE 'origin main|origin/main\.\.|--base main' "$section" && return 1
  in_order "$section" \
    'git -C <acting tree> symbolic-ref --quiet --short refs/remotes/origin/HEAD' \
    'git -C <acting tree> fetch origin <default branch>' \
    'git -C <acting tree> rev-list --count origin/<default branch>..<branch>' \
    'git -C <acting tree> show <branch>:.gaia/VERSION' \
    'git -C <acting tree> push -u origin <branch>' \
    'gh pr create --draft --base <default branch> --head <branch>' || return 1
  grep -qF 'git -C <acting tree> branch -r --list origin/main origin/master' "$section" || return 1
  # An open PR is reused, never duplicated.
  grep -F 'gh pr create --draft' "$section" | grep -qF 'gh pr list --head <branch> --state open' || return 1
  return 0
}

@test "Step 11: plain commands fetch, count, verify the version on the branch, then push and open" {
  step_11_holds "$SKILL"
  insert_after "$SKILL" "$STEP_11" 'branch="$(git branch --show-current)"'
  step_11_holds "$COPY" && return 1
  # The push moved ahead of the version check.
  awk '
    /^3\. `git -C <acting tree> show / { held = $0; next }
    { print }
    /^4\. `git -C <acting tree> push / && held != "" { print held }
  ' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  grep -vF 'fetch origin <default branch>' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  # The literal main a master-default repository cannot use.
  sed 's|--base <default branch>|--base main|' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  grep -vF 'symbolic-ref --quiet --short refs/remotes/origin/HEAD' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  true
}

# --- Step 9d: the cache bust and the manifest copy -------------------------------

BUST_CALL='bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode gaia --version <LATEST>'

# 0 when SKILL.md copy `$1` busts the cache through the script at the main
# checkout's path, reads it back, cites the contract, and uses no Write tool.
bust_holds() {
  local section
  section="$(section_file "$1" "$STEP_9D")" || return 1
  grep -qxF -- "$BUST_CALL" "$section" || return 1
  in_order "$section" "$BUST_CALL" 'Then read the file back' || return 1
  grep -qF '`.claude/skills/gaia/references/spec.md`, `## Operational primitives`' "$section" || return 1
  grep -qF 'Write tool' "$section" && return 1
  return 0
}

@test "Step 9d: the bust runs the script at the main checkout's cache path and reads it back" {
  bust_holds "$SKILL"
  insert_after "$SKILL" "$STEP_9D" 'Use the Write tool to overwrite `.gaia/local/cache/shared/update-check.json`.'
  bust_holds "$COPY" && return 1
  sed 's|Then read the file back|Then|' "$SKILL" > "$COPY"
  bust_holds "$COPY" && return 1
  grep -vxF -- "$BUST_CALL" "$SKILL" > "$COPY"
  bust_holds "$COPY" && return 1
  true
}

MANIFEST_STOP='A non-zero exit from the `cp` command is the `MANIFEST_COPY_FAILED` stop'

@test "Step 9d prose: a failed manifest copy is the MANIFEST_COPY_FAILED stop" {
  section_of "$SKILL" "$STEP_9D" | grep -qF "$MANIFEST_STOP"
  grep -vF "$MANIFEST_STOP" "$SKILL" > "$COPY"
  section_of "$COPY" "$STEP_9D" | grep -qF 'MANIFEST_COPY_FAILED' && return 1
  true
}

# --- Step 12: the residue sweep ---------------------------------------------------

# 0 when SKILL.md copy `$1` runs no sweep on a worktree run, printing the
# post-merge --apply step, and keeps the ask in mode 3.
step_12_holds() {
  local section worktree_arm sweeps applies
  section="$(section_of "$1" "$STEP_12")"
  worktree_arm="$(printf '%s\n' "$section" | grep -F '**Worktree run.**')"
  printf '%s\n' "$worktree_arm" | grep -qF 'Run no residue sweep' || return 1
  printf '%s\n' "$worktree_arm" | grep -qF '`bash .gaia/scripts/state-registry-lib.sh residue-sweep --apply` from the main checkout' || return 1
  sweeps="$(printf '%s\n' "$worktree_arm" | grep -oF 'residue-sweep' | wc -l | tr -d ' ')"
  applies="$(printf '%s\n' "$worktree_arm" | grep -oF 'residue-sweep --apply' | wc -l | tr -d ' ')"
  [ "$sweeps" -eq "$applies" ] || return 1
  printf '%s\n' "$section" | grep -F '**Mode 3.**' | grep -qF 'AskUserQuestion' || return 1
  return 0
}

@test "Step 12: a worktree run runs no sweep and prints the post-merge --apply step; mode 3 asks" {
  step_12_holds "$SKILL"
  sed 's|Run no residue sweep: it refuses|Run `bash .gaia/scripts/state-registry-lib.sh residue-sweep`: it refuses|' "$SKILL" > "$COPY"
  step_12_holds "$COPY" && return 1
  grep -vF '**Mode 3.**' "$SKILL" > "$COPY"
  step_12_holds "$COPY" && return 1
  true
}

# --- Step 3d and Step 4 prose ---------------------------------------------------

# 0 when the SKILL.md copy `$1` carries the blocking-note and Proceed pins.
prose_pins_hold() {
  local step_3d step_4
  step_3d="$(section_of "$1" "$STEP_3D")"
  step_4="$(section_of "$1" "$STEP_4")"
  printf '%s\n' "$step_3d" | grep -qF "as a note to follow after the blocking note's merge step and before its version write" || return 1
  printf '%s\n' "$step_3d" | grep -qF 'ask with `AskUserQuestion` whether to follow the blocking note in this session. On yes, read the note' || return 1
  printf '%s\n' "$step_4" | grep -qF 'name each `AFTER_MERGE` note (its version and its path) as a note this run follows after the merge' || return 1
  return 0
}

@test "Step 3d and Step 4 prose: the blocking stop and the Proceed question name the after-merge notes" {
  prose_pins_hold "$SKILL"
  local pin copy
  for pin in "before its version write" 'On yes, read the note' 'as a note this run follows after the merge'; do
    copy="$BATS_TEST_TMPDIR/skill-without-pin.md"
    grep -vF -- "$pin" "$SKILL" > "$copy"
    prose_pins_hold "$copy" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  true
}

# --- Step 4 and Step 9: the CHANGELOG range reaches the execution agent -------

# The release bundle withholds CHANGELOG.md, so Step 4's fetched range is the
# only copy Step 9's adopter-action suggestions can read.

STEP_9_ACTIONS='**Documented adopter actions (opt-in).**'

# Block text on stdin with the skill's typed-literal placeholders filled.
fill_placeholders() {
  sed -e 's/<BASELINE>/2.0.0/g' -e 's/<LATEST_TAG>/v2.1.0/g' -e 's/<LATEST>/2.1.0/g'
}

# A project holding the preflight script and the range walk, a verified-cache
# directory for v2.1.0, and stub curl and gh executables. The stub curl prints
# $CURL_FIXTURE, or fails when it is unset; the stub gh always fails.
step_4_setup() {
  PROJECT="$BATS_TEST_TMPDIR/project"
  CACHE="$PROJECT/.gaia/local/cache/shared/update-gaia"
  mkdir -p "$PROJECT/.gaia/scripts/lib" "$CACHE/v2.1.0/tree" "$BATS_TEST_TMPDIR/bin"
  cp "$PREFLIGHT" "$REPO_ROOT/.gaia/scripts/changelog-range.sh" "$PROJECT/.gaia/scripts/"
  cp "$COMPARE_LIB" "$PROJECT/.gaia/scripts/lib/"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FIXTURE:-}" ] || exit 22
cat "$CURL_FIXTURE"
STUB
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/gh"
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '## [2.1.0]' '' '### Removed' '' '- dropped `pnpm remove left-pad`' '' '## [2.0.0]' '' '- base' > "$BATS_TEST_TMPDIR/CHANGELOG.md"
  BLOCK_4="$(block_after_heading "$SKILL" "$STEP_4" | fill_placeholders)"
  printf '%s\n' "$BLOCK_4" | grep -qxF 'bash .gaia/scripts/update-gaia-preflight.sh changelog --baseline 2.0.0 --latest 2.1.0 --latest-tag v2.1.0'
}

run_step_4() {
  run_block_in "$PROJECT" "$BLOCK_4" PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$@"
}

run_step_9_actions() {
  local block
  block="$(block_after_heading "$MERGE_EXECUTION" "$STEP_9_ACTIONS")"
  [ -n "$block" ] || return 1
  run_block_in "$PROJECT" "$block" LATEST_DIR=.gaia/local/cache/shared/update-gaia/v2.1.0/tree BASELINE=2.0.0 LATEST=2.1.0
}

@test "Step 9: adopter actions read the range Step 4 saved, never a CHANGELOG inside the bundle" {
  step_4_setup
  run_step_4 CURL_FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run_step_9_actions
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF -- '- dropped `pnpm remove left-pad`'
  section_of "$MERGE_EXECUTION" '### Step 9: Summary' | grep -qF 'LATEST_DIR/CHANGELOG.md' && return 1
  true
}

@test "Step 9: a missing saved range is announced, not read as an empty range" {
  step_4_setup
  run_step_9_actions
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGELOG_RANGE_UNAVAILABLE'
}

# --- Step 9c prose ----------------------------------------------------------------

STEP_9C='## Step 9c: Carry new setup features'

# 0 when SKILL.md copy `$1` states that a failed apply records nothing and
# that the summary names every drift outcome by id.
drift_prose_holds() {
  section_of "$1" "$STEP_9C" | grep -qF 'A failed apply records nothing' || return 1
  section_of "$1" "$STEP_9D" |
    grep -qF 'the setup features applied, asked (with the answer), owed by an admin, failed, and handed to `/setup-gaia`, each by id' || return 1
  return 0
}

@test "Step 9c prose: a failed apply records nothing, and the summary names every outcome" {
  drift_prose_holds "$SKILL"
  local copy="$BATS_TEST_TMPDIR/skill-drift-prose.md" pin
  for pin in 'A failed apply records nothing' 'owed by an admin, failed, and handed to'; do
    grep -vF -- "$pin" "$SKILL" > "$copy"
    drift_prose_holds "$copy" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  true
}

# --- Prose order --------------------------------------------------------------

SELECTOR_CALL='bash .gaia/scripts/update-gaia-preflight.sh select-notes --latest-dir <LATEST_DIR>'
PROCEED_QUESTION='"Update GAIA from v$BASELINE to $LATEST_TAG?"'

# 0 when SKILL.md copy `$1` keeps the orchestrator order.
skill_order_holds() {
  local file="$1" anchor
  for anchor in 'EnterWorktree(' 'bash .gaia/scripts/update-gaia-preflight.sh prune' '## Model selection'; do
    in_order "$file" "$SELECTOR_CALL" "$PROCEED_QUESTION" "$anchor" || return 1
  done
  in_order "$file" '## Step 9b' 'update-gaia-drift.sh --features' 'GAIA_MANIFEST_WRITE=release cp <LATEST_DIR>' 'ping --event update' 'echo <LATEST> > .gaia/VERSION' || return 1
  in_order "$file" '## Step 9d' '### Step 12' || return 1
  section_of "$file" '## Step 11 (orchestrator' | sed -n 3p | grep -qF "The execution agent's work ends at Step 9," || return 1
  return 0
}

# 0 when merge-execution.md copy `$1` holds none of the orchestrator's writes.
merge_execution_is_merge_only() {
  grep -qF 'gh release download' "$1" && return 1
  grep -qE '>[[:space:]]*\.gaia/VERSION' "$1" && return 1
  grep -qF 'GAIA_MANIFEST_WRITE=release cp' "$1" && return 1
  grep -qF 'ping --event update' "$1" && return 1
  return 0
}

@test "prose order: SKILL.md verifies and selects before Proceed, and writes the version last" {
  skill_order_holds "$SKILL"
}

@test "prose order: a reordered SKILL.md copy is reported" {
  # The version write moved ahead of the ping.
  awk '
    /^\.gaia\/cli\/gaia ping --event update/ { held = $0; next }
    { print }
    /^echo <LATEST> > \.gaia\/VERSION$/ && held != "" { print held }
  ' "$SKILL" > "$COPY"
  [ "$(first_line "$COPY" 'ping --event update')" -gt "$(first_line "$COPY" 'echo <LATEST> > .gaia/VERSION')" ]
  skill_order_holds "$COPY" && return 1
  # A worktree created before the Proceed question.
  insert_after "$SKILL" '## Step 3b: Refuse a 1.x baseline' 'EnterWorktree({name: "early"})'
  skill_order_holds "$COPY" && return 1
  # Step 11 claiming the executor runs through Step 10.
  sed "s/The execution agent's work ends at Step 9,/The execution agent's work ends at Step 10,/" "$SKILL" > "$COPY"
  skill_order_holds "$COPY" && return 1
  true
}

@test "prose order: merge-execution.md downloads nothing and writes no version, manifest or ping" {
  merge_execution_is_merge_only "$MERGE_EXECUTION"
  local copy="$BATS_TEST_TMPDIR/merge-execution-readded.md" line
  for line in 'gh release download "$tag" --repo gaia-react/gaia' 'echo "$LATEST" > .gaia/VERSION' \
    'GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json' \
    '.gaia/cli/gaia ping --event update --from "$BASELINE" --to "$LATEST" || true'; do
    { cat "$MERGE_EXECUTION"; printf '%s\n' "$line"; } > "$copy"
    merge_execution_is_merge_only "$copy" && { echo "not reported: $line" >&2; return 1; }
  done
  true
}

# --- Bundle-root pin ------------------------------------------------------------

# Prints every line of the given files naming .gaia/migrations/ other than
# through the target bundle (`<LATEST_DIR>/` in SKILL.md, `$LATEST_DIR/` in
# merge-execution.md, `$latest_dir/` in the preflight script) or the refusal's
# bundled note path.
bare_migration_paths() {
  sed -e 's|<LATEST_DIR>/\.gaia/migrations/||g' \
    -e 's|\$LATEST_DIR/\.gaia/migrations/||g' \
    -e 's|\$latest_dir/\.gaia/migrations/||g' \
    -e 's|\.gaia/local/cache/shared/migrate-2/v2\.0\.0/tree/\.gaia/migrations/2\.0\.0\.md||g' "$@" |
    grep -F '.gaia/migrations/' || true
}

# Prints every line of file `$1` naming the selector that is not the preflight
# script's call of the target bundle's selector with the target bundle as its
# root. SKILL.md names the selector nowhere: its select-notes call runs it.
stray_selector_calls() {
  grep -F 'select-migration-notes.sh' "$1" |
    grep -vF 'bash "$latest_dir/.gaia/scripts/select-migration-notes.sh" "$latest_dir" ' || true
}

@test "bundle root: notes are selected and read only from the verified target bundle" {
  [ "$(grep -cF "$SELECTOR_CALL" "$SKILL")" -ge 1 ]
  [ "$(grep -cF 'bash "$latest_dir/.gaia/scripts/select-migration-notes.sh" "$latest_dir" ' "$PREFLIGHT")" -eq 1 ]
  [ -z "$(stray_selector_calls "$SKILL")" ]
  [ -z "$(stray_selector_calls "$PREFLIGHT")" ]
  [ -z "$(bare_migration_paths "$SKILL" "$MERGE_EXECUTION" "$PREFLIGHT")" ]
  local copy="$BATS_TEST_TMPDIR/skill-bare.md"
  { cat "$SKILL"; printf '%s\n' 'cat .gaia/migrations/2.1.0.md'; } > "$copy"
  [ -n "$(bare_migration_paths "$copy")" ]
  { cat "$PREFLIGHT"; printf '%s\n' 'cat .gaia/migrations/2.1.0.md'; } > "$copy"
  [ -n "$(bare_migration_paths "$copy")" ]
  { cat "$SKILL"; printf '%s\n' 'bash .gaia/scripts/select-migration-notes.sh . <BASELINE> <LATEST>'; } > "$copy"
  [ -n "$(stray_selector_calls "$copy")" ]
  { cat "$PREFLIGHT"; printf '%s\n' 'selection="$(bash .gaia/scripts/select-migration-notes.sh . "$baseline" "$latest")"'; } > "$copy"
  [ -n "$(stray_selector_calls "$copy")" ]
}

# --- Every tracked note is well-formed -------------------------------------------

@test "every tracked migration note is well-formed and listed by the selector" {
  local root="$BATS_TEST_TMPDIR/tracked" relative tracked_count
  mkdir -p "$root/.gaia/migrations"
  tracked_count=0
  while IFS= read -r -d '' relative; do
    [ -n "$relative" ] || continue
    cp "$REPO_ROOT/$relative" "$root/$relative"
    tracked_count=$((tracked_count + 1))
  done < <(git -C "$REPO_ROOT" ls-files -z .gaia/migrations)
  [ "$tracked_count" -gt 0 ]
  run bash "$SELECTOR" "$root" 0.0.0 999.999.999
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq "$tracked_count" ]
  for relative in "$root"/.gaia/migrations/*; do
    printf '%s\n' "$output" | grep -qF -- "$relative" || return 1
  done
  # Failing state: one note's frontmatter broken.
  first_note="$(ls "$root"/.gaia/migrations/* | head -n 1)"
  sed '2s/.*/mode: sometimes/' "$first_note" > "$first_note.tmp"
  mv "$first_note.tmp" "$first_note"
  run bash "$SELECTOR" "$root" 0.0.0 999.999.999
  [ "$status" -eq 1 ]
}

# --- No migrate URL anywhere ----------------------------------------------------

# The URL-absence token, assembled so this suite never matches itself.
migrate_url_token() {
  printf '%s/%s' gaiareact.com migrate
}

@test "no tracked file names the migrate URL, and a planted one is reported" {
  run git -C "$REPO_ROOT" grep -n -F -- "$(migrate_url_token)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  local planted="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$planted"
  git -C "$planted" init -q
  printf 'see https://%s\n' "$(migrate_url_token)" > "$planted/page.md"
  git -C "$planted" add page.md
  run git -C "$planted" grep -n -F -- "$(migrate_url_token)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'page.md:1:'
}
