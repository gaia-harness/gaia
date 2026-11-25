#!/usr/bin/env bats
#
# Doc-pin: the pull gate stands at every fresh start of a command that creates
# a branch, a worktree, a claim or a SPEC id, and nowhere a resume or an exempt
# command runs.
#
#   1. Presence: each gated file calls `gaia_pull_gate "<its command>"` exactly
#      once, and one line of the file names pull-gate.md and the exit code the
#      reader follows it on.
#   2. Order: the gate line comes after the file's own earlier step (its
#      worktree refusal, the interrupted update-worktree check, the claim
#      heading) and before the first creation marker named for that file.
#      A command file whose creation happens in its reference body is ordered
#      against the line that dispatches to that reference.
#   3. Exemptions: no exempt or resume-path file calls the gate.
#
# The files are named in the arrays below, so a file added to the gated set
# without a row here is caught by the reviewer of that change, not by a tree
# walk. A named file that is missing fails its check.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  DISPATCH='Read `.claude/skills/gaia/references/'
  REFUSAL='gaia_refuse_if_worktree "'
  # file|command|the earlier step the gate follows|the first creation marker it precedes|exit phrase
  GATED=(
    "$REFERENCES/spec.md|/gaia-spec|### 3. Allocate, anchor, stamp|spec-allocator.sh next|exit code"
    "$REFERENCES/plan.md|/gaia-plan|### 0. Pre-flight sweep|plan-allocator.sh next|exit code"
    "$REFERENCES/plan/orchestrator-template.md|/gaia-plan|**Resume detection (cold-start|## Pre-flight isolation|non-zero exit"
    ".claude/commands/gaia-debt.md|/gaia-debt|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-codify.md|/gaia-codify|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-cleanse.md|/gaia-cleanse|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-fitness.md|/gaia-fitness|$REFUSAL|$DISPATCH|exit code"
    ".claude/commands/gaia-residue.md|/gaia-residue|$REFUSAL|$DISPATCH|exit code"
    ".claude/skills/gaia-wiki/SKILL.md|/gaia-wiki|$REFUSAL|$DISPATCH|exit code"
    ".claude/skills/update-deps/SKILL.md|/update-deps|refs/heads/deps/|## Package layout|exit code"
    "$REFERENCES/work-lifecycle.md|ad-hoc work|## 1. Claim|## 2. Name|exit code"
  )
  # Files that never run the gate, each with its reason.
  UNGATED=(
    # Exempt commands: updating, setup, tooling and release flows.
    ".claude/commands/setup-gaia.md"
    ".claude/commands/gaia-forensics.md"
    ".claude/commands/gaia-release.md"
    ".claude/skills/update-gaia/SKILL.md"
    ".claude/skills/release-notes/SKILL.md"
    "$REFERENCES/forensics.md"
    "apps/web/.claude/skills/gaia-react-perf/SKILL.md"
    "wiki/concepts/PR Merge Workflow.md"
    # A residue resume (after /clear, or an owed run) bypasses the slash
    # command and never starts fresh work, so its reference stays ungated.
    "$REFERENCES/residue.md"
  )
}

# first_line <file> <fixed string>: the line number of the first line holding it, or 0.
first_line() {
  local number
  number="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  printf '%s\n' "${number:-0}"
}

# check_presence <root>
check_presence() {
  local root="$1" row file command earlier later phrase failed=0 calls sentence
  for row in "${GATED[@]}"; do
    IFS='|' read -r file command earlier later phrase <<<"$row"
    if [ ! -f "$root/$file" ]; then
      printf 'presence: %s missing\n' "$file"
      failed=1
      continue
    fi
    calls="$(grep -cF -- "gaia_pull_gate \"$command\"" "$root/$file" || true)"
    if [ "$calls" -ne 1 ]; then
      printf 'presence: %s calls gaia_pull_gate "%s" %s times, expected 1\n' "$file" "$command" "$calls"
      failed=1
      continue
    fi
    sentence="$(grep -F -- 'pull-gate.md' "$root/$file" | grep -F -- "$phrase" || true)"
    if [ -z "$sentence" ]; then
      printf 'presence: %s has no line naming pull-gate.md and "%s"\n' "$file" "$phrase"
      failed=1
    fi
  done
  return "$failed"
}

# check_order <root>
check_order() {
  local root="$1" row file command earlier later phrase failed=0 gate before after
  for row in "${GATED[@]}"; do
    IFS='|' read -r file command earlier later phrase <<<"$row"
    [ -f "$root/$file" ] || { printf 'order: %s missing\n' "$file"; failed=1; continue; }
    gate="$(first_line "$root/$file" "gaia_pull_gate \"$command\"")"
    before="$(first_line "$root/$file" "$earlier")"
    after="$(first_line "$root/$file" "$later")"
    if [ "$gate" -eq 0 ] || [ "$before" -eq 0 ] || [ "$after" -eq 0 ]; then
      printf 'order: %s lacks the gate (%s), its earlier step (%s) or its creation marker (%s)\n' \
        "$file" "$gate" "$before" "$after"
      failed=1
      continue
    fi
    if [ "$before" -ge "$gate" ] || [ "$gate" -ge "$after" ]; then
      printf 'order: %s must hold the earlier step (line %s), the gate (line %s), then the creation marker (line %s)\n' \
        "$file" "$before" "$gate" "$after"
      failed=1
    fi
  done
  return "$failed"
}

# check_ungated <root>
check_ungated() {
  local root="$1" file failed=0
  for file in "${UNGATED[@]}"; do
    if [ ! -f "$root/$file" ]; then
      printf 'ungated: %s missing\n' "$file"
      failed=1
      continue
    fi
    if grep -qF -- 'gaia_pull_gate' "$root/$file"; then
      printf 'ungated: %s calls gaia_pull_gate\n' "$file"
      failed=1
    fi
  done
  return "$failed"
}

# --- the checks on the real tree -----------------------------------------

# bats test_tags=whole-tree
@test "each gated file calls the gate once and names pull-gate.md with the exit code" {
  run check_presence "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "each gate follows its earlier step and precedes the first creation marker" {
  run check_order "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "no exempt or resume-path file calls the gate" {
  run check_ungated "$REPO_ROOT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
