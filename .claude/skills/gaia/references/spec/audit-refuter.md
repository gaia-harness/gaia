# /gaia-spec: the critical refuter

The batched refuter over the review's `critical` findings. `spec/audit.md` `## The critical refuter` routes here only when a lens raised at least one; control returns there once every verdict is routed.

Dispatch one `general-purpose` Agent keyed by `{ finding_ids, findings_files }` (the lens files that raised them), no finding fields interpolated. It reads each finding body from its file itself. Pre-clear every `verdicts/<finding-id>.json` (`rm -f`) before dispatch so its presence is a fresh-write signal.

Refuter prompt (interpolate `<finding_ids>`, `<findings_files>`, `<DRAFT_PATH>`, `<repo_root>`; no finding fields inline):

> Verify each finding in `<finding_ids>`, recorded in `<findings_files>`, against the SPEC draft at `<DRAFT_PATH>` (repo root `<repo_root>`). Read the findings there; each one's severity, location, issue, evidence, and recommendation all live in that file.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Read `<findings_files>` first.
>
> For each id, open the cited SPEC section and any cited file yourself and try to REFUTE it: did the auditor misread the SPEC or the code, or overstate severity (`partial` with a corrected severity, never refuted)? Refute a finding only when every gap it names fails, not just the harm it argues: a sound gap behind an overstated harm is `partial`. A finding that a value the app keeps server-only (a credential for another service, a signing key, a PKCE verifier) has no SPEC rule keeping it server-only is never refuted by who owns the value or by a cookie or transport attribute, and its `corrected_severity` is never lowered below `major` on those grounds. For a finding you do NOT refute, also classify its DISPOSITION: is the SPEC's binding contract already correct and only the implementation needs steering (`plan_directive`), or is a behavior, a flow, a success criterion or the intent itself wrong, gameable, or missing (`spec_defect`)? A finding whose fix is a page-markup or accessibility structure rule is `plan_directive` even when it cites a flow. Any other finding that a rule has no behavior or success criterion stating it is `spec_defect`, never `plan_directive`. Default to `refuted` if you cannot substantiate any gap it names from ground truth.
>
> **Write** one verdict file per id to `verdicts/<finding-id>.json` under the verdict schema below, then **return** only a JSON array of thin verdict lines, one per id: `{ "id": "<finding_id>", "verdict": "confirmed"|"partial"|"refuted", "corrected_severity": "...", "disposition": "plan_directive"|"spec_defect" }`.

Verdict schema (the file the refuter writes):

    {
      "verdict": "confirmed" | "partial" | "refuted",
      "corrected_severity": "critical" | "major" | "minor" | "none",
      "disposition": "plan_directive" | "spec_defect",
      "reasoning": "<one or two sentences>",
      "evidence": "<file:line or SPEC quote actually checked>"
    }

Main counts the returned lines against the ids, re-dispatches the batch once for any id missing a line, and carries an id still missing one forward unrefuted at its lens severity. Main reads the **thin lines only** and never opens a verdict file. Each confirmed or partial critical finding is routed by its `disposition`: `spec_defect` is a SPEC fix, `plan_directive` a plan-time directive; a `refuted` one is recorded `rejected`.

