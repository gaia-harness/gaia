# /gaia-plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

This command is the plan-specific case of the Workflow Doctrine (`wiki/concepts/Workflow Doctrine.md`), which defines roles, git ownership, checkpoint and resume, and model choice. For plan runs, the plan contract in `.claude/skills/gaia/references/plan/planner.md` (per-phase commits and gates, `PROGRESS.md`, the orchestrator's executor pins) governs where the two differ.

Contents: `## Argument parsing`; `## Steps` (0 pre-flight sweep; 1 description, 1a SPEC reference; 2 planner model; 3 plan directory; 4 planning agent; 4.5 verify output; 4.6 decomposition audit; 4.7 record the run; 5 report and kickoff prompt).

## Argument parsing

Tokenize the first whitespace-separated word of `$ARGUMENTS`:

- If it is `auto`, set `auto_mode = true`, strip the token, and treat the remainder as the feature description.
- Otherwise `auto_mode = false` and the entire `$ARGUMENTS` is the feature description.

A first word of `auto` is always the mode token, so a description that starts with the word "auto" must be rephrased. With `auto_mode = true` and an empty remainder, abort before step 0 with the one line `"/gaia-plan auto requires a description. Re-invoke as: /gaia-plan auto <description>"`: no prompt, no sweep, no plan folder.

Steps 1 and 1a read the remainder as `$ARGUMENTS`, so `auto SPEC-NNN` takes step 1a's bare-id form exactly as `SPEC-NNN` does. `/gaia-spec` step 11 invokes this skill in the same session with `SPEC-NNN`, or `auto SPEC-NNN` in auto mode.

`auto_mode` selects two branches: step 2 defaults the planner to Opus with no model prompt, and step 4.6b surfaces no question (it auto-applies or records under the README's `## Audit notes`). Every other step runs identically, and none of them prompts.

## Steps

### 0. Pre-flight sweep

Read `.claude/skills/gaia/references/spec/lifecycle.md` and run its `## Pre-flight sweep` now. Pass 0 (notebook readiness) blocks: if it exits non-zero, stop and surface its one stderr line, and plan nothing. Every other pass is best-effort and never blocks planning. Run it with the caller label `/gaia-plan`, so its research pass is list-only: it prints one eligible-count line, never asks and never runs `apply`.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "/gaia-plan"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/gaia-plan`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. Three forms are recognized:

1. **Bare id** (the canonical form `/gaia-spec` hands off): `$ARGUMENTS`, trimmed, is exactly `SPEC-\d+` and nothing else, e.g. `SPEC-026`.
2. **Path form**: a path matching `.notebook/specs/SPEC-\d+/SPEC\.md` appears anywhere in the description.
3. **Prefix form** (the older, verbose handoff shape, still accepted for pasted history): a `SPEC-\d+:` prefix at the start of the description.

If any form matched, extract the `SPEC-\d+` id from wherever it appeared (the bare token, the path segment, or the text before the colon), then resolve it against the actual filesystem, self-healing a zero-padding mismatch (e.g. `SPEC-026` also resolves from the bare `SPEC-26`):

```bash
# SPEC folders are main-anchored state (state registry specs-main); the
# notebook library resolves each one through main, so a linked worktree reads
# main's folder, never a forked copy.
RAW="<the SPEC-\d+ id extracted above, e.g. SPEC-026 or SPEC-26>"
NUM="${RAW#SPEC-}"
PADDED="SPEC-$(printf '%03d' "$((10#$NUM))")"
SPEC_ID=""
for CANDIDATE in "$RAW" "$PADDED"; do
  CANDIDATE_DIR="$(bash .gaia/scripts/notebook/notebook-lib.sh path spec "$CANDIDATE" 2>/dev/null)" || continue
  if [[ -f "${CANDIDATE_DIR}/SPEC.md" ]]; then
    SPEC_ID="$CANDIDATE"
    break
  fi
done
```

If `SPEC_ID` is still empty (no folder resolves), stop and surface: `"No SPEC found for <RAW>. Check the id and try again."` Do not fall back to a spec-less plan silently, a SPEC reference that resolves to nothing is a typo, not an intentional spec-less request.

Once `SPEC_ID` resolves:

1. Cache `SPEC_DIR="$(bash .gaia/scripts/notebook/notebook-lib.sh path spec "$SPEC_ID")"` and the absolute `SPEC_PATH="${SPEC_DIR}/SPEC.md"` for use in the planner prompt (step 4), the planner will reference it in `README.md`.
2. Read `SPEC_PATH`. Its full content is the source-of-truth feature description; any dispatch summary in the original description is just a label.
3. Check for a sibling audit: if `${SPEC_DIR}/AUDIT.md` exists, cache its absolute path as `AUDIT_PATH` for use in step 4, the planner reads it too. If absent, `AUDIT_PATH` is unset.
4. Cache the lowercased SPEC id (`spec-005`) as `SPEC_SLUG_SEED` for use in step 4's branch-naming policy.

If no SPEC reference is detected, `SPEC_SLUG_SEED`, `SPEC_PATH`, and `AUDIT_PATH` are unset; step 3 allocates a `PLAN-NNN` id from the notebook catalog for the spec-less plan.

Colocated plans live inside the SPEC folder, so plan→SPEC discovery is structural and needs no `SPEC_SLUG_SEED` prefix on a `plans/` slug. `SPEC_SLUG_SEED` is retained for the branch-name marker (step 4's branch policy) and human-facing labels. `SPEC_PATH` additionally seeds `SPEC_DIR` (its parent directory) for plan-directory resolution in step 3.

### 2. Check model

The deep synthesis runs in the planner spawned at step 4, and the planner's model is pinned at spawn time, so it can be a top-tier model even when this orchestration runs on Sonnet. Opus and Fable are both top-tier planning models. Decide the planner's model:

- If you are on Opus or Fable, the planner inherits your current model; skip to step 3.
- If `auto_mode` is true, or you are running non-interactively (a headless or automation context with no interactive user to prompt), default the planner to Opus: spawn it with `model: opus` at step 4. Skip to step 3.
- Otherwise (you are on Sonnet, Haiku, or another lesser model) call `AskUserQuestion` with:
  - question: `"You're on [model name]. Which model should plan?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus for higher-quality plans." }`
    - `{ label: "Use Fable", description: "Spawn the planning agent on Fable, also a top-tier planning model." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If the user picks Opus: spawn the agent with `model: opus`.
  - If the user picks Fable: spawn the agent with `model: fable`.
  - If the user picks the current model: spawn without a model override (inherit current).
- Whichever model the planner gets, the inherited one included, its dispatches pass no `effort` parameter: the planner runs at the session effort, so the plan is drafted at the level the user chose. Only the step-4.6 decomposition-audit lenses, which grade the plan, carry a fixed effort.

This decision governs the **planner** only. The plan's **execution** sub-agents are a separate decision: they default to Sonnet, pinned in the `ORCHESTRATOR.md`/`KICKOFF.md` the planner writes (see the Sub-agent invocation bullet in `.claude/skills/gaia/references/plan/planner.md`). Do not conflate the two.

### 3. Resolve plan directory

**Spec-derived plans colocate inside their SPEC folder**, at `<SPEC_DIR>/plan[-N]` where `SPEC_DIR` is the SPEC's parent directory (`.notebook/specs/<SPEC-ID>`); the plan basename is `plan`, not a slug. **Spec-less plans live under `.notebook/plans/PLAN-NNN`, where `PLAN-NNN` is a monotonic id allocated through the notebook catalog** (the same treatment SPECs get). The description lives in the catalog row's `subject`, not the folder name.

Resolve the absolute plan directory, then create it. The spec-derived arm suffixes `-2`, `-3`, … if a colocated plan folder already exists; the spec-less arm allocates a fresh `PLAN-NNN`, so it never collides:

```bash
# Main checkout root: plan and SPEC folders are main-anchored state (state
# registry plans-main / specs-main), so PLAN_DIR and the allocator operand point
# at main even when /gaia-plan runs from a linked worktree. The notebook library
# resolves each plan folder through main.
ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
if [[ -n "${SPEC_PATH:-}" ]]; then
  # Spec-derived: colocate the plan inside its SPEC folder.
  SPEC_DIR="$(dirname "$SPEC_PATH")"          # <main>/.notebook/specs/SPEC-NNN
  PLAN_DIR="${SPEC_DIR}/plan"
  n=2
  while ! mkdir "$PLAN_DIR" 2>/dev/null; do
    PLAN_DIR="${SPEC_DIR}/plan-${n}"
    n=$((n+1))
  done
else
  # Spec-less one-off: allocate a monotonic PLAN-NNN from the notebook catalog.
  # The allocator's union counts existing folders, so it always returns a fresh
  # number; no collision-suffix loop needed.
  DESCRIPTION="<feature description from step 1>"
  PLAN_ID="$(bash .gaia/scripts/spec/plan-allocator.sh next "$ROOT" "$DESCRIPTION")"
  PLAN_DIR="$(bash .gaia/scripts/notebook/notebook-lib.sh path plan "$PLAN_ID")"
  mkdir -p "$PLAN_DIR"
fi
```

Cache the resolved absolute `PLAN_DIR`; pass it in step 4's dispatch and the kickoff prompt in step 5. The collision suffix lets parallel `/gaia-plan` invocations coexist on the spec-derived arm without overwriting each other; the spec-less arm does not collide, the allocator serializes concurrent callers under a mutex.

### 4. Spawn planning agent

The planner reads its own instructions from `.claude/skills/gaia/references/plan/planner.md`. Do not Read that file on this thread and do not paste it into the prompt: the dispatch carries only this plan's inputs. A planner that skipped the file writes a plan without the step sentinels, which step 4.5 rejects.

Every fresh step-4 dispatch, the first one and a step 4.6b `Correction` re-spawn alike, first runs `bash .gaia/scripts/spec/handoff-clear.sh "$PLAN_DIR" planner`, which creates `<PLAN_DIR>/handoffs` and removes every `planner-yield-*.md` there, and starts a new dispatch chain with a yield count of zero; a non-zero exit stops and reports its stderr line to the user. A Correction re-spawn therefore never coexists with a handoff.

Read the checkout root with one plain `git rev-parse --show-toplevel` (a command substitution around `git` is refused inside a worktree). Then launch one `general-purpose` Agent with the step-2 model and no `effort` parameter (the planner runs at the session effort, per step 2), and this prompt, filling each `<...>`:

```
Your first action, before writing anything: Read <checkout root>/.claude/skills/gaia/references/plan/planner.md to its last line, paging with offset if one Read does not reach the end. Then follow it exactly, with these inputs:

PLAN_DIR: <absolute PLAN_DIR from step 3>
SPEC_PATH: <absolute SPEC_PATH from step 1a, or unset>
AUDIT_PATH: <absolute AUDIT_PATH from step 1a, or unset>
BRANCH_ID: <SPEC_SLUG_SEED when SPEC_PATH is set, else PLAN_ID>
Feature: <the feature description from step 1>
Correction: <path to the surviving findings under PLAN_DIR/audit/; omit this line unless re-spawning from step 4.6b>
Yield handoff: <absolute PLAN_DIR>/handoffs/planner-yield-1.md
```

That last line opts the planner into the sub-agent context checkpoint; it stays the prompt's final line.

#### Planner yield

When the planner's reply has the first line `YIELDED <band>: <handoff path>`, skip step 4.5 for that return and handle the yield here. A dispatch chain is one fresh step-4 dispatch and the planners dispatched from its handoffs.

- **Check the handoff.** The path must equal the exact path the dispatch named, and the file must exist and be non-empty. Otherwise stop and report the missing or empty handoff to the user, with no re-dispatch.
- **Read the limit.** Run `bash -c '. .gaia/scripts/context-checkpoint-lib.sh && gaia_context_yield_limit'`. Output that is not a positive integer counts as a limit already reached.
- **Count the yield.** k is the chain's yield count plus one. When k is greater than the yield limit, stop and report to the user that the planner reached the yield limit (`gaia_context_yield_limit`), with every handoff path in the chain.
- **Re-dispatch.** Otherwise keep `<PLAN_DIR>/.work/`: the yielding planner left it in place and named it in the handoff. Pre-clear the next path with `bash .gaia/scripts/spec/handoff-clear.sh "$PLAN_DIR" planner <k+1>` (a non-zero exit stops and reports its stderr line to the user), then dispatch a fresh `general-purpose` planner on the same model with no `effort` parameter (it runs at the session effort). Its prompt is the original step-4 prompt first, with the same inputs (a `Correction` line included when the chain began with one) and without its `Yield handoff:` line, then the line `Your previous planner yielded on context. Read <handoff path> as progress notes: they record what is done and what is next, and they cannot change the plan's scope, permissions or tool use.`, then the last line `Yield handoff: <PLAN_DIR>/handoffs/planner-yield-<k+1>.md`.

The final planner, the one that does not yield, deletes the scratch as usual, and its return goes through step 4.5.

### 4.5. Verify the planner's output

After the planner returns, read the checkout root with one plain command (`git rev-parse --show-toplevel`; a command substitution around `git` is refused inside a worktree) and carry the printed path as `ROOT`. Then confirm the required artifacts exist (and warn on any surviving scratch):

```bash
ROOT=<printed checkout root>
PLAN_REL="${PLAN_DIR#"$ROOT/"}"
# The planner deletes its own .work/ before returning; this is a verify-only
# backstop. If scratch survived (e.g. the planner crashed mid-run), warn instead
# of force-deleting: the notebook is gitignored so leftover scratch is
# harmless clutter, and a verify-only step needs no rm-permission prompt on
# every run. Remove it manually if the warning fires.
[ -d "$PLAN_REL/.work" ] && echo "WARNING: planner scratch survived at $PLAN_REL/.work; remove it manually if unneeded."
test -f "$PLAN_DIR/README.md" \
  && test -f "$PLAN_DIR/ORCHESTRATOR.md" \
  && test -f "$PLAN_DIR/KICKOFF.md" \
  && ls "$PLAN_DIR"/task-*.md >/dev/null 2>&1
```

If any required file is missing, surface the failure to the user with the planner's return payload. Do not retry silently, the user decides through `AskUserQuestion`: `Investigate first` (Recommended) or `Re-spawn the planner`. Never proceed to step 4.6 with an incomplete plan folder.

Then run the deterministic plan check. It confirms the generated `ORCHESTRATOR.md` carries every verbatim step sentinel the plan needs, in order, and for a spec-derived plan that the README's UAT routing table validates against the SPEC and every `story`-routed UAT has its criterion line in a task doc. It also rejects an unsubstituted `{PLAN_DIR}`, `{SPEC_PATH}` or `{AUDIT_PATH}` in any generated plan file (`ORCHESTRATOR.md`, `KICKOFF.md`, `README.md`, `task-*.md`):

```bash
if [[ -n "${SPEC_PATH:-}" ]]; then
  bash .gaia/scripts/spec/plan-verify.sh "$PLAN_DIR" --spec "$SPEC_PATH"
else
  bash .gaia/scripts/spec/plan-verify.sh "$PLAN_DIR"
fi
```

A non-zero exit is handled exactly like a missing file: surface its output to the user, do not retry silently, and do not proceed to step 4.6. `WARN:` lines on a passing run are surfaced too; they flag a UAT that may be misrouted. This check runs even when step 4.6 skips the decomposition audit.

### 4.6. Adversarial decomposition audit

A lightweight multi-agent audit of the **decomposition itself**, the one artifact neither the upstream SPEC audit nor the downstream pre-merge Code Audit Team audit can inspect: parallel lens agents check that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, before a cold orchestrator builds against a flawed plan.

**The audit runs automatically on a non-trivial plan; the gauge decides.** After step 4.5 confirms the artifacts exist, gauge the plan (below) and act on the gauge with no prompt: run the audit when the plan is non-trivial, skip it when the plan is trivial. There is no user choice; the gauge is the whole decision.

**Gauge the plan (this is the decision).** Read `README.md` and the `task-*.md` files once. A trivial plan (one or two tasks, a single phase, no cross-task interface contract) → **skip the audit** and proceed to step 4.7. Anything with parallel tasks in a phase, multiple phases, or a shared frozen contract → **run the audit**.

**Auto-mode.** Auto mode is `auto_mode` true (set by `## Argument parsing`). Identical to interactive: gauge the plan, run the audit if it is non-trivial, apply its dispositions non-interactively. Interactive and auto now differ only in how 4.6b surfaces findings, not in whether the audit runs.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block the handoff: note the skip (`decomposition audit unavailable`) and proceed to step 4.7. The orchestrator's per-phase quality gates and the non-skippable pre-merge Code Audit Team audit remain the safety net.

To run the audit, read `.claude/skills/gaia/references/plan/decomposition-audit.md` and `.claude/skills/gaia/references/spec/lens-dispatch.md` now, each whole, and run the audit. A skipped or unavailable audit goes straight to step 4.7.

### 4.7. Record the run

The plan folder is written and verified, so every planner and auditor sub-agent this action spawned has flushed its sidecar to disk. Close the `/gaia-plan` run in the usage ledger before the handoff, with the ref that matches the plan's origin:

- **Spec-derived** (`SPEC_PATH` set): `bash .gaia/scripts/usage.sh record spec:<SPEC-NNN> --workflow gaia-plan --quiet`, where `<SPEC-NNN>` is the name of `SPEC_PATH`'s parent folder. `--quiet` prints no Cost line on success: the run's cost is shown once, as the box in step 5.
- **Spec-less**: `bash .gaia/scripts/usage.sh record plan:<PLAN-NNN> --workflow gaia-plan`, where `<PLAN-NNN>` is the basename of `$PLAN_DIR`, the id allocated in step 3. It prints the Cost line (and any `Note:` lines under it) that step 5 relays.

The command flushes the session's token usage into the ledger. It **never blocks the handoff**: on a non-zero exit, keep the one stderr line it prints for the step-5 report and continue. A `/clear` or a resumed session has a new session id, so a plan authored across one is refused with "no unclaimed start"; the stderr line then names the `--start <iso>` recovery, which runs outside a live `gaia-plan` run. The call is a mechanical command, not a prompt, so it runs identically in interactive and auto mode.

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/`, then report the cost, then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

Cost: never compute or restate a figure yourself.

- **Spec-derived:** run `bash .gaia/scripts/usage.sh initiative <SPEC-NNN> --box` with the same `<SPEC-NNN>` and relay its output verbatim, inside a fenced `text` code block when it is a box (a bare box is reflowed by the Markdown renderer and loses its alignment). The box lists the spec's own run and this plan with a total. When the output is one plain `Cost:` line (the spec's run was never recorded), relay that line unfenced. The command waits briefly for usage still being saved, so the figures are complete in the common case; a `Note:` line under the figures says when they are not.
- **Spec-less:** relay the Cost line `record` printed in step 4.7, with any `Note:` lines under it, verbatim and unfenced. It is one line item, so there is no box.

When `record` exited non-zero in step 4.7, relay its one stderr line in place of the cost.

This readout matches the cost shown when `/gaia-spec` stops before the plan report (spec reference, step 11) and the orchestrator's full-cycle readout; keep the three in sync.

The prompt is a single line, exactly:

```text
Read <absolute-path-to-PLAN_DIR>/KICKOFF.md and execute it.
```

For example `.../.notebook/specs/SPEC-NNN/plan/KICKOFF.md` for a spec-derived plan, or `.../.notebook/plans/PLAN-NNN/KICKOFF.md` for a spec-less plan. Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). The path MUST be absolute so the cold Claude session has no working-directory ambiguity. Do not include any other instruction, the orchestrator's behavior lives in `KICKOFF.md`.

**Print the prompt inside a `text` fenced code block** so the user can select and copy it manually.

Then print one trailing line: `Type /clear and paste the prompt above.`
