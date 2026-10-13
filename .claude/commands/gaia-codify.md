---
name: gaia-codify
description: Drafts a guard (deterministic check, skill, or path-scoped rule) for a recurring code-audit finding class, with approval. Reviews recurring Code Audit Team findings and drafts the lowest-context-weight form into the working tree.
disable-model-invocation: true
argument-hint: [review|list|why <finding_class>]
---

Run the GAIA **codify** workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command drafts repo-wide rules, checks, and skills into the working tree from a repo-wide finding tally. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-codify" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/codify.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `review`, `list`, or `why <finding_class>`). If no arguments were provided, follow the reference's no-argument path (which defaults to `review`).
