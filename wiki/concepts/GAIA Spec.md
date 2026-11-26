---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-11-24
tags: [concept, claude, skill, orchestration]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's script-driven Socratic discovery workflow; no spec-kit runtime is involved. It produces an immutable SPEC artifact at `.notebook/specs/SPEC-NNN/SPEC.md` (see [[Notebook]]), then plans the SPEC in the same session through [[GAIA Plan]] and stops at the plan's KICKOFF prompt; execution starts in a fresh session. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

The workflow runs on GAIA's own scripts in `.gaia/scripts/spec/` and Claude-read prose in `.claude/skills/gaia/references/spec/`, called directly by the skill.

For cross-cutting architecture, consider `/effort high` before starting.

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** See `.claude/skills/gaia/references/spec.md` (Hard constraints).
- **One question at a time in the clarify loop.** Each answer shapes the next question. Closed-set questions go through `AskUserQuestion` within its four-option cap: recommended FIRST, up to two alternatives, `Discuss this`. The tool supplies `Other`, which also takes a typed save request; `.claude/skills/gaia/references/spec/clarify-loop.md` owns the full option contract, and `.claude/rules/user-questions.md` the general rule behind it. Open-ended questions use plain prompts.
- **Closed-set decisions are menus.** Both gates ask `Looks right` (Recommended) or `Revise` through `AskUserQuestion`, a typed revision arriving through `Other`. Review findings are never listed for a per-finding decision: the fixer applies them and gate 2 surfaces only what stays unsettled.
- **Two-gate ceremony.** Gate 1 confirms intent + critical flows in plain language before the clarify loop. Gate 2 confirms the SPEC from a brief of the draft and its review before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

**Model gate (pre-flight).** On entry, before any SPEC id is allocated. SPEC synthesis runs on the main thread, so it uses the session model, and unlike [[GAIA Plan]] this skill cannot pin a subagent (the interactive `AskUserQuestion` and plain-prompt steps do not work in dispatched subagents). Opus and Fable are both top-tier. On Opus or Fable it proceeds silently; on Sonnet/Haiku it offers, via `AskUserQuestion` (header `Model`), to switch to Opus (Recommended) or Fable, or stay on the current model. Picking a switch stops the workflow with a `/model`-and-re-run instruction (nothing is allocated or written); "stay" proceeds on the current model. Auto mode skips the gate and runs on whatever model the automation uses.

1. **Get description.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait.
2. **Resume-vs-start prompt.** `.gaia/scripts/spec/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. First the pre-flight sweep runs (`.claude/skills/gaia/references/spec/lifecycle.md` `## Pre-flight sweep` owns its passes, order and which one blocks), then `.gaia/scripts/spec/spec-abandon-empty.sh` retires any never-authored draft to `abandoned` (best-effort; see [[#Ledger status vocabulary]]). No silent overwrite, no silent fresh allocation.
3. **Initial draft (allocate, anchor, stamp).** Allocate the id via `.gaia/scripts/spec/spec-allocator.sh next` with a non-empty subject and halt on a non-zero exit. Create the main-anchored SPEC folder, failing closed when the main checkout cannot be resolved. Write the draft from `.claude/skills/gaia/references/spec/spec-template.md` with the GAIA frontmatter stamped (immutable flag, frozen `SPEC-NNN` id).
4. **Gate 1: shape confirmation.** Print the intent in one or two plain sentences and every proposed critical flow as one plain-language line, the recommended set marked (never a count, a theme list, or a pointer to the draft file), then ask `Looks right` or `Revise` through `AskUserQuestion`. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the draft step reads it as the confirmed sketch).
5. **Socratic loop.** Sequential coverage-based questioning, run in every mode (auto mode keeps the Recommended option for a closed-set question and answers an open-ended one itself, each recorded). Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human. Coverage over the topic bank (Clear / Partial / Missing) is the loop's stop condition, bounded by a question ceiling (`.claude/skills/gaia/references/spec/clarify-loop.md`).
6. **Requirements file.** When the loop stops, before the draft, `REQUIREMENTS.md` is written beside the SPEC: the brief and every clarify question and answer word for word. It is never committed and nothing edits it again; `.claude/skills/gaia/references/spec/clarify-loop.md` `## The requirements file` owns its shape and the pointer form a SPEC uses to cite one of its sections.
7. **Draft.** One turn writes the whole SPEC from `REQUIREMENTS.md`, the gate-1 sketch and the folded clarifications. Every behavior the requirements imply, error cases, refusals and security rules included, is stated under `## Behaviors` with a stable id, one kind and its cases; `.claude/skills/gaia/references/spec/spec-template.md` owns the section and `.gaia/scripts/spec/behaviors.mjs` its parser. The SPEC plans no tests: the test stage reads the behaviors later ([[Test Stage]]). Pending clarifications are resolved or deferred before review.
8. **Review.** One parallel wave of lens auditors runs over the draft on every spec with no prompt and no tier: five core lenses always, specialists only when the draft touches their area. A batched refuter runs only when the wave raises a critical finding, over the critical findings alone. One fixer then applies every finding, preserving each case it changes, and writes `AUDIT.md`; `.gaia/scripts/spec/drop-check.mjs` refuses a fix that removes a case with no destination or changes a behavior sentence no fix traces. Anything unsettled is recorded in `clarifications.deferred[]`. `.claude/skills/gaia/references/spec/audit.md` owns the wave, the refuter, the fixer and the drop check, and `.claude/skills/gaia/references/spec/lens-dispatch.md` the shared lens contract. It runs on the skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it works headless and in auto mode. Never blocks save.
9. **Gate 2: artifact confirmation.** Print a brief that synthesizes the draft and its `AUDIT.md`: what changes, why, and what success looks like; every flow as one line; what the plan will do for the audit's directives; the accepted risks; every Not settled item the review left in `clarifications.deferred[]`; and the paths to both files. It stays short enough to read in a session, never the whole artifact, and it never drops a flow or an accepted risk to stay short. `spec.md` step 9 owns its order and length bound. Then ask `Looks right` or `Revise` through `AskUserQuestion`. Revise to convergence, then proceed.
10. **Save** to `.notebook/specs/SPEC-NNN/SPEC.md` with one allowlisted command, `.gaia/scripts/spec/spec-save.sh`, which also flips the catalog row to `ready`, clears the draft caches and closes the run's usage record; its header owns the steps. One command keeps the save free of a permission prompt, which a compound shell command cannot. See `.claude/skills/gaia/references/spec.md` (10. Save to .notebook/specs/SPEC-NNN/SPEC.md).
11. **Immutability lint.** The skill runs `.gaia/scripts/spec/lint.sh` itself on the saved SPEC (frontmatter, a `flows:` list in place of `uats:`, a well-formed `## Behaviors` section, every answered clarification present in `REQUIREMENTS.md`, no placeholders; `lint.sh`'s header owns the check list). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: a `## Reopen rationale` section required.
12. **Plan in the same session, then stop.** After the final lint outcome, and only after a step-10 save, `/gaia-spec` invokes the `gaia-plan` skill once with the bare id (`auto SPEC-NNN` in auto mode); `/gaia-plan` resolves the id to `.notebook/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, when the audit produced one) itself. The session ends at the plan's KICKOFF report; execution never starts in this session. The planner synthesis and the decomposition auditors run as fresh sub-agents, so a `/clear` between spec and plan buys no cleaner planning. The plan run's main-thread steps (its gauge read and the fold of material decomposition findings) do carry the spec context, so a chained plan's cost reads higher than a fresh-session one, an accepted trade. The session shows its cost once, as the cost box at the end of the plan report; the spec's own record is silent. The boundary sits at execution, which runs for hours in its own orchestrator session and is the step people defer. Entering through the skill is what lets the usage ledger pair the plan run's close with a start ([[Usage Ledger]]). A chained plan run that stops before its report ends on the stop reason, the cost so far, and a fresh-session `/gaia-plan SPEC-NNN` recovery. The stop is held in prose with no hook. See [[Task Orchestration#Topology]].

## Critical flows

A SPEC names the feature's critical user flows under a `flows:` key. At gate 1 the skill proposes the flows with a recommended set marked, and the user confirms, drops, adds or edits them; the confirmed list is what the draft keeps. A flow is critical when breaking it blocks a user's main task or risks data, money or security. There is no quota and a flow carries no branch list. Its shape lives in `.claude/skills/gaia/references/spec/spec-template.md`: a web flow lists the folders it covers, and a CLI or harness flow names its test path instead. The SPEC lint refuses a SPEC that still carries the older `uats:` key. The [[Test Stage]] turns each flow into one test in a closing phase after the build.

## SPEC number allocation

SPEC numbers are reserved as immutable `spec/NNN` git tags pushed to the remote, pointed at git's empty-tree object so they pin no history and carry no commit alive; each is annotated once, at reservation, with the spec's one-line subject, readable via `git tag -n`. The registry survives a fresh clone; an existing clone syncs new reservations with `git fetch --tags`. The next number is max+1 over the union of those tags and the machine's local signals (the catalog, plan branches naming a SPEC as read by `.gaia/scripts/branch-name-lib.sh`, `.notebook/specs/` folders). Cross-team collision-avoidance reads the remote `spec/*` tag namespace live, not locally-fetched tags, so it never depends on a stale local mirror. The catalog is one union input, holding draft status, intent, and timestamps per machine: load-bearing local state, not scratch.

## Ledger status vocabulary

Each spec is one row of the notebook catalog, a local, gitignored per-machine file ([[Notebook]] owns it; the notebook library's header owns the row schema). The `status` field on a spec row is exactly one of four canonical values:

- `draft`: allocated, still being authored. The only status `.gaia/scripts/spec/spec-allocator.sh in_progress` surfaces for the resume-vs-start prompt.
- `ready`: artifact finalized and frozen. Downstream plan → implement → merge owns the feature from here.
- `merged`: the implementing PR has landed; `merged_at` records when. `.gaia/scripts/spec/spec-reconcile.sh` sets this from git ground truth.
- `abandoned`: a draft retired terminally, either a never-authored ghost or an authored one dropped for cause. `.gaia/scripts/spec/spec-abandon-empty.sh` sets this on every `/gaia-spec` preflight for a draft row that is BOTH empty (no SPEC.md, no draft cache, no gate-1 snapshot) AND older than the guard age (~1 day); an authored draft dropped for cause (a falsified premise, a change that shipped the same intent elsewhere) is set the same way through `.gaia/scripts/spec/ledger-update.sh`'s chokepoint, or by whatever process makes that call. Either way `abandoned_at` records when. `.gaia/scripts/spec/spec-allocator.sh in_progress` does not surface it, so it stops re-appearing on the resume-vs-start prompt, and (like a merged row) its folder is reaped once `abandoned_at` ages past the retention window (see [[#When a SPEC folder is deleted]]).

No other value is valid. `.gaia/scripts/spec/ledger-update.sh` is the single chokepoint for ledger writes; it accepts only these four canonical values and rejects anything else (exit 6), so a stray label cannot reach the ledger through a tool path. This ledger `status` is a distinct axis from the SPEC-artifact frontmatter's own `status` field (`in-progress | reopened | closed`, validated by `.gaia/scripts/spec/lint.sh`), which tracks whether the artifact itself is being drafted, has been reopened for amendment, or is closed, and from the `{PLAN_DIR}/RUNNING` execution sentinel, which tracks whether a plan is actively running. All three answer different questions and are never conflated.

A hand-edited ledger can still hold an off-vocabulary status. `spec-reconcile.sh` renames the one known alias (`shipped` to `merged`) through the guarded chokepoint on every `/gaia-spec`, and logs any other off-vocabulary status without guessing its lifecycle position. Such a row is repaired by hand through `.gaia/scripts/spec/ledger-update.sh`, which rejects a non-canonical value (exit 6).

## When a SPEC folder is deleted

A merged SPEC's working folder is kept at merge, not removed. Consolidation reads `SPEC.md` → `AUDIT.md` → the colocated plan's `PROGRESS.md` (top wins) and produces a verified `SUMMARY.md` before the merge; once the merge is confirmed, the orchestrator's post-merge close removes `SPEC.md` and `AUDIT.md`: what the folder keeps after the close, until the retention window reaps it with the folder, is listed in `.claude/skills/gaia/references/spec/lifecycle.md` `## Post-merge close`; the run's durable cost lives in the usage ledger ([[Usage Ledger]]; see [[Task Orchestration]]). The ledger row stays at `merged`, the terminal lifecycle state; the whole folder is reaped later, once it clears the retention window.

Two steps handle a merged folder:

- **Post-merge close.** The `/gaia-plan` orchestrator confirms the merge, reconciles the ledger, verifies `SUMMARY.md`, removes `SPEC.md` and `AUDIT.md`, and archives the plan folder. `.claude/skills/gaia/references/spec/lifecycle.md` owns the steps. Nothing reaps the folder early: the retention window is the only clock.
- **Auto-sweep.** `.gaia/scripts/spec/spec-archive-merged.sh` runs on every `/gaia-spec` and `/gaia-plan` pre-flight. It reaps any folder whose ledger row reads `merged`, whose `SUMMARY.md` is present and well-formed (a folder still holding `SPEC.md`/`AUDIT.md` with no consolidated `SUMMARY.md` is kept, consolidation never ran), whose `merged_at` has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days), and whose runs the usage ledger records (a fail-closed check: `usage.sh represented` must find a `gaia-spec` close for the SPEC, and a `gaia-plan` close too when the folder holds a plan subfolder, and a `gaia-test` close too when a plan subfolder's `TEST-STAGE` reads running or ran; a missing or unreadable ledger blocks that folder's reap, and a keep line names the `usage.sh record` recovery command). A merged row with no active folder is skipped. This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a close that never ran. The sweep is silent-but-logged: one summary stdout line listing the folders reaped.

An **abandoned** SPEC's folder follows the same clock on a simpler path: there is no merge event and no early reap, so auto-sweep is the only path, and there is no consolidation gate (nothing about an abandoned draft is ever promoted into the wiki), so the whole folder reaps as one unit. `.gaia/scripts/spec/spec-archive-abandoned.sh` runs alongside `spec-archive-merged.sh` in the same place, the `/gaia-spec` pre-flight sweep. It reaps any folder whose ledger row reads `abandoned` and whose `abandoned_at` has aged past the same retention window. An abandoned draft never closes a run, so the sweep does not consult the usage ledger and the reap waits on nothing beyond the retention window. The sweep is silent-but-logged: one summary stdout line listing the folders reaped.

### Durability

A `.notebook/specs/<ID>/` folder is working state, not the archival
record: it is gitignored, machine-local, and reaped by design after the
retention window above, whether the row is `merged` or `abandoned`. For a
merged SPEC the durable source of truth is the implementing PR, plus
anything the SPEC's content promotes into the wiki; consult those, not the
folder. An abandoned SPEC has no implementing PR and nothing promotes into
the wiki, so its folder genuinely is the only surviving record of the
audit findings and reasoning while it exists. That is a deliberate trade,
not an oversight: a SPEC is abandoned for a definitive reason, and
revisiting one past the retention window is vanishingly unlikely, so the
folder is not kept indefinitely just to hedge against it. Whether either
kind of folder is still present or already reaped says nothing about
whether its intent, decisions, or history are recoverable; consult the PR
(and the wiki, where promoted) for a merged SPEC, or accept that an
abandoned SPEC's detail does not outlive the window. Never mutate or
delete a folder to probe a lifecycle script's behavior or gates; read the
script instead. A folder's routine reap is not data loss.

## Pairs with

- [[GAIA Plan]]: the planning run step 12 chains into.
- [[Task Orchestration]]: what `/gaia-plan` produces.
