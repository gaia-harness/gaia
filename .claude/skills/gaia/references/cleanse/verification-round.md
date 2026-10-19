# /gaia-cleanse classification-verification round

An adversarial verification round that hardens Stage 1's classifications against ground truth in the MAIN CONVERSATION, between Stage 1 returning its draft report and the Apply / Discuss / Decline decision gate. Stage 1's DUPLICATE / STALE / CONFLICT / PROMOTE / shrink classifications are single-pass semantic judgments that nothing else verifies before they drive edits, and for memory entries those edits are IRREVERSIBLE (machine-local under `$HOME/.claude`, no git undo). The round verifies the checkable claim behind each action against the actual stores, wiki, and repo, then drops, corrects, or re-spawns to harden the report before any human approval or any apply path consumes it.

Contents: The recommendation; Dispatch the three lenses; CF-only second adjudication; Disposition routing and the stamp.

It runs only when Stage 1 reported ≥1 action; a 0-action report has no classification to verify and skips the round (it skips the decision gate too once the inventory recount verifies it). The round dispatches the skill's own parallel `general-purpose` Agent fan-out (the same primitive Stage 1 and Stage 2 use), so it is available in every context including headless and `--apply` runs.

**Deliberate divergences from the canonical adversarial pattern (`.claude/skills/gaia/references/spec/audit.md`, `.claude/skills/gaia/references/plan/decomposition-audit.md`); keep them:**

- **Asymmetric disposition, biased toward DROPPING flagged deletes.** Wrongly keeping an entry is trivial clutter; wrongly executing a memory delete is permanent. So when a lens flags a `delete` / `shrink` as mis-classified, the safe disposition is to DROP or correct that action, not to keep it. There is deliberately NO spec-style refuter that defaults to "refuted" and pushes surviving findings back toward executing the action: the spec round refutes findings to keep the SPEC as-authored, here the conservative default is the opposite.
- **Refutation is CF-only and deep-tier.** Only judgment-heavy CONFLICT (CF) findings get a second-adjudication pass. CL and ES findings are checkable and binary (the cited fact resolves or it does not; the load-bearing content survives or it does not), so they route to disposition directly with no refuter, like the plan audit.
- **Skip is a legitimate recommendation, and the round is a choice at all.** The canonical spec/plan rounds run automatically with no prompt and no Skip option; this round keeps an interactive gate whose recommendation is dynamic (Run vs. Skip-eligible per the recommendation below).

## The recommendation

**The round is a choice, presented once.** When the round is reached (≥1 action) in an interactive context, gauge the report, then ask via `AskUserQuestion` exactly once whether to run it. The recommendation is dynamic:

- **Recommend Run** when the report contains any memory `delete` / `delete-entry`, or any cross-store CONFLICT-driven `replace`: those actions are irreversible or carry contradiction risk.
- **Skip is eligible** (a legitimate recommendation) only when every action is a git-reversible shrink on an in-repo (non-memory) file and the Summary's cross-store `Conflicts:` count is 0; the decision gate plus git undo already cover that case. Recommend Run in every other case. Establish "no cross-store conflict behind the action" from that count, not by reading each `reason`: **only `Conflicts: 0` establishes it**, since a cross-store CONFLICT-driven action is emitted as the same `shrink` block as any other and need not name a contradiction in its `reason`.

Present the recommended option FIRST, carrying the `(Recommended)` tag:

- question: `"Run the classification-verification round before the decision gate? It verifies Stage 1's classifications against ground truth and drops or corrects any action that would drive a wrong or destructive edit."`
- header: `"Verify"`
- options:
  - `{ label: "Run the round", description: "Three parallel lenses verify the classifications against ground truth; a mis-classified delete is dropped, others corrected. A few agents, a couple of minutes." }`
  - `{ label: "Skip the round", description: "Proceed straight to the decision gate with the report as Stage 1 wrote it. Best when every action is a git-reversible shrink on an in-repo file with no cross-store conflict behind it." }`

On **Skip**, do not stamp `audit_hardened`; proceed to the decision gate. On **Run**, execute the sub-steps below, stamp `audit_hardened: true`, then proceed to the decision gate.

**Non-interactive paths run the round WITHOUT prompting** at the recommended setting: `--apply` against an unhardened report, headless runs, and any context with no user to prompt. They never present the gate; they run the round, stamp, and continue.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block: note the skip (`classification-verification unavailable, relying on the decision gate`), do NOT stamp `audit_hardened`, and proceed straight to the decision gate. The human Apply / Discuss / Decline gate is the safety net.

## Dispatch the three lenses (parallel fan-out)

Announce once, naming each lens in full with its id code in parentheses (e.g. `classification grounding (CL)`), never the bare code:

> Dispatching the three lenses in parallel against ground truth: classification grounding (CL), conflict adjudication (CF), edit safety / blast-radius (ES).

Dispatch **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens), each handed the shared preamble plus its lens line. Each agent reads the Stage 1 report at `<REPORT_PATH>` (resolved under `.gaia/local/cleanse/`), the cited stores, the wiki, and `node_modules` if relevant, and returns only the findings JSON below, no narrative.

Shared preamble (interpolate `<REPORT_PATH>` = the Stage 1 report path the main conversation just received, `<repo_root>` = `$PWD`, `<MEMORY_DIR>` = the resolved memory dir from the report frontmatter):

> You are an ADVERSARIAL verifier of a GAIA knowledge-audit report at `<REPORT_PATH>`. Repo root is `<repo_root>`; you may read any file under it. Read the report's actions first. Your job is to find MIS-CLASSIFICATIONS that would drive a wrong or destructive edit, not to praise the report.
>
> - Verify every checkable claim against ground truth; when an action cites a wiki page or a fact, open it and confirm.
> - Cite evidence as `file:line`.
> - Severity: `critical` = the action will execute a wrong or destructive edit (e.g. a memory delete whose cited fact does not resolve in the wiki); `major` = the classification is likely wrong and the action needs dropping or correcting before apply; `minor` = real but small, fix by default.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding a verifier can confirm by reading one file is a good finding; vague "could be clearer" is not.
> - Bias note: a wrongly-dropped delete is harmless (the entry stays); a wrongly-executed delete on a memory entry is PERMANENT (machine-local, no git undo), so when you cannot confirm a delete's basis from ground truth, flag it for dropping.

The three lenses (build each agent's prompt from the shared preamble plus its `LENS:` line):

- **CL, classification grounding (id prefix `CL`).** For each DUPLICATE-driven or STALE-driven `delete` / `shrink`, open the cited wiki `page:line` and confirm the fact TRULY lives there with the same nuance, not a superficially-similar sentence that drops a caveat the memory entry carries. For each STALE action, re-grep the repo with DIFFERENT search terms than Stage 1 used, to catch rename-not-removal (the file or feature still exists under a new name, so the entry is current, not stale). A delete whose cited fact does not resolve, or whose STALE basis is actually a rename, is a finding.
- **CF, conflict adjudication (id prefix `CF`).** For each cross-store CONFLICT-driven action (a memory entry against the wiki), INDEPENDENTLY re-pick the authoritative source and confirm a GENUINE contradiction exists, rather than: (a) sanctioned path-scoped-rule duplication (a live `paths:`-scoped `.claude/rules/*.md` rule, including a `gaia-harden:` provenance-marked rule, is allowed to duplicate wiki content and is never a CONFLICT); (b) a maintainer-only block; (c) an out-of-scope wiki-page-vs-wiki-page case (those route to `/gaia-wiki`, not here); or (d) a conflict between two committed instruction files (those route to `/doctor prompt-audit`, not here). A cross-store CONFLICT that is actually one of these, or that picks the wrong authoritative source, is a finding. An action that edits a committed instruction file on conflict grounds is itself a finding.
- **ES, edit safety / blast-radius (id prefix `ES`).** For each `promote` and `shrink` / `replace`, confirm the action PRESERVES all load-bearing content (a shrink-to-wikilink does not drop a nuance the inline text carried that the target page lacks; a promote carries the full content, not a truncation). For each memory `delete` / `delete-entry`, confirm the action's `reason` cites a canonical location that actually RESOLVES, the guardrail "never delete a memory entry unless the reason cites a canonical wiki location" is only as good as the citation resolving. A promote/shrink that loses content, or a delete whose reason citation does not resolve, is a finding.

Findings schema (each agent returns exactly this object; `location` is the offending action id, e.g. `delete-003`, or the classification; `evidence` is the wiki `page:line` or memory `file` actually opened):

    {
      "dimension": "<lens name>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "critical" | "major" | "minor",
          "title": "<short>",
          "location": "<action id or classification>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or quote actually checked>",
          "recommendation": "<one sentence: the fix>"
        }
      ]
    }

## CF-only second adjudication (deep-tier)

Collect the CF findings ONLY. CL and ES findings are checkable and binary, so they route to disposition directly with no refuter. For each CF finding, a cross-store conflict, dispatch ONE additional `general-purpose` Agent that independently re-adjudicates the conflict: re-pick the authoritative source from ground truth and decide whether a genuine cross-store contradiction exists.

This is NOT the spec round's "default to refuted" refuter; it is a second opinion whose DISPOSITION is conservative in the safe direction:

- A cross-store CONFLICT-driven `replace` / `delete` action **survives** only if the CF lens AND its re-adjudicator agree the conflict is genuine AND agree on the same authoritative source.
- On any disagreement (the re-adjudicator finds the conflict spurious, or picks a different authoritative source), **drop or downgrade** the action: do not execute a `replace` / `delete` that could clobber a legitimately-distinct local statement when two adjudicators cannot agree it is wrong.

## Disposition routing and the stamp

Route each surviving finding by scope (mirror `plan/decomposition-audit.md` 4.6b):

- **Localized finding** (one mis-classified action): drop or correct that action block directly in the report file. The main conversation edits the report; it lives under `.gaia/local/cleanse/`, which the main conversation may write. "Drop" removes the action block; "correct" fixes the cited target or `reason` when the lens supplies a correct one. Because the disposition is asymmetric, a `delete` / `shrink` a lens cannot confirm is DROPPED, not kept.
- **Structural finding** (a whole Stage-1 lens is miscalibrated, e.g. every STALE classification used the same flawed grep and they are all rename-not-removal): re-spawn the Stage 1 (Research) subagent (mirror `plan/decomposition-audit.md` 4.6b's re-spawn-the-planner) with the surviving findings appended as a correction directive. The re-spawn reuses the existing Stage 1 subagent definition, goes through the same report path, and overwrites the flawed report. Bound this to ONE re-spawn: after re-spawning, re-run the round once against the regenerated report, then proceed (do not loop indefinitely).

**The stamp.** After the round completes (findings dispositioned, report edited), stamp the report frontmatter `audit_hardened: true`. This is the idempotency and inheritance signal:

- The decision gate reads the now-hardened report.
- The `--apply` re-run path checks the stamp: `audit_hardened: true` present → `--apply` trusts the hardened report and does NOT re-run the round; absent (an un-hardened draft, e.g. one where the round was skipped or unavailable) → `--apply` runs the round itself non-interactively at the recommended setting before applying.
