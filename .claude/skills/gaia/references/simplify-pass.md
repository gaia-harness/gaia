# Simplify pass

Contents: When it runs; The step (skip, dispatch, classify, read the tree, gate, discard, report); Permissions.

This page owns a plan run's one whole-branch `simplify` pass, in its closing stage. An executor applies it, so the main thread still edits nothing, and the orchestrator commits. It never blocks the run: every outcome is recorded, and only a discard that cannot save its patch halts.

## When it runs

The orchestrator's main thread runs the step once, after the last phase commits and before the pre-audit flow checks (a spec-less plan: before the worthiness step), so they and the pre-audit verification see the final shape. It never runs inside the audit loop, where an edit moves HEAD and voids the verification pass.

`<RESOLVED_ROOT>` is the working root. `<RUN_FOLDER>` is the run folder `.claude/doctrine/execution.md` names, at its main-checkout absolute path. Scratch files live in the session's scratchpad directory.

## The step

### 1. Skip

An exact `## Simplify pass` heading already in the plan folder's `PROGRESS.md` ends the step. So does a commit with the subject `refactor: simplify the branch as a whole` on the branch, a pass that committed and stopped before its record: record it as `applied` and end the step.

Otherwise read the base and the tree:

```bash
git -C <RESOLVED_ROOT> merge-base HEAD <default branch>
git -C <RESOLVED_ROOT> status --porcelain
```

No merge base, or a tree that is not clean, records `Result: not run` with the reason and ends the step.

### 2. Dispatch

Pre-clear a scratchpad result file with `rm -f`. Capture `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`. Dispatch one fresh `Agent(subagent_type: "general-purpose", model: "opus")` with no `effort`, no `Yield handoff:` line and no SendMessage continuation. Opus is the one measured configuration for this lead, whose job is judging findings. The reviewers' models are the skill's choice.

The prompt opens `You are the simplify pass executor for this plan.`, then carries:

- The working root and the expected-tree check: first run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to the captured value; on a mismatch, make no edit and report `could not run`.
- This call: `Skill(simplify)` with the args `Scope: the whole branch diff, git diff <merge base sha>...HEAD, run from <RESOLVED_ROOT>. The working tree is clean, so do not use the uncommitted diff. Review every changed file in that range and apply the fixes to the working tree. Do not commit. Do not install dependencies or run tests.` The range is required: the skill defaults to `@{upstream}...HEAD`, which is empty on a pushed branch, so an unscoped pass reviews nothing and reports clean.
- A refused or missing `Skill` call is reported as `could not run` with the exact error, never replaced by a review of its own.
- No git that changes state, for it or for any reviewer it dispatches.
- The result file: a JSON array of one object, `{"outcome": "ran" | "could not run", "reason": "<exact error, or empty>", "applied": <n>, "skipped": <n>}`. It returns a short summary.

### 3. Classify

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <result file> --expect-count 1
```

On a no-op with a clean tree, re-dispatch once against the re-cleared path. A second no-op records `Result: not run` and the run continues. This departs from the general inline ending (`wiki/concepts/Code Review Audit Agent.md`, `### The terminal action, stated once`) deliberately: the main thread edits nothing in a plan run, and nothing depends on this pass.

### 4. Read the tree

Run `git -C <RESOLVED_ROOT> status --porcelain`. The tree decides, not the report:

| Tree | Report | Next |
|---|---|---|
| clean | `ran` | `Result: no changes` |
| clean | `could not run`, or no result | `Result: not run`, with the reason |
| changed | `ran` | step 5 |
| changed | `could not run`, or no result | step 6, reason `the pass stopped partway` |

### 5. Gate and commit

Run the Quality Gate (`wiki/decisions/Quality Gate.md`) without step 1, saving its output to a scratchpad log. On a pass, commit with the subject `refactor: simplify the branch as a whole` and push. Any step that does not pass, or a commit a hook refuses, goes to step 6 with no repair attempt. A refused push stops under the plan's Stop conditions, as a phase push does.

<!-- gaia:maintainer-only:start -->
On the maintainer repo, a new shipped file the pass added owes its answer in that commit, by the wiki promotion's manifest note (`.claude/skills/gaia/references/spec/wiki-promote.md`).
<!-- gaia:maintainer-only:end -->

### 6. Discard

Copy the gate log to `<RUN_FOLDER>/simplify-gate.log` with one plain `cp`, then run:

```bash
bash .gaia/scripts/simplify-discard.sh --root <RESOLVED_ROOT> --patch <RUN_FOLDER>/simplify-discarded.patch
```

Exit 0 records `Result: discarded` and the run continues. Any other exit reset nothing, so the edits are still in the tree: append `## Simplify pass (HALTED)` with the script's stderr line, a heading step 1 does not match, then ask one `AskUserQuestion`, `Stay halted (Recommended)` first, then `Discuss this`, and append the pick as `Answered: <label>`.

### 7. Report

Append to `PROGRESS.md`, and print the block in the final summary:

```
## Simplify pass
Result: <applied | no changes | not run | discarded>
Reason: <one line; required unless Result is applied or no changes>
Commit: <short-sha or none>
Changes: <applied and skipped counts from the result file, or none>
Patch: <path to the patch, or none>
Gate log: <path to the log, or none>
```

## Permissions

A sub-agent cannot prompt, so a tool call the project's allow rules do not cover is refused in the executor or its reviewers. A refused `Skill` call records `not run`. A refused edit leaves a partial pass, which the gate commits or step 6 discards. `simplify-discard.sh` has no allow rule on purpose, so an attended run asks before the reset. Denied, it resets nothing and the run halts as in step 6.
