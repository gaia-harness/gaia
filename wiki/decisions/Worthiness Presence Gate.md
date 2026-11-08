---
type: decision
status: active
priority: 1
date: 2026-06-23
created: 2026-06-23
updated: 2026-11-08
tags: [decision, tdd, testing, audit, merge, quality]
---

# Worthiness Presence Gate

A merge-time `gh pr merge` gate that requires each test in the worthiness selection a PR changes to
carry a worthiness-ledger line matching its current content. It is the
merge-time half of the [[Worthiness Audit]]: the evaluator judges each changed
test and the shared worthiness step or the tdd skill's arm appends one ledger
line per judged test; this gate
enforces at merge that such a line exists for the content being merged. It sits
alongside the [[PR Merge Workflow]]'s Code Audit Team gate, both deny
`gh pr merge` independently.

Machine-enforced by `.claude/hooks/worthiness-presence-check.sh`, a PreToolUse
Bash hook registered in `.claude/settings.json` as a sibling to
`.claude/hooks/pr-merge-audit-check.sh`.

## What the gate proves, and what it does not

The check is a ledger lookup plus a signal recompute. It never re-runs tests and
never re-runs the evaluator. A present, signal-matching ledger line proves only
that the test-identity extractor **ran over the test's current content** and a
verdict was recorded against that exact content. It does **not** prove that
judgement was applied.

A scripted rubber-stamp, run `.gaia/scripts/test-signals/extract-test-signals.mjs`
over the changed files and append a `keep` for every emitted signal, mints every
matching line at near-zero cost and is the cost-minimizing path through this
gate. The judgement guarantee rests on the human PR rollup, not on the presence
of a line. The gate is a forgery floor against "no audit ran at all," not a proof
that an honest audit ran.

The presence decision reads **presence and signal match only**; it never reads
the keep/fix/delete verdict. That keeps the verdict advisory and avoids
gating the merge on a judgement call.

## Honesty lint is not re-checked here

The gate reads no verdict and re-runs no lint. Static test-honesty (the
`vi.mock`-internal, literal-tautology, call-through-only, and
server/internals-import patterns) is owned, once, by its own gate: the
[[Quality Gate]] at commit (`eslint --max-warnings=0`) and CI lint at PR. A file
carrying a honesty-lint error cannot be committed or merged, so re-checking it at
merge would double-gate an invariant another system already enforces. GAIA gates
each invariant once, at its owning gate: this gate owns presence, lint owns
honesty.

The call-through-only and server/internals-import patterns ship as stock ESLint
ids (`vitest/prefer-called-with`, `no-restricted-imports`). The same-module-mock
and literal-tautology patterns have no stock-tool equivalent and are not
currently enforced; if they become custom `gaia-test-honesty/*` rules, they too
enforce at lint-time, not here.

## Per-verdict artifact

Each non-keep verdict carries a machine-checkable `artifact` on its ledger line
(the cited sibling for a redundancy delete, the unreachable or missing assertion
for a fix), enforced by the ledger writer
`.gaia/scripts/audit-ledger/append-worthiness.mjs`. An all-keep run with no
artifacts is therefore a shape the human PR rollup can scrutinize: a real audit
that found nothing to fix or delete is plausible, but it is also what a scripted
rubber-stamp produces, so the rollup, not this gate, makes that call.

## Scope

The gate scopes to the test files **this PR changed** that the worthiness selection names, the diff against
the merge base with the default branch, not the whole repo's tests. A
whole-repo scope would demand a ledger line for every existing test and
block every unrelated merge.

Membership is decided by the worthiness selection library
(`.claude/hooks/lib/worthiness-selection.sh`): a changed test file that a package's `emergentTests` or `tddUnitTests` globs name ([[Package Descriptor]]) and whose [[Determinism Classifier]] verdict (`.gaia/scripts/classifier/classify-determinism.mjs`) is `emergent`, `strict` or `route` is in scope (a `*.stories.tsx` is in scope through its own globs entry, one ledger line per base story and per attached `.test()`, and per story with a play and no tests; an old-format story file denies, see [[Stories as Tests]]). A changed test in any file the run folder's `flow-tests.tsv` lists is in scope whatever the globs and the classifier say, which is what brings a bats or CLI flow test in.

When zero in-scope test files changed, the gate is a no-op and allows the merge.

## Stale-signal rejection

The `signal` is the `sha256`-of-normalized-test-call that `extract-test-signals.mjs` computes
(wrapped by `.claude/hooks/lib/test-signals.sh`),
the same primitive the worthiness ledger writer uses, so the recomputed signal
byte-matches the ledger. The hash covers the test's comment-free content, so
rewording a comment inside a test leaves the signal unchanged and a matching
line still counts. A line written before an edit to what the test executes
carries the old signal and never matches the recomputed current signal, so such
an edit invalidates the line.

## Cost and latency

The recompute is O(in-scope test files changed in the PR): each in-scope file is
fed through the signal helper once. Wall-clock therefore scales with the in-scope
test count. This is a separate axis from the per-test token cost, which does not
scale with suite size; the recompute is deliberately linear in the changed
in-scope file count and is not made sub-linear.

## Fail-open posture

The `Fail-open vs fail-closed` block in `.claude/hooks/worthiness-presence-check.sh` owns which failures allow and which deny.

## Relationship to the other merge gates

- The Code Audit Team gate ([[PR Merge Workflow]]) proves a clean code review
  ran against HEAD. This gate proves the in-scope tests the PR changed carry
  worthiness verdicts for their current content. They are independent denials;
  both must clear.
- This gate requires a current ledger line for each changed test the worthiness
  selection names, strict included; it does not judge verdicts (see
  [[Worthiness Audit]]).

See [[Worthiness Audit]], [[PR Merge Workflow]], [[Determinism Classifier]].
