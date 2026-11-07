---
type: decision
status: active
created: 2026-11-07
updated: 2026-11-07
promoted_at: 2026-11-07T13:40:47Z
promoted_hash: sha256:00992341ac2c36796d5e7129201ff8df859e06046618cd80393c69314df9b3a3
pr_number: 3361
tags: [promoted, decisions]
---

# Flow machinery for a test-after testing layer (build)

The harness can now read a SPEC's critical user flows and check that each one has a test, while the existing test-first pipeline still runs unchanged: nothing in the pipeline calls the new pieces yet.

## Decisions

- **Flows reader.** `.gaia/scripts/spec/flows-lib.sh` parses a SPEC's `flows:` list into one row per flow (a web flow names the folders it covers; a command flow names its test path), validates the shape, refuses a SPEC that carries `uats:` or has no flows rather than returning zero flows, and reads a spec file's `// @covers` header paths.
- **Test-signal helpers.** The per-test signal extractors and their shell library live in `.gaia/scripts/test-signals/` and `.claude/hooks/lib/test-signals.sh`, independent of the RED ledger, which keeps only its ledger path. A `.bats` file gets one signal per `@test` block (comment edits leave it unchanged), so bats and CLI flow tests can be judged and gated like TypeScript tests. See [[Determinism Classifier]] and [[Stories as Tests]] for the other signal sources.
- **Flow-coverage check.** `.gaia/scripts/spec/flow-coverage.sh` reports every mechanical gap between a flow-based SPEC and the branch: a missing or unchanged flow test, a web spec absent from the Playwright listing, a missing or unresolvable `@covers`, a covered folder the branch changed that `@covers` misses, and a working-document id in a flow test. It can write the flow-tests list the worthiness step and the presence gate read.
- **Worthiness.** The evaluator judges honesty on every changed test, strict-classified tests included, and can judge a flow test against its flow: untested error paths, an outcome never asserted, undeclared folders. The worthiness step takes the flows SPEC and flow-tests list together, selects every test in a listed flow file, tags each with its flow, and `record` refuses a malformed flow judgment or a keep that names a gap. The merge-time presence gate demands a verdict for a changed test in a listed bats or CLI flow file. See [[Worthiness Audit]] and [[Worthiness Presence Gate]].
- **Test Layering** owns the closed list of capabilities that justify a browser test and admits one browser spec per critical web flow. See [[Test Layering]].
- **Playwright** collects `apps/web/.playwright/flows/` beside `.playwright/e2e/`; the template ships the empty folder. CI provisions Node on the lib bats legs for the suite that proves the collection. See [[Playwright]].

## Divergence

- The flow-key validation sits in the worthiness step's `record`, the ledger writer's only caller, rather than in the writer itself; the writer only checks the value parses.
- The switch of `/gaia-spec`, the planner and the pipeline pages to flows, and the removal of the RED gate and UAT pipeline, are later pull requests.
