---
type: decision
status: active
created: 2026-11-05
updated: 2026-11-11
promoted_at: 2026-11-05T08:13:38Z
promoted_hash: sha256:cf8eb56c3735344b9960e004fee01598fec3ef8368da70e944859d1461fbbb2f
pr_number: 3316
tags: [promoted, decisions]
---
# Testing Trophy Doctrine

GAIA places tests by the testing trophy: write tests, not too many, mostly integration. The planner, the executors, the worthiness review and the overlap pass all serve that rule, so a build writes the tests its behaviors need and no more. The doctrine decides which tests get written; a test proves it can fail by its author's own failing run and by the worthiness audit. The rule itself lives in [[Test Layering]].

## Decisions

The doctrine replaces "every check lives at the lowest layer that can prove it". That axiom, together with references that asked for one test per behavior and a planner that asked for one criterion per guard, led executors to write a unit test for nearly every function. In pre-release tuning builds, test work cost about as much generation as the feature code, and most of the builder's unit tests repeated what an acceptance test already proved. The trophy keeps what the old rule got right, that a browser is the most expensive layer, and drops the push of every check down to a unit test.

Five mechanisms carry the decision:

- **Placement rule.** The route layer is the default home for behavior. A unit test is written only when both unit-test conditions hold: the integration layer cannot cover its cases cheaply, and the logic is important or likely to fail. At most one test covers a user-observable behavior, and a parameterized table counts as one test. [[Test Layering]] defines each term, and the tdd skill, the React testing reference, the Storybook rule, the planner, the SPEC template and self-review point at that page rather than restating it.
- **Vertical slices.** The planner cuts each build phase as a vertical slice that delivers a behavior end to end. A spec-derived plan then closes with one phase of flow tests, one per critical flow, written by the implementer after the build. Task docs name no test per function, and a guard is driven to its failing state by the build task's own test at the lowest layer that shows the refusal, never by the closing flow test.
- **Named tests only.** A task doc names a test only for the flow test it owns, a seam test its behavior needs (a route test, or the real-server check [[Test Layering]] calls for), the guard tests that drive each guard, refusal, validation or gate it delivers to its failing state, or a unit test meeting both conditions. Any other test worth having goes into the plan's follow-ups, not the tree. Test-first with the tdd skill is an opt-in tool, not a rule.
- **A worth check on every new test.** The worthiness selection covers the package descriptor's `emergentTests` and `tddUnitTests` globs together, and the shipped descriptor's `emergentTests` includes the app's test helper folder. A test the determinism classifier labels strict is judged on honesty and worth like any changed test; the worthiness audit judges whether it can fail. The merge-time presence gate shares the selection, so a pull request adding such a test is denied at merge until the worthiness step has recorded a verdict for it ([[Worthiness Audit]], [[Worthiness Presence Gate]]).
- **Overlap fold-up and a reason-gated unit demote.** The overlap pass runs whenever a branch changed a test on any layer. It can fold two or more tests into an existing route, story or real-server test that already asserts their property: the fixer deletes the subjects and writes nothing, and a post-fix check refuses the fold if a baseline file gained a test. Any proposal that leaves a unit test (not a story) covering a route-or-higher subject needs a reason stating both unit-test conditions. A fold-up or demote that would need a new test is report-only: it is listed for the human and never written.

## Divergence

- A fold-up's post-fix check reads only the baseline files it recorded, so a fixer that wrote the folded property into a new test file elsewhere would pass the checker. The fixer's editable paths, limited to the subject files, are what forbid that today.
- The planner's gate-retry block (`.claude/skills/gaia/references/plan/planner.md`) has no arm for a shell-lint failure, so one halts the run even when it is mechanical and attributable to one task.
