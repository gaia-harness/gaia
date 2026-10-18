# /gaia-cleanse publish

Runs in the **main conversation** after Stage 2 returns, on any finalizing path (gated Apply, 0-action auto-apply, `--apply`). It does for the audit's in-repo edits what `/update-deps` Phase 8 does for a dep bump and `/gaia-debt`'s "Drive the PR to merge" does for a fix. It never runs on Decline.

Contents: Empty diff footprint; Isolated run (not in CI); In CI; Failure handling.

Every "Run ends here" below means the run ends after the cost record in the entry file's `## Cost record (run end)`.

## Empty diff footprint

**If Stage 2's diff footprint is empty, skip the rest of this file.** A memory-only or 0-action run touched no in-repo file, memory edits live under `$HOME/.claude`, outside the repo, and are never committed. When the run isolated (`### Isolate before Stage 2` in the entry file), release it per `.claude/skills/gaia/references/isolation.md` `## Releasing an isolation that holds nothing`. Tell the user the audit is finalized and stop. (Run ends here.)

Otherwise `RESOLVED_ROOT` carries the applied `wiki/` / `.claude/` / `CLAUDE.md` edits on `<CLEANSE_BRANCH>`.

## Isolated run (not in CI)

Every command below runs from `RESOLVED_ROOT`, on `<CLEANSE_BRANCH>`, whichever branch the main checkout holds; the branch already exists, so cut none.

1. **Commit.** `.gaia/local/` is gitignored, so `git add -A` never sweeps in the report; memory edits are outside the repo. Route the message through a file, never `-m`, so package/keyword text can't trip a shell hook:

   ```bash
   git add -A
   git commit -F <commit-message-file>
   ```

   Subject: `chore(audit): <concise summary of what was pruned / shrunk / promoted>`. The diff is expected to touch only out-of-scope surfaces (`wiki/`, `.claude/`, root `CLAUDE.md`), in which case the PR clears the merge gate through the **out-of-scope bypass** (`wiki/concepts/Audit Gate Reference.md`, `#### Signals`) with no `code-audit-frontend` marker. Do not assume it. Before `gh pr merge`, run

   ```bash
   bash .gaia/scripts/resolve-audit-members.sh
   ```

   Empty output confirms the bypass applies and no marker is owed (this also covers the rare case of an audit edit to a nested `CLAUDE.md` under an in-scope path such as `frontend/app/`, which would otherwise silently defeat the bypass). If it names any member, dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit` like any in-scope PR (a one-round, no-fix audit costs the unit nothing extra), then post the status per `#### Posting the status last` before `gh pr merge`. Run the Quality Gate first **only** if the applied diff touched a gate-affecting file (`.ts|tsx|js|jsx|mjs|cjs|css` or gate config); a docs-only audit diff has nothing for it to check.
   <!-- gaia:maintainer-only:start -->

   Then clear the **CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md`: decide whether the change warrants a `## [Unreleased]` entry (pure pruning / consolidation is usually an internal, no-entry change; a rule or concept-page behavior change is worthy) and, if so, land it on the branch before merging (HEAD moves, so any bypass/marker must still cover the new HEAD). Scrubbed from adopter bundles.
   <!-- gaia:maintainer-only:end -->

2. **Open the PR and drive it to merge** through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory), exactly as `/gaia-debt`:

   ```bash
   git push -u origin <CLEANSE_BRANCH>
   gh pr create --draft --title "<commit subject>" --body-file <report-summary-file>
   gh pr merge <N> --squash --delete-branch --auto
   ```

   `--auto` queues the merge behind required checks (the oracle check before `gh pr create` already confirmed whether a marker is owed). Verify the terminal state before any local cleanup with the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`, per `.claude/skills/gaia/references/work-lifecycle.md` `## 7. Merge (when asked)`. The merge above is already queued and the script issues no `gh pr merge` of its own, so nothing here re-merges. One arm per verdict plus one for the exit-2 refusal:

   - **`MERGED`** (exit 0) → clean up per `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, with `<branch-name>` = `<CLEANSE_BRANCH>`: `### Worktree entered by name in this session` under `RESOLVED_MODE=worktree`, `### Feature branch` under `feature-branch`. Then print the merged PR URL. (Run ends here.)

   - **`CONFLICTING`** (exit 3) → repair it per `wiki/concepts/PR Merge Workflow.md`'s `### Conflict found mid-wait` and run the wait again.
   - **`CHECK_FAILED`** (exit 4) → print the PR URL and the failing check, and leave the branch in place as for a queued merge. (Run ends here.)
   - **`TIMEOUT`** (exit 5) → the window closed with the pull request still open: print the PR URL, note auto-merge is queued and lands when checks pass, and **do not** delete the local branch or switch off it. (Run ends here.)
   - **`CLOSED`** (exit 6) → the pull request was closed without merging, so no wait can clear it: report the closure, print the PR URL, and leave the branch in place. (Run ends here.)
   - **exit 2** → the wait refused rather than answered: report what it could not read, print the PR URL, leave the branch in place, and assert no state for the pull request, since nothing about it was read. The merge queued above may still land. (Run ends here.)

   Every arm that leaves the branch in place names its worktree path under `RESOLVED_MODE=worktree`, so a kept worktree never goes unreported.

## In CI

The CI workflow owns the branch, so the run did not isolate:

```bash
git add -A
git commit -F <commit-message-file>
git push
```

Do not open a PR and do not merge; the CI workflow drives it from here. (Run ends here.)

## Failure handling

If any `git push`, `gh pr create`, or `gh pr merge` above exits non-zero, print the command's error and STOP. Do not retry, force-push, or amend, a rejected push or blocked merge is the user's call to resolve. (Run ends here, passing `--pr` to the cost record only if `gh pr create` already succeeded before the failure.)
