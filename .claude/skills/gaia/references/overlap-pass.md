# Overlap pass

Contents: When it runs; The step (skip, reuse, dispatch, classify, check, dispose, report); What it never does.

This page owns the overlap pass of a plan run: a check that no test the branch changed duplicates a property another test already asserts, across the unit, route, real-server and browser layers, and that each one sits on the lowest layer that shows its property, so the pass also moves a test down to that layer. The orchestrator follows it after the worthiness step (`.claude/skills/gaia/references/worthiness-step.md`) and before the wiki promotion. The judgment is `.claude/agents/overlap-evaluator.md`; the deterministic half is `.gaia/scripts/overlap-check.sh`.

## When it runs

The orchestrator's main thread runs the step once, after the worthiness step settles and before the wiki promotion, so a fix it makes never rotates a clearance a member already earned.

`<RESOLVED_ROOT>` is the working root. `<RUN_FOLDER>` is the run folder `.claude/doctrine/execution.md` names, at its main-checkout absolute path. Scratch files live in the session's scratchpad directory.

## The step

### 1. Skip

An exact `## Overlap pass` heading already in the plan folder's `PROGRESS.md` ends the step with no dispatch and no commit. A did-not-run block suppresses a retry too, since nothing depends on the pass.

Otherwise run:

```bash
bash .gaia/scripts/overlap-check.sh route --root <RESOLVED_ROOT>
```

A printed `skip-no-playwright-change` or `skip-no-base` records `## Overlap pass` with `Outcome: skipped (<reason>)` in `PROGRESS.md`, with no commit, and ends the step. Only `run` continues. Exit 3 stops the step: surface the reason on stderr.

### 2. Reuse

When `<RUN_FOLDER>/overlap-proposals.json` exists, parses, and its `head` field equals the current HEAD, skip steps 3 to 5 and go to step 6 with no dispatch. Otherwise discard the file. Step 5 writes that `head` field, so a resume reuses the checked set rather than dispatching again.

### 3. Dispatch

```bash
bash .gaia/scripts/overlap-check.sh changed --root <RESOLVED_ROOT>
```

Capture `git -C <RESOLVED_ROOT> status --porcelain` before the dispatch. Pre-clear a scratchpad proposals file with `rm -f`, then dispatch `Agent(subagent_type: "overlap-evaluator")` once. The prompt holds a `Proposals file: <path>` line, says the file is JSON, and carries the `changed` list. Wait for the completion notification. A `git -C <RESOLVED_ROOT> status --porcelain` that differs from the capture is a HALT: the evaluator edits no tracked file, so stop and say which paths changed.

### 4. Classify

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <proposals file>
```

Pass no count: an empty array means no proposals and is a valid result. A no-op re-dispatches once against the re-cleared path. A second no-op records `Outcome: did not run` in the `## Overlap pass` block, lists it in the final summary, and the run continues to the wiki promotion. This departs from the general inline ending (`wiki/concepts/Code Review Audit Agent.md`, `### The terminal action, stated once`) deliberately, and from the worthiness step's halt: nothing depends on this pass, so an absent proposal set loses an optimization and no correctness.

### 5. Check

```bash
bash .gaia/scripts/overlap-check.sh check --root <RESOLVED_ROOT> --proposals <proposals file>
```

Write its output, the current HEAD as the `head` field, and the changed test files the evaluator's summary names as having no proposal as a `skipped` field (`[{file, reason}]`) to `<RUN_FOLDER>/overlap-proposals.json` first, before any question, so a resume reuses the checked set. A `discarded` entry is logged as unverified and goes no further.

### 6. Dispose

Attended: print every kept proposal as one review list (`.claude/rules/user-questions.md`). Each seam proposal shows its property, actor, action and the cited sibling, so the human judges whether the sibling asserts the same property for the same actor and action; the check proves only the citation and the layer. List report-only entries as information. Proposals whose `property` begins `Uncertain:` come last. Then ask one `AskUserQuestion`: `Accept all as recommended (Recommended)` or `Revise`.

Approved proposals with disposition `offer` go to one fresh `general-purpose` fixer on `model: "sonnet"`, under the same prompt constraints as the worthiness Fix step: the working root, the expected-tree check, the listed test files as its only editable paths, no state-changing git, no edit outside the list, a JSON result file in the scratchpad and a short summary. For each approved sibling-less demote (a `target` and no `sibling`), the fixer writes the replacement real-server test (the request fixture only, no page) and lists it in its JSON result as `{file, fullName, replacement: {file, line, fullName, assertion}}`; the replacement's file joins its editable paths. The orchestrator merges each `replacement` into the kept list's entry with that `file` and `fullName` before running `--post-fix`. Then re-verify the proposals the fixer acted on, before the commit. `--post-fix` accepts either the original proposals file or the kept list, and a sibling-less demote with no replacement is refused there:

```bash
bash .gaia/scripts/overlap-check.sh check --root <RESOLVED_ROOT> --proposals <file> --post-fix
```

Then confirm every changed path is in the list, run the Quality Gate, commit with a `test(<scope>):` subject, push, and run one more worthiness step. A re-check that refuses, or a second Quality Gate failure, stops with no commit and records `## Overlap pass (HALTED)`, a heading the skip in step 1 does not match.

Unattended: nothing changes. The proposals are listed in `PROGRESS.md` and the final summary.

### 7. Report

Only after disposal completes, append to `PROGRESS.md`:

```
## Overlap pass
Outcome: <applied | proposals listed | no proposals | skipped (<reason>) | did not run>
Counts: kept <n>, discarded <n>, applied <n>, report-only <n>
<one line per proposal: kind, file, fullName, disposition>
<one line per `skipped` entry: file, reason>
```

and put the block in the final summary.

## What it never does

It files no tech debt, records no accepted residual, and edits no report-only test.
