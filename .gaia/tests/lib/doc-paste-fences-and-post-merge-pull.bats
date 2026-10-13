#!/usr/bin/env bats
#
# Doc-conformance suite for two operator-facing contracts:
#
#   a. every prompt, command or line GAIA hands the user to copy and paste is
#      printed inside a fenced code block, and the always-loaded rule saying so
#      lives in .claude/rules/context-discipline.md;
#   b. the post-merge worktree cleanup pulls `main` into the main checkout only
#      when that checkout is on `main`, and still runs no `git checkout`.
#
# Every check is a function taking a root laid out like the repository, so the
# red twins run the same function against a mutated scratch copy: removing a
# site's fence, or its pull, has to turn that site's check red.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  RUNBOOK='wiki/concepts/PR Merge Workflow.md'
  PULL='pull --ff-only origin main'
}

# section <file> <heading prefix>: prints the section whose heading line starts
# with the prefix, up to the next heading of the same or a higher level. Lines
# inside a fence are never read as headings, since a `# comment` in a bash
# fence would otherwise end the section early.
section() {
  awk -v want="$2" '
    /^[[:space:]]*```/ { fenced = !fenced }
    !found && !fenced && index($0, want) == 1 {
      found = 1; match($0, /^#+/); level = RLENGTH; print; next
    }
    found && !fenced && /^#+ / { match($0, /^#+/); if (RLENGTH <= level) exit }
    found { print }
  ' "$1"
}

# fence_bodies <info string>: reads text on stdin and prints the lines inside
# every fence opened with exactly that info string, at any indentation.
fence_bodies() {
  awk -v info="$1" '
    !open && $0 ~ ("^[[:space:]]*```" info "$") { open = 1; next }
    open && /^[[:space:]]*```[[:space:]]*$/ { open = 0; next }
    open { print }
  '
}

# scratch_copy: copies every file this suite reads into a scratch root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" relative
  rm -rf "$copy"
  for relative in \
    .claude/rules/context-discipline.md \
    "$REFERENCES/plan.md" \
    "$REFERENCES/plan/planner.md" \
    "$REFERENCES/spec.md" \
    "$REFERENCES/isolation.md" \
    "$REFERENCES/debt/spec-handoff.md" \
    "$REFERENCES/debt/worktree-cleanup.md" \
    .claude/skills/update-gaia/references/merge-execution.md \
    .claude/hooks/audit-loop-bound.sh \
    "$RUNBOOK"; do
    mkdir -p "$copy/$(dirname "$relative")"
    cp "$REPO_ROOT/$relative" "$copy/$relative"
  done
  printf '%s\n' "$copy"
}

# --- a. the rule and the print sites -----------------------------------------

rule_line() {
  grep -qF -- 'A prompt, command or line the user is meant to copy and paste is printed inside a fenced code block' \
    "$1/.claude/rules/context-discipline.md" || return 1
  grep -qF -- 'fence it with four backticks' "$1/.claude/rules/context-discipline.md" || return 1
  grep -qF -- 'carries its own context' "$1/.claude/rules/context-discipline.md"
}

plan_kickoff_prompt() {
  section "$1/$REFERENCES/plan.md" '### 5. Report to user' | fence_bodies text |
    grep -qF -- 'Read <absolute-path-to-PLAN_DIR>/KICKOFF.md and execute it.'
}

planner_continuation_prompt() {
  section "$1/$REFERENCES/plan/planner.md" '## Plan files' | fence_bodies text |
    grep -qF -- 'is ready to discard.'
}

debt_continuation_prompt() {
  section "$1/$REFERENCES/debt/worktree-cleanup.md" '### Isolation-context detection' | fence_bodies text |
    grep -qF -- 'is ready to discard.'
}

spec_model_switch_line() {
  section "$1/$REFERENCES/spec.md" '### Model gate' | fence_bodies text | grep -qE -- '^[[:space:]]*/gaia-spec <description>$'
}

spec_plan_handoff() {
  section "$1/$REFERENCES/spec.md" '### 11.' | sed 's/^> \{0,1\}//' | fence_bodies '' |
    grep -qxF -- '/gaia-plan SPEC-NNN'
}

debt_spec_handoff() {
  fence_bodies text <"$1/$REFERENCES/debt/spec-handoff.md" | grep -qF -- '/gaia-spec Design-first tech debt from issue #<N>'
}

update_gaia_follow_up_commands() {
  local file="$1/.claude/skills/update-gaia/references/merge-execution.md"
  grep -qF -- 'printed beneath the table inside a fenced code block' "$file" || return 1
  grep -qF -- 'to run by hand, printed inside a fenced code block' "$file" || return 1
  grep -qF -- 'the literal command from its `argv`, printed inside a fenced code block' "$file"
}

unattended_grant_line() {
  grep -qF -- 'print the typed grant line above inside a fenced code block' "$1/.claude/hooks/audit-loop-bound.sh" || return 1
  grep -qF -- "\`grant_line\` and no continuation prompt, the line alone in a fenced code block" "$1/$RUNBOOK"
}

FENCE_SITES=(rule_line plan_kickoff_prompt planner_continuation_prompt debt_continuation_prompt
  spec_model_switch_line spec_plan_handoff debt_spec_handoff update_gaia_follow_up_commands unattended_grant_line)

@test "every paste site prints inside a fence, and the always-loaded rule says so" {
  local site
  for site in "${FENCE_SITES[@]}"; do
    "$site" "$REPO_ROOT" || { echo "site not fenced: $site" >&2; return 1; }
  done
}

@test "red twin: unfencing the copies turns every fence site red" {
  local copy site file
  copy="$(scratch_copy)"
  # Drop every fence opener and closer, and every fence wording the rule and
  # prose sites carry, so each site's own check has nothing left to find.
  while IFS= read -r file; do
    sed -e '/^[[:space:]]*>\{0,1\}[[:space:]]*```/d' -e 's/inside a fenced code block//' \
      -e 's/in a fenced code block//' "$file" >"$file.new"
    mv "$file.new" "$file"
  done < <(find "$copy" -type f)
  for site in "${FENCE_SITES[@]}"; do
    if "$site" "$copy"; then
      echo "site stayed green after unfencing: $site" >&2
      return 1
    fi
  done
}

# --- b. the pull after a worktree merge --------------------------------------

worktree_arm_pulls() {
  local arm
  arm="$(section "$1/$RUNBOOK" '### Cleanup under worktree isolation')"
  fence_bodies bash <<<"$arm" | grep -qF -- "git -C <main-checkout> $PULL" || return 1
  grep -qF -- 'prints `main`' <<<"$arm" || return 1
  grep -qiF -- 'never force or stash' <<<"$arm"
}

worktree_arm_has_no_checkout() {
  local arm
  arm="$(section "$1/$RUNBOOK" '### Cleanup under worktree isolation')"
  [ -n "$(fence_bodies bash <<<"$arm")" ] || return 1
  if fence_bodies bash <<<"$arm" | grep -qE -- 'git( -C [^ ]+)? (checkout|switch)'; then
    return 1
  fi
}

isolation_removal_pulls() {
  local removal
  removal="$(section "$1/$REFERENCES/isolation.md" '### Post-merge removal')"
  grep -qF -- 'rev-parse --abbrev-ref HEAD' <<<"$removal" || return 1
  grep -qF -- "git -C <main root> $PULL" <<<"$removal"
}

continuation_prompts_pull() {
  section "$1/$REFERENCES/plan/planner.md" '## Plan files' | fence_bodies text | grep -qF -- "$PULL" || return 1
  section "$1/$REFERENCES/debt/worktree-cleanup.md" '### Isolation-context detection' | fence_bodies text |
    grep -qF -- "$PULL"
}

main_checkout_paragraph_uses_digest() {
  local paragraph
  paragraph="$(grep -F -- '**Read what the main checkout is holding' "$1/$RUNBOOK")"
  [ -n "$paragraph" ] || return 1
  section "$1/$RUNBOOK" '## Post-merge verification before cleanup' | grep -qF -- 'audit-member-digest.sh --root <root> --member <member>' || return 1
  if section "$1/$RUNBOOK" '## Post-merge verification before cleanup' | grep -qF -- "marker body's \`tree\` field"; then
    return 1
  fi
}

debt_pointer_names_planner() {
  grep -qF -- '`plan/planner.md`' "$1/$REFERENCES/debt/worktree-cleanup.md" || return 1
  if grep -qF -- "matches \`plan.md\`" "$1/$REFERENCES/debt/worktree-cleanup.md"; then return 1; fi
}

@test "the worktree arm pulls main only when the main checkout holds main, and never forces" {
  worktree_arm_pulls "$REPO_ROOT"
}

@test "red twin: a worktree arm without the pull fails" {
  local copy
  copy="$(scratch_copy)"
  grep -vF -- "$PULL" "$copy/$RUNBOOK" >"$copy/runbook.new"
  mv "$copy/runbook.new" "$copy/$RUNBOOK"
  run worktree_arm_pulls "$copy"
  [ "$status" -ne 0 ]
}

@test "the worktree arm's fences still carry no git checkout" {
  worktree_arm_has_no_checkout "$REPO_ROOT"
}

@test "red twin: a git checkout inside the worktree arm's fence fails" {
  local copy
  copy="$(scratch_copy)"
  awk -v pull="$PULL" 'index($0, "git -C <main-checkout> " pull) { print "git -C <main-checkout> checkout main" } { print }' \
    "$copy/$RUNBOOK" >"$copy/runbook.new"
  mv "$copy/runbook.new" "$copy/$RUNBOOK"
  run worktree_arm_has_no_checkout "$copy"
  [ "$status" -ne 0 ]
}

@test "isolation.md's post-merge removal reads the main checkout's HEAD and pulls" {
  isolation_removal_pulls "$REPO_ROOT"
}

@test "red twin: a post-merge removal without the pull fails" {
  local copy
  copy="$(scratch_copy)"
  grep -vF -- "$PULL" "$copy/$REFERENCES/isolation.md" >"$copy/isolation.new"
  mv "$copy/isolation.new" "$copy/$REFERENCES/isolation.md"
  run isolation_removal_pulls "$copy"
  [ "$status" -ne 0 ]
}

@test "both worktree continuation prompts carry the pull" {
  continuation_prompts_pull "$REPO_ROOT"
}

@test "red twin: a continuation prompt without the pull fails" {
  local copy file
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES/debt/worktree-cleanup.md"
  grep -vF -- "$PULL" "$file" >"$file.new"
  mv "$file.new" "$file"
  run continuation_prompts_pull "$copy"
  [ "$status" -ne 0 ]
}

@test "the main-checkout read keys a monitor on the member digest, not the marker tree field" {
  main_checkout_paragraph_uses_digest "$REPO_ROOT"
}

@test "worktree-cleanup.md points at plan/planner.md for the matching prompt" {
  debt_pointer_names_planner "$REPO_ROOT"
}
