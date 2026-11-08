---
type: decision
status: active
created: 2026-11-08
updated: 2026-11-08
promoted_at: 2026-11-07T23:18:48Z
promoted_hash: sha256:d020133773a46814a9ad7a443c6b55e846bb8ec6fc78434d94de61931801dbae
pr_number: 3364
tags: [promoted, decisions]
---

# Flow-based test-after pipeline

GAIA's spec-to-build pipeline runs on critical flows and tests them after the build. The test-first machinery (UAT render, owning-phase gate, fidelity judge, RED ledger and hook scripts, test review, author scope) still exists on disk but nothing in a new plan calls it, and its removal is a separate change.

## Decisions

### Spec stage

- `/gaia-spec` gate 1 proposes the feature's critical user flows, each a one-line name and why, with a marked recommended set confirmed through `AskUserQuestion`; gate 2 prints every flow and confirms the whole SPEC.
- A SPEC saves them under `flows:`. The SPEC lint sources `flows-lib.sh`, turns each validation line into a finding, and refuses a SPEC that still carries `uats:` (`uats_key_present`) or has no flows (`missing_flows`).
- The SPEC template states that a flow names one critical user path and that case tables belong to one parameterized test at the layer Test Layering picks; the spec audit's testability lens reads flows and success criteria.

### Plans

- The planner writes build phases (implement, typecheck, lint, existing tests; no test author, render or RED gate) and, for a spec-derived plan, one closing phase with one task per flow. Each closing task carries one `Flow test (<flow_id>): <path>` line; a web flow is a Playwright spec in the frontend package's `.playwright/flows/`, a command flow is its `test_path`.
- The closing phase's gate runs every flow test before its commit (`playwright test`, `pnpm test:shell` for bats, `test --run` for Vitest). `gate-retry` sends a failing flow test once to a fresh executor free to fix code or test.
- A `flow-checks` block after the last phase runs `flow-coverage.sh` and writes `flow-tests.tsv`, with one fixer round and a halt. Resume detection enters a fully complete spec-derived plan at the flow checks, a spec-less one at the worthiness step.
- `plan-verify.sh` checks the new shape: the task-stem-to-phase rule, one flow line per closing task and per flow, the closing-phase gate check, and refuses `uats:`. Spec-less plans follow Test What Matters and still carry the worthiness and overlap blocks.

### Ids, principle and hooks

- The working-document id detector bans `FLOW-` ids in place of `UAT-` ids: uppercase at any digit count, other case only in the three-digit shape, so ordinary `flow-` words in file names pass. The release scrub check is `flow-narrative`.
- The coding guidelines' section 3 is Test What Matters; `/tdd` is an opt-in tool whose red step runs inside the skill. The web rules, README, debt reference and tdd skills follow.
- The RED commit hook and its capture hook are no longer registered in either settings file; the jq-availability baseline is empty.

## Divergence

- The closing gate runs a bats flow through `pnpm test:shell`, the bats runner every GAIA project has.
- [[TDD RED Verification]], [[Determinism Classifier]] and [[Quality Gate]] step 3 still describe the RED hooks as enforcing, though neither hook is registered; they change when the test-first machinery is removed.
