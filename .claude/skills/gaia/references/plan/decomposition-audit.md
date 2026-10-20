# Decomposition audit

The `/gaia-plan` step 4.6 audit, run when the gauge in `plan.md` says the plan is non-trivial. `.claude/skills/gaia/references/spec/lens-dispatch.md` is the lens contract: the shared preamble, the findings file each lens writes, and the pre-clear, classify and re-dispatch steps. This file owns which lenses run and how their findings are applied.

Contents: `## What the audit checks`, `## 4.6a. Dispatch the lens auditors`, `## 4.6b. Apply findings`.

## What the audit checks

A lightweight multi-agent audit of the **decomposition itself**: the one artifact neither the upstream SPEC audit (which ran before the plan existed) nor the downstream pre-merge Code Audit Team audit (which sees the executed diff) can inspect. It verifies that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, BEFORE a cold orchestrator burns execution cycles building against a flawed plan.

The audit stays narrow: three checks that exist only at plan stage, and no refutation pass (these findings are checkable and binary). It dispatches the same parallel `general-purpose` Agent primitive step 4 uses, each call at `effort: "medium"`, so it works headless and in auto mode.

## 4.6a. Dispatch the lens auditors

1. Choose the lenses. The **SPEC coverage** lens is dispatched only when `SPEC_PATH` was set in step 1a; the other two always run. A SPEC-less plan's undispatched SPEC coverage lens is recorded not-applicable, never as a no-op.
2. Clear and create the findings directory `<PLAN_DIR>/audit/`, spelled repo-relative as the contract's pre-clear step does: `rm -rf <repo-relative PLAN_DIR>/audit`, then `mkdir -p <repo-relative PLAN_DIR>/audit` (for example `.notebook/plans/<PLAN-NNN>/audit`, or `.notebook/specs/<SPEC-ID>/plan/audit` for a spec-derived plan).
3. Spawn **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens, each passing `effort: "medium"` on the call). Each prompt is the contract's shared preamble filled from its plan column (including its rule that, in a linked worktree, the lens writes its file with `Bash` at the main-checkout path (the clone's primary working directory, on any branch) and reads it back), with `<repo_root>` = `$PWD` and `<FINDINGS_DIR>` = `<PLAN_DIR>/audit/`, then the `LENS:` line and the lens's focus text below. Each lens writes `<PLAN_DIR>/audit/<LENS>.json` (`DP.json`, `CG.json`, `COV.json`) and returns only the short summary. A dispatch rejected with an error that names `effort` or an unknown or unrecognized parameter means Claude Code is older than 2.1.292: stop, tell the user to run `claude update` and relaunch, and never re-dispatch without `effort`.
4. Classify each lens's file after its completion notification with the contract's `audit-noop-detect.sh` call, re-dispatch a no-op lens exactly once against its re-cleared file, with the same `effort: "medium"`, and on a second consecutive no-op run it inline, all per the contract's `## Pre-clear, classify, re-dispatch`.

The lenses:

- **Decomposition & dependency soundness (id prefix `DP`).** The highest-value lens, with no analog upstream or downstream. Attack the task graph: tasks placed in the same phase as "parallel" that actually share state, edit the same files, or consume each other's outputs; phase order that does not respect a real data or interface dependency; a frozen interface contract that two tasks interpret inconsistently; acceptance criteria that are not independently verifiable; a task in a parallel phase whose acceptance criteria run a repo-wide mutating or shared-state check (the project's lint script, typecheck or typegen, Playwright, a dev server) instead of one scoped to its own files, which races its siblings in the shared tree. Construct the concrete scenario where every per-task acceptance criterion passes yet the integrated result is broken. Flag as `critical` any task that registers net-new files into `.gaia/manifest.json`, or that treats a file's absence from the manifest as `/update-gaia` drift: the manifest is release-generated only.
- **Contract grounding (id prefix `CG`).** Treat every file path, export subpath, type name, and function signature named in a task's interface contract or files-to-touch list as a factual claim, and verify each resolves against the real repo and `node_modules`. A contract that names a non-existent export, a wrong signature, or a hallucinated module is at least `major`, likely `critical`: the orchestrator will build against it and fail at integration.
- **SPEC coverage (id prefix `COV`, dispatched only when `SPEC_PATH` is set).** Build the matrix SPEC `UATs` + `success_criteria` ↔ task acceptance criteria. Find the holes: a UAT or success criterion no task covers; a task that drifts from or contradicts the SPEC's binding contract; scope the SPEC declared out-of-bounds that a task re-introduces. Read `<SPEC_PATH>` (interpolated) as the source of truth.

## 4.6b. Apply findings

Read the findings from each `<PLAN_DIR>/audit/<LENS>.json` that classified real; this thread applies the fixes, so it reads the finding bodies.

- **Localized findings** (a wrong contract, a missing acceptance criterion, an uncovered UAT): fold the fix directly into the affected `task-*.md` or `README.md` yourself.
- **Structural findings** (the phase graph is wrong, tasks need re-factoring across phases): re-spawn the planner rather than hand-patching the graph. Re-run `plan.md` step 4's dispatch with its optional `Correction` input set to the path of the surviving findings under `<PLAN_DIR>/audit/`, then re-run step 4.5 against the regenerated folder. This goes through the same `PLAN_DIR` and overwrites the flawed artifacts.

**Interactive:** surface each material (critical or major) finding to the user before applying: print every one (id, issue, evidence, and its recommendation: apply the suggested fix, or keep the current plan when the finding itself recommends keeping) as text, never a count, a summary, or a pointer to a findings file, and response-length or terseness preferences do not shorten the list; then ask one `AskUserQuestion` for the whole list (header `Plan audit`), per `.claude/rules/user-questions.md`'s review-list rule: `Accept all as recommended (Recommended)` or `Revise`. `Revise` asks which findings to change and what to change, unless a typed answer through the tool's own `Other` already says, then follows up only on those; every finding not named keeps its recommendation. Record every finding's decision before applying. Apply `minor` findings by default. **Auto-mode** (`auto_mode` true in `plan.md`): auto-apply unambiguous fixes; if a repair is ambiguous (more than one defensible fix), leave the plan unchanged and record the finding in a `## Audit notes` section appended to `README.md` so the orchestrator and user see it.

Then return to `plan.md` step 4.7.
