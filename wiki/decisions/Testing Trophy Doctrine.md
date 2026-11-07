---
type: decision
status: active
created: 2026-11-05
updated: 2026-11-07
promoted_at: 2026-11-05T08:13:38Z
promoted_hash: sha256:f352c0e433cf0fd66665695839a35c3234e4439e91e494e6b7734ba684a5195a
pr_number: 3316
tags: [promoted, decisions]
---
# Testing Trophy Doctrine

GAIA places tests by the testing trophy: write tests, not too many, mostly integration. The planner, the executors, the worthiness review and the overlap pass all serve that rule, so a build writes the tests its behaviors need and no more. How a test proves it can fail (the RED gate) is unchanged; the doctrine decides which tests get written. The rule itself lives in [[Test Layering]].

## Decisions

The doctrine replaces "every check lives at the lowest layer that can prove it". That axiom, together with references that asked for one test per behavior and a planner that asked for one criterion per guard, led executors to write a unit test for nearly every function. In pre-release tuning builds, test work cost about as much generation as the feature code, and most of the builder's unit tests repeated what an acceptance test already proved. The trophy keeps what the old rule got right, that a browser is the most expensive layer, and drops the push of every check down to a unit test.

Five mechanisms carry the decision:

- **Placement rule.** The route layer is the default home for behavior. A unit test is written only when both unit-test conditions hold: the integration layer cannot cover its cases cheaply, and the logic is important or likely to fail. One test covers each user-observable behavior, and a parameterized table counts as one test. [[Test Layering]] defines each term, and the tdd skill, the React testing reference, the Storybook rule, the planner, the SPEC template and self-review point at that page rather than restating it.
- **Vertical slices.** The planner cuts each phase as a vertical slice that delivers a behavior end to end and owns the acceptance test proving it. Task docs name the behavior and its owning acceptance test, never a list of tests per function, and a guard is driven to its failing state at the layer where its caller sees the refusal. For a spec-derived plan, plan verification refuses a phase whose number appears in no routing-table row unless the README marks it `- Phase <N>: Infrastructure: <reason>`. Plan verification checks the marker's syntax; the decomposition audit judges whether the reason holds. The check lives in `.gaia/scripts/spec/plan-phases-lib.sh`.
- **Named tests only.** The executor prompt template and the tdd loop limit new tests to the behaviors and acceptance tests the task doc names, plus unit tests meeting both conditions. Any other test an executor judges worth adding goes into its findings, not the tree.
- **A worth check on every new test.** The worthiness selection covers the package descriptor's `emergentTests` and `tddUnitTests` globs together, and the shipped descriptor's `emergentTests` includes the app's test helper folder. A test the determinism classifier labels strict is judged on honesty and worth like any changed test; the RED gate proves it can fail. The merge-time presence gate shares the selection, so a pull request adding such a test is denied at merge until the worthiness step has recorded a verdict for it ([[Worthiness Audit]], [[Worthiness Presence Gate]]).
- **Overlap fold-up and a reason-gated unit demote.** The overlap pass runs whenever a branch changed a test on any layer. It can fold two or more tests into an existing route, story or real-server test that already asserts their property: the fixer deletes the subjects and writes nothing, and a post-fix check refuses the fold if a baseline file gained a test. Any proposal that leaves a unit test (not a story) covering a route-or-higher subject needs a reason stating both unit-test conditions. A fold-up or demote that would need a new test is report-only: it is listed for the human and never written.

## Divergence

- A fold-up's post-fix check reads only the baseline files it recorded, so a fixer that wrote the folded property into a new test file elsewhere would pass the checker. The fixer's editable paths, limited to the subject files, are what forbid that today.
- The planner's gate-retry block covers only typecheck and lint failures. A shell-lint failure halts the run even when it is mechanical and attributable to one task.
