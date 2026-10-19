---
name: gaia-codify
description: Drafts a guard (deterministic check, skill, or path-scoped rule) for a recurring code-audit finding class, with approval. Reviews recurring Code Audit Team findings and drafts the lowest-context-weight form into the working tree.
disable-model-invocation: true
---

Run the GAIA **codify** workflow.

## Pre-flight: Worktree check

This command drafts repo-wide rules, checks, and skills from a repo-wide finding tally and publishes them through a pull request of its own. It starts from the main checkout and isolates its own work right before its first write, through `.claude/skills/gaia/references/isolation.md`, so it never writes onto the branch the checkout holds. A linked worktree holds someone else's work, so it refuses to run in one (`gaia_refuse_if_worktree`, `.gaia/scripts/main-only-lib.sh`).

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-codify" || exit 1
```

Anchor for the next pre-flight step: a check that must pass before this command starts goes here, after the worktree check and before the workflow dispatch line.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-codify"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-codify`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

Read `.claude/skills/gaia/references/codify.md` from the project root and follow it exactly.
