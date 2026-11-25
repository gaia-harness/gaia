---
type: decision
status: active
created: 2026-11-25
updated: 2026-11-25
promoted_at: 2026-11-25T09:37:31Z
promoted_hash: sha256:3e9849cc040bde394113d4839f0d7c0f846edd36e61a08909864adb910903317
pr_number: 3841
tags: [promoted, decisions]
---

# PR Review Step

Every non-fork pull request gets one independent, read-only review of the whole PR before it merges, by the `pr-reviewer` agent, and the merge waits until every finding it raises is disposed. [[PR Merge Workflow]] `#### PR review` owns when it runs, `.claude/skills/gaia/references/pr-review.md` owns the procedure, and `.claude/hooks/lib/pr-review-verdict.sh` owns what a complete review record is. This page records the choices behind that design and why each was made.

## Decisions

- **Why a whole-PR reviewer at all.** The Code Audit Team reviews by remit: each member clears its own paths and lenses, and nothing reads the PR as one artifact against what it was meant to do. A completion criterion with no coverage, a body that overstates the change, a test that proves nothing, or a stale CHANGELOG line could all reach the human merge reviewer with every gate green, and a PR wholly outside audit scope reached the human with no reader at all.
- **Unanchored by construction.** The reviewer gets only a bundle built by `.gaia/scripts/pr-review-bundle.sh`: the changed files, the spec, the PR body with the audit-written sections stripped, the relevant rules, and the CHANGELOG and PR template. A hook denies its reads of audit state. A reviewer that saw the audit's conclusions would re-find what the audit already found and miss the PR-level gaps it exists to catch.
- **It gates the merge.** The merge hook, the `GAIA-Audit` success poster and `gaia wiki chain finish` all refuse until the record is complete, because GitHub auto-merge completes on the status alone and the wiki chain queues its own merge outside the hook. The gate reads only completeness (a record, a disposition per finding, fixes recorded fixed, a current PR-body section), never a finding's content or severity.
- **Merges are backed by a local review.** The merge hook, the GAIA-Audit status poster and `gaia wiki chain finish` reject merges when the branch has no local review record. The PR body section must match the local record but never serves as a substitute for it, because it can be edited independently. Merges from another clone or without the original review data are denied until the review runs again on that machine.
- **Fixes go through the audit loop or a human, never the reviewer.** A `fix` on a path a member owns becomes a `pr-<n>` veto, so the audit's own fixer repairs it and the owning member re-reviews it; the code review's hand-over could not carry these findings, since it holds one review per branch and closes after the first wave. A `fix` on a path no member owns has no reviewer to satisfy a veto, so it stops for a human. PR-body findings go to the body-truth rewrite.
- **Once per PR.** The review runs on the first clean audit unit (or at the merge step when no unit runs) and never re-runs on its own fixes, so it cannot loop. A second silent dispatch stops for a human rather than being done inline, because an inline review by the main thread would be anchored on the ledger.
- **Severity and class are the reviewer's.** A Critical or security-class finding takes only `fix`, and neither the main thread nor the reviewer can change its class after the reviewer writes it. A security-class finding leaves the local record only by severity and class.
- **Cost.** About one audit member dispatch per PR, plus one audit unit when an owned-path finding is disposed `fix`. Small and docs-only PRs do not skip it, since they are the ones that reached the human unread.
<!-- gaia:maintainer-only:start -->
- **Release version PRs are waived, by diff.** A `chore(release): v<x.y.z>` PR needs no review only when `release-bookkeeping-check.sh` also passes on its diff (`.claude/hooks/lib/pr-review-waiver.sh`), so a forged title on any other change still owes the review; there is no code in a pure release for a reviewer to read. The shipped copy never waives. The `@gaia-harness/lint` version PR lives in a sibling repository the merge gate does not cover.
<!-- gaia:maintainer-only:end -->

## Divergence

- The create-gaia lockstep merge is unchanged: the merge hook deliberately does not gate the sibling repository.
