---
name: gaia-plan
description: Plans a complex feature with GAIA's task-orchestration pattern, structuring the work into fresh-context subagent phases for approval. Does not implement. Use when the user asks to plan a feature, break work into phases, or turn a SPEC into an execution plan.
argument-hint: "[auto] [feature description]"
---

**Ask first when Claude picked this.** When Claude started this command from a request that asked for neither a spec nor a plan, ask the question in `.claude/skills/gaia/references/work-lifecycle.md` (`## Spec, plan or proceed`) with this command recommended, before anything below: on the recommended answer continue here, and on `Just do it` leave this command and go on at that page's step 1. No question for a typed or pasted command, an answer to that question, an `auto` argument, a SPEC id, an unattended run, or a workflow instruction that names this command, such as the plan `/gaia-spec` chains.

Run the GAIA **plan** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/plan.md` from the project root and follow it exactly. Treat the arguments above as the reference's `$ARGUMENTS`.

`plan.md` routes a run to these. Read one only when a line in `plan.md` says to, and then read the whole file:

- `.claude/skills/gaia/references/spec/lifecycle.md`: step 0's pre-flight sweep.
- `.claude/skills/gaia/references/plan/decomposition-audit.md`: step 4.6, when the gauge runs the audit.
- `.claude/skills/gaia/references/spec/lens-dispatch.md`: step 4.6, with the audit.
- `.claude/skills/gaia/references/plan/planner.md`: never read on this thread; the planner sub-agent spawned at step 4 reads it first.
- `.claude/skills/gaia/references/spec/uat-write.md`, `.claude/skills/gaia/references/spec/uat-divergence.md`, `.claude/skills/gaia/references/spec/wiki-promote.md`: never read on this thread; `planner.md` routes the planner to each at the step that needs it.
