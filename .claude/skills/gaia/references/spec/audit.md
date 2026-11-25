# /gaia-spec: spec review wave

The review of `/gaia-spec`: one parallel wave of lens auditors over the draft, a batched refuter over critical findings only, one fixer, the drop-destination check, and `AUDIT.md`. `spec.md` routes here together with `spec/lens-dispatch.md`, which owns the shared lens preamble and severity rubric, the findings file schema, the short summary, and the pre-clear, classify, and re-dispatch rule; this file owns lens selection, the refuter and fixer dispatch, and the drop check. Three files hold text the main thread does not act on at every run: `spec/lenses.md` (each lens's focus text, read by the lens agent), `spec/audit-refuter.md` (read only when a lens raises a critical) and `spec/audit-fixer.md` (the fixer's prompt and the `AUDIT.md` shape, read by the fixer agent). Control returns to `spec.md` (gate 2) at the end of this file.

Contents: The wave; The lenses; The critical refuter; The fixer; The drop check.

## The wave

The review always runs, interactive or auto, with no prompt and no skip option, and it dispatches the skill's own parallel `general-purpose` Agent fan-out, not the Workflow tool, so it is available in every context including headless and auto-mode runs. The one exception is the Fallback below, a capability limit rather than a choice.

**Auto mode** reads **no finding body** during the review (the transcript carries only ids, severities, titles, verdicts, and dispositions) and applies every finding through the fixer, non-interactively.

**Fallback (never block).** If the parallel Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block save: note the skip (`spec review unavailable`), remove the cache with `rm -rf .gaia/local/cache/audit-<spec_id>/`, and proceed to gate 2.

Paths this file names, all main-anchored or cache paths resolved by `spec.md`:

- `<DRAFT_PATH>`: the working draft, `.gaia/local/cache/draft-<spec_id>.md`.
- `<PRE_FIX>`: `.gaia/local/cache/audit-<spec_id>/pre-fix.md`, a byte copy of the draft taken before the fixer runs.
- `<REQUIREMENTS_PATH>`: `${SPEC_DIR}/REQUIREMENTS.md`, read-only requirement data for every lens and the fixer.
- `<CODE_MAP_PATH>`: filled from the spec-audit cell of the code map row in `spec/lens-dispatch.md` `## Caller slots`, which owns the value; read-only, for every lens and the fixer.
- `<FINDINGS_DIR>`: `.gaia/local/cache/audit-<spec_id>/findings/`.

Resolve the main-anchored SPEC folder (stored in the main checkout: the clone's primary working directory, on any branch) before the fixer dispatch consumes it. The SPEC folder is main-anchored state (state registry `specs-main`), so `AUDIT.md` lands beside the artifact the catalog row indexes rather than in a second specs tree inside a linked worktree. The fixer writes `AUDIT.md` there per the tool-choice contract in `spec.md`'s Operational primitives.

```bash
SPEC_DIR="$(bash .gaia/scripts/notebook/notebook-lib.sh path spec "$SPEC_ID")" || SPEC_DIR=""
if [ -z "$SPEC_DIR" ]; then
  echo "gaia-spec: cannot resolve the notebook's SPEC folder; refusing to write the audit report" >&2
  exit 1
fi
mkdir -p "$SPEC_DIR"
AUDIT_MD="${SPEC_DIR}/AUDIT.md"
```

## The lenses

Announce once, verbatim, naming each lens in full with its id code in parentheses (e.g. `factual grounding (FG)`), never the bare code:

> Dispatching the SPEC review: lenses <selected lens names, each with its id in parentheses>, then a critical-findings check if any lens raises a critical, then one fixer (a few minutes).

Dispatch **every selected lens in one assistant turn**: one message, one `general-purpose` Agent call per lens, the five core lenses always and each specialist whose area the draft touches. Each agent audits `<DRAFT_PATH>` and is dispatched per `spec/lens-dispatch.md` with the spec column of its caller slots (`<DRAFT_PATH>`, `<spec_id>`, `<repo_root>` = `$PWD`, `<LENS>` = the lens id prefix, `<CODE_MAP_PATH>`, and `<REQUIREMENTS_PATH>`): the shared preamble, then a `LENS: <name> (id prefix <ID>)` line and the focus line `Your focus text is the <ID> section of <repo_root>/.claude/skills/gaia/references/spec/lenses.md. Read that section, and only that section, before judging the artifact; the other sections belong to other lenses.` Every lens may read `<REQUIREMENTS_PATH>`; BRIEF-FIT reads its `## Brief` whole first. Each writes its findings to `<FINDINGS_DIR><LENS>.json` under the findings file schema (writing the file even when its findings array is empty), then returns only the short summary.

Before dispatching, pre-clear each `findings/<LENS>.json` (`rm -f`) for every lens about to be dispatched, and after each finishes classify its file per `## Pre-clear, classify, re-dispatch` in `spec/lens-dispatch.md`. A specialist the draft does not touch is never issued and is recorded `not_applicable`. Append one `coverage.jsonl` record (`phase: "lens"`, `lens: "<LENS>"`, `disposition: "first_pass"|"not_applicable"`) per in-scope lens to `.gaia/local/cache/audit-<spec_id>/coverage.jsonl`.

A lens that hit a second no-op ran inline, so it produced its finding bodies on the main thread, auto mode included: write that lens's file and carry on with only its ids, severities, and titles, exactly as for a dispatched lens.

Specialists join the same wave only when the draft touches their area, chosen by scanning `intent`, `scope_boundaries`, `success_criteria`, the required-reading list, and the touched paths against the "Fires when" column.

### Core lenses (every run)

- `TST`: flow and criteria testability.
- `COV`: coverage and consistency.
- `SEC`: security.
- `BRIEF-FIT`: brief fit.
- `FG`: factual grounding.

### Specialist lenses (only when the draft touches their area)

| ID | Fires when the spec touches |
| --- | --- |
| `MIG` | schema, format, or ledger changes; renamed, removed, or added fields; breaking API or serialization changes; config-vocabulary changes |
| `A11Y` | UI components, routes, pages, anything that renders DOM |
| `DOC` | wiki or docs deliverables, "points to X" pointer criteria, README or section-title citations |
| `PERF` | data volume, loops over collections, network fan-out, caching, render or hydration paths |

## The critical refuter

From the lens short summaries, main collects the ids of every `critical` finding across all lenses. When there is **at least one**, Read `.claude/skills/gaia/references/spec/audit-refuter.md` now, whole, and run its **one batched refuter, with no question asked**, over those ids only. Below critical no refuter runs: `major` and `minor` findings go to the fixer unchanged. Append one `coverage.jsonl` record (`phase: "refuter"`, `disposition: "first_pass"|"not_applicable"`).

## The fixer

Before dispatching, copy the draft to `<PRE_FIX>` (a plain `cp`) and finalize `coverage.jsonl`, one thin JSON-Lines record per in-scope dispatch, no finding body. Pre-clear `findings/fixes.json` (`rm -f`).

Dispatch **one** `general-purpose` Agent, the fixer, with: `<DRAFT_PATH>`, `<PRE_FIX>`, `<REQUIREMENTS_PATH>`, `<CODE_MAP_PATH>` (when it is non-empty), `<FINDINGS_DIR>`, the verdict files directory (when a refuter ran), the main-anchored `${AUDIT_MD}`, `<repo_root>`, and the tool-choice contract from `spec.md`'s Operational primitives, which governs its write into that folder. Fixer prompt:

> You are the fixer for the SPEC draft at `<DRAFT_PATH>`. Your first action is a Read of `<repo_root>/.claude/skills/gaia/references/spec/audit-fixer.md`, whole: it is your prompt, and these values fill its placeholders: <each input above, by name and value>. Then follow it.

In auto mode the fixer's reply is the only thing main reads, and no finding body reaches main. The fixer reads `<REQUIREMENTS_PATH>` and never edits it. **Fallback:** if subagent dispatch is unavailable, the review is skipped per the Fallback above, never folded inline.

## The drop check

Run the check on the main thread after the fixer returns, spec mode, with the pre-fix copy and the draft as post-fix:

```bash
node .gaia/scripts/spec/drop-check.mjs --fixes "<FINDINGS_DIR>fixes.json" --findings "<FINDINGS_DIR>" \
  --pre "<PRE_FIX>" --post "<DRAFT_PATH>" --requirements "<REQUIREMENTS_PATH>"
```

The script's header owns the fixes-file format and the refusal list. Exit 0 accepted, 1 refused, 2 a usage error or unreadable file (stop and surface it).

- **Refusal.** Re-dispatch the fixer once with the script's output, pre-clearing `fixes.json` and restoring `<DRAFT_PATH>` from `<PRE_FIX>` first so it re-applies against the pre-fix text. Run the check again.
- **A second refusal.** Keep the fixer's output: every valid fix stays, security ones included. For each refused line, put its declared dropped cases into `clarifications.deferred[]` as quoted superseded text awaiting a decision, never as live behavior; the SPEC body wins.
- **A missing or duplicate finding id** gets the same one re-dispatch. If it persists, stop (interactive), or list the unhandled ids in `clarifications.deferred[]` (auto).

After the check passes and `AUDIT.md` is written, proceed to gate 2 in `spec.md`, which renders the hardened draft.
