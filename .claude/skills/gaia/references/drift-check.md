# Drift check

Contents: When it runs; The drift JSON; Matching; The step (classify, honesty, missing, unplanned or moved, commit and re-classify, report); The round step; The late pass.

This page owns the post-build test check of a plan whose plan folder carries a `TEST-DESIGN` marker. A deterministic diff against the plan's test-design table replaces the full worthiness review there: a test that matches its row gets only an honesty read, a missing planned test is written from its row, and only an unplanned or moved test gets a worth judgment. An unchanged test no row names is not drift. Which test and which layer is `.claude/doctrine/testing.md`; the table's files and row fields are `.claude/skills/gaia/references/plan/test-table.md`.

An unmarked plan, work with no planner (the work lifecycle, `/gaia-debt`) and an older in-flight plan use `.claude/skills/gaia/references/worthiness-step.md` instead.

## When it runs

The plan run's `drift-check` block runs the step after the last phase commits and the flow checks pass (a spec-less plan: after the simplify pass), before the wiki promotion and the first member dispatch, so a fix the step makes never rotates a clearance a member already earned. A `## Drift check` block already in `{PLAN_DIR}/PROGRESS.md` makes the step skip-safe on a resume: it settles only what the next classify still reports. Inside the audit loop the unit runs `## The round step`; after a clean unit the main thread runs `## The late pass`.

<!-- gaia:maintainer-only:start -->
In this repo a fix commit lands first.
The verification (`bash .gaia/tests/verify-harness.sh branch`) runs next, then the first dispatch. A commit after that verification passed needs a new pass.
<!-- gaia:maintainer-only:end -->

`<RESOLVED_ROOT>` is the working root. `{PLAN_DIR}` is the plan folder at its main-checkout absolute path; its table writes go through the scratchpad-plus-`cp` route (`.claude/doctrine/execution.md`, `## Run folder`). Scratch files live in the session's scratchpad directory.

## The drift JSON

```bash
bash .gaia/scripts/test-drift-check.sh classify --root <RESOLVED_ROOT> --plan-dir {PLAN_DIR} > <drift file>
```

It prints one JSON object whose lists are:

- `matched`: `{row, file, title, signal}` per row whose test holds.
- `missing`: `{row, file, title, security}` per row whose test does not.
- `unplanned`: `{file, title, signal}` per test new or changed on the branch that no row names.
- `unplannedDeletes`: `{file, title}` per test present at base and deleted on the branch that no `retire` row names.
- `moved`: `{row, file, title, signal, fromFile}` per unplanned test carrying a missing row's title in another file; the row leaves `missing`.
- `likelyRenames`: `{row, file, title, renamedTo}` per pairing by signal across a rename (`row` is null for a renamed test no row names). A pair whose signals are equal leaves `missing`, `unplanned` and `unplannedDeletes`; the sole remaining missing row and sole new unplanned test of one file are listed and stay in both.
- `uncoveredKeys`: requirement-source keys some approved-copy row carries that no matched row carries.
- `honesty`: `{file, title, signal, row}` per matched row's test new or changed on the branch, plus every matched `reuse` or `extend` row's test.
- `fixer`: `{row}` per missing row.
- `evaluator`: the unplanned tests plus the moved ones (with `row`).

Exit 2 is a usage error or a plan folder with no marker; exit 3 is a refusal with its reason on stderr (an approved copy that is missing or does not match the marker's `approved_sha256`, an unreadable table, a test file the extractor refuses or whose test or describe title is not a string literal, a full name repeated in a planned file, an unresolvable base). Either stops the step: surface the reason.

## Matching

A row is matched when a test at its `file` with full name `title` exists, its `caseKey` (if any) is a string literal in the test's `.each` or `.for` case table, it is not a todo, skip, fixme or conditional skip (`.skip`, `.todo`, `.fixme`, `.skipIf`, `.runIf`, `test.skip(...)` or `test.fixme(...)` in the body, a bats `skip`), its body is not empty, and its action holds:

- `new`: present.
- `reuse`: present with a signal equal to base.
- `extend`: the `caseKey` absent at base and present at head.
- `change`: present at base, and at head with a different signal.
- `retire`: absent; a `held` retire row: present.

A security row other than `retire` matches only when its current signal is in `{PLAN_DIR}/security-tests.jsonl` for that row. A test under a security row's title that the security writer did not write is unplanned drift.

`bash .gaia/scripts/test-drift-check.sh security --root <tree> --plan-dir <dir>` applies the same rule to every approved security row for the merge gate and the status post, adding that a matched test whose latest worthiness-ledger line at its current signal is `fix` is `hollow` until a fresh honesty read records `keep`.

## The step

### 1. Classify

Run the classify command above into a scratchpad file. Lists that are all empty end the step at 6.

### 2. Honesty

For the `honesty` tests: pre-clear a scratchpad verdict file with `rm -f`, then dispatch `Agent(subagent_type: "test-honesty-checker")`. The prompt carries the working root, a `Verdict file: <path>` line, says the file is JSON, and for each test the two lines `Test: <file> › <title>` and `Row: <id> › <source> › <case>`, read from the row in `{PLAN_DIR}/tests.json`. Wait for the completion notification, then classify the file:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <verdict file> --expect-count <n>
```

A no-op re-dispatches once against the re-cleared path; a second no-op is a HALT, because an absent verdict is not a keep. Record every verdict, so the merge-time presence gate finds a ledger line for each judged test:

```bash
bash .gaia/scripts/worthiness-step.sh record --root <RESOLVED_ROOT> --verdicts <verdict file>
```

A `fix` (hollow) verdict goes to a fresh `general-purpose` fixer on `model: "sonnet"` for a non-security row, or to the security writer's arm (`.claude/skills/gaia/references/security-writer.md`) for a security row, with the verdict's `artifact`. Then one fresh honesty read of the repaired tests, recorded the same way. A second `fix` is a residual named in the report.

### 3. Missing

A fresh `general-purpose` fixer on `model: "sonnet"` writes each non-security `fixer` row's test from its row (`file`, `title` verbatim, `layer`, `case`, `action`, `caseKey`); the security writer's step writes each security row's. Every fixer dispatch prompt in this step opens with an explicit Read of `.claude/doctrine/testing.md`, carries the working root and the editable list (the rows' files), and forbids state-changing git and any edit outside the list.

### 4. Unplanned or moved

For the `evaluator` tests: dispatch `Agent(subagent_type: "worthiness-evaluator")` the way step 2 dispatches, with one `Test: <file> › <title>` line per test, plus `Unplanned:` beside an unplanned test and `Moved from row: <id> (<fromFile>)` beside a moved one. Classify the verdict file with `--expect-count`, then record the verdicts with `bash .gaia/scripts/worthiness-step.sh record --root <RESOLVED_ROOT> --verdicts <verdict file>`.

- `keep`: add a row for the test with a `reason` through `node .gaia/scripts/test-design/test-table.mjs amend --plan-dir {PLAN_DIR} --root <RESOLVED_ROOT> --changes <file>` (`{"add":[row]}`); a moved test's row is replaced with its new `file` instead.
- `fix`: the step 2 fixer, then one fresh evaluation, recorded.
- `delete`: with a human, ask `Confirm the delete` (Recommended) or `Keep the test`; a confirmed delete goes to the fixer. With no human, keep the test and name it as a residual in the report.

A likely rename whose signals are equal is the row's own test under a new title: replace the row with the new `title` through `amend`.

Each `unplannedDeletes` entry asks the maintainer `Keep the test (Recommended)`, which restores it from base, or `Confirm the delete`, which adds a `retire` row with a `reason` through `amend`. Auto mode and an unattended run take the recommended keep. These never go to the evaluator.

### 5. Commit and re-classify

Confirm every changed path is one the step's fixers were given, run the Quality Gate, commit with a `test(<scope>):` subject and push. Classify once more, then run step 2's honesty read and record over every test newly in `honesty` (the tests the fixers and the security writer wrote), so every changed in-scope test ends with a ledger line at its final signal. A second Quality Gate failure or an edit outside the list stops the step with no commit.

### 6. Report

Append a `## Drift check` block to `{PLAN_DIR}/PROGRESS.md` with the counts of matched, missing, unplanned, moved, unplanned-delete and likely-rename entries, the residuals, and the `uncoveredKeys` from the final classify. The final summary surfaces it.

## The round step

Inside the audit loop, after a round that committed, the unit runs classify and keeps only the tests the round's commit changed (`git -C <RESOLVED_ROOT> diff --name-only <round base>..HEAD`), plus any row of those files. It runs steps 2 to 5 for those, unattended: a `delete` verdict keeps the test as a residual, and an unplanned delete takes the recommended keep, restored from base. Any stop the step names stops the unit `needs-human`, naming it.

## The late pass

After a `clean` audit unit and before the `GAIA-Audit` status, the main thread classifies again, because a test can still reach it unchecked: a unit that stopped before its round step, or a commit made outside a unit. Anything new takes the step's arms as residual recommendations, mirroring `.claude/skills/gaia/references/worthiness-step.md` `## The late pass`: with a human, one review list with the recommendation to record each as a residual, then `Accept all as recommended (Recommended)` or `Revise`, whose description states that a repair reopens the audit; an unattended run records them as residuals. Honesty reads still run and record, since they move no HEAD.
