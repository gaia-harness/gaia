---
name: gaia-fitness
description: Lints this project's Claude integration (skills, commands, agents, rules, hooks, settings, CLAUDE.md files, wiki) with a deterministic rule catalog and reports an F-to-A+ grade, plus Claude Code built-in results and an advisory model judgment of descriptions, trigger overlap, rule scope and terminology. Proposes fixes for project-owned files only and applies each one only on a per-file yes, then offers to publish. Use when the user asks to check, grade or tidy their Claude setup.
disable-model-invocation: true
---

Run the GAIA **fitness** workflow.

## Pre-flight: Worktree check

This command heals this clone's Claude integration in place and reports a grade for the clone. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-fitness" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/fitness.md` from the project root and follow it exactly.
