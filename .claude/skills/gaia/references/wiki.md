# /gaia-wiki

Wiki-maintenance router. It runs sync, consolidate, and lint with fixes, and lands them as one commit on one branch and one PR.

## Arguments

`/gaia-wiki` takes no arguments.

```
Usage: /gaia-wiki
```

If `$ARGUMENTS` is non-empty, whatever it holds (a retired argument: `sync`, `consolidate`, or `lint`; `--help`; free text from a natural-language trigger such as `run wiki maintenance`), print this notice once, with the whole argument string in place of `<arguments>`, then run "The run" exactly as with no argument:

```
Note: /gaia-wiki takes no arguments; ignoring "<arguments>" and running sync, consolidate, and lint.
```

## The run

The run lands as **one commit on one branch and one PR**. The stages commit nothing: each leaves its edits uncommitted in the working tree, and step 6 commits them all at once. The parent (the agent reading this file) owns the branch lifecycle through `gaia wiki chain`; each stage still runs as its own subagent. The `chain` calls are the only parent-side git/branch/PR actions, the playbook bans inlining any other branch logic, manual `git commit` or `gh pr` calls, or push narrative.

1. **Begin.** Run `.gaia/cli/gaia wiki chain begin --branch-aware`. On `main`/`master` it cuts a `wiki/<YYYY-MM-DD-HHMM>` branch (UTC) for the run's commit; on a feature branch it is a no-op and the run commits in place. If `chain begin` exits non-zero, stop the run: run no stage, make no commit, and surface its error output to the user.

2. **Sync.** Run the "Sync" section below. Capture the final summary. Sync's edits, including the advanced `wiki/.state.json`, stay uncommitted for step 6.

3. **Branch on sync's outcome.** Sync's summary ends with the line `SYNC_COMPLETE: true` on every normal path, including drift=0 and the `suggested_base` recovery path. The line is **absent** on the state-init path, the fallback re-anchor path, a cancelled run, and every interruption and abort `references/wiki/sync.md`'s Failure modes section lists, all of which leave the wiki in a known-incomplete state. No other condition decides whether consolidate runs.
   - **Line present**: run consolidate (step 4), then lint (step 5), then commit (step 6), finish (step 7), and land (step 8).
   - **Line absent, `SYNC_PARTIAL: true` present** (the state-init path, the fallback re-anchor path, a mid-sync interruption): skip consolidate and lint, then commit (step 6) what sync left, finish (step 7), land per step 8 when finish opened a PR, and surface the exceptional state.
   - **Both lines absent** (a cancelled run, the fabrication-guard abort, a corrupt state file): skip consolidate, lint, **and the commit**, then run finish (step 7) and surface the exceptional state. Never commit here: the fabrication-guard abort leaves Step 5's log lines for edits that were never written, and committing them would land the very sync the guard refused. With no commit, `chain finish` removes a clean empty branch, or leaves a dirty tree in place for the maintainer.

4. **Consolidate.** Run the "Consolidate" section below. Its applied edits and advanced state stay uncommitted for step 6.

5. **Lint.** Run the "Lint" section below, both stages. Lint runs after consolidate because consolidate may move, rename, or archive pages and lint's orphan/dead-link/broken-wikilink/drift checks need the true post-state. Its fixes and final report stay uncommitted for step 6.

6. **Commit.** Run `.gaia/cli/gaia wiki chain commit`. It commits every stage's `wiki/` edits as one commit with the subject `wiki: <YYYY-MM-DD> <HH:MM> UTC`, which the CLI mints from the branch's timestamp (from the clock on an in-place run); pass no label. It is a no-op when no stage changed anything. Lint's fixes land in this commit, before `finish`, rather than on the PR `finish` opens, so the PR's head stays on the sha `finish` stamps: a push after `finish` moves the head off that stamp, and a queued auto-merge then waits on a `GAIA-Audit` status that never arrives.

7. **Finish.** Run `.gaia/cli/gaia wiki chain finish --branch-aware`. On the wiki branch it pushes, opens ONE PR titled with the commit's subject, posts the out-of-scope `GAIA-Audit` stamp, and queues auto-merge, then stays on the branch and prints `chain finish: opened PR #<N> for <branch>; auto-merge queued, merge not yet confirmed`. That line means the PR is open, not merged: the run is not done, so go on to step 8. If the run produced no commit it drops the empty branch and returns to base; on a feature-branch (in-place) run it is a no-op and the commit remains on the current branch. In those two cases no PR was opened, so the run ends here: relay the summary. A non-zero exit also ends the run: relay its stderr, which names the next step.

8. **Merge and clean up.** The wiki PR lands like every other GAIA PR, through `.claude/skills/gaia/references/work-lifecycle.md`. The stamp in step 7 is this skill's audit, so the lifecycle's `## 6. Audit` does not run, and the merge is already queued, so nothing here re-merges. Run the merge wait from `## 7. Merge (when asked)` on the PR number `finish` printed (when it printed no number, read it with `gh pr view <branch> --json number --jq .number`), passing `--attempts 30`. Run it as a background Bash command and act on its verdict when it exits. A full CI run on the merge outlasts the default bound, and the wait returns the moment it reads `MERGED`, so a high ceiling costs nothing on a fast repository. Act on the verdict:
   - **`MERGED`**: clean up per `## 8. Cleanup` `### Feature branch`, with `<branch-name>` = the wiki branch. Then run `.gaia/cli/gaia wiki chain refresh-nudge`, which writes the main checkout's new drift into the statusline cache so the `/gaia-wiki` nudge clears now rather than on a later background refresh. Report the merged PR URL and that the nudge was refreshed. The run is complete.
   - **Any other verdict, or the exit-2 refusal**: the run is **not** complete. Report the PR URL and the verdict, follow `wiki/concepts/PR Merge Workflow.md`'s arm for it, and leave the branch in place. Never report the wiki as landed. Tell the user to check out the base branch once they are done with the queued PR: the session-start janitor reaps the wiki branch and fast-forwards base only when HEAD is off the wiki branch.

A `chain commit` that exits non-zero stops the run before `finish`: surface its message. For the non-wiki-changes refusal, tell the user to commit or stash the non-wiki changes, then rerun `/gaia-wiki`. For the protected-branch refusal, relay the CLI's own next step.

Each stage still dispatches its own subagent; never run a subagent's playbook yourself in this conversation. The parent-side stages, consolidate's apply loop and lint's fix loop, are the ones that run here.

## Sync

Dispatch a Sonnet subagent via `Agent`. Sync generates judgment and prose (deep-reading WORTHY diffs, locating the right page, writing accurate edits and ADRs), which is beyond Haiku's reliability on a long multi-step run; a fresh context also keeps git diffs and log content out of the parent.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki sync"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA wiki-sync workflow in a fresh context. Read .claude/skills/gaia/references/wiki/sync.md from the project root and execute the "Playbook" section (Steps 1–8) verbatim. Your working directory is the project root. Print only the final summary block from Step 8, ending with the SYNC_COMPLETE: true line when Step 8 emits it, or the SYNC_PARTIAL: true line when the playbook says to print it, no preamble, no recap, no narration of intermediate steps.`

When the subagent returns, relay its final summary verbatim. Do not redo the work in the parent.

## Consolidate

Two-stage. **Detection (Steps 1–3) runs in a Sonnet subagent** so the heavy page-index walk and frontmatter reads stay out of the parent. **Apply, state, and report (Steps 4–6) run in the parent** because Step 4 calls `AskUserQuestion` per finding, and `AskUserQuestion` is unavailable inside dispatched subagents.

### Stage 1, detection subagent

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki consolidate (detection)"`
- `prompt`: the string below (literal):

  > `You are running the detection stage of the GAIA wiki-consolidate workflow in a fresh context. Read .claude/skills/gaia/references/wiki/consolidate.md from the project root and execute Steps 1–3 of the "Playbook" section verbatim, then STOP. Do NOT execute Steps 4–6. Your working directory is the project root. After writing the report file in Step 3, return ONLY a JSON payload on stdout, no preamble, no narration:`
  >
  > ```json
  > {
  >   "report_path": "wiki/meta/consolidate-report.md",
  >   "findings": [
  >     {
  >       "id": "<stable id, e.g. supersession-0, near-collision-2>",
  >       "kind": "supersession" | "reversed" | "near_collision" | "subject_orphan",
  >       "domain": "<domain>",
  >       "label": "<short label suitable for a question>",
  >       "canonical": { "path": "<rel path>", "title": "<title>", "slug": "<slug>" },
  >       "other":     { "path": "<rel path>", "title": "<title>", "slug": "<slug>" },
  >       "summary":   "<one-sentence summary of the apply action>"
  >     }
  >   ]
  > }
  > ```

### Stage 2, parent loop

After the subagent returns, the parent (the agent reading this file in the live conversation):

1. Parses the `findings[]` payload.
2. Iterates findings in order **supersession → reversed → near-collision → subject-orphan** (most-impactful first), surfacing each via `AskUserQuestion` per Step 4 of the playbook in `references/wiki/consolidate.md`.
3. Applies the user's chosen action (Apply / Keep both / Skip) per the playbook's per-kind rules.
4. Runs Step 5 (advance state) and Step 6 (report) directly; the commit is "The run" step 6.

If any HIGH-severity supersession or reversed-decision finding is applied, surface it prominently (prefix the final summary line with `WIKI CONSOLIDATE:`).

## Lint

Two-stage, like consolidate. **Detection runs in a Haiku subagent** and writes the report. **Fixing runs in the parent** because it asks the user where a fix needs judgment, and `AskUserQuestion` is unavailable inside dispatched subagents. Both stages run every time: a report that lists defects and leaves them standing fixes nothing.

### Stage 1, detection subagent

Dispatch a Haiku subagent via `Agent`. The work is mechanical (rule-based orphan, dead-link, broken-wikilink, and frontmatter checks plus a deterministic drift severity table), Haiku is sufficient.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"haiku"`
- `description`: `"Wiki lint"`
- `prompt`: the string below (literal):

  > `You are running the GAIA wiki-lint workflow in a fresh context. Read .claude/skills/gaia/references/wiki/lint.md from the project root and execute the "Playbook" section (Steps 1–9) verbatim. Your working directory is the project root. Return only the report path and the one-line summary required by Step 9: no recap of the report contents.`

When the subagent returns, relay its summary verbatim. If the drift severity is **`high`**, prefix the surfaced line with `WIKI DRIFT:` per Step 9. If the subagent returns a `WIKI DEAD-PATHS:`, `UAT-SPEC DRIFT:`, `WIKI ORPHANS:`, `WIKI FRONTMATTER:`, `WIKI EMPTY-SECTIONS:`, or `WIKI BROKEN-LINKS:` line, surface it too.

### Stage 2, parent fix loop

Read `.claude/skills/gaia/references/wiki/lint-fix.md` and run it in this conversation, then relay its summary line. It fixes each finding, asks only where a fix needs judgment, files the instruction-file findings that cannot ride a wiki branch as tech-debt, and re-dispatches stage 1 so the final report describes the fixed wiki.
