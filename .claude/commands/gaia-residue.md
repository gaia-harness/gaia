---
name: gaia-residue
description: Triages the keyed audit residue recorded in merged pull-request bodies. Enumerates candidates, resolves each one's cited line, and takes one disposition per entry (promote to a tech-debt issue, dismiss, or keep). Never fixes anything.
disable-model-invocation: true
---

Run the GAIA **residue** workflow.

## Pre-flight: Worktree check

This command publishes a branch and a pull request from a repo-wide read of every merged pull request. It starts from the main checkout and isolates its own work right before its first write, through `.claude/skills/gaia/references/isolation.md`, so it never writes onto the branch the checkout holds. A linked worktree holds someone else's work, so if invoked from one, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-residue" || exit 1
```

Anchor for the next pre-flight step: a check that must pass before this command starts goes here, after the worktree check and before the workflow dispatch line.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-residue"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-residue`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

Read `.claude/skills/gaia/references/residue.md` from the project root and follow it exactly.
