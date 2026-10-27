---
type: concept
status: active
created: 2026-10-27
updated: 2026-10-27
promoted_at: 2026-10-27T04:41:04Z
promoted_hash: sha256:ec219432f88df7ead88b81a12ba1bfb9b5a3d66d3695468f62d5b9dc6ce05bf3
pr_number: 3117
tags: [promoted, concepts]
---

# Per-dispatch audit cost telemetry

Every Code Audit Team member dispatch and every light reviewer dispatch in the maintainer repo leaves one `dispatch_cost` event in the audit telemetry log (`.gaia/local/telemetry/audit-light-routing.jsonl` in the main checkout). A member the round skips because it is already cleared for its digest leaves a `not_dispatched` event with reason `already_cleared`. A member a light reviewer clears gets no not-dispatched event; the reviewer's own event stands for it.

## Behavior

### Pieces

- **Measurement library** (`.gaia/scripts/audit-dispatch-cost-lib.sh`, `gaia_dispatch_cost_measure <subagents-dir> <agent-id> <rates-json>`): reads the dispatch's transcript and every descendant reached through parent agent ids, in two jq passes whatever the descendant count. Usage deduplicates by message id with the last block winning; a zero-usage line (a synthetic call) adds no call, tokens or model. It returns the dispatch's own tokens by bucket, calls, wall seconds and dollars, plus per-role child figures with each child counted under its own agent type and the longest child wall time per role. A model with no rate row keeps every figure and nulls dollars; a call without a timestamp flags a missing anchor and nulls dollars, never zero. Fewer linked depth-1 children than the dispatch's own Agent calls, or any torn child meta, marks the children block `unparsed` with null figures while the dispatch's own figures stand.
- **Recorder** (`.gaia/scripts/audit-dispatch-cost.sh record`): finds the transcript by agent id with one non-recursive glob over this repository's own Claude Code project folders only (the main checkout's encoded folder and its worktree folders), refuses an agent id carrying a path separator or glob character, waits a bounded time for the transcript's finish mark, measures, and appends the event with kind (`member` or `light_reviewer`), member, branch and digest. It runs only where the maintainer marker file exists, and it never blocks the audit: every failure is swallowed with one stderr line. `--kind` is required in every form.
- **Report** (`audit-dispatch-cost.sh report`, delegating to `.gaia/scripts/audit-dispatch-cost-report.sh`): for each member, the last N branches (`--window`, default 30) holding any `dispatch_cost` or `member_result` event for that member; per-member, per-kind medians of complete events, with incomplete, unparsed-children, not-dispatched, transcript-missing and transcript-unparsed events counted apart. A `member_result` or `light_outcome` with no cost event of its own kind for the same member, branch and digest, at or after the branch's first cost event, counts as unrecorded; each result consumes at most one cost event, so a light reviewer's event never masks a full member's missing one.
- **Tally**: `audit-light-telemetry.sh` windows only on its own event types (the allowlist in its window expression), so cost events cannot shift its branch window, its kill-rule figures or its escalation follow-up output. Its spend ratio reads complete cost events: a light reviewer's spend against the full member spend of the same members.
- **Wiring**: the audit loop unit's maintainer-only blocks run the recorder beside `member-result` for a member (keeping the agent id the launch returns), beside `audit-light-mark` for a light reviewer, and with the not-dispatched state for an already-cleared member. The bundle-time scrub strips those blocks, and all three scripts are release-excluded, so nothing reaches an adopter.

### Parity

The committed measurement toolkit (`.gaia/tests/audit-cost/measure-dispatch.mjs`) is the oracle for calls, cache tokens, wall seconds and dollars; the suites assert equality on a fully priced fixture. Deliberate differences: the recorder roles children by agent type across all descendants, keeps the longest child wall time per role, records null dollars for an unpriced model where the toolkit exits, does not count zero-usage lines as calls, and records input and output totals the toolkit does not report.

## Divergence

None in scope. The SPEC lists the audit loop unit agent file among the paths that rotate every member's digest; it is not audit machinery and routes to `code-audit-maintainer-shell` only, so it rotates that member's digest alone.
