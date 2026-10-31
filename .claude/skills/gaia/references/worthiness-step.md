# Worthiness step

Contents: When it runs; The step (route, evaluate, fix, judge again, delete, file, report); The late pass; The tdd arm.

This page owns the worthiness audit's dispatch and verdict routing. The work lifecycle, `/gaia-debt` and a plan run's orchestrator follow it, and the tdd skill follows its own arm. The evaluator's judgment is `.claude/agents/worthiness-evaluator.md`; the merge-time presence check that backs this step up is `wiki/decisions/Worthiness Presence Gate.md`.

## When it runs

The caller is the main thread of a plan run, the work lifecycle or `/gaia-debt`. It runs once the draft PR is open, before the audit's pre-dispatch verification and before the first member dispatch, so a fix the step makes never rotates a clearance a member already earned.

<!-- gaia:maintainer-only:start -->
In this repo a fix commit lands first.
The verification (`bash .gaia/tests/verify-harness.sh branch`) runs next, then the first dispatch. A commit after that verification passed needs a new pass.
<!-- gaia:maintainer-only:end -->

`<RESOLVED_ROOT>` is the working root. `<RUN_FOLDER>` is the run folder `.claude/doctrine/execution.md` names, at its main-checkout absolute path. Scratch files live in the session's scratchpad directory.

## The step

### 1. Route

Run `prune` first, then `route` into a scratchpad file:

```bash
bash .gaia/scripts/worthiness-step.sh prune --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>
bash .gaia/scripts/worthiness-step.sh route --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> > <route file>
```

Exit 3 stops the step: surface the reason on stderr. An array whose every element is `keep` or `settled`, or an empty array, ends the step with no dispatch and no commit.

### 2. Evaluate

For the tests whose route is `evaluate`: pre-clear a scratchpad verdict file with `rm -f`, then dispatch `Agent(subagent_type: "worthiness-evaluator")`. The prompt holds a `Verdict file: <path>` line, says the file is JSON, and lists one `Test: <file> › <fullName>` line per test. Wait for the completion notification, then classify the file:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <verdict file> --expect-count <n>
```

A no-op re-dispatches once against the re-cleared path. A second no-op is a HALT: stop and say why, because the caller wrote the code under judgment and an absent verdict is not a keep. Then record against the route file and route again:

```bash
bash .gaia/scripts/worthiness-step.sh record --root <RESOLVED_ROOT> --verdicts <verdict file> --expect <route file>
```

### 3. Fix

Tests routed `fix` go to one fresh `general-purpose` fixer on `model: "sonnet"`. Its prompt carries the working root, the expected-tree check, the listed test files as its only editable paths, each test's `artifact`, and the audit fixer's prohibitions: no state-changing git, no edit outside the list. It writes a JSON result array to a scratchpad file and returns a short summary. `audit-fix-verify.sh` does not apply, because no dispositions file exists.

The caller then confirms every changed path is in the list, runs the Quality Gate, commits with a `test(<scope>):` subject, pushes, and runs `settle --as fixed` for each fixed test at its new signal. A fixer entry of `cannot_fix` or `disputed` settles as a residual. A second fixer no-op, a second Quality Gate failure or an edit outside the list stops the step with no commit.

### 4. Judge again once

Return to route and evaluate what it now names, so the changed tests are judged a second time after the fix commit. A `residual` route calls `settle --as residual`. A `delete` from this judgment takes the Delete step.

### 5. Delete

With a human, ask one `AskUserQuestion` per test: `Confirm the delete` (Recommended) or `Keep the test`, rendering the cited evidence inline. An approved delete goes to the same fixer, then the Quality Gate, a commit and a push. A refused delete runs `settle --as refused` and records no residual. With no human, run `settle --as residual` and keep the test.

### 6. File

This step runs from a route read after the last fix commit, because a `file` element read earlier carries a stale `firstLine`. For each `file` element, write it to a scratchpad file, build the finding, and run the filer with an outcome file in the run folder:

```bash
bash .gaia/scripts/worthiness-step.sh finding --entry <element file> > <finding file>
bash .gaia/scripts/file-tech-debt.sh file --finding <finding file> --outcome-file <RUN_FOLDER>/worthiness-filing-outcome.jsonl
```

Read the stdout word; a non-zero exit does not stop the step. One arm per word:

- `filed` or `matched`: `settle --as filed`.
- `diverted`: `settle --as filed`, so the test never re-files and never writes a second local record.
- `refused-authored`: `settle --as residual`, passing the element's `firstLine` and `artifact`, because the site proved branch-authored. A worthiness verdict on an authored test is never filed.
- `failed`: list it in the caller's summary and leave it unsettled. It does not stop the step.
- `absent` or `transient`: list it in the caller's summary and leave it unsettled.

### 7. Report

Residuals, refused deletes and filings go in the caller's summary. A plan run appends a `## Worthiness step` block to `PROGRESS.md`, which the final summary surfaces.

## The late pass

After a `clean` audit unit and before the `GAIA-Audit` status, the main thread runs `route` again, because an audit fixer can have edited a judged test. Each route value has one arm:

- `keep`, `settled`: nothing.
- `evaluate`: the Evaluate step. It moves no HEAD. Route again afterwards.
- `file`: the File step.
- `residual`: `settle --as residual`.
- `delete`: the Delete step. An approved delete then takes the unit dispatch below.
- `fix`: ask the human, recommending the fix. The question states that the fix rotates the clearance of the member owning the test, which means a Full re-dispatch of that member and one CI cycle, with an accepted residual as the alternative. It never offers tech debt. Accepted: the Fix step, then the Judge again step, then a unit dispatch per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`. Declined, or unattended: `settle --as residual`.

A residual decided here reaches the PR body through the status post's rewrite (`wiki/concepts/PR Merge Workflow.md` `#### Posting the status last`).

## The tdd arm

The tdd skill follows this arm only. It dispatches and records, nothing else, because tdd runs once its tests pass, on work still in the working tree and possibly with no PR, and `route` selects from the saved `base...HEAD` range, so it would read an unsaved test as `[]`.

- The test list is the task's own changed emergent files, not a `route` result.
- Dispatch the evaluator with a `Verdict file:` line in the scratchpad and classify the file as the Evaluate step does, with `--expect-count`.
- Record with `bash .gaia/scripts/worthiness-step.sh record --root <root> --verdicts <verdict file>`, with no `--expect`.
- Run no repair agent, make no history change and ask no question. The verdicts go in tdd's end-of-task summary. A second no-op is reported in that summary rather than halting, because tdd never interrupts mid-implementation and the presence check backs up a missing line.
