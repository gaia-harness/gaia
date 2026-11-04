---
description: 'GAIA self-review: pre-gate-2 review pass on the in-progress SPEC draft.'
---

# Self-review pass before gate 2

The `/gaia-spec` wrapper dispatches this at step 6 as a `general-purpose` Agent, after the clarify loop and before gate 2.

## Inputs

- The in-progress SPEC draft. The wrapper writes the working draft to `.gaia/local/cache/draft-<spec_id>.md` during the loop and passes its path in the dispatch prompt.
- The gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`, captured when the user confirmed intent + UATs.

## Audit checklist

Read the draft and the gate-1 snapshot. Record every finding under the headings below (the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md` is the authoritative return/apply contract): write them to `.gaia/local/cache/audit-<spec_id>/findings/self-review.json`, apply the minor `suggested_fix`es to the draft yourself in a single write, and surface the critical and major findings to the wrapper for gating.

### 1. Placeholder text

Scan for `[PLACEHOLDER]`, `<TODO>`, `<TBD>`, `FIXME`, and bare `TBD` tokens. Any hit is a finding: name the field and the offending line.

### 2. Scope drift relative to gate 1

Compare draft fields against the gate-1 snapshot:

- `intent` paragraph diverged in shape, not just polish.
- A UAT was renumbered, removed, or added since gate 1.
- `success_criteria` gained or lost an entry without a corresponding answered clarification.

For each drift, name the gate-1 value, the current value, and ask the wrapper to surface a confirmation prompt before gate 2 (or to revert).

### 3. Internal inconsistency

Cross-check fields against each other:

- A UAT references a behavior absent from `intent` or `success_criteria`.
- `scope_boundaries.always` includes a behavior contradicted by `scope_boundaries.never`.
- `clarifications.answered[]` entries that contradict the current `intent`.

### 4. Ambiguous UAT phrasing

Each UAT must be testable. Flag UATs that:

- Use hedging ("should", "might", "ideally").
- Lack a falsifiable `then`.
- Reference an undefined system (e.g. "the orchestrator" without prior naming).

### 5. Case-enumerating UATs

A UAT states a rule and one representative journey; case tables belong to the lowest layer, written by the implementer. Flag a UAT whose `then` enumerates input values or outcomes of one rule about user-visible behavior (a list of inputs each with its own result). Suggest stating the rule with one representative journey and leaving the cases to the lowest layer.

Also flag several UATs that walk one user flow and differ only in which transition they exercise (assign, decline, reopen, confirm), when their then-clauses name a browser capability (the closed list at the browser step of the routing ladder in `.claude/skills/gaia/references/plan/planner.md`; point there, never copy the list). Left as siblings, each becomes its own browser file. A `sibling_fold` finding's `suggested_fix` is the fold: one browser journey UAT for the flow, and each transition, status or role rule its own UAT routed by the ladder. Keeping the siblings needs a stated reason and is only a non-recommended alternative, never the recommendation. Siblings whose then-clauses name no browser capability are not flagged: each is a cheap non-browser test.

Also flag a UAT that mixes a browser-capability journey with an access refusal (a 403 page, a refused post). A `refusal_split` finding's `suggested_fix` splits the refusal into its own UAT, which the ladder routes off the browser.

Exempt a UAT on harness, script or doc behavior: its distinct outcomes are the contract, so enumerating them is correct.

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
  ambiguous_uats: <N>: UAT-NNN: <phrasing>
  case_enumerating_uats: <N>: UAT-NNN: <phrasing>
  sibling_transition_uats: <N>: UAT-NNN, UAT-NNN: <flow>
  access_refusal_in_journey: <N>: UAT-NNN: <refusal>
  pending: <N>: <item summary>, ... (listed as pending_clarifications for the wrapper to ask)
```

If every section is clean:

> Self-review clean: ready for gate 2.

## Notes

- Surface every candidate finding in each section, including borderline and low-confidence ones; gate 2 (the human) triages.
- Self-review applies the minor fixes to the draft itself and returns a short summary; the wrapper gates only the critical and major findings.
- The pending-clarifications gate is itself a required behavior. The agent reports the items; the wrapper asks, honors the user's choice, and loops until each item is answered or deferred.

