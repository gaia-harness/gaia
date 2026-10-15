---
name: gaia-codify
description: Drafts a guard (deterministic check, skill, or path-scoped rule) for a recurring code-audit finding class, with approval. Reviews recurring Code Audit Team findings and drafts the lowest-context-weight form into the working tree.
disable-model-invocation: true
---

Run the GAIA **codify** workflow.

## Pre-flight: Worktree check

This command drafts repo-wide rules, checks, and skills into the working tree from a repo-wide finding tally. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-codify" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/codify.md` from the project root and follow it exactly.
