---
description: 'GAIA self-review: pre-gate-2 review pass on the in-progress SPEC draft.'
---

# Self-review pass before gate 2

The `/gaia-spec` wrapper dispatches this directly at step 6 as a `general-purpose` Agent, after the Socratic clarify loop and before the GAIA wrapper presents the rendered artifact for gate-2 confirmation.

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

### 5. Pending clarifications

For each item in `clarifications.pending[]`, list it in the digest `pending_clarifications` as `{topic, question}`. The agent does not ask: the wrapper asks at `.claude/skills/gaia/references/spec/self-review-dispatch.md` 6c, offering `Answer now`, `Defer with rationale` (recorded in `clarifications.deferred[]`), or `Discuss this`.

Save stays blocked while any pending item is neither answered nor deferred.

## Output

When run as the dispatched 6a self-review agent, return the JSON digest defined by the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md` (that prompt is authoritative); the plaintext shape below is the fallback for a non-dispatched read.

Emit a structured report the wrapper can fold back in:

```
self-review findings (gate 2 gate):
  placeholders: <N>: <field>:<line>, ...
  scope_drift:  <N>: gate1.<field> vs current.<field>
  inconsistency: <N>: <description>
  ambiguous_uats: <N>: UAT-NNN: <phrasing>
  pending: <N>: <item summary>, ... (listed as pending_clarifications for the wrapper to ask)
```

If every section is clean:

> Self-review clean: ready for gate 2.

## Notes

- Surface every candidate finding in each section, including borderline and low-confidence ones; do not pre-filter for importance or confidence. Gate 2 (the human) triages. Suppressing a borderline finding here is the failure mode this gate exists to catch.
- Self-review applies the minor fixes to the draft itself and returns a thin digest; the wrapper gates only the critical and major findings. The authoritative return/apply contract is the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md`.
- The pending-clarifications gate is itself a required behavior. The agent reports the items; the wrapper asks, honors the user's choice, and loops until each item is answered or deferred.
- The first-tool-call contract (lead with a Read, no prose before it) lives in the 6a dispatch prompt in `.claude/skills/gaia/references/spec/self-review-dispatch.md`, this file's dispatcher, not here.
