---
name: gaia-residue
description: Triages the keyed audit residue recorded in merged pull-request bodies. Enumerates candidates, resolves each one's cited line, and takes one disposition per entry (promote to a tech-debt issue, dismiss, or keep). Never fixes anything.
disable-model-invocation: true
---

Run the GAIA **residue** workflow.

## Pre-flight: Worktree check

This command publishes a branch and a pull request from a repo-wide read of every merged pull request. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-residue" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/residue.md` from the project root and follow it exactly.
