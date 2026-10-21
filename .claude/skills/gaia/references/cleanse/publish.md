# /gaia-cleanse publish

Runs in the **main conversation** after Stage 2 returns, on any finalizing path (gated Apply, 0-action auto-apply, `--apply`). It never runs on Decline.

Contents: Empty diff footprint; Isolated run; Failure handling.

Every "Run ends here" below means the run ends after the cost record in the entry file's `## Cost record (run end)`.

## Empty diff footprint

**If Stage 2's diff footprint is empty, skip the rest of this file.** A memory-only or 0-action run touched no in-repo file, memory edits live under `$HOME/.claude`, outside the repo, and are never committed. When the run isolated (`### Isolate before Stage 2` in the entry file), release it per `.claude/skills/gaia/references/isolation.md` `## Releasing an isolation that holds nothing`. Tell the user the audit is finalized and stop. (Run ends here.)

Otherwise `RESOLVED_ROOT` carries the applied `wiki/` / `.claude/` / `CLAUDE.md` edits on `<CLEANSE_BRANCH>`.

## Isolated run

Every command below runs from `RESOLVED_ROOT`, on `<CLEANSE_BRANCH>`, whichever branch the main checkout holds; the branch already exists, so cut none.

1. **Commit.** `.gaia/local/` is gitignored, so `git add -A` never sweeps in the report; memory edits are outside the repo. Route the message through a file, never `-m`, so package/keyword text can't trip a shell hook:

   ```bash
   git add -A
   git commit -F <commit-message-file>
   ```

   Subject: `chore(audit): <concise summary of what was pruned / shrunk / promoted>`. The diff is expected to touch only out-of-scope surfaces (`wiki/`, `.claude/`, root `CLAUDE.md`), but do not assume the out-of-scope bypass: before `gh pr merge`, resolve the members per `wiki/concepts/PR Merge Workflow.md` `## Who audits: the dispatched member set` and run whatever audit it owes. An audit edit to a nested `CLAUDE.md` under an in-scope path such as `frontend/app/` is the case that defeats the bypass. Run the Quality Gate first **only** if the applied diff touched a gate-affecting file (`.ts|tsx|js|jsx|mjs|cjs|css` or gate config); a docs-only audit diff has nothing for it to check.
   <!-- gaia:maintainer-only:start -->

   Then clear the **CHANGELOG gate** per `wiki/concepts/PR Merge Workflow.md`: decide whether the change warrants a `## [Unreleased]` entry (pure pruning / consolidation is usually an internal, no-entry change; a rule or concept-page behavior change is worthy) and, if so, land it on the branch before merging (HEAD moves, so any bypass/marker must still cover the new HEAD). Scrubbed from adopter bundles.
   <!-- gaia:maintainer-only:end -->

2. **Open the PR and drive it to merge** through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory):

   ```bash
   git push -u origin <CLEANSE_BRANCH>
   gh pr create --draft --title "<commit subject>" --body-file <report-summary-file>
   gh pr merge <N> --squash --delete-branch --auto
   ```

   `--auto` queues the merge behind required checks (the oracle check before `gh pr create` already confirmed whether a marker is owed). Then run `bash .gaia/scripts/pr-wait-merge.sh --pr <N> --attempts 20` and follow the verdict arms in `wiki/concepts/PR Merge Workflow.md` `## Post-merge verification before cleanup`, with `<branch-name>` = `<CLEANSE_BRANCH>`. Every arm but `CONFLICTING` ends the run. (Run ends here.)

## Failure handling

If any `git push`, `gh pr create`, or `gh pr merge` above exits non-zero, print the command's error and STOP. Do not retry, force-push, or amend, a rejected push or blocked merge is the user's call to resolve. (Run ends here, passing `--pr` to the cost record only if `gh pr create` already succeeded before the failure.)
