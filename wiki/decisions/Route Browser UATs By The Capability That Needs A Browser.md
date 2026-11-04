---
type: decision
status: active
created: 2026-11-04
updated: 2026-11-04
promoted_at: 2026-11-04T04:03:43Z
promoted_hash: sha256:dc6fab7c58a8d6631c20ddc65bba015738b7f4bcedc3be77978d0606354a6bea
pr_number: 3284
tags: [testing, playwright, plan, routing]
---

# Route browser UATs by the capability that needs a browser

A GAIA plan routes a UAT to the browser surface only when its then-clause needs a capability that a real browser alone shows, and the plan names that capability for every browser row. A JavaScript-disabled flow or a native form post leaves the browser and routes by the rest of the ladder: to the real-server surface, where Playwright's request fixture drives the app with no page, when that ladder's real-server step claims it (such as a then-clause that needs the served form or a multi-page workflow over native forms across the live stack), and otherwise to a route test.

## Decisions

Why the browser surface is gated on a capability, not on the shape of the journey: every workflow is a multi-page journey and every native form is submitted by the client, so a ladder that sends "a client-submitted form" or "a multi-page journey" to the browser sends nearly every live-stack UAT there. A request client never runs JavaScript, so a JavaScript-off flow gains nothing from Chromium and costs its startup time and a slower failure diagnosis. Routing on the capability the then-clause asserts keeps the browser suite to the tests that need one.

Why the plan names the capability and plan-verify refuses rather than warns: an advisory warning on a browser row is dismissed by the planner it warns, and an unattended run accepts the dismissal. Each browser row's owning task doc carries one `Browser capability` line naming a capability from a closed list and citing a then-clause phrase. plan-verify refuses the row when the line is missing, names a value outside the list, cites a phrase that is absent from the then-clause, not word-bounded there, or holds no cue word of the capability it names, and when the UAT's Given says JavaScript is disabled. The closed list, the cue words and the JavaScript-disabled pattern live in the header of `.gaia/scripts/spec/plan-verify.sh`; the capability-line parsing lives in `.gaia/scripts/spec/browser-capability-lib.sh`. The routing table keeps its five columns, so no shared parser and no older plan changes. The earlier word-list warning on browser rows is gone; the story and non-ui warning stays.

Why the template gains a form serializer: the one honest argument left for a JavaScript-off browser test is field drift, where a hand-built POST keeps passing after a field is renamed, a hidden intent changes or a default option moves. `serializeForm` in `apps/web/.playwright/html.ts` serializes a parsed form's text-valued controls, with overrides (file inputs are skipped and an image submitter is sent as name=value, not name.x and name.y), so a real-server test builds its body from the served page and catches that drift over HTTP. A repeated field name keeps its last value; a caller passes the intended value through the overrides.

Why only browser siblings fold into one journey: one UAT per transition, status or role rule keeps traceability, and a real-server or route test is cheap, so folding them saves nothing. The SPEC self-review recommends folding sibling UATs that walk one browser flow into one browser journey UAT, with the fold as the recommended fix so an unattended run takes it, and each rule stays its own UAT routed by the ladder. The self-review also splits an access refusal out of a browser journey into its own UAT, which keeps every access check off the browser surface. The plan's decomposition audit drops a self-test of the plan's own Given builders, as it drops a self-test of the Playwright fixture wiring: the specs that use them prove them.

Where each part is stated: the planner reference's routing ladder (`.claude/skills/gaia/references/plan/planner.md`) names the closed list once and points to the plan-verify header; [[Test Layering]], the Playwright rule, the tdd-react tests reference and the SPEC self-review point to that ladder.
