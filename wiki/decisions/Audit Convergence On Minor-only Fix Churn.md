---
type: decision
status: active
created: 2026-11-01
updated: 2026-11-10
promoted_at: 2026-11-01T11:43:15Z
promoted_hash: sha256:1cc302513f499a7e96c556eacbf89a7e88a128a60beaa7d3314fa0ff54119097
pr_number: 3224
tags: [decision, audit, quality]
---

# Audit convergence on Minor-only fix churn

The audit loop ends on its own from round 3 through round 9 when a round reviewed only an incremental delta and reports nothing but ordinary Minor findings. Those findings become accepted residuals shown on the pull request and in the merge report, the loop makes no further commit, and every commit it did make has been reviewed.

## Decisions

Late rounds review only the previous fix, so they mostly critique that fix: each one costs a member wave and a full gate run for findings such as translation-key tidying. The loop already had signals for fix-on-fix churn, but they stopped for a human, and an all-Minor round waited until round 6. The default stop ends the ordinary case without a human and keeps the human for the cases that need one.

**The default stop.** `.gaia/scripts/audit-loop-eval.sh`'s header owns the formula and is its single owner; pages point at it. In outline: every dispatched member reviewed incrementally and holds an earned marker for its current digest, the round's history is readable, every counted finding is Minor and not security-class, nothing in the round of any authorship is Critical, Major or security-class, no key sits under an unsatisfied veto, and the repeat signal does not hold. A qualifying round overrides the enriching, nitpicky, small-tail and stalled signals for itself. A repeating Minor and the round-10 cap still stop at the branch checkpoint, and a checkpoint grant does not suspend the stop. A checkpoint grant lifts the same four signals for the rounds of the unit it admits, and the same two stops still hold inside it. The result and the review scope it read are frozen in the round's snapshot, so a re-grade reads the same answer.

**Only the stop or a human accepts a residual.** `.gaia/scripts/audit-dispositions-check.sh` passes an `accept-residual` entry only when the frozen stop holds for that round or a human accept is recorded, and otherwise reports `accept-residual-not-eligible`. A unit can no longer choose accept-and-note on its own. On maintainer harness paths the triage threshold wins over the stop: honored marks count toward nothing, a threshold waive may sit in a qualifying round, and a Minor meeting a fix criterion is fixed, so the stop does not apply that round.

**Residuals reach the human before the status.** The residuals render in the pull request body under the accepted residuals heading, each with its own failure mode from its sidecar entry. In an interactive run the main thread asks one question before the status posts, merge or fix chosen ones; a chosen key becomes a veto. An unattended run does not pause, and the residue drain is its route after merge. The merge report carries the residual count, read once per run from `audit-dispositions-check.sh residual-count`, and links the pull request section. The loop files none of them as tech debt.

**A veto reopens a round.** A veto after a stop leaves the tree unmoved and every member cleared, so the next unit opens a new round for the vetoed keys, commits their fix before its first member wave, then reviews the new tree. A veto is satisfied only by a fix after it that a member then reviewed without re-reporting the key, and `audit-dispositions-check.sh`'s header owns the conditions. A satisfied veto no longer blocks an accepted closing round, so the closing round needs no hand-written entry for it.

**The smaller gate.** A fix round whose entries are all Minor, non-security findings with sidecar rows runs every Quality Gate step except Playwright, the dev smoke test and the production build, and those three stay owed. `.gaia/scripts/audit-gate-owed.sh` chooses the gate and keeps the owed record. The owed steps run once on the final tree before the status posts, on every loop ending, selected from the branch range since they last ran, and the status post refuses while they are owed. A failure a fixer can take reopens a round whose fix runs the full gate; where no fixer can run, the loop stops `needs-human` naming the step. Commits the loop does not make, such as a post-clearance commit, a CHANGELOG commit, a catch-up merge or a wiki-only correction, owe nothing.

**Why these choices.** Round 3 is the first round whose incremental delta is normally a fix of a fix, and it matches the start of the existing repeat and fix-on-fix signals. An incremental delta is the branch's own change since a member's anchor, so branch-own change beside the fix can sit in it; that is an accepted limit. An absent security field reads as security, and an absent review scope reads as whole-branch, so an unreadable input fails toward today's path. Member prompts, the light route and its cap are unchanged.
