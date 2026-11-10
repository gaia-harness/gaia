---
name: tdd
description: Runs test-driven development with a red-green-refactor loop, an opt-in tool for logic where test-first helps. Use when the user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
---

# Test-Driven Development

An opt-in tool for logic where test-first helps, not a rule: the principle is Test What Matters (`.claude/rules/coding-guidelines.md`, section 3). The skill verifies its own red step: run the new test, see it fail for the right reason, then implement. No hook or ledger records it.

Contents: Selecting a Stack Reference; Philosophy; Anti-Pattern: Horizontal Slices; Workflow; Checklist Per Cycle.

## Selecting a Stack Reference

Before writing the first red test, consult the reference for your stack:

- **React / Vitest / MSW / Storybook** → the `tdd-react` skill (`apps/web/.claude/skills/tdd-react/SKILL.md`)
- **Shell / bats** → `.claude/skills/tdd/references/tests-shell.md`

Add a new stack reference (a skill or a `references/tests-{stack}.md`) when adopting a new stack. The stack reference covers concrete patterns, test layers, mocking rules, and good/bad examples specific to that environment.

## Philosophy

**Core principle**: tests verify behavior through public interfaces, not implementation details. Good tests are integration-style: they exercise real code paths through public APIs, read like a specification ("user submits a valid form and sees a success toast"), and survive refactors. A test that breaks on a behavior-preserving refactor is coupled to implementation.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation.** This is "horizontal slicing", treating RED as "write all tests" and GREEN as "write all code."

Tests written in bulk test _imagined_ behavior, not _actual_ behavior. You outrun your headlights, committing to structure before understanding the implementation, producing tests insensitive to real changes.

**Correct approach**: vertical slices via tracer bullets. One test → one implementation → repeat.

```
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
  ...
```

## Workflow

### 1. Planning

Before writing any code:

- [ ] Confirm which layer owns this test (see stack reference for layer breakdown)
- [ ] Confirm which behaviors to test (prioritize)
- [ ] Name the user-observable behaviors and the one acceptance test that owns each; one test may own several (not implementation steps, not one test per function)
- [ ] Get user approval on the plan with `AskUserQuestion`: `Approve the plan` (Recommended) or `Revise`

Ask: "What should the public interface look like? Which behaviors are most important to test?"

**You can't test everything.** Focus on critical paths and complex logic, not every edge case.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing end-to-end for this layer. `RED → GREEN`. The tracer bullet confirms the testing infrastructure wires up before adding real coverage.

### 3. Incremental Loop

For each behavior your task names (a plan's task doc, or the plan approved in step 1): `RED → GREEN`, extending the test that already owns it, if one does, rather than writing a second. Write a new test only for those behaviors and their acceptance tests, plus a unit test for logic meeting both unit-test conditions (`wiki/decisions/Test Layering.md`): the integration layer cannot cover its cases cheaply, and the logic is important or likely to fail. Only enough code to pass the current test. Don't anticipate future tests.

**Bound the green chase.** If a test won't pass after a few focused attempts, stop and reassess instead of thrashing the implementation: the test, the interface, or an assumption may be wrong. Surface the blocker rather than looping indefinitely to force green.

#### Running an honest red step

For every new test, run it before implementing and look at the failure: `pnpm -C <package dir> test --run <test-file>` (path relative to the package), or the stack reference's runner. It must fail for the right reason, an assertion that the missing behavior breaks (or the stub's throw), never a collection or import error.

**Author the test against a stub of the implementation symbol.** First write a stub of each new exported symbol the test imports, under its final name and with its final signature (async-ness, parameter and return types; a Promise-returning function is stubbed async, since type-aware lint on the test reads the signature), returning a wrong value (throwing only when the symbol has no return value to get wrong). Write the test against the stub, lint both, then run it: it fails on the assertion (or the stub's throw) because the implementation is missing. That failure is the honest red, not a manufactured one. Then write the implementation that turns it green. Never point the test at a module file that does not exist yet: vitest fails the file at collection, no test body runs, and nothing shows the test can fail.

```
RIGHT:  stub parseAmount() returning a wrong value → write the test → lint → run → fails on the assertion → implement → green
WRONG:  write the test importing a parse-amount module that does not exist → run → collection error, no honest red
WRONG:  implement parseAmount() → write the test → break parseAmount() to force red → restore it → green
```

**Never break working production code to force a red, then restore it.** Nothing enforces this, so it is an authoring obligation.

**Single-pass-author exemption.** When the implementation already exists in the same change with no prior failing observation (a single-pass author landing impl and test together), author the test honestly against the existing behavior and route it to the worthiness audit, exactly as an emergent test is routed.

### 4. Refactor

After all tests pass, refactor the code this cycle wrote:

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Run tests after each refactor step

Refactor only on GREEN.

### 5. Determinism Roll-up

After green, classify every touched source file and report the verdict. Classification is **per-file and silent**: never prompt the human to choose strict versus test-after, the classifier decides from the file's content.

Run the determinism classifier over each touched source file:

```
node .gaia/scripts/classifier/classify-determinism.mjs <repo-relative-source-path>
```

It emits `{file, classification: "strict" | "emergent" | "route", reasons}`. A `strict` file is on the deterministic surface, where the red step is easy to run and show; an `emergent` file is clock-/entropy-/I-O-bound or tree-dependent, with no stable failing-then-passing run; a `route` test gets both the red step and the worthiness audit.

**Emit one verdict line per touched file in the end-of-task summary, routine-looking ones included**: a silent misclassification (a pure-looking file the classifier marks emergent, or vice versa) stays auditable only if it appears as a named line.

```
Determinism roll-up:
  • apps/web/app/utils/money.ts            strict
  • apps/web/app/components/cart/tests/index.stories.tsx  emergent (story file: a *.stories.tsx is emergent regardless of path)
```

### 6. Worthiness Audit

A story is a visual state and a behavior is a `.test()` on it (`wiki/decisions/Stories as Tests.md`); a story file is emergent, so a behavior added as a `.test()` goes through the audit below.

On every surface the honesty proof is this skill's own red step plus the audit. The emergent surface (the `emergentTests` globs in the package descriptor `apps/web/gaia.package.json`) has no stable failing-then-passing run to show, so its honesty and worthiness come from an **advisory audit**. The audit judges every test the task changed that the worthiness selection names: emergent, route and strict tests on honesty and worth. Run it after green (the classifier roll-up above tells you which touched files are `strict`, `emergent` or `route`).

#### Dispatch and record

Run the `## The tdd arm` of `.claude/skills/gaia/references/worthiness-step.md` after green, over the test and story files the task changed. A genuine fresh-context evaluator judges them (the author shares their own blind spots, so an in-context self-review does not satisfy this step), and the arm records each verdict in the worthiness ledger. The arm dispatches the evaluator and records its verdicts only: it runs no repair, makes no commit and asks no question, since this skill runs on uncommitted work. Surface the verdicts in the same end-of-task summary (see "Surfacing the advisory findings").

#### Path-scoped guarantees

The guarantee this audit provides is scoped to **the subset a same-model fresh-context reviewer reliably flags**, not a proof of test worthiness. State the surviving guarantees by path:

- **No-orchestrator path (this skill alone), surviving guarantees:** static honesty lint on every test; the red step you ran and saw fail; the fresh-subagent worthiness audit **if it was dispatched**. On this path the audit is advisory and depends on this dispatch step running; a skipped dispatch leaves only the static lint, your own red step and the merge presence check.
- **Orchestrated path, additional guarantees (NOT available here):** leaf isolation enforced by the orchestrator. That is orchestrator-owned; the no-orchestrator path does not provide it. The merge presence gate (which recomputes signals and refuses a merge whose audit ledger is absent or mismatched) is a repo-wide hook that fires on every `gh pr merge`: see `wiki/concepts/PR Merge Workflow.md`, "Second merge gate: the worthiness presence gate".

### 7. Surfacing the advisory findings

Advisory findings (the worthiness verdicts) never interrupt mid-implementation. They surface only in the one end-of-task summary the determinism roll-up also renders into, before commit (no-orchestrator path), or in the orchestrator's `SUMMARY.md` plus the pre-merge summary (orchestrated path). A fix verdict is advisory only here: the pre-audit worthiness step of a plan run, the work lifecycle or `/gaia-debt` (`.claude/skills/gaia/references/worthiness-step.md`) acts on it before the audit.

#### Two tiers, capped

The summary presents advisory findings in two tiers:

- **HONESTY findings auto-fix.** A test that fails the honesty axis (couples to implementation, asserts a tautology, asserts platform bytes) is rewritten in place and left in the working tree for normal review. No confirmation prompt: the fix is a normal code edit the human reviews like any other.
- **Every proposed DELETE requires human confirmation and renders its evidence INLINE.** A delete is never acted on. Each proposed delete renders, in the summary, the cited redundant sibling assertion AND the subsuming seam assertion that makes it redundant, so the human confirms against the evidence without opening files. Ask each confirmation with `AskUserQuestion`, one delete per question and up to 4 questions per call: `Confirm the delete` (Recommended) or `Keep the test`. A delete whose cited sibling cannot be machine-verified is downgraded, never shown as a delete.

Cap the list: show the **top-N by severity with a count** (`delete` proposals before `fix` findings; "3 of 11 findings shown"), never a wall of every line.

#### Where it renders

- **No-orchestrator path (main loop):** one end-of-task summary before commit, sharing the surface with the determinism roll-up and the worthiness verdicts.
- **Orchestrated path:** the same two-tier content goes into the leaf's `SUMMARY.md` ledger entry and the pre-merge summary, so the merge presence gate and the human reviewer see the deletes and their inline evidence before a merge.

## Checklist Per Cycle

```
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only (no spying on internals)
[ ] Test would survive an internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
[ ] Mock only at system boundaries (network, time, randomness)
```
