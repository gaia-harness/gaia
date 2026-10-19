# Execution doctrine

This session is on a working branch or in a linked worktree, so it executes. The reasons behind each line, and the model table, live in `wiki/concepts/Workflow Doctrine.md`. When a running command defines its own contract (a plan orchestrator's per-phase commits and ledger, a debt fix's inline flow), its own contract governs where the two differ.

## Roles and git

- Read-only advisors investigate and write plan JSON; the main thread decides; executors edit files; a verifier checks executor output against the plan JSON before the Quality Gate.
- Only the main thread runs git that changes state: stage, commit, push, branch. Executors and advisors never run git that changes state; read-only queries such as `git rev-parse` are allowed.
- The main thread runs the Quality Gate (`wiki/decisions/Quality Gate.md`) once per commit: after that commit's executors finish and the verifier passes, and before the commit.
- To open, merge and clean up this branch's pull request, follow `.claude/skills/gaia/references/work-lifecycle.md` (`## 7. Merge (when asked)` and `## 8. Cleanup`); a running command's own contract still governs.

## Inline floor

Stay on the main thread when the work is small, tightly iterative (edit-run-fix), or needs the user. Sub-agents cannot prompt the user. Keep dispatch depth-1. The one exception is `audit-loop-unit`, which the main thread dispatches during the pre-merge audit: it is the sanctioned depth-2 orchestrator allowed to run state-changing git and the Quality Gate for its own rounds.

## Run folder

One per normalized branch key, `branch:` prefix dropped, slashes nesting: `branch:feat/9-sample` uses `.gaia/local/runs/feat/9-sample/`; a detached HEAD uses `.gaia/local/runs/session-<session id>/`. `runs/` is registered in `.gaia/state-registry.json`. It holds:

- `STATE.md`: Facts, a Status checklist recording each dispatch's expected artifact count, and one `NEXT:` line. At most 4 KB, rewritten in place.
- One JSON artifact per dispatch, named `<role>-<round>-<slug>.json`.
- `log.md`, append-only. Append only with Bash (`printf '...\n' >> <abs path>/log.md`), never Edit or Write, so appending never loads it.

In a linked worktree, `.gaia/local` resolves into the shared main checkout (the clone's primary working directory, on any branch): the runtime's worktree isolation refuses an Edit or Write there, and refuses a Bash command it cannot verify stays in the worktree (a heredoc, a pipe, a compound command, a redirect after another command). So write each run-folder file with Write into the session's scratchpad directory, then copy it in with one plain command, `cp <scratch file> <main checkout absolute path>/<file>`, and read it back. Append `log.md` with the one-command `printf` above. A command whose output belongs in the run folder redirects to the scratchpad and is copied in the same way.

## Resume

Read `STATE.md` and list the artifacts. Never read `log.md`. Re-dispatch any dispatch whose artifact is missing. If `STATE.md` is over 4 KB, compact it before continuing.

## Initiative linking and research

Once per branch, run the key line's `usage.sh link` command unless the branch name already derives the issue edge. How a research write binds: `wiki/concepts/Workflow Doctrine.md` (`## Research attribution`).
