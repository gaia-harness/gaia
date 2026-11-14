---
description: 'GAIA self-review: pre-gate-2 review pass on the in-progress SPEC draft.'
---

# Self-review pass before gate 2

The `/gaia-spec` wrapper dispatches this at step 6 as a `general-purpose` Agent, after the clarify loop and before gate 2.

## Inputs

- The in-progress SPEC draft. The wrapper writes the working draft to `.gaia/local/cache/draft-<spec_id>.md` during the loop and passes its path in the dispatch prompt.
- The gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`, captured when the user confirmed intent + critical flows.

## Audit checklist

Read the draft and the gate-1 snapshot. Record every finding under the headings below (the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md` is the authoritative return/apply contract): write them to `.gaia/local/cache/audit-<spec_id>/findings/self-review.json`, apply the minor `suggested_fix`es to the draft yourself in a single write, and surface the critical and major findings to the wrapper for gating.

### 1. Placeholder text

Scan for `[PLACEHOLDER]`, `<TODO>`, `<TBD>`, `FIXME`, and bare `TBD` tokens. Any hit is a finding: name the field and the offending line.

### 2. Scope drift relative to gate 1

Compare draft fields against the gate-1 snapshot:

- `intent` paragraph diverged in shape, not just polish.
- A flow was renumbered, removed, or added since gate 1.
- `success_criteria` gained or lost an entry without a corresponding answered clarification.

For each drift, name the gate-1 value, the current value, and ask the wrapper to surface a confirmation prompt before gate 2 (or to revert).

### 3. Internal inconsistency

Cross-check fields against each other:

- A flow names a behavior absent from `intent` or `success_criteria`.
- `scope_boundaries.always` includes a behavior contradicted by `scope_boundaries.never`.
- `clarifications.answered[]` entries that contradict the current `intent`.

### 4. Ambiguous flow wording

Each flow names one critical user path and says why it is critical. Flag flows that:

- Use hedging ("should", "might", "ideally").
- Name no observable user path, or only an implementation detail.
- Reference an undefined system (e.g. "the orchestrator" without prior naming).
- Place one element relative to another (beside, above, below, next to, aligned with) when the placement only stands for a relationship. Record a `major` `ambiguity` whose `suggested_fix` states the testable requirement instead, such as the error naming its field through `aria-describedby`.

### 5. Missing flows

Compare the intent's critical paths with the flows: a path whose breakage would block a user's main task, or risk data, money or security, with no flow, is a `missing_flow` finding. Flow shape: each flow has an id, slug, name, why, and exactly one of covers or test path. A flow lists no branches, inputs or outcomes; case tables belong to one parameterized test (`.claude/doctrine/testing.md`), so flag a flow that enumerates cases.

### 6. Pending clarifications

For each item in `clarifications.pending[]`, list it in the summary's `pending_clarifications` as `{topic, question}`. The agent does not ask: the wrapper asks at `.claude/skills/gaia/references/spec/self-review-dispatch.md` 6c, offering `Answer now`, `Defer with rationale` (recorded in `clarifications.deferred[]`), or `Discuss this`.

Save stays blocked while any pending item is neither answered nor deferred.

## Output

When run as the dispatched 6a self-review agent, return the JSON summary defined by the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md` (that prompt is authoritative); the plaintext shape below is the fallback for a non-dispatched read.

Emit a structured report the wrapper can fold back in:

```
self-review findings (gate 2 gate):
  placeholders: <N>: <field>:<line>, ...
  scope_drift:  <N>: gate1.<field> vs current.<field>
  inconsistency: <N>: <description>
  ambiguous_flows: <N>: FLOW-NNN: <phrasing>
  missing_flows: <N>: <critical path with no flow>
  pending: <N>: <item summary>, ... (listed as pending_clarifications for the wrapper to ask)
```

If every section is clean:

> Self-review clean: ready for gate 2.

## Notes

- Surface every candidate finding in each section, including borderline and low-confidence ones; gate 2 (the human) triages.
- Self-review applies the minor fixes to the draft itself and returns a short summary; the wrapper gates only the critical and major findings.
- The pending-clarifications gate is itself a required behavior. The agent reports the items; the wrapper asks, honors the user's choice, and loops until each item is answered or deferred.

