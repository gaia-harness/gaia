---
type: decision
status: active
created: 2026-11-05
updated: 2026-11-14
promoted_at: 2026-11-05T08:13:38Z
promoted_hash: sha256:cf8eb56c3735344b9960e004fee01598fec3ef8368da70e944859d1461fbbb2f
pr_number: 3316
tags: [promoted, decisions]
---
# Testing Trophy Doctrine

GAIA places tests by the testing trophy: write tests, not too many, mostly integration. The planner, the executors and the worthiness review all serve that rule, so a build writes the tests its behaviors need and no more. The rules themselves live in [`.claude/doctrine/testing.md`](../../.claude/doctrine/testing.md); this page keeps the reasons, and [[Test Layering]] keeps the reasons for each layer.

## Decisions

The doctrine replaces "every check lives at the lowest layer that can prove it". That axiom, together with references that asked for one test per behavior and a planner that asked for one criterion per guard, led executors to write a unit test for nearly every function. In pre-release tuning builds, test work cost about as much generation as the feature code, and most of the builder's unit tests repeated what an acceptance test already proved. The trophy keeps what the old rule got right, that a browser is the most expensive layer, and drops the push of every check down to a unit test.

Four reasons carry the decision:

- **Route is the default.** Most behavior a user relies on crosses a route, so a route test proves it without a server or a browser, and a unit test is kept for logic the integration layer cannot cover cheaply.
- **Vertical slices.** Cutting each build phase as a slice that delivers a behavior end to end keeps tests attached to behaviors instead of functions. The flow tests come last, after the build, because a journey can only be walked once the slices exist, and a guard is driven to its failing state by the build task's own test, since a flow test walks the happy path and rarely shows a refusal.
- **Named tests only.** A task doc that names a test per function invites a test per function. Naming only the tests a behavior needs keeps the count at what the requirements ask, and any other test worth having goes into the plan's follow-ups, not the tree. Test-first with the tdd skill is an opt-in tool, not a rule.
- **A worth check on every new test.** A test the determinism classifier labels strict is judged on honesty and worth like any changed test, because a test that cannot fail proves nothing. The merge-time presence gate shares the selection, so a pull request adding such a test is denied at merge until a verdict is recorded for it ([[Worthiness Audit]], [[Worthiness Presence Gate]]).

## Divergence

- The planner's gate-retry block (`.claude/skills/gaia/references/plan/planner.md`) has no arm for a shell-lint failure, so one halts the run even when it is mechanical and attributable to one task.
