#!/usr/bin/env bats
# The /update-gaia orchestrator as SKILL.md writes it: the guard fence and its
# own-worktree prefix, every command block in the shape a worktree session
# admits, the run modes' classification of an earlier run's update branch
# (Step 3), the decision log check before any download, the update worktree on
# Proceed (Step 4), the provisioning waits, the dispatch, classify and
# validate order around the merge report, the questions, answers and decision
# records, the follow-ups, the version written last (Step 9d), the quality
# gate, the single commit confirm at the review point, the draft PR (Step 11)
# and the leftover-file cleanup deferred to the post-merge cleanup (Step 12). The pre-merge blocks live in
# .gaia/scripts/update-gaia-preflight.sh and the drift block in
# update-gaia-drift.sh; their behavior is driven by update-gaia-preflight.bats
# and update-gaia-drift.bats, so this suite pins the skill's calls and prose.
# Every pin has a red twin: a fixture copy
# carrying the forbidden content, or missing or reordering the required
# content.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md"
  CONFLICT_FLOW="$REPO_ROOT/.claude/skills/update-gaia/references/conflict-flow.md"
  CLAIM_REF="$REPO_ROOT/.claude/skills/update-gaia/references/claim-flow.md"
  PULL_REF="$REPO_ROOT/.claude/skills/update-gaia/references/pull-mode.md"
  LIFECYCLE="$REPO_ROOT/.claude/skills/gaia/references/work-lifecycle.md"
  GATE_REF="$REPO_ROOT/.claude/skills/update-gaia/references/pull-gate.md"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
  SELECTOR="$REPO_ROOT/.gaia/scripts/select-migration-notes.sh"
  COPY="$BATS_TEST_TMPDIR/skill-copy.md"
}

STEP_3='## Step 3: Compare versions'
STEP_3_DEFAULT='### Step 3, main checkout: classify the update branch'
STEP_3_WORKTREE='### Step 3, worktree run in place'
STEP_3D='## Step 3d: Select migration notes'
STEP_4='## Step 4: Show the release notes and confirm'
STEP_4_WORKTREE='### Step 4, on Proceed: the update worktree'
STEP_9D='## Step 9d: Record the update'
STEP_CONFLICT_FLOW='## Conflict flow: dispatch, questions, decisions, follow-ups'
STEP_REVIEW='## Review point'
STEP_11='### Step 11: Open a pull request'
STEP_12='### Step 12: The leftover-file cleanup'
LIFECYCLE_LEFTOVERS='### Leftover-file cleanup after an update merge'

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
fence_violations() {
  awk '
    !inside && /^```bash$/ { inside = 1; next }
    inside && /^```$/ { inside = 0; next }
    inside {
      if (index($0, "$(") || index($0, "`") || index($0, "<<") || $0 ~ /\$[A-Za-z_{]/) print NR ": " $0
    }
  ' "$1"
}

@test "command shape: no bash block substitutes, interpolates or uses a heredoc" {
  [ "$(grep -cxF '```bash' "$SKILL")" -gt 10 ]
  [ -z "$(fence_violations "$SKILL")" ]
  [ -z "$(fence_violations "$CONFLICT_FLOW")" ]
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

# 0 when SKILL.md copy `$1` keeps the main-checkout classification.
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
    printf '%s\n' "$arm" | grep -qF 'decision log check' && return 1
  done
  for outcome in RESUME_IN_WORKTREE RESUME_ADD_WORKTREE; do
    arm_line "$section" "$outcome" | grep -qF 'Continue to the decision log check' || return 1
  done
  arm_line "$section" NONE | grep -qF 'Continue to the pull check' || return 1
  arm="$(arm_line "$section" COMMITTED)"
  printf '%s\n' "$arm" | grep -qF 'gh pr list --head <branch> --state all --json number,state,url' || return 1
  printf '%s\n' "$arm" | grep -qF "the PR's state" || return 1
  printf '%s\n' "$arm" | grep -qF 'the worktree path' || return 1
  printf '%s\n' "$arm" | grep -qF 'the removal commands' || return 1
  return 0
}

@test "Step 3, main checkout: classify names all five outcomes and the applied and committed arms exit" {
  default_arm_holds "$SKILL"
  sed 's|then opens the PR. Exit. Never resume|then opens the PR. Continue to Step 3b. Never resume|' "$SKILL" > "$COPY"
  default_arm_holds "$COPY" && return 1
  # Failing state: a fresh run skipping the pull check.
  sed 's|a fresh run. Continue to the pull check.|a fresh run. Continue to Step 3b.|' "$SKILL" > "$COPY"
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
  arm_line "$section" RESUME_IN_WORKTREE | grep -qF 'decision log check' || return 1
  arm_line "$section" APPLIED_UNCOMMITTED | grep -qF 'Go straight to `## Quality gate`, then `## Review point`' || return 1
  arm_line "$section" APPLIED_UNCOMMITTED | grep -qF 'decision log check' && return 1
  arm_line "$section" COMMITTED | grep -qF 'Step 11' || return 1
  return 0
}

@test "Step 3, worktree run in place: applied goes to the quality gate, committed to Step 11, an older release stops" {
  worktree_arm_holds "$SKILL"
  sed 's|Go straight to `## Quality gate`, then `## Review point`|Continue to the decision log check|' "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  sed 's|must start `update/<LATEST_TAG>-`; otherwise stop|may be any update branch|' "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  sed 's|- \*\*`COMMITTED`\*\*: go straight to Step 11|- **`COMMITTED`**: continue|' "$SKILL" > "$COPY"
  worktree_arm_holds "$COPY" && return 1
  true
}

# --- Branch check: any branch in the main checkout takes the worktree ----------

MAIN_CHECKOUT_MODE='2. **Main checkout.** On `main`, `master` or any other branch:'

# 0 when SKILL.md copy `$1` sends every main-checkout run, on any branch, to the
# deferred update worktree and keeps no mode that works on the current branch.
branch_check_holds() {
  local section
  section="$(section_file "$1" '## Pre-flight: Branch check')" || return 1
  grep -F -- "$MAIN_CHECKOUT_MODE" "$section" | grep -qF 'Set `SHOULD_CREATE_WORKTREE=true`' || return 1
  grep -qF 'SHOULD_CREATE_WORKTREE=false` and work on the current branch' "$section" && return 1
  grep -qE '^3\. ' "$section" && return 1
  return 0
}

@test "branch check: a run on any branch of the main checkout takes the update worktree" {
  branch_check_holds "$SKILL"
  # Failing state: the in-place mode restored.
  insert_after "$SKILL" "$MAIN_CHECKOUT_MODE" '3. **In place.** Any other branch: set `SHOULD_CREATE_WORKTREE=false` and work on the current branch, creating no branch and no worktree.'
  branch_check_holds "$COPY" && return 1
  # Failing state: the main-checkout mode narrowed back to the default branch.
  sed 's|2. \*\*Main checkout.\*\* On `main`, `master` or any other branch:|2. **Default branch.** On `main` or `master`:|' "$SKILL" > "$COPY"
  branch_check_holds "$COPY" && return 1
  true
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

# --- Review point --------------------------------------------------------------

# 0 when SKILL.md copy `$1` waits before showing the diff, shows the stat, the
# untracked files and the diff before the commit question, and names the log
# path.
review_point_holds() {
  local section
  section="$(section_file "$1" "$STEP_REVIEW")" || return 1
  in_order "$section" "$WAIT_CALL" 'git -C <acting tree> diff --stat' 'git -C <acting tree> status --short' 'Commit this update?' || return 1
  grep -qxF 'git -C <acting tree> diff' "$section" || return 1
  grep -qF '`INSTALL_FAILED` stops only when `CREATED_WORKTREE=true`' "$section" || return 1
  grep -qF 'naming the provisioning `Log:` path' "$section" || return 1
  grep -qF 'every `auto-merged` file by name' "$section" || return 1
  grep -qF 'Never commit without the `Commit` answer.' "$section" || return 1
  return 0
}

@test "review point: the wait, the stat, the untracked files and the diff precede the one commit question" {
  review_point_holds "$SKILL"
  sed 's|naming the provisioning `Log:` path|naming nothing|' "$SKILL" > "$COPY"
  review_point_holds "$COPY" && return 1
  grep -vxF 'git -C <acting tree> status --short' "$SKILL" > "$COPY"
  review_point_holds "$COPY" && return 1
  sed 's|every `auto-merged` file by name|the files|' "$SKILL" > "$COPY"
  review_point_holds "$COPY" && return 1
  grep -vF 'Never commit without the `Commit` answer.' "$SKILL" > "$COPY"
  review_point_holds "$COPY" && return 1
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
    'git -C <acting tree> show <branch>:.gaia/VERSION' \
    'bash <main checkout path>/.gaia/scripts/update-claim.sh list --tree <main checkout path>' \
    'git -C <acting tree> push -u origin <branch>' \
    'gh pr create --draft --base <default branch> --head <branch>' || return 1
  # The claim commit defeats a commits-ahead count, so the VERSION check alone
  # proves the update commit is on the branch.
  grep -qF 'rev-list --count' "$section" && return 1
  grep -qF 'git -C <acting tree> show-ref --verify --quiet refs/remotes/origin/main' "$section" || return 1
  grep -qF 'git -C <acting tree> show-ref --verify --quiet refs/remotes/origin/master' "$section" || return 1
  # An open PR is reused, never duplicated.
  grep -F 'gh pr create --draft' "$section" | grep -qF 'gh pr list --head <branch> --state open' || return 1
  return 0
}

@test "Step 11: plain commands fetch, verify the version on the branch, re-list the claims, then push and open" {
  step_11_holds "$SKILL"
  insert_after "$SKILL" "$STEP_11" 'branch="$(git branch --show-current)"'
  step_11_holds "$COPY" && return 1
  # The push moved ahead of the version check.
  awk '
    /^2\. `git -C <acting tree> show / { held = $0; next }
    { print }
    /^4\. `git -C <acting tree> push / && held != "" { print held }
  ' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  # The commits-ahead count is back.
  insert_after "$SKILL" "$STEP_11" 'git -C <acting tree> rev-list --count origin/<default branch>..<branch>'
  step_11_holds "$COPY" && return 1
  # The re-list is gone, and the re-list moved after the push.
  grep -vF 'update-claim.sh list --tree <main checkout path>' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  awk '
    /^3\. `bash <main checkout path>\/.gaia\/scripts\/update-claim.sh list / { held = $0; next }
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
  sed 's|show-ref --verify --quiet refs/remotes/origin/master|branch -r --list origin/master|' "$SKILL" > "$COPY"
  step_11_holds "$COPY" && return 1
  true
}

# --- The team claim: SKILL.md's pointer steps and references/claim-flow.md -----------

CLAIM_CHECK='## Pre-flight: Claim check'
CLAIM_PARAGRAPH='**Claim.**'
STEP_3B='## Step 3b: Refuse a 1.x baseline'
STEP_4B='## Step 4b: Prune prior-run artifacts'
CLAIM_REF_CHECK='## Claim check'
CLAIM_REF_AFTER_PROCEED='## Claim after Proceed'
CLAIM_REF_STEP_11='## Step 11: the claim-aware pull request'
CLAIM_STOP_LINE='`GAIA <tag> is already being updated in PR #<number> by @<login>, opened <age> ago. Wait for it to merge, then run /update-gaia again.`'
CLAIM_START_CALL='bash <main checkout path>/.gaia/scripts/update-claim.sh start --tree <worktree path> --tag <LATEST_TAG> --branch <branch> --base <default branch>'
CLAIM_TIE_BREAK_CALL='bash <main checkout path>/.gaia/scripts/update-claim.sh tie-break --tree <worktree path> --own <number>'

# Writes the claim reference `$1` into $COPY_REF.
use_ref_copy() {
  COPY_REF="$BATS_TEST_TMPDIR/claim-flow-copy.md"
  cp "$1" "$COPY_REF"
}

# 0 when SKILL.md copy `$1` runs the claim check before Step 3b, the download,
# the first worktree entry and the prune, pointing at the reference; and
# reference copy `$2` reads the claims and the current login, stops on a
# teammate's claim with the pinned line before creating anything, and
# classifies an own claim by its own branch.
claim_check_holds() {
  local skill="$1" ref="$2" section
  in_order "$skill" '## Pre-flight: Decision log check' "$CLAIM_CHECK" || return 1
  exact_in_order "$skill" "$CLAIM_CHECK" "$STEP_3B" "$VERIFY_CALL" || return 1
  [ "$(first_line "$skill" "$CLAIM_CHECK")" -lt "$(first_line "$skill" 'EnterWorktree(')" ] || return 1
  [ "$(first_line "$skill" "$CLAIM_CHECK")" -lt "$(first_line "$skill" "$PRUNE_CALL")" ] || return 1
  section="$(section_file "$skill" "$CLAIM_CHECK")" || return 1
  grep -qF 'references/claim-flow.md' "$section" || return 1
  section="$(section_file "$ref" "$CLAIM_REF_CHECK")" || return 1
  grep -qF -- "$CLAIM_STOP_LINE" "$section" || return 1
  grep -qF 'leaves no download, worktree, prune or cache change and no other branch change' "$section" || return 1
  in_order "$section" \
    'update-claim.sh list --tree <starting checkout>' \
    'update-claim.sh login --tree <starting checkout>' \
    'Warning: team claim skipped (<reason>).' \
    "$CLAIM_STOP_LINE" || return 1
  grep -F 'update-gaia-branch-state.sh classify' "$section" | grep -qF -- '--branch <headRefName>' || return 1
  grep -qF 'update-claim.sh close-own --tree <starting checkout> --number <number> --branch <headRefName>' "$section" || return 1
  return 0
}

@test "claim check: it precedes Step 3b and every download and worktree, and a teammate's claim stops with the pinned line" {
  claim_check_holds "$SKILL" "$CLAIM_REF"
  # Failing state: the check moved after the download.
  move_line_after "$SKILL" "$CLAIM_CHECK" "$VERIFY_CALL"
  claim_check_holds "$COPY" "$CLAIM_REF" && return 1
  # Failing state: the check removed.
  grep -vxF -- "$CLAIM_CHECK" "$SKILL" > "$COPY"
  claim_check_holds "$COPY" "$CLAIM_REF" && return 1
  use_ref_copy "$CLAIM_REF"
  # Failing state: the pinned stop line reworded.
  sed 's|Wait for it to merge, then run /update-gaia again.|Try later.|' "$CLAIM_REF" > "$COPY_REF"
  claim_check_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the current-user source missing.
  sed 's|update-claim.sh login --tree|update-claim.sh whoami --tree|' "$CLAIM_REF" > "$COPY_REF"
  claim_check_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the own-claim classify call loses its branch.
  sed 's| --branch <headRefName>$||' "$CLAIM_REF" > "$COPY_REF"
  claim_check_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the stop no longer promises to create nothing.
  sed 's|leaves no download, worktree, prune or cache change and no other branch change|cleans up|' "$CLAIM_REF" > "$COPY_REF"
  claim_check_holds "$SKILL" "$COPY_REF" && return 1
  true
}

# 0 when SKILL.md copy `$1` claims after the provisioning wait and before the
# Step 4b prune and the conflict flow's dispatch, and reference copy `$2` starts
# the claim, then breaks a tie, and removes a lost run's own worktree and branch.
claim_start_holds() {
  local skill="$1" ref="$2" section
  section="$(section_file "$skill" "$STEP_4_WORKTREE")" || return 1
  in_order "$section" "$WAIT_CALL" "$CLAIM_PARAGRAPH" || return 1
  grep -F "$CLAIM_PARAGRAPH" "$section" | grep -qF 'Unless the claim check was skipped' || return 1
  exact_in_order "$skill" "$STEP_4B" "$STEP_CONFLICT_FLOW" || return 1
  [ "$(first_line "$skill" "$CLAIM_PARAGRAPH")" -lt "$(first_line "$skill" "$STEP_4B")" ] || return 1
  section="$(section_file "$ref" "$CLAIM_REF_AFTER_PROCEED")" || return 1
  grep -qxF -- "$CLAIM_START_CALL" "$section" || return 1
  grep -qxF -- "$CLAIM_TIE_BREAK_CALL" "$section" || return 1
  in_order "$section" \
    'update-claim.sh start --tree' \
    'update-claim.sh tie-break --tree' \
    '`LOST <other> <login>`' || return 1
  grep -F '`LOST <other> <login>`' "$section" | grep -qF 'work-lifecycle.md` (`## Releasing an empty worktree`)' || return 1
  return 0
}

@test "claim: it follows the provisioning wait, precedes the prune and the dispatch, and a lost tie-break removes the run's own worktree" {
  claim_start_holds "$SKILL" "$CLAIM_REF"
  # Failing state: the claim paragraph missing.
  grep -vF "$CLAIM_PARAGRAPH" "$SKILL" > "$COPY"
  claim_start_holds "$COPY" "$CLAIM_REF" && return 1
  # Failing state: the claim paragraph above the wait.
  awk -v anchor="$STEP_4_WORKTREE" '
    index($0, "**Claim.**") == 1 { next }
    { print }
    index($0, anchor) == 1 { print "**Claim.** early. Unless the claim check was skipped"; print "" }
  ' "$SKILL" > "$COPY"
  claim_start_holds "$COPY" "$CLAIM_REF" && return 1
  # Failing state: the claim paragraph after the prune heading.
  awk '
    index($0, "**Claim.**") == 1 { held = $0; next }
    { print }
    index($0, "## Step 4b: Prune prior-run artifacts") == 1 { print ""; print held }
  ' "$SKILL" > "$COPY"
  claim_start_holds "$COPY" "$CLAIM_REF" && return 1
  use_ref_copy "$CLAIM_REF"
  # Failing state: the worktree is left behind after a lost tie-break.
  sed 's|(`## Releasing an empty worktree`)|(nowhere)|' "$CLAIM_REF" > "$COPY_REF"
  claim_start_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the tie-break runs before the start.
  grep -vxF -- "$CLAIM_START_CALL" "$CLAIM_REF" > "$COPY_REF"
  claim_start_holds "$SKILL" "$COPY_REF" && return 1
  true
}

# 0 when SKILL.md copy `$1` adds the claim PR's close command to the worktree
# notice and says a stop leaves the claim PR open.
claim_notice_holds() {
  local section
  section="$(section_file "$1" "$STEP_4_WORKTREE")" || return 1
  grep -F 'The worktree notice.' "$section" >/dev/null || return 1
  grep -qF 'gh pr close <CLAIM_PR> --delete-branch' "$section" || return 1
  grep -F '**The stop rule.**' "$section" | grep -qF 'leaves the claim PR open' || return 1
  return 0
}

@test "the worktree notice and the stop rule account for a claim PR that exists before Step 11" {
  claim_notice_holds "$SKILL"
  sed 's|gh pr close <CLAIM_PR> --delete-branch|gh pr close|' "$SKILL" > "$COPY"
  claim_notice_holds "$COPY" && return 1
  sed 's|leaves the claim PR open|leaves nothing open|' "$SKILL" > "$COPY"
  claim_notice_holds "$COPY" && return 1
  true
}

# Prints each line of file `$1` that runs a bash call of the claim script
# without the --tree flag every subcommand takes.
claim_calls_without_tree() {
  grep -E 'bash .*update-claim\.sh' "$1" | grep -vF -- '--tree' || true
}

@test "every update-claim.sh call in SKILL.md and the reference carries --tree" {
  local calls
  calls="$(cat "$SKILL" "$CLAIM_REF" | grep -cE 'bash .*update-claim\.sh')"
  [ "$calls" -ge 6 ]
  [ -z "$(claim_calls_without_tree "$SKILL")" ]
  [ -z "$(claim_calls_without_tree "$CLAIM_REF")" ]
  # Failing state: a call without the tree.
  sed 's| --tree <worktree path> --tag| --tag|' "$CLAIM_REF" > "$COPY"
  [ -n "$(claim_calls_without_tree "$COPY")" ]
  sed 's|update-claim.sh list --tree <main checkout path>|update-claim.sh list|' "$SKILL" > "$COPY"
  [ -n "$(claim_calls_without_tree "$COPY")" ]
}

# 0 when file `$1` holds no forced push, no bypassed hook and no pull gate name.
no_forced_or_bypassed_git() {
  grep -qE 'push --force|push -f|--force-with-lease|--no-verify' "$1" && return 1
  grep -qE 'pull-gate|gaia_pull_gate' "$1" && return 1
  return 0
}

@test "no push is forced, no hook is bypassed, and no pull gate name appears in the skill or the claim reference" {
  no_forced_or_bypassed_git "$SKILL"
  no_forced_or_bypassed_git "$CLAIM_REF"
  # The worktree notice's own removal flag is not a push flag.
  grep -qF 'git worktree remove --force <worktree path>' "$SKILL"
  local needle
  for needle in 'git push --force origin x' 'git push -f' 'git push --force-with-lease' 'git commit --no-verify' 'pull-gate.md' 'gaia_pull_gate x'; do
    { cat "$SKILL"; printf '%s\n' "$needle"; } > "$COPY"
    no_forced_or_bypassed_git "$COPY" && { echo "not caught: $needle" >&2; return 1; }
    { cat "$CLAIM_REF"; printf '%s\n' "$needle"; } > "$COPY"
    no_forced_or_bypassed_git "$COPY" && { echo "not caught: $needle" >&2; return 1; }
  done
  true
}

# 0 when SKILL.md copy `$1` pushes before it hands the claim PR to the
# reference, and reference copy `$2` rewrites the PR body and then drops the
# claim from the cache, both after the push.
claim_step_11_holds() {
  local skill="$1" ref="$2" section
  section="$(section_file "$skill" "$STEP_11")" || return 1
  in_order "$section" 'git -C <acting tree> push -u origin <branch>' 'When `CLAIM_PR` is set' || return 1
  grep -F 'When `CLAIM_PR` is set' "$section" | grep -qF 'references/claim-flow.md' || return 1
  section="$(section_file "$ref" "$CLAIM_REF_STEP_11")" || return 1
  in_order "$section" \
    '**Re-list before the push.**' \
    '**After the push, when `CLAIM_PR` is set.**' \
    'pr-body.md' \
    'gh pr edit <CLAIM_PR> --body-file <main checkout path>/.gaia/local/cache/shared/update-gaia/run/pr-body.md' \
    '--mode gaia --version <LATEST> --drop-claim <CLAIM_PR>' || return 1
  return 0
}

@test "Step 11 with a claim: the body is rewritten and the claim dropped from the cache after the push" {
  claim_step_11_holds "$SKILL" "$CLAIM_REF"
  use_ref_copy "$CLAIM_REF"
  # Failing state: the cache drop above the push.
  awk '
    /^\*\*After the push, when `CLAIM_PR` is set\.\*\*/ { print "bash x update-check-bust.sh --mode gaia --version <LATEST> --drop-claim <CLAIM_PR>" }
    { print }
  ' "$CLAIM_REF" > "$COPY_REF"
  claim_step_11_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the drop is gone.
  sed 's| --drop-claim <CLAIM_PR>||' "$CLAIM_REF" > "$COPY_REF"
  claim_step_11_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: the body is never rewritten.
  grep -vF 'gh pr edit <CLAIM_PR>' "$CLAIM_REF" > "$COPY_REF"
  claim_step_11_holds "$SKILL" "$COPY_REF" && return 1
  # Failing state: SKILL.md no longer hands over.
  grep -vF 'references/claim-flow.md' "$SKILL" > "$COPY"
  claim_step_11_holds "$COPY" "$CLAIM_REF" && return 1
  true
}

@test "the Contents line names the claim check and the claim reference" {
  sed -n 6p "$SKILL" | grep -qF 'Pre-flight: Claim check'
  sed -n 6p "$SKILL" | grep -qF 'references/claim-flow.md'
  sed 's|Pre-flight: Claim check|Pre-flight: Gone|' "$SKILL" | sed -n 6p | grep -qF 'Pre-flight: Claim check' && return 1
  true
}

# --- Pull mode: the pull check and references/pull-mode.md -------------------------

PULL_CHECK='## Pre-flight: Pull check'
DECISION_LOG_HEADING='## Pre-flight: Decision log check'
STEP_3C='## Step 3c: Download and verify the bundles'
PULL_REF_LOCKFILE='## Step 3: Install when the lockfile changed'
PULL_RESIDUE_CALL='bash <main checkout path>/.gaia/scripts/state-registry-lib.sh residue-sweep'
PULL_BUST_CALL='bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode pull --version <new version>'
PULL_DRIFT_CALL='bash <main checkout path>/.gaia/scripts/update-gaia-drift.sh --features <main checkout path>/.gaia/setup-features.json --scope machine'
PULL_INSTALL_CALL='pnpm -C <main checkout path> install --frozen-lockfile'

# 0 when SKILL.md copy `$1` runs the pull check before the decision log check,
# which runs before the claim check, which runs before Step 3c.
pull_check_order_holds() {
  exact_in_order "$1" "$PULL_CHECK" "$DECISION_LOG_HEADING" "$CLAIM_CHECK" "$STEP_3C" || return 1
  sed -n 6p "$1" | grep -qF 'references/pull-mode.md' || return 1
  return 0
}

@test "pull check: it precedes the decision log check, which precedes the claim check, which precedes Step 3c" {
  pull_check_order_holds "$SKILL"
  # Failing state: the pull check moved after the decision log check.
  move_line_after "$SKILL" "$PULL_CHECK" "$DECISION_LOG_HEADING"
  pull_check_order_holds "$COPY" && return 1
  # Failing state: the decision log check moved after the claim check.
  move_line_after "$SKILL" "$DECISION_LOG_HEADING" "$CLAIM_CHECK"
  pull_check_order_holds "$COPY" && return 1
  # Failing state: the pull check moved after Step 3c.
  move_line_after "$SKILL" "$PULL_CHECK" "$STEP_3C"
  pull_check_order_holds "$COPY" && return 1
  # Failing state: the pull check gone.
  grep -vxF -- "$PULL_CHECK" "$SKILL" > "$COPY"
  pull_check_order_holds "$COPY" && return 1
  # Failing state: the Contents line no longer names the reference.
  sed '6s|references/pull-mode.md|references/gone.md|' "$SKILL" > "$COPY"
  pull_check_order_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` limits the pull check to a fresh main-checkout run,
# reads origin's version with update-claim.sh, fails open on exit 3 and hands
# off to the reference with the update-gaia caller.
pull_check_content_holds() {
  local section
  section="$(section_file "$1" "$PULL_CHECK")" || return 1
  grep -F 'Applies only in' "$section" | grep -qF 'mode 2' || return 1
  grep -F 'Applies only in' "$section" | grep -qF '`NONE`' || return 1
  grep -qxF 'bash .gaia/scripts/update-claim.sh origin-version --tree <main checkout path>' "$section" || return 1
  grep -qF 'Exit 3' "$section" || return 1
  grep -qF 'fails open' "$section" || return 1
  grep -qF 'references/pull-mode.md' "$section" || return 1
  grep -qF 'caller `update-gaia`' "$section" || return 1
  return 0
}

@test "pull check: it names mode 2 and NONE, reads origin with update-claim.sh, fails open and follows pull-mode.md" {
  pull_check_content_holds "$SKILL"
  sed 's|^Applies only in mode 2 when|Applies in every mode when|' "$SKILL" > "$COPY"
  pull_check_content_holds "$COPY" && return 1
  sed 's|the classifier printed `NONE`|the classifier ran|' "$SKILL" > "$COPY"
  pull_check_content_holds "$COPY" && return 1
  sed 's|update-claim.sh origin-version --tree|update-claim.sh origin-version|' "$SKILL" > "$COPY"
  pull_check_content_holds "$COPY" && return 1
  sed 's|the check fails open|the check stops|' "$SKILL" > "$COPY"
  pull_check_content_holds "$COPY" && return 1
  sed 's|read `references/pull-mode.md` and follow it|continue|' "$SKILL" > "$COPY"
  pull_check_content_holds "$COPY" && return 1
  true
}

# Prints each line inside a fenced code block of file `$1` that runs a stash,
# fetch, checkout, switch or reset, or carries --force. Prose is not checked.
pull_command_violations() {
  awk '
    /^```/ { inside = !inside; next }
    inside && ($0 ~ /git (-C [^ ]+ )?(stash|fetch|checkout|switch|reset)/ || index($0, "--force")) { print NR ": " $0 }
  ' "$1"
}

@test "pull mode: no command line stashes, fetches, switches or resets, or forces, and prose prohibitions stay" {
  local section_copy needle
  section_copy="$(section_file "$SKILL" "$PULL_CHECK")"
  [ -z "$(pull_command_violations "$PULL_REF")" ]
  [ -z "$(pull_command_violations "$section_copy")" ]
  # The prose prohibition is allowed, and the fence scan sees real blocks.
  grep -qF 'It never stashes, never forces and never switches branches' "$PULL_REF"
  [ "$(grep -c '^```bash$' "$PULL_REF")" -ge 6 ]
  [ "$(grep -c '^```bash$' "$section_copy")" -ge 1 ]
  # The frozen install carries --frozen-lockfile, not --force, so it stays clean.
  grep -qF -- 'install --frozen-lockfile' "$PULL_REF"
  # Failing state: each forbidden command inside a fence of the reference and of the skill's section.
  for needle in 'git stash' 'git -C <main checkout path> fetch origin main' 'git checkout main' 'git switch main' 'git reset --hard' 'bash x pull --force'; do
    awk -v added="$needle" '{ print } /^## Step 2: Pull$/ { print "```bash"; print added; print "```" }' "$PULL_REF" > "$COPY"
    [ -n "$(pull_command_violations "$COPY")" ] || { echo "not caught: $needle" >&2; return 1; }
    { cat "$section_copy"; printf '%s\n' '```bash' "$needle" '```'; } > "$COPY"
    [ -n "$(pull_command_violations "$COPY")" ] || { echo "not caught in the skill: $needle" >&2; return 1; }
  done
  true
}

@test "pull mode: drift runs with --scope machine and the bust with --mode pull" {
  grep -qxF -- "$PULL_DRIFT_CALL" "$PULL_REF"
  grep -qxF -- "$PULL_BUST_CALL" "$PULL_REF"
  sed 's| --scope machine$||' "$PULL_REF" > "$COPY"
  grep -qxF -- "$PULL_DRIFT_CALL" "$COPY" && return 1
  sed 's| --mode pull | --mode gaia |' "$PULL_REF" > "$COPY"
  grep -qxF -- "$PULL_BUST_CALL" "$COPY" && return 1
  true
}

# 0 when reference copy `$1` runs the frozen install once, under the
# LOCKFILE_CHANGED yes condition.
pull_install_holds() {
  local section
  [ "$(grep -cF 'install --frozen-lockfile' "$1")" -eq 1 ] || return 1
  section="$(section_file "$1" "$PULL_REF_LOCKFILE")" || return 1
  in_order "$section" 'Only on `LOCKFILE_CHANGED yes`' "$PULL_INSTALL_CALL" || return 1
  return 0
}

@test "pull mode: the frozen install runs only under LOCKFILE_CHANGED yes" {
  pull_install_holds "$PULL_REF"
  grep -vF 'Only on `LOCKFILE_CHANGED yes`' "$PULL_REF" > "$COPY"
  pull_install_holds "$COPY" && return 1
  awk '{ print } /^## Step 2: Pull$/ { print "pnpm -C <main checkout path> install --frozen-lockfile" }' "$PULL_REF" > "$COPY"
  pull_install_holds "$COPY" && return 1
  true
}

@test "pull mode: the residue sweep is offered before the cache bust" {
  exact_in_order "$PULL_REF" "$PULL_RESIDUE_CALL" "$PULL_BUST_CALL"
  move_line_after "$PULL_REF" "$PULL_RESIDUE_CALL" "$PULL_BUST_CALL"
  exact_in_order "$COPY" "$PULL_RESIDUE_CALL" "$PULL_BUST_CALL" && return 1
  grep -vxF -- "$PULL_RESIDUE_CALL" "$PULL_REF" > "$COPY"
  exact_in_order "$COPY" "$PULL_RESIDUE_CALL" "$PULL_BUST_CALL" && return 1
  true
}

@test "pull mode: the continue offer comes after the cache bust" {
  in_order "$PULL_REF" '--mode pull' 'Continue to the full update'
  # Failing state: the offer ahead of the bust.
  awk '/^## Step 6:/ && !done { print "Continue to the full update"; done = 1 } { print }' "$PULL_REF" > "$COPY"
  in_order "$COPY" '--mode pull' 'Continue to the full update' && return 1
  # Failing state: no offer.
  grep -vF 'Continue to the full update' "$PULL_REF" > "$COPY"
  in_order "$COPY" '--mode pull' 'Continue to the full update' && return 1
  true
}

@test "pull mode: continuing invokes /update-gaia through the Skill tool after the bust" {
  in_order "$PULL_REF" '--mode pull' 'invoke `/update-gaia` again through the Skill tool'
  # Failing state: the invocation without the Skill tool.
  sed 's|invoke `/update-gaia` again through the Skill tool|run it again|' "$PULL_REF" > "$COPY"
  in_order "$COPY" '--mode pull' 'invoke `/update-gaia` again through the Skill tool' && return 1
  # Failing state: the invocation ahead of the bust.
  awk '/^## Step 2: Pull$/ { print "invoke `/update-gaia` again through the Skill tool" } { print }' "$PULL_REF" | grep -vF 'On continue, invoke' > "$COPY"
  in_order "$COPY" '--mode pull' 'invoke `/update-gaia` again through the Skill tool' && return 1
  true
}

# 0 when pull-mode copy `$1` names both callers and confines the full-update
# offer to the update-gaia caller, with the gate returning to the restart step.
pull_callers_hold() {
  local section
  grep -F '**Caller**' "$1" | grep -qF '`update-gaia`' || return 1
  grep -F '**Caller**' "$1" | grep -qF '`gate`' || return 1
  section="$(section_of "$1" '## Step 7')"
  grep -F 'Caller `gate`' <<<"$section" | grep -qF 'restart step' || return 1
  [ "$(grep -cF 'Continue to the full update' "$1")" -eq 1 ] || return 1
  grep -F 'Continue to the full update' "$1" | grep -qF 'Caller `update-gaia`' || return 1
  grep -F 'Caller `gate`' <<<"$section" | grep -qF 'Continue to the full update' && return 1
  return 0
}

@test "pull mode: both callers are named and the continue offer belongs to update-gaia only" {
  pull_callers_hold "$PULL_REF"
  # Failing state: the gate caller dropped.
  sed 's|`update-gaia` or `gate`|`update-gaia`|' "$PULL_REF" > "$COPY"
  pull_callers_hold "$COPY" && return 1
  # Failing state: the update-gaia caller dropped.
  sed 's|`update-gaia` or `gate`|`gate`|' "$PULL_REF" > "$COPY"
  pull_callers_hold "$COPY" && return 1
  # Failing state: the offer no longer named for update-gaia alone.
  sed 's|^Caller `update-gaia`: when|When|' "$PULL_REF" > "$COPY"
  pull_callers_hold "$COPY" && return 1
  # Failing state: the gate arm offers the update too.
  sed 's|^Caller `gate` skips the update offer and returns|Caller `gate` offers "Continue to the full update" and returns|' "$PULL_REF" > "$COPY"
  pull_callers_hold "$COPY" && return 1
  # Failing state: the gate arm no longer returns to the restart step.
  sed 's|restart step\.|end.|' "$PULL_REF" > "$COPY"
  pull_callers_hold "$COPY" && return 1
  true
}

# --- The pull gate: references/pull-gate.md -----------------------------------

GATE_STEP_1='## Step 1: A linked worktree (exit 2)'
GATE_STEP_2='## Step 2: Ask (exit 1)'
GATE_STEP_4='## Step 4: Pull'
GATE_STEP_5='## Step 5: Restart'

# 0 when gate reference copy `$1` puts the linked-worktree arm before the question.
gate_exit_2_order_holds() {
  in_order "$1" "$GATE_STEP_1" "$GATE_STEP_2" "$GATE_STEP_4" "$GATE_STEP_5"
}

# 0 when gate reference copy `$1`'s linked-worktree arm stops, offers no pull
# and no restart.
gate_exit_2_arm_holds() {
  local arm
  arm="$(section_of "$1" "$GATE_STEP_1")"
  [ -n "$arm" ] || return 1
  grep -qF 'Stop the command' <<<"$arm" || return 1
  grep -qF 'Never offer to pull and never restart' <<<"$arm" || return 1
  grep -qF 'AskUserQuestion' <<<"$arm" && return 1
  grep -qF 'Skill tool' <<<"$arm" && return 1
  grep -qF 'pull-mode.md' <<<"$arm" && return 1
  return 0
}

@test "pull gate: the linked-worktree arm precedes the question and offers no pull and no restart" {
  gate_exit_2_order_holds "$GATE_REF"
  gate_exit_2_arm_holds "$GATE_REF"
  # Failing state: the arm after the question.
  { grep -vF "$GATE_STEP_1" "$GATE_REF"; printf '%s\n' "$GATE_STEP_1"; } > "$COPY"
  gate_exit_2_order_holds "$COPY" && return 1
  # Failing state: the arm gone.
  grep -vF "$GATE_STEP_1" "$GATE_REF" > "$COPY"
  gate_exit_2_order_holds "$COPY" && return 1
  # Failing state: the prohibition dropped.
  sed 's|Never offer to pull and never restart|Offer to pull|' "$GATE_REF" > "$COPY"
  gate_exit_2_arm_holds "$COPY" && return 1
  # Failing state: the arm asks.
  insert_after "$GATE_REF" "$GATE_STEP_1" 'Ask with `AskUserQuestion`.'
  gate_exit_2_arm_holds "$COPY" && return 1
  # Failing state: the arm restarts through the Skill tool.
  insert_after "$GATE_REF" "$GATE_STEP_1" 'Invoke it again through the Skill tool.'
  gate_exit_2_arm_holds "$COPY" && return 1
  # Failing state: the arm follows pull mode.
  insert_after "$GATE_REF" "$GATE_STEP_1" 'Follow `pull-mode.md`.'
  gate_exit_2_arm_holds "$COPY" && return 1
  true
}

# 0 when gate reference copy `$1` names the three commands only a user can
# start and the plan orchestrator's KICKOFF re-run line.
gate_restart_kinds_hold() {
  local restart command_name
  restart="$(section_of "$1" "$GATE_STEP_5")"
  for command_name in '/gaia-codify' '/gaia-fitness' '/gaia-residue'; do
    grep -qF "\`$command_name\`" <<<"$restart" || return 1
  done
  grep -qF 'disable-model-invocation' <<<"$restart" || return 1
  grep -qF 'Read <absolute KICKOFF.md path> and execute it.' <<<"$restart" || return 1
  return 0
}

@test "pull gate: the disable-model-invocation commands and the KICKOFF re-run line are listed" {
  gate_restart_kinds_hold "$GATE_REF"
  local command_name
  for command_name in '/gaia-codify' '/gaia-fitness' '/gaia-residue'; do
    # Failing state: one of the three commands dropped.
    sed "s|\`$command_name\`|\`/other\`|" "$GATE_REF" > "$COPY"
    gate_restart_kinds_hold "$COPY" && { echo "not caught: $command_name" >&2; return 1; }
  done
  # Failing state: the KICKOFF line gone.
  grep -vF 'KICKOFF.md path' "$GATE_REF" > "$COPY"
  gate_restart_kinds_hold "$COPY" && return 1
  # Failing state: the marker gone.
  sed 's|disable-model-invocation|other|' "$GATE_REF" > "$COPY"
  gate_restart_kinds_hold "$COPY" && return 1
  true
}

# 0 when gate reference copy `$1`'s question carries the auto arm and keeps
# the auto token in the restart arguments.
gate_auto_arm_holds() {
  local ask
  ask="$(section_of "$1" "$GATE_STEP_2")"
  grep -qF 'choose the Recommended option without asking' <<<"$ask" || return 1
  grep -qF 'keep the `auto` token in the restart arguments' <<<"$ask" || return 1
  grep -qF 'verbatim, an `auto` token included' "$1" || return 1
  return 0
}

@test "pull gate: the auto arm picks Recommended and keeps the auto token" {
  gate_auto_arm_holds "$GATE_REF"
  sed 's|choose the Recommended option without asking|ask anyway|' "$GATE_REF" > "$COPY"
  gate_auto_arm_holds "$COPY" && return 1
  sed 's|keep the `auto` token in the restart arguments|drop it|' "$GATE_REF" > "$COPY"
  gate_auto_arm_holds "$COPY" && return 1
  sed 's|, an `auto` token included||' "$GATE_REF" > "$COPY"
  gate_auto_arm_holds "$COPY" && return 1
  true
}

# 0 when gate reference copy `$1` and pull-mode copy `$2` never restart after
# a refused or failed pull.
gate_refusal_never_restarts() {
  local pull_step
  pull_step="$(section_of "$1" "$GATE_STEP_4")"
  grep -qF 'It never restarts' <<<"$pull_step" || return 1
  grep -qF 'stops here with pull mode' <<<"$pull_step" || return 1
  grep -qF 'Caller `gate` never restarts after a refusal' "$2" || return 1
  grep -qF 'caller `gate` never restarts after either' "$2" || return 1
  return 0
}

@test "pull gate: a pull refusal or failure never restarts the command" {
  gate_refusal_never_restarts "$GATE_REF" "$PULL_REF"
  sed 's|It never restarts\.|It restarts anyway.|' "$GATE_REF" > "$COPY"
  gate_refusal_never_restarts "$COPY" "$PULL_REF" && return 1
  sed 's|stops here with pull mode|continues with pull mode|' "$GATE_REF" > "$COPY"
  gate_refusal_never_restarts "$COPY" "$PULL_REF" && return 1
  sed 's|Caller `gate` never restarts after a refusal\.||' "$PULL_REF" > "$COPY"
  gate_refusal_never_restarts "$GATE_REF" "$COPY" && return 1
  sed 's|; caller `gate` never restarts after either||' "$PULL_REF" > "$COPY"
  gate_refusal_never_restarts "$GATE_REF" "$COPY" && return 1
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

BLEND_RECORD_CALL='bash <main checkout path>/.gaia/scripts/fitness-blend-record.sh record --main-root <main checkout path> --tree <acting tree> --report <run dir>/report.json --decisions <acting tree>/.gaia/update-decisions.json --tag <LATEST_TAG>'

# 0 when SKILL.md copy `$1` records the blended harness files in Step 9d after
# the ping and before the version write, as its own command.
blend_record_order_holds() {
  local section
  section="$(section_file "$1" "$STEP_9D")" || return 1
  grep -qxF -- "$BLEND_RECORD_CALL" "$section" || return 1
  in_order "$section" 'ping --event update' 'fitness-blend-record.sh record' 'echo <LATEST> > .gaia/VERSION' || return 1
}

@test "Step 9d: the blend record is written after the ping and before the version write" {
  blend_record_order_holds "$SKILL"
  # The writer call dropped.
  grep -vxF -- "$BLEND_RECORD_CALL" "$SKILL" > "$COPY"
  blend_record_order_holds "$COPY" && return 1
  # The writer block moved after the version write.
  awk -v call="$BLEND_RECORD_CALL" '
    $0 == call { next }
    { print }
    /^echo <LATEST> > \.gaia\/VERSION$/ { getline; print; print ""; print "```bash"; print call; print "```" }
  ' "$SKILL" > "$COPY"
  [ "$(first_line "$COPY" 'fitness-blend-record.sh record')" -gt "$(first_line "$COPY" 'echo <LATEST> > .gaia/VERSION')" ]
  blend_record_order_holds "$COPY" && return 1
  true
}

MANIFEST_STOP='A non-zero exit from the `cp` command is the `MANIFEST_COPY_FAILED` stop'

@test "Step 9d prose: a failed manifest copy is the MANIFEST_COPY_FAILED stop" {
  section_of "$SKILL" "$STEP_9D" | grep -qF "$MANIFEST_STOP"
  grep -vF "$MANIFEST_STOP" "$SKILL" > "$COPY"
  section_of "$COPY" "$STEP_9D" | grep -qF 'MANIFEST_COPY_FAILED' && return 1
  true
}

# --- Step 12: the leftover-file cleanup ---------------------------------------

# 0 when SKILL.md copy `$1` runs no sweep and no in-place ask in Step 12, and
# hands the cleanup to the work-lifecycle section that runs it after the merge.
step_12_holds() {
  local section
  section="$(section_of "$1" "$STEP_12")"
  [ -n "$section" ] || return 1
  printf '%s\n' "$section" | grep -qF 'Run no cleanup here' || return 1
  printf '%s\n' "$section" | grep -qF "work-lifecycle.md\`, \`$LIFECYCLE_LEFTOVERS\`" || return 1
  printf '%s\n' "$section" | grep -qF 'residue-sweep' && return 1
  printf '%s\n' "$section" | grep -qF 'AskUserQuestion' && return 1
  return 0
}

@test "Step 12: the run runs no sweep and hands the cleanup to the post-merge cleanup" {
  step_12_holds "$SKILL"
  # Failing state: the user handed the command to run by hand.
  insert_after "$SKILL" "$STEP_12" 'Print as the next step: run `bash .gaia/scripts/state-registry-lib.sh residue-sweep --apply` from the main checkout.'
  step_12_holds "$COPY" && return 1
  # Failing state: an in-place ask restored.
  insert_after "$SKILL" "$STEP_12" '**Mode 3.** Ask once with `AskUserQuestion` whether to delete the leftover files.'
  step_12_holds "$COPY" && return 1
  # Failing state: the pointer to the lifecycle section dropped.
  grep -vF "$LIFECYCLE_LEFTOVERS" "$SKILL" > "$COPY"
  step_12_holds "$COPY" && return 1
  true
}

LIFECYCLE_SWEEP_CALL='bash <main checkout path>/.gaia/scripts/state-registry-lib.sh residue-sweep'

# 0 when work-lifecycle.md copy `$1` runs the listing in the main checkout for
# an update branch, asks once, and applies only on the yes.
lifecycle_leftovers_hold() {
  local section
  section="$(section_of "$1" "$LIFECYCLE_LEFTOVERS")"
  [ -n "$section" ] || return 1
  printf '%s\n' "$section" | grep -qF 'starts with `update/`' || return 1
  printf '%s\n' "$section" | grep -qxF -- "$LIFECYCLE_SWEEP_CALL" || return 1
  printf '%s\n' "$section" | grep -qF 'ask once with `AskUserQuestion`' || return 1
  printf '%s\n' "$section" | grep -qF 'on `Delete them` run the same command with `--apply`' || return 1
  printf '%s\n' "$section" | grep -qxF -- "$LIFECYCLE_SWEEP_CALL --apply" && return 1
  return 0
}

@test "work-lifecycle cleanup: an update merge lists the leftover files, asks, and applies only on yes" {
  lifecycle_leftovers_hold "$LIFECYCLE"
  # Failing state: the listing call dropped.
  grep -vxF -- "$LIFECYCLE_SWEEP_CALL" "$LIFECYCLE" > "$COPY"
  lifecycle_leftovers_hold "$COPY" && return 1
  # Failing state: an unconditional --apply.
  insert_after "$LIFECYCLE" "$LIFECYCLE_LEFTOVERS" "$LIFECYCLE_SWEEP_CALL --apply"
  lifecycle_leftovers_hold "$COPY" && return 1
  # Failing state: the ask dropped.
  sed 's/ask once with `AskUserQuestion`/delete them/' "$LIFECYCLE" > "$COPY"
  lifecycle_leftovers_hold "$COPY" && return 1
  true
}

LIFECYCLE_MACHINE_DRIFT_CALL='bash <main checkout path>/.gaia/scripts/update-gaia-drift.sh --features <main checkout path>/.gaia/setup-features.json --scope machine'

# 0 when work-lifecycle.md copy `$1` runs the machine-scope drift in the pulled
# main checkout after the sweep, records a feature only once it ran there, and
# names `/setup-gaia` where nobody can run it.
lifecycle_machine_drift_holds() {
  local section_path
  section_path="$(section_file "$1" "$LIFECYCLE_LEFTOVERS")" || return 1
  grep -qxF -- "$LIFECYCLE_MACHINE_DRIFT_CALL" "$section_path" || return 1
  in_order "$section_path" "$LIFECYCLE_SWEEP_CALL" "$LIFECYCLE_MACHINE_DRIFT_CALL" || return 1
  grep -qF 'records it only after it ran here' "$section_path" || return 1
  grep -qF 'run /setup-gaia from the main checkout to carry the machine-scope setup features this update deferred' "$section_path" || return 1
  return 0
}

@test "work-lifecycle cleanup: an update merge runs the deferred machine-scope features in the main checkout" {
  lifecycle_machine_drift_holds "$LIFECYCLE"
  # Failing state: the drift call dropped.
  grep -vxF -- "$LIFECYCLE_MACHINE_DRIFT_CALL" "$LIFECYCLE" > "$COPY"
  lifecycle_machine_drift_holds "$COPY" && return 1
  # Failing state: the drift widened to every scope.
  sed 's| --scope machine$||' "$LIFECYCLE" > "$COPY"
  lifecycle_machine_drift_holds "$COPY" && return 1
  local pin
  for pin in 'records it only after it ran here' 'run /setup-gaia from the main checkout'; do
    grep -vF -- "$pin" "$LIFECYCLE" > "$COPY"
    lifecycle_machine_drift_holds "$COPY" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
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

MACHINE_IDS_CALL="jq -r '.features[] | select(.scope == \"machine\") | .id' <LATEST_DIR>/.gaia/setup-features.json"

# 0 when SKILL.md copy `$1` keeps every machine-scope feature out of the update
# worktree: Step 9c lists the machine-scope ids, never applies, asks or records
# one there, and hands them to the post-merge cleanup; Step 9d's addendum and
# Step 12 name the hand-off.
machine_scope_rule_holds() {
  local section
  section="$(section_of "$1" "$STEP_9C")"
  [ -n "$section" ] || return 1
  printf '%s\n' "$section" | grep -qxF -- "$MACHINE_IDS_CALL" || return 1
  printf '%s\n' "$section" | grep -qF 'is never applied, asked or recorded inside the update worktree' || return 1
  printf '%s\n' "$section" | grep -qF "work-lifecycle.md\`, \`$LIFECYCLE_LEFTOVERS\`" || return 1
  section_of "$1" "$STEP_9D" | grep -qF 'the machine-scope features deferred to the main checkout, each by id' || return 1
  section_of "$1" "$STEP_12" | grep -qF 'the machine-scope setup features Step 9c deferred' || return 1
  return 0
}

@test "Step 9c: a machine-scope feature is deferred to the main checkout, never run in the update worktree" {
  machine_scope_rule_holds "$SKILL"
  local pin
  for pin in "$MACHINE_IDS_CALL" 'is never applied, asked or recorded inside the update worktree' \
    'the machine-scope features deferred to the main checkout' 'the machine-scope setup features Step 9c deferred'; do
    grep -vF -- "$pin" "$SKILL" > "$COPY"
    machine_scope_rule_holds "$COPY" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  # Failing state: the hand-off pointer dropped from Step 9c alone.
  awk -v heading="$STEP_9C" -v pointer="$LIFECYCLE_LEFTOVERS" '
    index($0, heading) == 1 { inside = 1 } inside && /^## Step 9d/ { inside = 0 }
    !(inside && index($0, pointer)) { print }' "$SKILL" > "$COPY"
  machine_scope_rule_holds "$COPY" && return 1
  true
}

@test "Step 9c: the machine-scope id list names migrate-2-machine and no project-scope feature" {
  local call output_ids
  call="$(section_of "$SKILL" "$STEP_9C" | grep -xF -- "$MACHINE_IDS_CALL")"
  [ -n "$call" ] || { echo "the call is not in Step 9c" >&2; return 1; }
  output_ids="$(bash -c "${call//<LATEST_DIR>/$REPO_ROOT}")"
  printf '%s\n' "$output_ids" | grep -qxF 'migrate-2-machine' || return 1
  local project_ids
  project_ids="$(jq -r '.features[] | select(.scope == "project") | .id' "$REPO_ROOT/.gaia/setup-features.json")"
  [ -n "$project_ids" ] || { echo "no project-scope ids to check against" >&2; return 1; }
  printf '%s\n' "$output_ids" | grep -qxF -f <(printf '%s\n' "$project_ids") && return 1
  true
}

# --- Prose order --------------------------------------------------------------

SELECTOR_CALL='bash .gaia/scripts/update-gaia-preflight.sh select-notes --latest-dir <LATEST_DIR>'
PROCEED_QUESTION='"Update GAIA from v$BASELINE to $LATEST_TAG?"'

# 0 when SKILL.md copy `$1` keeps the orchestrator order.
skill_order_holds() {
  local file="$1" anchor
  for anchor in 'EnterWorktree(' 'bash .gaia/scripts/update-gaia-preflight.sh prune' "$STEP_CONFLICT_FLOW"; do
    in_order "$file" "$SELECTOR_CALL" "$PROCEED_QUESTION" "$anchor" || return 1
  done
  in_order "$file" '## Step 9b' 'update-gaia-drift.sh --features' 'GAIA_MANIFEST_WRITE=release cp <LATEST_DIR>' 'ping --event update' 'echo <LATEST> > .gaia/VERSION' || return 1
  in_order "$file" '## Step 9d' '### Step 12' || return 1
  section_of "$file" '## Step 11 (orchestrator' | sed -n 3p | grep -qF "The execution agent's work ends at Step 9," || return 1
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

# --- The conflict flow: decision log, dispatch, answers, one commit ----------

DECISIONS_CHECK='bash .gaia/scripts/update-decisions.sh check --file <starting checkout>/.gaia/update-decisions.json'
VERIFY_CALL='bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --latest-tag <LATEST_TAG>'
PREPARE_CALL='bash <main checkout path>/.gaia/scripts/update-gaia-report.sh prepare --run-dir <main checkout path>/.gaia/local/cache/shared/update-gaia/run'
CLASSIFY_CALL='bash <main checkout path>/.gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <run dir>/report.json --report-key files --expect-count <n>'
LOCKFILE_CALL='<LATEST_DIR>/.gaia/cli/gaia update lockfile-command --root <acting tree>'
RECORD_CALL='bash <main checkout path>/.gaia/scripts/update-decisions.sh record --file <acting tree>/.gaia/update-decisions.json'
COMMIT_QUESTION='Commit this update?'
ADD_CALL='git -C <acting tree> add -A'
COMMIT_CALL='git -C <acting tree> commit -m "chore(gaia): update to <LATEST_TAG>"'

# The line number of the line in file `$1` that is exactly `$2`; empty if none.
exact_line() {
  grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# 0 when the lines exactly equal to `$2`, `$3`, ... appear in file `$1` in that
# order, each present. Headings are matched whole, so a prose mention of a
# heading earlier in the file never stands in for it.
exact_in_order() {
  local file="$1" previous=0 needle line
  shift
  for needle in "$@"; do
    line="$(exact_line "$file" "$needle")"
    [ -n "$line" ] || { echo "missing line: $needle" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { echo "out of order: $needle" >&2; return 1; }
    previous="$line"
  done
}

# Writes file `$1` to $COPY with the line exactly `$2` moved to just after the
# line exactly `$3`.
move_line_after() {
  awk -v moved="$2" -v anchor="$3" '
    $0 == moved { next }
    { print }
    $0 == anchor { print moved }
  ' "$1" > "$COPY"
  [ "$(exact_line "$COPY" "$2")" -gt "$(exact_line "$COPY" "$3")" ]
}

# 0 when SKILL.md copy `$1` checks the decision log before Step 3b and the
# first download, and its stop writes nothing.
decision_log_check_holds() {
  local section
  section="$(section_file "$1" '## Pre-flight: Decision log check')" || return 1
  grep -qxF -- "$DECISIONS_CHECK" "$section" || return 1
  grep -F '**Exit 1**' "$section" | grep -qF 'writing nothing: no download, and no worktree, branch, prune or cache change' || return 1
  exact_in_order "$1" '## Pre-flight: Decision log check' "$DECISIONS_CHECK" '## Step 3b: Refuse a 1.x baseline' "$VERIFY_CALL" || return 1
  return 0
}

@test "decision log check: it precedes Step 3b and the download, and an invalid log stops writing nothing" {
  decision_log_check_holds "$SKILL"
  # Failing state: the check moved after the download.
  move_line_after "$SKILL" "$DECISIONS_CHECK" "$VERIFY_CALL"
  decision_log_check_holds "$COPY" && return 1
  # Failing state: the stop no longer says it writes nothing.
  sed 's|writing nothing: no download, and no worktree, branch, prune or cache change|then clean up|' "$SKILL" > "$COPY"
  decision_log_check_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` verifies each deferred baseline tag, keeps it
# through the prune, and saves the CHANGELOG range from the oldest one.
deferred_baselines_hold() {
  section_of "$1" '## Step 3c: Download and verify the bundles' | grep -qF 'adding one `--extra-tag <tag>` per extra baseline tag' || return 1
  section_of "$1" '## Step 3c: Download and verify the bundles' | grep -qF 'one `EXTRA_DIR=<tag>:<path>` line per extra tag' || return 1
  section_of "$1" '## Step 3c: Download and verify the bundles' | grep -qF 'Name each deferred path whose `DEFERRED` line carries that tag' || return 1
  section_of "$1" '## Step 4: Show the release notes and confirm' | grep -qF '`--save-from <oldest extra tag' || return 1
  section_of "$1" '## Step 4b: Prune prior-run artifacts' | grep -qF 'one `--keep-tag <tag>` per extra baseline tag' || return 1
  return 0
}

@test "deferred baselines: Step 3c verifies each extra tag, Step 4 saves from the oldest, the prune keeps them" {
  deferred_baselines_hold "$SKILL"
  local pin
  for pin in 'adding one `--extra-tag <tag>`' 'line per extra tag' 'carries that tag' '`--save-from <oldest extra tag' 'one `--keep-tag <tag>`'; do
    grep -vF -- "$pin" "$SKILL" > "$COPY"
    deferred_baselines_hold "$COPY" && { echo "pin not enforced: $pin" >&2; return 1; }
  done
  true
}

# The snapshot copies in file `$1`, one `<source name> <snapshot name>` line
# each, sorted.
snapshot_copies() {
  grep -F '<run dir>/instructions/' "$1" | grep -E '^cp ' |
    sed -E 's|^cp <acting tree>/\.claude/skills/update-gaia/references/([^ ]+) <run dir>/instructions/([^ ]+)$|\1 \2|' | sort
}

SNAPSHOT_SET='merge-execution.md merge-execution.md
merge-generated.md merge-generated.md
merge-report.md merge-report.md'

# 0 when SKILL.md copy `$1` snapshots exactly the three instruction files,
# after the run directory is prepared and before the dispatch.
snapshot_holds() {
  [ "$(snapshot_copies "$1")" = "$SNAPSHOT_SET" ] || return 1
  exact_in_order "$1" "$PREPARE_CALL" \
    'cp <acting tree>/.claude/skills/update-gaia/references/merge-report.md <run dir>/instructions/merge-report.md' \
    '### Dispatch the execution agent' || return 1
  return 0
}

@test "snapshot: exactly merge-execution.md, merge-generated.md and merge-report.md are copied before dispatch" {
  snapshot_holds "$CONFLICT_FLOW"
  # Failing state: a fourth file joins the snapshot.
  insert_after "$CONFLICT_FLOW" '### Snapshot the instructions' 'cp <acting tree>/.claude/skills/update-gaia/SKILL.md <run dir>/instructions/SKILL.md'
  snapshot_holds "$COPY" && return 1
  # Failing state: one of the three is missing.
  grep -vF 'references/merge-generated.md <run dir>' "$CONFLICT_FLOW" > "$COPY"
  snapshot_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` derives the count with expect-count and splits the
# both-changed files with the chunk subcommand before the dispatch.
count_and_chunk_hold() {
  local section expect chunk
  section="$(section_file "$1" '### Count the expected entries and split the judgment work')" || return 1
  expect="$(grep -E '^bash <main checkout path>/\.gaia/scripts/update-gaia-report\.sh expect-count ' "$section")"
  chunk="$(grep -E '^bash <main checkout path>/\.gaia/scripts/update-gaia-report\.sh chunk ' "$section")"
  [ -n "$expect" ] && [ -n "$chunk" ] || return 1
  printf '%s\n' "$chunk" | grep -qF -- '--run-dir <run dir> --size 25' || return 1
  grep -qF 'never a count made by hand' "$section" || return 1
  exact_in_order "$1" "$expect" "$chunk" '### Dispatch the execution agent' "$CLASSIFY_CALL" || return 1
  return 0
}

@test "count and chunks: expect-count derives n, update-gaia-report.sh chunk splits the work, both before dispatch" {
  count_and_chunk_hold "$CONFLICT_FLOW"
  grep -vE 'update-gaia-report\.sh chunk ' "$CONFLICT_FLOW" > "$COPY"
  count_and_chunk_hold "$COPY" && return 1
  grep -vE 'update-gaia-report\.sh expect-count ' "$CONFLICT_FLOW" > "$COPY"
  count_and_chunk_hold "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` classifies the report with its key and derived
# count, clears only the report on a no-op, re-dispatches once and then runs
# the merge inline, and prepares the run directory exactly once, before that.
classify_holds() {
  local section
  section="$(section_file "$1" '### Classify the report')" || return 1
  grep -qxF -- "$CLASSIFY_CALL" "$section" || return 1
  grep -qxF 'rm -f <run dir>/report.json' "$section" || return 1
  grep -qF 'update-gaia-report.sh prepare' "$section" && return 1
  in_order "$section" "$CLASSIFY_CALL" 'rm -f <run dir>/report.json' 're-dispatch exactly once' || return 1
  grep -qE 're-dispatch exactly once.* second consecutive no-op means the orchestrator runs the merge inline itself' "$section" || return 1
  grep -qF 'never classify at the moment the Agent call returns' "$section" || return 1
  [ "$(grep -cF 'update-gaia-report.sh prepare' "$1")" -eq 1 ] || return 1
  in_order "$1" "$PREPARE_CALL" "$CLASSIFY_CALL" || return 1
  return 0
}

@test "classify: the report key and derived count, clear only the report, re-dispatch once, then inline" {
  classify_holds "$CONFLICT_FLOW"
  # Failing state: the no-op branch re-prepares, deleting the snapshot and candidates.
  sed 's|^rm -f <run dir>/report.json$|bash <main checkout path>/.gaia/scripts/update-gaia-report.sh prepare --run-dir <run dir>|' "$CONFLICT_FLOW" > "$COPY"
  classify_holds "$COPY" && return 1
  sed 's|--report-key files --expect-count <n>|--expect-count <n>|' "$CONFLICT_FLOW" > "$COPY"
  classify_holds "$COPY" && return 1
  sed 's|re-dispatch exactly once with the same prompt|re-dispatch with the same prompt|' "$CONFLICT_FLOW" > "$COPY"
  classify_holds "$COPY" && return 1
  sed 's|never classify at the moment the Agent call returns|classify when the Agent call returns|' "$CONFLICT_FLOW" > "$COPY"
  classify_holds "$COPY" && return 1
  sed 's|means the orchestrator runs the merge inline itself|means the run stops|' "$CONFLICT_FLOW" > "$COPY"
  classify_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` validates the final report before copying any clean
# merge, and copies clean merges before any answer's candidate.
validate_before_copy_holds() {
  in_order "$1" 'update-gaia-report.sh validate --final' 'update-gaia-report.sh apply-auto' \
    '## Apply answers and record decisions' 'cp <run dir>/candidates/' || return 1
  return 0
}

@test "validate --final precedes apply-auto, which precedes any candidate copy for an answer" {
  validate_before_copy_holds "$CONFLICT_FLOW"
  local validate apply
  validate="$(grep -E '^bash .*update-gaia-report\.sh validate --final ' "$CONFLICT_FLOW")"
  apply="$(grep -E '^bash .*update-gaia-report\.sh apply-auto ' "$CONFLICT_FLOW")"
  [ -n "$validate" ]
  [ -n "$apply" ]
  # Failing state: the clean merges copied before the report validates.
  move_line_after "$CONFLICT_FLOW" "$validate" "$apply"
  validate_before_copy_holds "$COPY" && return 1
  # Failing state: an answer's candidate copied before validation.
  insert_after "$CONFLICT_FLOW" '### Judgment chunks' 'cp <run dir>/candidates/x.combine <acting tree>/x'
  validate_before_copy_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` runs the conflict flow, which records decisions
# (reference copy `$2`), before the commit question and stages before it
# commits, so the decision log lands in the update commit.
record_before_commit_holds() {
  in_order "$1" "$STEP_CONFLICT_FLOW" "$COMMIT_QUESTION" || return 1
  exact_in_order "$1" "$ADD_CALL" "$COMMIT_CALL" || return 1
  in_order "$1" "$COMMIT_QUESTION" "$ADD_CALL" || return 1
  grep -qF -- "$RECORD_CALL" "$2" || return 1
  return 0
}

@test "decision records precede the commit question, and add -A precedes the update commit" {
  record_before_commit_holds "$SKILL" "$CONFLICT_FLOW"
  # Failing state: the reference no longer records.
  grep -vF -- "$RECORD_CALL" "$CONFLICT_FLOW" > "$BATS_TEST_TMPDIR/flow-copy.md"
  record_before_commit_holds "$SKILL" "$BATS_TEST_TMPDIR/flow-copy.md" && return 1
  # Failing state: the conflict flow step moved after the commit question.
  move_line_after "$SKILL" "$STEP_CONFLICT_FLOW" "$COMMIT_CALL"
  record_before_commit_holds "$COPY" "$CONFLICT_FLOW" && return 1
  # Failing state: the commit runs before the staging.
  move_line_after "$SKILL" "$ADD_CALL" "$COMMIT_CALL"
  record_before_commit_holds "$COPY" "$CONFLICT_FLOW" && return 1
  true
}

# 0 when SKILL.md copy `$1` runs the conflict flow, then Steps 9b to 9d, then
# the gate, then the review, and reference copy `$2` runs the questions, the
# answers, then the follow-ups (lockfile, regions, settings).
post_merge_order_holds() {
  local section
  exact_in_order "$1" "$STEP_CONFLICT_FLOW" \
    '## Step 9b: Follow the after-merge notes' '## Step 9c: Carry new setup features' \
    '## Step 9d: Record the update' '## Quality gate' '## Review point' || return 1
  [ "$(first_line "$1" "$COMMIT_QUESTION")" -gt "$(exact_line "$1" '## Review point')" ] || return 1
  exact_in_order "$2" '## Questions' '## Apply answers and record decisions' '## Follow-ups' || return 1
  section="$(section_file "$2" '## Follow-ups')" || return 1
  in_order "$section" 'update lockfile-command' 'update regen-regions' 'packages sync-settings' || return 1
  return 0
}

@test "order: the conflict flow, Steps 9b to 9d, the quality gate, then the review point" {
  post_merge_order_holds "$SKILL" "$CONFLICT_FLOW"
  # Failing state: the gate runs before the conflict flow.
  sed -e 's/^## Quality gate$/## SWAPPED/' -e "s/^$STEP_CONFLICT_FLOW\$/## Quality gate/" -e 's/^## SWAPPED$/'"$STEP_CONFLICT_FLOW"'/' "$SKILL" > "$COPY"
  post_merge_order_holds "$COPY" "$CONFLICT_FLOW" && return 1
  # Failing state: the version written after the gate.
  sed -e 's/^## Quality gate$/## SWAPPED/' -e 's/^## Step 9d: Record the update$/## Quality gate/' -e 's/^## SWAPPED$/## Step 9d: Record the update/' "$SKILL" > "$COPY"
  post_merge_order_holds "$COPY" "$CONFLICT_FLOW" && return 1
  # Failing state: the follow-ups run before the answers.
  sed -e 's/^## Follow-ups$/## SWAPPED/' -e 's/^## Apply answers and record decisions$/## Follow-ups/' -e 's/^## SWAPPED$/## Apply answers and record decisions/' "$CONFLICT_FLOW" > "$COPY"
  post_merge_order_holds "$SKILL" "$COPY" && return 1
  # Failing state: the region regeneration before the lockfile.
  move_line_after "$CONFLICT_FLOW" "$LOCKFILE_CALL" '<LATEST_DIR>/.gaia/cli/gaia update regen-regions --manifest <LATEST_DIR>/.gaia/manifest.json --root <acting tree> --backup-dir <backupDir> --json'
  post_merge_order_holds "$SKILL" "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` asks the commit question exactly once and holds no
# commit command before it.
single_confirm_holds() {
  local question
  [ "$(grep -cF "$COMMIT_QUESTION" "$1")" -eq 1 ] || return 1
  question="$(first_line "$1" "$COMMIT_QUESTION")"
  [ "$(grep -cxF -- "$COMMIT_CALL" "$1")" -eq 1 ] || return 1
  grep -nF 'commit -m' "$1" | cut -d: -f1 | while read -r line; do
    [ "$line" -gt "$question" ] || exit 1
  done || return 1
  return 0
}

@test "the commit question appears exactly once, and the commit command only after it" {
  single_confirm_holds "$SKILL"
  # Failing state: a second confirm.
  insert_after "$SKILL" '## Quality gate' "Ask \"$COMMIT_QUESTION\" here too."
  single_confirm_holds "$COPY" && return 1
  # Failing state: a commit before the question.
  insert_after "$SKILL" '## Quality gate' "$COMMIT_CALL"
  single_confirm_holds "$COPY" && return 1
  true
}

# 0 when SKILL.md copy `$1` picks the lockfile command with lockfile-command
# and runs dedupe or install once.
lockfile_follow_up_holds() {
  local section
  section="$(section_file "$1" '## Follow-ups')" || return 1
  grep -qxF -- "$LOCKFILE_CALL" "$section" || return 1
  grep -qF '`pnpm -C <acting tree> dedupe` once' "$section" || return 1
  grep -qF '`pnpm -C <acting tree> install` once' "$section" || return 1
  return 0
}

@test "follow-ups: the lockfile command comes from lockfile-command" {
  lockfile_follow_up_holds "$CONFLICT_FLOW"
  grep -vxF -- "$LOCKFILE_CALL" "$CONFLICT_FLOW" > "$COPY"
  lockfile_follow_up_holds "$COPY" && return 1
  true
}

# Prints every line of file `$1` naming the retired patch directory or the
# retired report name, both assembled so this suite never matches itself.
retired_names() {
  grep -nE "$(printf '%s|%s' '\.gaia-''merge' 'UpdateMerge''Report')" "$1" || true
}

@test "no line in SKILL.md names the retired patch directory or report name" {
  [ -z "$(retired_names "$SKILL")" ]
  [ -z "$(retired_names "$CONFLICT_FLOW")" ]
  { cat "$SKILL"; printf 'Review patches in .gaia-%s/\n' merge; } > "$COPY"
  [ -n "$(retired_names "$COPY")" ]
  { cat "$SKILL"; printf 'returns its UpdateMerge%s\n' Report; } > "$COPY"
  [ -n "$(retired_names "$COPY")" ]
  { cat "$CONFLICT_FLOW"; printf 'Review patches in .gaia-%s/\n' merge; } > "$COPY"
  [ -n "$(retired_names "$COPY")" ]
}

# --- Bundle-root pin ------------------------------------------------------------

# Prints every line of the given files naming .gaia/migrations/ other than
# through the target bundle (`<LATEST_DIR>/` in SKILL.md, `$latest_dir/` in the
# preflight script) or the refusal's bundled note path.
bare_migration_paths() {
  sed -e 's|<LATEST_DIR>/\.gaia/migrations/||g' \
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
  [ -z "$(bare_migration_paths "$SKILL" "$CONFLICT_FLOW" "$PREFLIGHT")" ]
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

# bats test_tags=whole-tree
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

# bats test_tags=whole-tree
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
