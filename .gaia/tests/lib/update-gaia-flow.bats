#!/usr/bin/env bats
# The /update-gaia skill's commands and hand-offs as SKILL.md and its
# references write them, and the migration notes it reads from the verified
# target bundle. The pre-merge
# blocks live in .gaia/scripts/update-gaia-preflight.sh and the drift block in
# update-gaia-drift.sh; their behavior is driven by update-gaia-preflight.bats
# and update-gaia-drift.bats.
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

STEP_3_DEFAULT='### Step 3, main checkout: classify the update branch'
STEP_4_WORKTREE='### Step 4, on Proceed: the update worktree'
STEP_9D='## Step 9d: Record the update'
STEP_11='### Step 11: Open a pull request'
STEP_12='### Step 12: The leftover-file cleanup'
LIFECYCLE_LEFTOVERS='### Leftover-file cleanup after an update merge'

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

# --- Pull mode: the pull check and references/pull-mode.md -------------------------

PULL_CHECK='## Pre-flight: Pull check'

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

# --- The pull gate: references/pull-gate.md -----------------------------------

GATE_STEP_2='## Step 2: Ask (exit 1)'

GATE_EXIT_3='## Unpushed default-branch commits (exit 3)'

# 0 when gate reference copy `$1`'s unpushed-commits arm precedes the question,
# stops in auto mode too, never pushes for the user, and offers no pull or
# restart.
gate_exit_3_arm_holds() {
  local arm
  in_order "$1" "$GATE_EXIT_3" "$GATE_STEP_2" || return 1
  arm="$(section_of "$1" "$GATE_EXIT_3")"
  [ -n "$arm" ] || return 1
  grep -qF 'Stop the command, in auto mode too' <<<"$arm" || return 1
  grep -qF 'never push for them' <<<"$arm" || return 1
  grep -qF 'Never offer to pull and never restart' <<<"$arm" || return 1
  grep -qF 'AskUserQuestion' <<<"$arm" && return 1
  grep -qF 'pull-mode.md' <<<"$arm" && return 1
  return 0
}

@test "pull gate: the unpushed-commits arm stops, never pushes, and offers no pull or restart" {
  gate_exit_3_arm_holds "$GATE_REF"
  # Failing state: the arm gone.
  grep -vF "$GATE_EXIT_3" "$GATE_REF" > "$COPY"
  gate_exit_3_arm_holds "$COPY" && return 1
  # Failing state: the arm after the question.
  { grep -vF "$GATE_EXIT_3" "$GATE_REF"; printf '%s\n' "$GATE_EXIT_3"; } > "$COPY"
  gate_exit_3_arm_holds "$COPY" && return 1
  # Failing state: auto mode no longer stops.
  sed 's|Stop the command, in auto mode too|Stop the command|' "$GATE_REF" > "$COPY"
  gate_exit_3_arm_holds "$COPY" && return 1
  # Failing state: the push prohibition dropped.
  sed 's|never push for them|push for them|' "$GATE_REF" > "$COPY"
  gate_exit_3_arm_holds "$COPY" && return 1
  # Failing state: the arm follows pull mode.
  insert_after "$GATE_REF" "$GATE_EXIT_3" 'Follow `pull-mode.md`.'
  gate_exit_3_arm_holds "$COPY" && return 1
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

STEP_9C='## Step 9c: Carry new setup features'

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

# --- The update commit ---------------------------------------------------------

# The commit subject is read back: fitness-nudge-lib.sh matches
# `chore(gaia): update to ` as a GAIA update commit.
COMMIT_QUESTION='Commit this update?'
COMMIT_CALL='git -C <acting tree> commit -m "chore(gaia): update to <LATEST_TAG>"'

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

SELECTOR_CALL='bash .gaia/scripts/update-gaia-preflight.sh select-notes --latest-dir <LATEST_DIR>'

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
