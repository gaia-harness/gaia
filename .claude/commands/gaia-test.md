---
name: gaia-test
description: Designs the tests of a saved plan as a short per-task list and a closing flow-test phase, checks them against the SPEC's stated behaviors, and records the stage. Use when the user asks to design, list or redo the tests of a plan.
argument-hint: "[auto] [SPEC-NNN | plan dir]"
---

Run the GAIA **test stage** with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/test-stage.md` from the project root and follow it exactly. Treat the arguments above as the reference's arguments. It runs on a plan already saved by `/gaia-plan`.

`test-stage.md` routes a run to this. Read it only when the reference says to, and then read the whole file:

- `.claude/skills/gaia/references/spec/lens-dispatch.md`: the review lens's shared preamble and test-stage column.
