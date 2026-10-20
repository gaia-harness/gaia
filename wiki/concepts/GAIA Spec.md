---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-10-20
tags: [concept, claude, skill, orchestration]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's script-driven Socratic discovery workflow; no spec-kit runtime is involved. It produces an immutable SPEC artifact at `.notebook/specs/SPEC-NNN/SPEC.md` (see [[Notebook]]), then plans the SPEC in the same session through [[GAIA Plan]] and stops at the plan's KICKOFF prompt; execution starts in a fresh session. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

The workflow runs on GAIA's own scripts in `.gaia/scripts/spec/`, Claude-read prose in `.claude/skills/gaia/references/spec/`, and script-consumed templates in `.gaia/templates/spec/`, called directly by the skill.

For cross-cutting architecture, consider `/effort high` before starting.

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** Every write during a session lands in `.notebook/specs/**`, `.gaia/local/cache/**`, `.gaia/local/telemetry/**`, or `.notebook/catalog.json` (through the ledger and notebook libraries). Source files are off-limits. No automated check enforces this allowlist; the session polices it at the instruction level, and the step-10 lint checks only the saved SPEC's immutability.
- **One question at a time in the clarify loop.** Each answer shapes the next question. Closed-set questions go through `AskUserQuestion` within its four-option cap: recommended FIRST, up to two alternatives, `Discuss this`. The tool supplies `Other`, which also takes a typed save request; `.claude/skills/gaia/references/spec/clarify-loop.md` owns the full option contract, and `.claude/rules/user-questions.md` the general rule behind it. Open-ended questions use plain prompts.
- **Closed-set decisions are menus.** Both gates ask `Looks right` (Recommended) or `Revise` through `AskUserQuestion`, a typed revision arriving through `Other`. Self-review and audit findings print as one list, each with its recommendation, and ask once: `Accept all as recommended` (Recommended) or `Revise`, which follows up only on the findings the user names.
- **Two-gate ceremony.** Gate 1 confirms intent + UATs in plain language before the clarify loop. Gate 2 confirms the SPEC from a brief of the draft and its audit before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

**Model gate (pre-flight).** On entry, before any SPEC id is allocated. SPEC synthesis runs on the main thread, so it uses the session model, and unlike [[GAIA Plan]] this skill cannot pin a subagent (the interactive `AskUserQuestion` and plain-prompt steps do not work in dispatched subagents). Opus and Fable are both top-tier. On Opus or Fable it proceeds silently; on Sonnet/Haiku it offers, via `AskUserQuestion`, to switch to Opus (Recommended) or Fable, or stay on the current model. Picking a switch stops the workflow with a `/model`-and-re-run instruction (nothing is allocated or written); "stay" proceeds on the current model. Auto mode skips the gate and runs on whatever model the automation uses.

1. **Get description.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait.
2. **Resume-vs-start prompt.** `.gaia/scripts/spec/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. First the pre-flight sweep runs (`.claude/skills/gaia/references/spec/lifecycle.md` `## Pre-flight sweep` owns its passes, order and which one blocks), then `.gaia/scripts/spec/spec-abandon-empty.sh` retires any never-authored draft to `abandoned` (best-effort; see [[#Ledger status vocabulary]]). No silent overwrite, no silent fresh allocation.
3. **Initial draft (allocate, anchor, stamp).** Allocate the id via `.gaia/scripts/spec/spec-allocator.sh next` with a non-empty subject and halt on a non-zero exit. Create the main-anchored SPEC folder, failing closed when the main checkout cannot be resolved. Write the draft from `.claude/skills/gaia/references/spec/spec-template.md` with the GAIA frontmatter stamped (immutable flag, frozen `SPEC-NNN` id).
4. **Gate 1: shape confirmation.** Print the intent in one or two plain sentences and every UAT as one plain-language line with its id (never a count, a theme list, or a pointer to the draft file), then ask `Looks right` or `Revise` through `AskUserQuestion`. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the step-6 self-review reads this to detect scope drift before gate 2).
5. **Socratic loop.** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human. Coverage over the topic bank (Clear / Partial / Missing) is the loop's stop condition, bounded by a question ceiling (`.claude/skills/gaia/references/spec/clarify-loop.md`).
6. **Self-review.** The wrapper dispatches it as a `general-purpose` Agent after the loop and before gate 2, as an explicit step of the skill. It audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Adversarial SPEC-audit.** Before gate 2, the audit runs automatically on every spec with no prompt: the draft's stakes and content are gauged to set the rigor tier (Standard or Deep) and the specialist lens set, then the fan-out runs at that tier. Four low-overlap core lenses (factual grounding, UAT testability, coverage/consistency, red-team/feasibility) always run, plus any content-selected specialists (security, migration, accessibility, docs, performance); each verifies the draft's checkable claims against the repo and `node_modules` with `file:line` evidence. Each lens writes its findings to a file that is checked after it finishes, and a silent lens is re-dispatched once. A refutation pass keeps severity honest (Deep adds perspective-diverse refuters and a completeness critic; above a refuter cap, either tier batches one refuter per lens and Deep skips the critic); each surviving finding routes to a plan-time directive (recorded in a sibling `AUDIT.md`) or a SPEC contract fix folded into the draft pre-save (no reopen ceremony). The skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it runs in headless and auto-mode contexts. The single-agent step-6 self-review is the always-on baseline. Interactive and auto mode share the same gauge and tier and differ only in how findings surface at disposition; an unavailable fan-out falls back to the self-review. Never blocks save.
8. **Gate 2: artifact confirmation.** Print a brief that synthesizes the draft and its `AUDIT.md`: what changes, why, and what success looks like; every UAT as one line; what the plan will do for the audit's directives; the accepted risks; anything not settled; and the paths to both files. It stays short enough to read in a session, never the whole artifact, and it never drops a UAT or an accepted risk to stay short. `spec.md` step 8 owns its order and length bound. Then ask `Looks right` or `Revise` through `AskUserQuestion`. Revise to convergence, then proceed.
9. **Save** to `.notebook/specs/SPEC-NNN/SPEC.md` with one allowlisted command, `.gaia/scripts/spec/spec-save.sh`, which also flips the catalog row to `ready`, clears the draft caches and closes the run's usage record; its header owns the steps. One command keeps the save free of a permission prompt, which a compound shell command cannot. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept).
10. **Immutability lint.** The skill runs `.gaia/scripts/spec/lint.sh` itself on the saved SPEC (frontmatter, frozen UAT-NNN ids, no placeholders; `lint.sh`'s header owns the check list). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: `## Reopen rationale` and `## UAT diff` sections required.
11. **Plan in the same session, then stop.** After the final lint outcome, and only after a step-9 save, `/gaia-spec` invokes the `gaia-plan` skill once with the bare id (`auto SPEC-NNN` in auto mode); `/gaia-plan` resolves the id to `.notebook/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, when the audit produced one) itself. The session ends at the plan's KICKOFF report; execution never starts in this session. The planner synthesis and the decomposition auditors run as fresh sub-agents, so a `/clear` between spec and plan buys no cleaner planning. The plan run's main-thread steps (its gauge read and the fold of material decomposition findings) do carry the spec context, so a chained plan's cost reads higher than a fresh-session one, an accepted trade. The session shows its cost once, as the cost box at the end of the plan report; the spec's own record is silent. The boundary sits at execution, which runs for hours in its own orchestrator session and is the step people defer. Entering through the skill is what lets the usage ledger pair the plan run's close with a start ([[Usage Ledger]]). A chained plan run that stops before its report ends on the stop reason, the cost so far, and a fresh-session `/gaia-plan SPEC-NNN` recovery. The stop is held in prose with no hook. See [[Task Orchestration#Topology]].

## UAT divergence contract

The `/gaia-plan` orchestrator's UAT render step turns each browser-flow UAT into a red Playwright spec before the first implementation phase, and each rendered spec carries a contract marker plus an inline header defining the cosmetic-vs-logical boundary. The owning phase must turn the spec green, and a logical divergence halts the run for a SPEC reopen. `.claude/skills/gaia/references/spec/lifecycle.md` owns the render, gate and close steps:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running the implementation.

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

A merged SPEC's working folder is kept at merge, not removed. Consolidation reads `SPEC.md` → `AUDIT.md` → the colocated plan's `PROGRESS.md` (top wins) and produces a verified `SUMMARY.md` before the merge; once the merge is confirmed, the orchestrator's post-merge close removes `SPEC.md` and `AUDIT.md`: the folder reduces to `SUMMARY.md`, the merged folder's archival record; the run's durable cost lives in the usage ledger ([[Usage Ledger]]; see [[Task Orchestration]]). The ledger row stays at `merged`, the terminal lifecycle state; the whole folder is reaped later, once it clears the retention window.

Two steps handle a merged folder:

- **Post-merge close.** The `/gaia-plan` orchestrator confirms the merge, reconciles the ledger, verifies `SUMMARY.md`, removes `SPEC.md` and `AUDIT.md`, and archives the plan folder. `.claude/skills/gaia/references/spec/lifecycle.md` owns the steps. Nothing reaps the folder early: the retention window is the only clock.
- **Auto-sweep.** `.gaia/scripts/spec/spec-archive-merged.sh` runs on every `/gaia-spec` and `/gaia-plan` pre-flight. It reaps any folder whose ledger row reads `merged`, whose `SUMMARY.md` is present and well-formed (a folder still holding `SPEC.md`/`AUDIT.md` with no consolidated `SUMMARY.md` is kept, consolidation never ran), whose `merged_at` has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days), and whose runs the usage ledger records (a fail-closed check: `usage.sh represented` must find a `gaia-spec` close for the SPEC, and a `gaia-plan` close too when the folder holds a plan subfolder; a missing or unreadable ledger blocks that folder's reap, and a keep line names the `usage.sh record` recovery command). A merged row with no active folder is skipped. This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a close that never ran. The sweep is silent-but-logged: one summary stdout line listing the folders reaped.

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

- [[GAIA Plan]]: the planning run step 11 chains into.
- [[Task Orchestration]]: what `/gaia-plan` produces.
