---
type: concept
title: Test Stage
status: active
created: 2026-11-18
updated: 2026-11-24
tags: [concept, claude, skill, testing, plan]
---

# Test Stage

The test stage designs a plan's tests after the plan is written: a short list of tests per task, a closing flow-test phase for a spec-derived plan, and one review lens that checks the lists against the SPEC. `/gaia-plan` offers it as its last step and it is on by default; `/gaia-test [auto] [<SPEC-ID> | <plan dir>]` runs it alone on a saved plan. The procedure, the line forms and the cap live in `.claude/skills/gaia/references/test-stage.md`; this page holds why the stage is separate.

## Why it is a separate stage

Plans stopped paying for test design. A test table inside the plan made the planner, the plan review and every later check carry a second artifact that had to agree with the task docs, and the checks around it cost more than the tests they protected. The planner now plans tasks only, from the SPEC's stated behaviors, and test design is its own step with its own target: at most one test per stated behavior, at the cheapest layer that proves it, with flow tests outside the cap. Measuring the stage on that target alone is what keeps it honest, because its output is a list a script can check against the SPEC rather than a table a judge must read.

The SPEC owns the requirements. Its `## Behaviors` section states each behavior with an id, a kind and its cases (`.claude/skills/gaia/references/spec/spec-template.md`), and expected behaviors come only from those; when the SPEC folder holds a code map, it serves only to locate existing tests. A spec-less plan has no behavior ids, so the stage names each task's acceptance criteria instead.

## What it writes

- A `## Tests` section in each task doc, one line per test naming the behavior, the layer, the security kind and the test's file and title.
- For a spec-derived plan, a closing phase with one task per SPEC flow, each carrying one flow test line.
- A `TEST-STAGE` record in the plan folder: `running` before any line is written, `ran` only after the checks pass, `skipped` when the user skips. `.gaia/scripts/spec/flow-coverage.sh` and `.gaia/scripts/spec/plan-verify.sh` read it, and a skipped or absent stage reports each flow as a gap instead of a finding.

## Checks

`.gaia/scripts/spec/test-stage-check.mjs` is the deterministic floor: well-formed lines, ids the SPEC states, a test for every security, refusal and data-loss behavior and for every flow, and no two tests of one behavior at one layer. One review lens (`TST`) checks what a script cannot, that each listed test proves a behavior the SPEC states and that the cap holds. The lens dispatches through `.claude/skills/gaia/references/spec/lens-dispatch.md`.

## Security tests

A test whose behavior kind is `access`, `forgery` or `secret` carries that kind, and the phase's orchestrator entry names a security writer line. A separate agent writes those tests from the stated rule, never from the code, so a test cannot repeat the code's mistake (`.claude/skills/gaia/references/security-writer.md`). Skipping the stage skips those tests with it.

## Cost

The stage records its own `gaia-test` run in the usage ledger, separate from the `gaia-plan` run, so a spec's initiative readout shows the spec, plan and test stage as three lines ([[Usage Ledger]]).

## Related

- [[GAIA Plan]]: offers the stage after its review.
- [[GAIA Spec]]: the behaviors the stage reads.
- [[Task Orchestration]]: the closing flow-test phase and the security writer in a plan run.
- [[Worthiness Audit]]: judges the tests that were written, after the build.
- [[Testing Trophy Doctrine]] and [[Test Layering]]: the reasons behind the layer rules.
