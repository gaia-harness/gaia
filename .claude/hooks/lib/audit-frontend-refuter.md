# Frontend member: refutation pass

Read this only when at least one holistic Critical or Major candidate survived the Finding Proof Gate's four checks. The pass covers your own (probabilistic) findings at those two tiers; Minor findings stay self-policed, and the oracles, the rule specialists' findings and every other member's findings are out of scope. The four checks are self-applied and share your blind spots, so each survivor goes to a fresh-context refuter that did not produce it.

A refuter overturns a finding only with **concrete counter-evidence**, the mirror of the gate's concrete-failure-mode bar:

- the specific guard (`file:line`) that prevents the claimed input or state from reaching the defect,
- a test that already asserts the correct behavior, or
- a demonstration that the failure path is unreachable.

## Dispatch

One `Agent` call per surviving finding, in parallel from one message, with `subagent_type: "audit-refuter"` and `description: "refute <path>:<line>"`. Pass no `model` and no `effort` parameter: the type definition owns both. The prompt:

```
Finding:
- Location: `<path>:<line>`
- Failure mode: <input + state + bad outcome, verbatim from the finding>
- Claimed severity: <Critical | Major>

Changed files in scope: <list from CHANGED>

Reply with exactly one verdict line: REFUTED (cannot occur): <counter-evidence>, DOWNGRADE (occurs but smaller): <evidence and the tier it warrants>, or STANDS (no concrete counter-evidence found). If you cannot cite counter-evidence, the verdict is STANDS.
```

## Act on the verdict

- Counter-evidence shows the defect cannot occur: **drop** the finding.
- Counter-evidence shows it occurs but with a smaller blast radius than claimed: **demote** to the tier the evidence supports.
- No concrete counter-evidence: the finding **stands** at its tier. "Seems unlikely" or "probably fine" is not a refutation.

## No-op detection and retry for each refuter

After each refuter returns, write the returned text to a file in your scratchpad with Write and classify it with `bash <root>/.gaia/scripts/audit-noop-detect.sh --shape cra-refuter --path <file>` (exit 0 = real, exit 1 = no-op). A return carrying a standalone `REFUTED`, `DOWNGRADE` or `STANDS` token is a real result, never a no-op; only a harness-reminder-echo carrying none of those tokens is a no-op.

On a no-op, re-dispatch that refuter **exactly one** time with the hardened retry prefix (`.claude/agents/code-audit-frontend.md`, "Hardened retry prefix"), naming the finding's `file:line` as the target. A second consecutive no-op does not re-dispatch a third time: refute that one finding yourself inline (the **inline fallback**), apply the verdict as if the refuter had returned it, and record the degraded unit in the report's Summary.

## Unknown agent type

A dispatch that errors naming an unknown or missing agent type (a session started before the update loaded the new definitions) is not retried. Take the inline fallback at once and add the Summary note `relaunch Claude Code to load the new agent types`.
