---
type: decision
status: active
priority: 1
date: 2026-06-23
created: 2026-06-23
updated: 2026-11-08
tags: [decision, tdd, testing, audit, quality]
---

# Worthiness Audit

An advisory review of the tests the worthiness selection names (the `emergentTests` and `tddUnitTests` globs, per [[Package Descriptor]]). An emergent test has no stable
failing-then-passing run to gate on, so its honesty and worthiness come from a
fresh-context reviewer. Every changed test, strict included, is judged on honesty and worth. A test the [[Determinism Classifier]] labels strict is judged on whether it asserts the outcome that matters; nothing proves mechanically that it can fail. The reviewer
**proposes** verdicts and **edits no files**; a human acts on every proposal.

## Problem

A component-interaction test, an async test, a layout test or an E2E test has no
stable failing-then-passing run to observe. Without a mechanism, an emergent test that always
passes (a tautology, a child-redundant re-prove, a platform-byte assertion, a
behavior-rich component covered only by a tracer bullet) ships unchallenged and
adds maintenance cost while catching none of its own component's bugs.

## Decision

A committed reviewer prompt judges each changed test on two axes (every changed test, strict included, is judged on honesty and worth) and
returns one verdict per test. A fresh-context reviewer is the cheapest way to
recover the honesty signal a failing run cannot supply here, because the author
who wrote the tests shares their blind spots.

### The two axes

- **Honesty**: the test can fail for a real reason, asserts through the public
  interface, and survives an internal refactor. A tautology, an internal-collaborator
  mock, or a sole `toHaveBeenCalled` fails this axis.
- **Worthiness**: the discriminator (a failure points at MY code, not a
  dependency), composition non-redundancy (the test asserts the seam, not a
  child's own output), no platform-output tests (the formatter's bytes belong to
  the formatter), and non-triviality (a behavior-rich tracer-bullet
  test is incomplete).

### Verdicts

`keep` clears both axes. `fix` is honest-but-flawed (implementation coupling,
platform-byte assertion, or a behavior-rich tracer-bullet
test, which returns `fix`, not `keep`). `delete` is worthless or unfalsifiable
and is **always human-gated**.

### Delete constraints

The full set is `## Hard delete constraints` in `.claude/agents/worthiness-evaluator.md`; the main ones:

- **Propose-only.** The reviewer never deletes; a human confirms every delete.
- **Composition deletes cite both sides and the sibling is machine-verified.** A
  child-redundancy delete cites the redundant sibling assertion AND the subsuming
  seam assertion, and the cited sibling is confirmed to contain a matching
  assertion before the proposal reaches a human. An unverifiable sibling downgrades
  the proposal.
- **Security / escaping / data-integrity carve-out.** A seam test asserting XSS
  escaping, sanitization, injection resistance, or data integrity is never
  deleted without a machine-verified sibling that asserts the same property.

### Stories are audited tests

A story is a visual state and a behavior is a `.test()` attached to it ([[Stories as Tests]]). Each attached test, with its story's `base story` entry, is one test to the audit, wherever the file sits: stories classify emergent ([[Determinism Classifier]]), and `extract-test-signals.mjs` emits one identity per entry. A story with an effective play and no tests is one test; a render-only story is not counted. The a11y axe check is automatic for every story, so a story that only renders and passes axe is a complete a11y test for a component with no interactive behavior; the reviewer judges a `.test()` on its behavior assertions, and a test that asserts nothing a user could see break returns `fix`; an `expect` inside a play also returns `fix`. No separate static a11y check runs: addon-a11y covers the mechanical half.

### Layers

The composition rule compares a story's tests with its own children's stories. The review judges each test on its own worth and does not propose moves across layers; [[Test Layering]] states the division of work between the review and the overlap pass.

### Strict tests: honesty and worth

Every changed test, strict included, is judged on honesty. The classifier picks which judgment arm and evidence a test gets, not whether honesty is judged: a strict test's subject is deterministic, so a weak assertion there is a defect, not noise. Nothing proves mechanically that a strict test can fail, so the review is where it is checked that the test asserts the outcome that matters. On worth, the reviewer asks whether the test is worth having: trivial, covered by an integration test, proving what the type checker or lint already proves, a table that should be one test, or a unit test whose logic is neither important nor likely to fail. The verdict is `keep` or a human-gated `delete` naming the criterion, or a `fix` when the test fails the honesty axis.

### Two-tier surfacing

On the tdd path, advisory findings never interrupt mid-implementation; they
surface only at end-of-task, in two tiers. A plan run, the work lifecycle and
`/gaia-debt` run the pre-audit worthiness step instead, which acts on a `fix`
verdict before the audit (`.claude/skills/gaia/references/worthiness-step.md`). Honesty findings auto-fix in place and are left in the
working tree for normal review. Every proposed delete requires human
confirmation and renders its cited redundant sibling AND the subsuming seam
assertion inline, so the human confirms against the evidence without opening
files. The list is capped: top-N by severity with a count (`delete` proposals
before `fix` findings), never a wall. On the no-orchestrator path the findings
share one end-of-task summary with the determinism roll-up; on the orchestrated
path the same content goes into the leaf's `PROGRESS.md` and the pre-merge
summary.

## Audit ledger

Each verdict appends one line to an append-only ledger, per tree:

```json
{"schema": 1, "file": "<repo-rel>", "fullName": "<vitest fullName>", "signal": "sha256:...", "verdict": "keep"|"fix"|"delete", "auditedAt": "<iso>", "artifact": "<...>"}
```

- Path: `.gaia/local/worthiness-ledger/<tree_key>/worthiness.jsonl` (append-only,
  gitignored, grows-forever, a directory keyed per tree).
  `<tree_key>` identifies
  the working tree, printed by `bash .gaia/scripts/main-root-lib.sh --tree-key`.
- `signal` is the SAME `sha256`-of-normalized-test-call the test-signals helper computes
  via `.gaia/scripts/test-signals/extract-test-signals.mjs`. The writer reuses
  that helper, so the signal byte-matches what the merge presence gate
  recomputes; reinventing the identity primitive would desync the gate. The
  hash covers the test's comment-free content, so rewording a comment inside a
  test does not change the signal and a recorded verdict survives it; a change
  to what the test executes still rotates the signal and invalidates the
  recorded verdict.
- Each non-keep verdict carries a machine-checkable `artifact` (the cited
  sibling for a redundancy delete, the unreachable/missing assertion for a fix),
  so an all-keep run with no artifacts is a detectable contradiction.

## Infrastructure

- `.claude/agents/worthiness-evaluator.md`: the committed, versioned reviewer
  prompt. Reads only the changed in-scope test files plus their sibling suites,
  judges both axes, returns `{keep, fix, delete}` per test, edits no files. The
  human-facing encoding of the same contract is
  `apps/web/.claude/skills/tdd-react/references/tests-react.md` (the discriminator, composition,
  and platform rules).
- `.gaia/scripts/audit-ledger/append-worthiness.mjs`: the ledger writer. Takes a
  repo-relative test path, a `fullName`, a verdict, and (for non-keep) an
  artifact; recomputes the signal via the test-signals helper and appends one
  JSONL line. Rejects an unknown verdict and a non-keep with no artifact.

## Consumers

- The shared worthiness step (`.claude/skills/gaia/references/worthiness-step.md`)
  owns dispatch and verdict routing for a plan run, the work lifecycle and
  `/gaia-debt`; its `worthiness-step.sh record` is the only caller of the
  ledger writer. The tdd skill dispatches the reviewer through that page's tdd arm,
  which dispatches and records only (otherwise principle-6 always-on is
  violated). The tdd path's
  surviving no-orchestrator guarantees (static honesty lint, the fresh-subagent
  audit if dispatched) are distinct
  from the orchestrated-only guarantee (leaf isolation).
- The merge presence gate reads this ledger, recomputes each test's signal, and
  scopes to the same worthiness selection the review reads.
