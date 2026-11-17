---
type: decision
status: active
created: 2026-11-17
updated: 2026-11-17
promoted_at: 2026-11-17T10:21:51Z
promoted_hash: sha256:2cdd922a2fd4cf95a1e312d9c9bb8bb77904a1db349856b3cb236eb1ef4f21ae
pr_number: 3644
tags: [audit, spec, plan, performance]
---
# Faster spec and plan audits that keep every check

The SPEC audit and the plan audit run every check they always ran, on the same inputs, and spend less wall time waiting. Only mechanics change: how lens and refuter prompts reach their agents, when refuters start, who writes the SPEC audit report, and who applies the plan audit's fixes. Trading a plan-time check for speed would move the mistake to build time, where code already exists and gets patched around rather than fixed, so no lens, refuter, self-review, clarify round or planner decision is skipped, merged, thinned or moved to a cheaper model.

## Decisions

**Rendered briefs instead of long inline prompts.** `lens-brief.mjs` renders each lens's prompt (the shared preamble from `lens-dispatch.md`, the lens's focus text read from the playbook at render time, and one appended output-format clause) to a brief file, and prints a short per-agent prompt whose first instruction is a Read of that brief. The parallel Agent calls then carry a few lines each, so they launch together instead of one prompt-generation at a time. Every existing preamble and focus sentence is kept verbatim; the brief adds only the output-format clause and the optional findings fields defined once in `lens-dispatch.md`'s findings file schema. Each brief carries a per-run token the lens echoes into its findings file, and `classify --brief` reads a missing or wrong token as a no-op, so a lens that never read its brief cannot pass as real. Refuter briefs come only from `lens-brief.mjs refuter`, which classifies the lens's findings file first and refuses, with no brief, when it is not real.

**Refuters start early only when the dispatch shape is already certain.** `refuter-schedule.mjs` runs as each lens classifies real and prints the refuters to start now. It starts them early only when no later lens can change the dispatch shape: the plan audit refutes only the test-design lens, so its refuters start when that lens finishes; a SPEC audit whose finished lenses already exceed the batching threshold is certain to batch, so each finished lens's batched refuter starts at once. Below the threshold, nothing starts until every lens has finished. The cross-lens cap and the completeness-critic skip rule are unchanged, and the dispatched refuter pairs and coverage records equal the all-lenses-first run for every completion order. Reading the cap as a certainty about the final shape, rather than a running count, is what keeps that parity: starting single refuters while the running count is under the cap produces a mixed shape when a later lens pushes the total over it.

**The SPEC audit report is rendered by script.** The fold agent writes an on-disk routing record (per finding: survived or refuted, corrected severity, disposition, decision and folded text, plus the Verdict paragraph and any rewording of a partial verdict's directive) instead of writing AUDIT.md by hand. `audit-render.mjs` renders AUDIT.md from that record and the findings, verdicts and coverage files in the template's headings, one column-0 numbered line per surviving plan-time directive, byte-identical to its wording. It refuses, writing nothing and naming the finding, a directive that would break the numbered list or a surviving directive with no text, so a check's result is never silently dropped or garbled.

**Plan audit fixes are applied by script, and every row they touch is judged for its security flag.** Plan lenses write row patches (field deltas keyed by row id, carrying the expected prior value of each field they change) and exact text replacements in named plan files. `plan-audit-apply.mjs` snapshots the plan before any change, runs every mechanical check on each fix in its new form, applies only accepted fixes that pass, writes atomically and records applied findings so a rerun applies nothing twice. A replacement applies only when its old text occurs exactly once at apply time; any other goes untouched to a fix-up agent. A patch that removes or weakens a flagged security row goes to the review list unless the review ruled the flag wrong, and a replacement aimed outside the task docs and phase plan is refused. After the apply and the fix-up, `judge-set` lists every added, changed or unflagged row against the snapshot, and an agent, never a pattern match, applies the existing security-flag judgment to each; a kind it assigns is handled like a flag-candidates line, and a judgment lowering a flagged row to none is never applied. A round with a surviving structural finding applies nothing and re-spawns the planner as before.

<!-- gaia:maintainer-only:start -->
**Speed is judged against the unchanged harness, never a minute target.** `compare-arms.mjs` turns paired replay runs of the current and changed harness, two runs per arm on each of two frozen SPECs from the same starting inputs, into an equal-grade verdict (no critical, no requirement with a major in both changed runs, nothing worse than the baseline arm had) and a shorter-median verdict, with every reported metric beside the baseline arm.
<!-- gaia:maintainer-only:end -->

## Divergence

- A SPEC audit that stays under the batching threshold, the typical case, gets no early refuter start: early start waits for the dispatch shape to be certain. The refuter-wait saving comes from the plan audit's test-design refuters and from over-threshold SPEC audits. This parity-first reading was accepted at the plan audit.
- The planner split (one decision pass plus parallel writers) is not part of this change; it is its own follow-up, decided by its own frozen-SPEC trial.
<!-- gaia:maintainer-only:start -->
- The speed and equal-grade verdicts come from paired replays in the maintainer's eval ladder, outside the repository; the comparator is maintainer-only test infrastructure, and the replay results gate the merge rather than the build.
<!-- gaia:maintainer-only:end -->
