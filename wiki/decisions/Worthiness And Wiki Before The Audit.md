---
type: decision
status: active
created: 2026-11-01
updated: 2026-11-01
promoted_at: 2026-10-31T15:56:24Z
promoted_hash: sha256:480436ddb170817c90e9e789992a2fc9c6912620862cf3cf4ed824c759697854
pr_number: 3210
tags: [promoted, decisions]
---

# Worthiness And Wiki Before The Audit

A GAIA run finishes its test-worthiness audit and its wiki promotion before the first code audit round, and work a branch wrote stays that branch's work: `file-tech-debt.sh file` refuses a non-security finding on code the branch authored, and routes it to a fix on the branch or an accepted residual.

## Decisions

**Why the order is what it is.** A fix or a promoted page that lands after clearance moves HEAD, which restarts required CI and can owe another audit unit. Paying that late made filing debt look cheaper than fixing, so debt was filed against tests the same pull request had just written. Running both steps first costs no clearance, because no member has earned one yet.

**The order.** A plan run goes from its phases and any pre-audit UAT checks to the worthiness step, then consolidation and wiki promotion, then the verification and the Code Audit Team audit, then the final summary, a post-clearance refresh, the status and the merge. The work lifecycle and `/gaia-debt` run the same worthiness step after their draft pull request opens and before their audit. Each plan block is a named sentinel, so a later pass can share the slot. Plans generated before this order keep their own block order. This rests on those instructions being followed: no gate refuses a dispatch that skipped the step.

**The worthiness step.** `.gaia/scripts/worthiness-step.sh` holds the deterministic half, routing and recording, and `.claude/skills/gaia/references/worthiness-step.md` holds dispatch and the human questions. A stored keep skips a test. A fix verdict on a branch-authored test goes to a fresh fixer, the changed test is judged once more, and a remaining fix verdict becomes an accepted residual. A delete verdict never removes a test without a human's answer: an approved delete goes to the same fixer, a refused delete keeps the test with no residual, and an unattended run keeps the test and records a residual. A fix verdict on a test the branch did not touch follows the filing path. Settlements are keyed by file, full name and signal, so a resume repeats no work and an edit to the test lapses them. A test is branch-authored when any line of its extent falls in a new-side hunk of the branch's diff, with the extent taken from the same parse that produces the test's signal.

**A late fix.** An audit fixer can edit a judged test, so the main thread runs the route again after a clean unit. Evaluating costs no commit, and only a fix verdict reaches a priced question, which recommends the fix, states which clearances rotate and the CI cycle, and offers an accepted residual as the alternative. A worthiness refusal at merge makes the same recommendation and never suggests filing debt.

**The filer's refusal.** `file-tech-debt.sh file` runs the security screen, then for a non-security finding the authorship test, then the existing probe and dedup. An authored site produces a `refused-authored` outcome with no issue created: one stdout line, exit 0, and the two routes on stderr. The subject is the committed HEAD of the tree holding the script against its merge base with the default branch, so a linked worktree tests its own branch and an uncommitted edit does not count. Nothing is authored on the default branch. An uncomputable merge base files with a recorded note, since losing a finding costs more than one misfile. A security-class finding skips the authorship test and keeps its existing handling.

**Reading the refusal.** `audit-dispositions-check.sh check-outcomes` reports `refused-authored` as a named violation. The audit unit re-disposes the entry as a fix or an accepted residual, and the round stays open until the check clears. A replayed retry records the finding as a residual without editing a frozen dispositions file. Callers with no accepted residuals heading list the finding as unfiled in their summary, and `/gaia-residue` leaves the candidate for a later run from the default branch.

**What stays outside this decision.** The maintainer-only CHANGELOG gate's commit can still land after the audit, so a change owing an entry restarts CI once. What the evaluator judges does not change, and neither does the presence check's decision.
