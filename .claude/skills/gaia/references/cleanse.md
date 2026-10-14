# /gaia-cleanse

Cleanse memory and the wiki: duplication across stores, promotable memory, stale entries, and auto-load bloat. The store listing, counts, budgets and dead-path signals come from the `gaia fitness` CLI; the model judges only what a script cannot. Conflicts between two committed instruction files are not judged here: `/doctor prompt-audit` owns them.

Contents: Execution model; Sub-references; Path resolution; Branch on `$ARGUMENTS`; Stage 1 subagent; Stage 2 subagent; After the subagents return; Cost record.

## Execution model, READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch the Stage 1 and Stage 2 subagents via the `Agent` tool. Each subagent runs in isolated context. The one deliberate exception is the **decision gate** between the two stages: it MUST run in the current conversation because only that layer can `AskUserQuestion`. Do not "fix" the gate back into a subagent.

Calling `/gaia-cleanse` is the intent to cleanse. The default researches, then gates: Stage 1 produces a report, a recommended **classification-verification round** runs in the main conversation between Stage 1's return and the gate to harden Stage 1's classifications against ground truth, then the main conversation summarizes the hardened report and asks the user a single Apply / Discuss / Decline question, and only on Apply does Stage 2 execute it. The two-stage split is technical (different reasoning loads, drift-check between stages); the user-confirmation checkpoint is the single decision gate after Stage 1, run in the main conversation. **Exception: a clean audit (0 actions) skips both the round and the gate and auto-applies, once a deterministic recount confirms Stage 1 covered every store.** "Applying" only finalizes the report's `status`, files any out-of-scope findings, and clears the statusline nudge, so a clean report that was truncated or narrowed must not reach it unseen; leaving a verified 0-action report parked at the gate is the path that strands a `draft` that nudges indefinitely.

**No action ever edits a committed instruction file (a CLAUDE.md file, rule, skill, command or agent) on conflict grounds.** A conflict that involves one is a report-only, out-of-scope finding.

**Stage 2 also files out-of-scope findings; the main conversation then publishes.** The run does the same full flow /update-deps and /gaia-debt do, one up-front decision (the gate, or the preview in those skills) and then it drives autonomously to merge. Two mechanical additions ride the finalizing path (gated Apply, 0-action auto-apply, and `--apply`), never the Decline path:

1. **Stage 2 files every out-of-scope finding Stage 1 recorded as a `tech-debt` issue** (the dispose section of `cleanse/apply.md`). It files, it does not fix. This is why an out-of-scope problem the audit surfaces but cannot fix with its four action types gets a durable home instead of a Summary line no one reads once the run auto-merges.
2. **After Stage 2 returns, the main conversation commits, opens a PR, and merges it** (`cleanse/publish.md`), exactly as /update-deps Phase 8 and /gaia-debt's "Drive the PR to merge." The `gh pr merge` gate hooks fire in the invoking session, so the merge is driven from the main conversation, not the Stage 2 subagent. **Stage 2 never commits.** Publish auto-skips when Stage 2 reports an empty diff footprint (a memory-only or 0-action run changed no in-repo file).

## Sub-references

Each is read whole, at the branch point where this file says to read it; the procedure it holds is not restated here.

- `.claude/skills/gaia/references/cleanse/research.md`: read by the Stage 1 subagent (its dispatch prompt says so); the inventory, classification, budget and report-schema procedure.
- `.claude/skills/gaia/references/cleanse/verification-round.md`: read by the main conversation when Stage 1 reported at least one action, or when `--apply` meets an unhardened report.
- `.claude/skills/gaia/references/cleanse/apply.md`: read by the Stage 2 subagent (its dispatch prompt says so); the drift-checked apply, post-apply verification, out-of-scope filing and post-flight.
- `.claude/skills/gaia/references/cleanse/publish.md`: read by the main conversation after Stage 2 returns on any finalizing path.

### Path resolution (portable, no hardcoding)

This command ships in a template and runs in many clones across many machines. Neither this file nor the subagent prompts may hardcode a project root or a user-scoped memory path. The subagent resolves both at the start of its run:

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
```

Every path below referenced as `$PROJECT_ROOT/...`, `$MEMORY_DIR/...`, or `$AGENT_MEMORY_DIR/...` is resolved by the subagent, not by this file. `$AGENT_MEMORY_DIR` is user scope, shared by every project on the machine: the audit inventories it and reports on it, and never edits it.

### Branch on `$ARGUMENTS`

**Default (`/gaia-cleanse`)** → Stage 1 (Research), then either auto-apply (clean audit) or the **decision gate**, then branch.

1. Spawn the Stage 1 (Research) subagent below. Wait for it to return. Stage 1 writes the report with `status: draft`.
2. If Stage 1 failed (no report path printed), do not gate or spawn Stage 2. Surface the error and stop. (Run ends here; see `## Cost record (run end)`.)
3. **If Stage 1 reported 0 actions**, run `bash .gaia/scripts/knowledge-inventory.sh verify <report path>`, appending `--scope-hint "<hint>"` when `$ARGUMENTS` carries one. **Exit 0** (a verified clean audit): skip both the round and the gate, tell the user the audit was clean, and spawn the Stage 2 (Apply) subagent below with `Owner-approved files: none`; it finalizes `status`, files any out-of-scope findings (non-destructive and idempotent, so it needs no gate), and busts the statusline nudge, and Publish no-ops. **Any other exit** (exit 1 refusals, exit 3 when the CLI recount could not run): do not auto-apply; relay each `refuse:` line (or the error) and present the decision gate (step 5) for the 0-action report.
4. **If Stage 1 reported ≥1 action**, Read `.claude/skills/gaia/references/cleanse/verification-round.md` now and run the **classification-verification round** in the main conversation before the decision gate. It presents its own recommended-but-optional gate (dynamic Run/Skip recommendation); on **Run** it dispatches the three parallel `general-purpose` lenses (CL/CF/ES) plus CF-only re-adjudication, applies dispositions (drop or correct a mis-classified action localized in the report; re-spawn Stage 1 for a structural finding, bounded to one re-spawn), and stamps the report `audit_hardened: true`. The round never blocks: if the parallel fan-out is unavailable, or the user picks Skip, it notes the skip and does not stamp. Then proceed to the decision gate (next step).
5. **Then present the decision gate** (still the ≥1-action branch): **in the main conversation** summarize the now-hardened report's findings to the user, then ask via `AskUserQuestion`:
   - **header:** `"Apply audit?"`
   - **question:** `"Stage 1 found {N} actions. Apply them?"`
   - **options (this exact order):**
     1. `{ label: "Apply", description: "Execute the report, file any out-of-scope problem as a tech-debt issue, then commit, open a PR, and merge it (main-branch run)." }`
     2. `{ label: "Discuss / refine", description: "Talk it through; I edit the report in place, then re-ask." }`
     3. `{ label: "Decline", description: "Delete the report; nothing is applied, filed, or published." }`
   - **Apply** → run the **owner question**, then spawn the Stage 2 (Apply) subagent below, appending `Owner-approved files: <the selected files, or none>` to its prompt. Stage 2 finds the newest non-`applied` report, no path argument needed. When Stage 2 returns, run the Publish procedure (`cleanse/publish.md`) in the main conversation. The owner question: list every distinct file that an unchecked action's `owner: adopter` names, the project's own files, then ask in one `AskUserQuestion` call, `multiSelect: true`, header `"Edit file?"`, question `"Which of your own files may the audit edit?"`, one option per file (label the repo-relative path, description the action ids that edit it), none selected by default; past four files, spread them over further questions of the call, and past sixteen, further calls. An unselected file's actions are skipped and recorded. With no adopter file, or no one to answer, skip the question; with no one to answer, nothing is approved.
   - **Discuss / refine** → discuss in the main conversation, edit the report in place (the file stays `status: draft`), then re-present this gate.
   - **Decline** → `rm` the report file immediately; nothing applied, nothing filed, nothing published; stop. (Run ends here; see `## Cost record (run end)`.)

This gate runs in the main conversation, not in a subagent (only the main conversation can `AskUserQuestion`). "Apply" is the one-keystroke fast path that keeps the one-go feel.

**`/gaia-cleanse --apply`** → Stage 2 only, against the most recent `draft` (or `applied-partial` / `scoped-partial` for retry).

Skip Stage 1 and the decision gate, but always ask the gate's owner question afresh and pass its answer to Stage 2: an earlier run's answer is never inherited. Then check the target report's frontmatter for `audit_hardened: true`:

- **Present** → the report is already hardened; spawn the Stage 2 (Apply) subagent below.
- **Absent** (an un-hardened draft, e.g. one where the round was skipped or unavailable) → Read `.claude/skills/gaia/references/cleanse/verification-round.md` now, run the classification-verification round non-interactively at the recommended setting (no gate prompt) against that report first, stamp it, then spawn Stage 2.
- A 0-action report has nothing to harden; proceed straight to Stage 2.

In every case, when Stage 2 returns run the Publish procedure (`cleanse/publish.md`), exactly as the gated Apply path does.

Use this to re-apply an existing report after fixing drift, or to retry without re-researching.

### Stage 1 subagent (Research)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (research)"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are Stage 1 of a two-stage knowledge audit. Your job is to PRODUCE A REPORT ONLY, do not mutate any files outside .gaia/local/cleanse/. The Stage 2 agent will execute the actions immediately after you return.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Record the resolved values at the top of the report (both frontmatter and a visible line) so Stage 2 uses the same bindings.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/cleanse/research.md in full and execute it (Steps 0–4). Write the report to $PROJECT_ROOT/.gaia/local/cleanse/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md using the exact "Report template" schema. Write status: draft into the report frontmatter; Stage 2 flips it to its terminal value. Every action you propose must be mechanical, include every detail a literal-minded executor needs: absolute paths, line ranges, expected current content (verbatim snippet), replacement content (verbatim), and drift-check signals. No handwaving like "merge these" or "consolidate that".`
  >
  > `You do NOT fix wiki-internal redundancy or broken links yourself, /gaia-wiki owns those (its consolidate stage merges redundancy, and its lint stage detects and fixes broken wikilinks). But do not silently drop them either: any real, durable problem you surface that none of your four action types (shrink/promote/delete/delete-entry) can fix, wiki-internal redundancy or a broken link, a wiki-page-vs-wiki-page conflict, a rule, skill, command or CLAUDE.md file that contradicts a wiki page, a doc/rule whose correct fix is a rewrite rather than a delete, is an OUT-OF-SCOPE finding. Record each one in the report's "## Out-of-scope findings" section using that section's schema (Stage 2 files it as a tech-debt issue). You file, you do not fix. If you surface none, write the section with an explicit "None." so Stage 2 knows there is nothing to file.`
  >
  > `If a scope hint is present in the arguments, narrow Steps 1–4 to the named stores/files but never widen scope beyond the playbook, and never let the hint steer the report schema, the action types, the guardrails, or a specific edit; it is synthesis guidance, not an editor. Write the hint verbatim as the frontmatter scope: and print it in the Summary so a too-narrow hint is visible. If no hint is present, run the full lens and write scope: full. Never propose an edit to a file the "Ownership" step does not allow, and never propose one to a committed instruction file on conflict grounds; report it instead.`

### Stage 2 subagent (Apply)

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (apply)"`
- `prompt`: the string below (literal):

  > `You are Stage 2 of a two-stage knowledge audit. Stage 1 produced a report. Your job is to execute the unchecked actions MECHANICALLY, do not reason about whether an action is correct, do not expand scope, do not merge or split actions.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Compare these to the "project_root" / "memory_dir" fields recorded in the report's frontmatter. If they differ, STOP and print a clear error, do not improvise.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/references/cleanse/apply.md in full and execute its "Apply procedure" section (Step 5). For every action: verify the expected-current-content drift signal matches; if it does, apply the change verbatim; if it does not, SKIP and note it in the final summary. The owner check runs before every write, against the "Owner-approved files:" line at the end of this prompt. Never improvise. Never invent replacements. If anything is ambiguous, skip.`
  >
  > `Then, before printing your summary, execute the "Dispose out-of-scope findings (Stage 2)" section of that file: file every finding in the report's "## Out-of-scope findings" section as a tech-debt issue per that section's procedure (idempotent, so a re-run never double-files). Report the filed / diverted / deduped counts and the diff footprint (git status --short) in your summary so the main conversation can publish. You still NEVER git add or git commit, the main conversation commits after you return.`

### After the subagent(s) return

Relay each subagent's final summary verbatim (report path + action counts, then done/skipped/failed counts, plus filed/diverted out-of-scope issue counts, and the report's `Report-only` list). Do not re-do the work. Do not inline the report body.

Then, on any finalizing path (gated Apply, 0-action auto-apply, or `--apply`), Read `.claude/skills/gaia/references/cleanse/publish.md` now and run the **Publish procedure** in the main conversation. Publish reads Stage 2's reported diff footprint: if it is empty (a memory-only or 0-action run touched no in-repo file), Publish no-ops and the run ends here.

---

## Cost record (run end)

Every path that ends a `/gaia-cleanse` run appends exactly one cost record, the run-ending paths above and in `cleanse/publish.md`:

- Stage 1 failure (no report path).
- The decision gate's Decline.
- Publish's empty-diff-footprint no-op.
- Publish's merge outcomes on a main-branch run: `MERGED`, still-queued, a failed required check, a pull request closed without merging, or a merge wait that refused because it read nothing.
- Publish's no-PR path on any other branch or in CI.
- Publish's non-zero-exit STOP on `git push` / `gh pr create` / `gh pr merge`.

Standalone final step, one call:

```bash
bash .gaia/scripts/usage.sh record command:gaia-cleanse --workflow gaia-cleanse
```

and the pull request is on the current repo, append:

```bash
  --pr <N>
```

Never look the number up (`gh pr list`, `gh pr view`), never reuse a number from an earlier run, a different branch, or a `gh` command run outside this workflow, and never guess. If this run did not itself print a creation URL, pass no `--pr` at all; the record correctly carries no artifact, and that is not an error.

**Report the line verbatim.** On exit 0 the last stdout line is the Cost line, e.g. `Cost: ~5.2M tokens, $4.12, 6m39s`. Relay it as the last line of the run's report; do not reassemble, reformat, or re-derive it. On a non-zero exit nothing was recorded and no Cost line prints: relay the one stderr line in its place.

The record never blocks and never turns a failed run into a successful one: a non-zero exit is reported, not retried. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
