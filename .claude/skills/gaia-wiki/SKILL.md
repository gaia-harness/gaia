---
name: gaia-wiki
description: Runs GAIA wiki maintenance (sync, consolidate, lint with fixes) in one command and lands it as one commit and PR. Trigger on `/gaia-wiki` or natural-language asks like "sync the wiki", "run wiki maintenance", "consolidate the wiki", or "lint the wiki".
---

Run the GAIA **wiki** maintenance workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command rewrites tracked `wiki/` content and its state file for the whole repository, and lands them through a pull request of its own. It starts from the main checkout and isolates its own work before its first write, through `.claude/skills/gaia/references/isolation.md`, so it never writes onto the branch the checkout holds. A linked worktree holds someone else's work, so if invoked from one, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-wiki" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Anchor for the next pre-flight step: a check that must pass before this command starts goes here, after the worktree check and before the workflow dispatch line.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-wiki"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-wiki`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

Read `.claude/skills/gaia/references/wiki.md` from the project root and follow it exactly. The reference takes no arguments; when arguments were given above, it prints one notice naming them and runs sync, consolidate, and lint anyway.
