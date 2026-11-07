---
type: decision
status: active
created: 2026-11-07
updated: 2026-11-08
promoted_at: 2026-11-07T13:40:47Z
promoted_hash: sha256:de0cc6f81dfc96286264830333050c0da69241b35664e4dc29a212ac2f2d4b58
pr_number: 3361
tags: [promoted, decisions]
---

# Flow machinery for a test-after testing layer

The harness reads a SPEC's critical user flows and checks that each one has a test. The spec stage, the SPEC lint, the planner and `plan-verify.sh` call these pieces.

## Decisions

- **Flows reader.** `.gaia/scripts/spec/flows-lib.sh` parses a SPEC's `flows:` list into one row per flow (a web flow names the folders it covers; a command flow names its test path), validates the shape, refuses a SPEC that carries `uats:` or has no flows rather than returning zero flows, and reads a spec file's `// @covers` header paths.
- **Test-signal helpers.** The per-test signal extractors and their shell library live in `.gaia/scripts/test-signals/` and `.claude/hooks/lib/test-signals.sh`, independent of the RED ledger, which keeps only its ledger path. A `.bats` file gets one signal per `@test` block (comment-line edits leave it unchanged), so a bats flow test can be judged and gated like a TypeScript test. See [[Stories as Tests]] for story signals.
- **Flow-coverage check.** `.gaia/scripts/spec/flow-coverage.sh` reports every mechanical gap between a flow-based SPEC and the branch: a missing or unchanged flow test, a web spec absent from the Playwright listing, a missing or unresolvable `@covers`, a covered folder the branch changed that `@covers` misses, and a working-document id in a flow test. It can write the flow-tests list the worthiness step and the presence gate read.
- **Worthiness.** The evaluator judges honesty on every changed test, strict-classified tests included, and can judge a flow test against its flow: untested error paths, an outcome never asserted, undeclared folders. The worthiness step takes the flows SPEC and flow-tests list together, selects every test in a listed flow file, tags each with its flow, and `record` refuses a malformed flow judgment or a keep that names a gap. The merge-time presence gate demands a verdict for a changed test in a listed bats or CLI flow file. See [[Worthiness Audit]] and [[Worthiness Presence Gate]].
- **Test Layering** lists the closed set of capabilities that justify a browser test and admits one browser spec per critical web flow; the planner and `plan-verify.sh` keep no copy of it. See [[Test Layering]].
- **Playwright** collects `apps/web/.playwright/flows/` beside `.playwright/e2e/`; the template ships the empty folder. CI provisions Node on the lib bats legs for the suite that proves the collection. See [[Playwright]].

## Divergence

- The flow-key validation sits in the worthiness step's `record`, the ledger writer's only caller, rather than in the writer itself; the writer only checks the value parses.
- The removal of the test-first machinery (the RED scripts, the UAT gate and the fidelity judge) is still to come; the pipeline already runs on flows.
