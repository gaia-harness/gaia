---
name: gaia-cleanse
description: Cleanses memory and auto-loaded files (CLAUDE.md, rules) of duplication with the wiki, contradictions with the wiki, and stale content, then asks one Apply / Discuss / Decline question; on Apply it applies the report, files any out-of-scope problem as a tech-debt issue, then commits, opens a PR, and merges it on a main-branch run like /update-deps. Pass --apply to re-run the apply-and-publish stage against the most recent report. Use when the user asks to cleanse or clean up memory, CLAUDE.md, or rules for duplication, contradictions with the wiki, or stale instructions. For duplication or broken links inside the wiki itself, use /gaia-wiki instead.
argument-hint: "[--apply] [scope-hint]"
---

Run the GAIA **cleanse** workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command applies a repo-wide report, opens a pull request, and merges it. It starts from the main checkout (the clone's primary working directory, on any branch) and isolates its own work right before its first write, through `.claude/skills/gaia/references/isolation.md`, so it never writes onto the branch the checkout holds. A linked worktree holds someone else's work, so it refuses to run from one. Run this first, before anything else; a non-zero exit is the refusal: relay it and stop.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-cleanse" || exit 1
```

Anchor for the next pre-flight step: a check that must pass before this command starts goes here, after the worktree check and before the workflow dispatch line.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-cleanse"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-cleanse`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

Read `.claude/skills/gaia/references/cleanse.md` from the project root and follow it exactly, with the arguments above as its input (none: its default research-then-gate path). Its Apply / Discuss / Decline gate MUST run here in the main conversation, not in a subagent, because only this layer can prompt the user.
