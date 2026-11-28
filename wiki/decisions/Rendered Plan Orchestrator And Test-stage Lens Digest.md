---
type: decision
status: active
created: 2026-11-25
updated: 2026-11-28
promoted_at: 2026-11-24T17:31:01Z
promoted_hash: sha256:902cfa2598450d0653549a7d8b48466b46ec037c213d0dade68950e2f788006f
pr_number: 3821
tags: [promoted, decisions]
---
# Rendered plan orchestrator and test-stage lens digest

A plan's `ORCHESTRATOR.md` and `KICKOFF.md` are assembled by a script from one template and a short parts file the planner writes, and the test-stage review lens reads a script-written digest of the test lists before anything else. Both changes shrink what a dispatch holds in context; every lens, check and gate runs unchanged.

## Decisions

The fixed orchestrator blocks and the generic sections that are identical in every plan but for paths and branch live in `.claude/skills/gaia/references/plan/orchestrator-template.md`, their one source. The planner no longer loads or retypes them: `planner.md` names no template path and holds no fixed block. The planner writes `<PLAN_DIR>/orchestrator-parts.md` with six parts (`## Title` with its `Type:` and `Slug:` lines, an optional `## Pushes`, `## Phase loop`, `## Phase entries`, `## Kickoff goal`, `## Kickoff outline`) and runs `.gaia/scripts/spec/orchestrator-render.sh`, whose header owns the parts grammar, the template grammar, the re-render flags and the refusals. The renderer writes both files to temporary files and replaces them only on success, so a failed render leaves no partial file. The parts file stays in the plan folder, and re-rendering it reproduces both files byte for byte.

`plan-verify.sh` reads the same template as its block source, so the planner's output and the verifier's expectation cannot drift apart. It refuses once, by name, when the template is missing, and checks the four path and branch placeholders.

The renderer is a bash script beside `plan-verify.sh`, not a CLI command: assembling text needs no TypeScript, test runner or bundle rebuild, and `plan-verify.sh` already extracts these fences with awk.

The test stage is the only other writer of the parts file. It writes each closing phase entry, each `- Security writer:` line and one `## Kickoff outline` line into `orchestrator-parts.md`, and edits any phase gate that runs a test before its placed phase, replacing the previous closing entry on a re-run, then re-renders; it never edits `ORCHESTRATOR.md` or `KICKOFF.md`. A plan folder with no `orchestrator-parts.md`, saved before rendering existed, halts the test stage before any edit with a one-line pointer to re-plan with `/gaia-plan`.

After clearing its findings folder, the test stage runs `test-stage-check.mjs --digest`, which writes `test-stage-findings/digest.md` and prints its sha256: the plan's test lines, what they must prove (the SPEC's behaviors and flows, or a spec-less plan's acceptance criteria), the task-graph rows and the phase entries, each under a line naming its source path, in the order the header of `.gaia/scripts/spec/test-stage-digest.mjs` owns. The task-graph rows and phase entries let the lens check that each test sits in a phase that delivers what it asserts. The model never writes digest content. The stage re-hashes the digest before every lens dispatch, a re-dispatch after a no-op included, and dispatches on the digest only when the file exists and the hash matches; otherwise it prints one line and gives the lens the whole plan as before. The lens's first read is the digest, and it opens other plan files by path only when a judgment needs them. A test-stage no-op re-clear removes only `TST.json`, so the digest survives a re-dispatch. The digest is an index of where the test lines live, never a replacement for the SPEC's behaviors as the source of expected outcomes.

## Divergence

The original design also moved the auto-mode plan stage and the test stage that follows it into off-thread runners with a fresh context, so their turns would not replay the whole spec session. That part is not built. A measured chained run put the runner's plan-stage saving at 0 to 2 percent of the run's cost, too small to justify two agent files, a third depth-2 dispatch site and a runner report contract. The plan and test stages still run in the invoking session in both interactive and auto mode.
