---
name: gaia-wiki
description: Runs GAIA wiki maintenance (sync, consolidate, lint with fixes) in one command and lands it as one commit and PR. Trigger on `/gaia-wiki` or natural-language asks like "sync the wiki", "run wiki maintenance", "consolidate the wiki", or "lint the wiki".
---

Run the GAIA **wiki** maintenance workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command rewrites tracked `wiki/` content and its state file for the whole repository, and lands them through a pull request of its own. It starts from the main checkout (the clone's primary working directory, on any branch) and isolates its own work before its first write, through `.claude/skills/gaia/references/isolation.md`, so it never writes onto the branch the checkout holds. A linked worktree holds someone else's work, so it refuses to run from one. Run this first, before anything else; a non-zero exit is the refusal: relay it and stop.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-wiki" || exit 1
```

Anchor for the next pre-flight step: a check that must pass before this command starts goes here, after the worktree check and before the workflow dispatch line.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-wiki"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-wiki`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

Read `.claude/skills/gaia/references/wiki.md` from the project root and follow it exactly.
