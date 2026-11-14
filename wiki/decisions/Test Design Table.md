---
type: decision
status: active
priority: 1
date: 2026-11-14
created: 2026-11-14
updated: 2026-11-14
tags: [decision, testing, plan, audit, merge, security]
---

# Test Design Table

A plan decides its tests once, at plan time, in a table of rows. The build writes tests to that table, a deterministic drift check compares the branch to it, and the merge gate refuses a merge while an approved security row has no test. This page holds the reasons and the behavior. The rules for which test and which layer are `.claude/doctrine/testing.md`; the table's files, row fields and key grammar are `.claude/skills/gaia/references/plan/test-table.md`; the post-build check is `.claude/skills/gaia/references/drift-check.md`; the security step is `.claude/skills/gaia/references/security-writer.md`.

## Why tests are decided at plan time

Tests that emerge during the build are judged after the fact, by a reviewer who sees only the test and its code. That review can only delete or repair what already exists, and it cannot see a requirement nobody tested or two tests that prove one behavior. Deciding the tests from the stated requirements before any code exists makes the requirement the unit of coverage: every requirement-source key maps to at least one row, and every row maps back to a key, so a gap or a duplicate shows up as a table defect instead of a review opinion.

A second reason is independence. A test written by the author of the code under test tends to agree with that code. The table fixes what each test must prove before the author writes the code, and a separate agent writes the security tests.

## The table, the marker and the approved copy

The plan folder carries a marker file, the table, and an approved copy of the table. `/gaia-plan` writes the marker right after it creates the folder; the planner writes the table and never the marker. At approval the approved copy is taken byte for byte and the marker records its hash. Nothing edits the approved copy afterwards, so it is the fixed reference the drift check and the merge gate compare against, and a changed approved copy no longer matches the marker. A plan with the marker is a marked plan; `plan-verify.sh` requires the marker on every new plan.

The marker's presence is what routes the later steps: a marked plan takes the drift check, and an unmarked plan takes the worthiness step.

## The test-design lens and its refuter

The plan's decomposition audit always runs a test-design lens over a plan with a table, whatever the plan's size, because the table is the one artifact the later checks trust. The lens reviews rows against the doctrine, the requirements and the existing tests that drive the touched code. Its findings are judgment calls (a layer, a duplicate, a flag), so each material one goes to a refuter that tries to disprove it before it is applied. Applying a finding edits the table and the owning task docs, and plan verification then re-checks that the table and the task docs still agree. Step 4.6c of `/gaia-plan` then approves the table; approving the plan approves its retire rows, so execution does not ask again, and an auto-mode plan holds every security-flagged retire row for the merge checkpoint.

## The security writer

A security row is a test of access, forgery or secret handling. A separate agent writes it, at the end of each build phase whose entry names security rows, so the test cannot mirror the code author's mistake. The writer's tests are recorded in an append-only authorship ledger keyed by the test's signal. A security row matches only while its current signal is in that ledger; an executor-written test under a security title is unplanned drift. A failing security test goes back to the code's owner, never to the test. The step ends without an inline fallback and halts on a repeated empty dispatch, a declared departure its owner page states.

## The audit fixer's row amendment

An audit fixer can add or replace a test, which changes what the table describes. The fixer reports its row changes in a file and the loop applies them through the table tool's amend command. Amend refuses a change that removes a security row's key coverage drops a security flag or changes a security row's kind (the merge gate reads either as a lost flag), and it names a checkpoint for a security fold that loses a key, so a fixer cannot shrink the security surface by rewriting the table. The approved copy stays untouched, which keeps the merge gate's reference intact. A security row the fixer adds or replaces goes to the security writer before the round's gate.

## The drift check's routes

After the last phase the drift check classifies the branch against the table and gives each class its own route:

- A matched test gets an honesty read only, by a dedicated checker; a hollow verdict is repaired and read again.
- A missing row's test is written from the row by a fresh executor, or by the security writer for a security row.
- An unplanned or moved test is the only kind that gets a worth judgment from the worthiness evaluator. A kept one gains a row with a reason.
- A test the base had and the branch deleted without a retire row asks the maintainer, defaulting to keep.

An unchanged test no row names is not drift. Inside the audit loop the unit runs the same step over the round's commit, unattended, and the main thread runs it once more after a clean unit for anything that arrived unchecked. The step ends without an inline fallback: an absent verdict is not a keep, so a repeated empty dispatch halts it, a declared departure its owner page states. Each honesty read and each evaluator verdict records a ledger line, so the worthiness presence gate keeps finding the line it reads; the drift check writes the same ledger and adds no second one. No overlap pass runs: the table decides the layer, so a separate pass hunting for redundant or misplaced tests has nothing left to find.

## The security-row merge gate and its grant

A PreToolUse hook on `gh pr merge` denies the merge while an approved security row is missing from the current table, has lost its security flag, or has no matching test the security writer step registered in the plan's ledger and not judged hollow (the ledger records registration, an instruction-level separation from the task executor, not an enforced check of who wrote the test). Whether the tests pass stays CI's job; the gate checks only that each approved security row is still planned, still flagged and still tested. The verdict lives in one library that the gate and the status post share, and every error path fails closed with its reason: an unloadable library, an unresolvable branch, two plan runs claiming one branch, an unreadable table, an approved copy that no longer matches the marker. This is deliberate, since it is the backstop for a security row's test. It trusts the plan folder's own files (`RUNNING`, `TEST-DESIGN`, the tables and the ledger), which no write-guard hook covers, so a Claude write that removes the sentinel or the marker makes it allow.

The gate finds the table through the branch's plan run, and it reads the branch of the checkout it runs in. A merge run from the default branch's checkout finds no plan and allows, so the status post runs the same security check and declines its success post on an uncovered row; that is what holds the path and what stops a GitHub auto-merge from completing around the hook. A plan with no marker has no approved security rows, so it allows.

A maintainer can release a row by typing `test-row-grant <row id>` in an interactive session. A second hook records the grant against the marker's approved hash and the grant counts only while that hash still matches, so it never carries to a later approved table. The grant lives in the audit loop's protected folder, covered by that folder's existing write guard.

## Why older plans and unplanned work keep the full review

Work with no planner (the work lifecycle, `/gaia-debt`), an unmarked plan and an older in-flight plan have no table to compare against. Without a table every changed test is unplanned, so the drift check would reduce to the full review anyway. Those paths keep the worthiness step ([[Worthiness And Wiki Before The Audit]], [[Worthiness Audit]]) so no test lands unjudged.

## Related

- [[Worthiness Audit]] and [[Worthiness Presence Gate]]: the review and its merge-time ledger check.
- [[Test Layering]] and [[Testing Trophy Doctrine]]: the reasons behind the layer rules.
- [[Task Orchestration]] and [[GAIA Plan]]: where the steps sit in a plan run.
- [[Code Review Audit Agent]]: the terminal-ending contract and the departures this page's steps declare.
- [[Claude Hooks]]: the merge gate and grant hook.
