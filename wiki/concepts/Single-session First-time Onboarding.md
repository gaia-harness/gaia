---
type: concept
status: active
created: 2026-10-26
updated: 2026-10-26
promoted_at: 2026-10-25T17:02:29Z
promoted_hash: sha256:29495eaffdd1397b43cc454b42ddef7b966e900aed7bb16f12c8ccf0eb16e936
pr_number: 3071
tags: [promoted, concepts]
---
# Single-session first-time onboarding

`npx create-gaia` onboarding runs in the one Claude session `create-gaia` opens, with no exit, no restart and no reload.

## Behavior

### How it works

1. `npx create-gaia <name>` scaffolds, installs and launches Claude with `/gaia-init` in the project folder (create-gaia is unchanged).
2. `/gaia-init` installs the React Doctor skill with `install-react-doctor.sh` at the end of Step 1, after the dependency and Chromium installs and before any step reads a file under `frontend/` with a file tool. Claude Code lists the skills in `frontend/.claude/skills/` the first time a session reads a file there, so the skill is available in the same session. The install records nothing.
3. Init runs no `gaia setup` per-machine step: no per-machine reference read, no `mark-step`, no per-machine record, no setup-scope bootstrap-env and no `setup finalize`. Its own Step 6 `gaia init bootstrap-env` stays in its scope and resume order. The old per-machine Step 8 is gone and the later steps renumber (Step 8 Project settings, Step 9 Refresh the wiki, Step 10 Finalize, Step 11 Continue into /setup-gaia).
4. Step 10 touches the machine-local `.gaia/local/setup-running` marker, then runs `gaia init finalize` (which deletes `gaia-init.md`) and commits. Step 11, in order: sends the `--event init` adoption ping; on `COMMIT_FAILED` removes the marker, prints a Required warning and stops before the handoff (a `--no-git` project stops here); prints the CODEOWNERS placeholder warning when the placeholder is present; prints the handoff line saying setup is now running; then reads `.claude/commands/setup-gaia.md` whole and runs it from its `## Pre-flight: Worktree check` with `RECONFIGURE` false, because an inline read gets no `$ARGUMENTS` substitution.
5. From the handoff on, setup's own gates apply. Init's Automatic run mode covered init's questions only, and setup's repo connect question is always asked. Any halt in setup's phases, an auto-mode classifier denial included, tells the user to re-run `/setup-gaia`, never `gaia init resume`.
6. `/setup-gaia` alone runs and records install-tools, install-plugins, chmod-statusline and bootstrap-env. Its install-tools probe finds React Doctor and records the step without reinstalling it; install-plugins installs typescript-lsp from the shell, which loads live in the running session.
7. While setup runs, the statusline hides its right side whenever `.gaia/local/setup-running` is fresh (120-minute expiry), so the user is never told to run the command already running. Setup's Pre-flight touches the marker after the worktree refusal; Phase 6 removes it after finalize; `## On failure: re-run` removes it on any halt. The marker is registered in `.gaia/state-registry.json` (machine markers and the rm whitelist).
8. Setup's closing is a sequence of separate lines: the done (or not-finished) line, the sandbox next-session sentence only when this run enabled the sandbox, the line "If this session is in auto mode, press Shift+Tab to leave it, or start Claude with plain claude next time." printed unconditionally, a `/clear` suggestion to start the first feature with a fresh context, and a link to https://docs.gaiaharness.com/getting-started/onboarding/. No closing asks for a reload or a restart.

Stopping partway: before init finalizes, re-running `/gaia-init` resumes from `.gaia/init-state.json` and continues through Step 11's handoff. After finalize, the statusline shows `⚙️ /setup-gaia (Required)` and `/setup-gaia` resumes at the first owed step. A fresh clone runs `/setup-gaia` on its own and gets the same closing; in a session that already read a file under `frontend/` before setup installed React Doctor, the skill appears from the next session.

Supporting changes: the Droid-only React Doctor copy under `frontend/.factory/` is gitignored and all five statusline scripts are tracked as executable, so the tree is clean when setup connects GitHub. The command-chaining exception (one person-started command's own last step reads and runs another command's file; a plain-language ask still never starts a user-only command) is recorded in the skills wiki page. The `wiki.dead-paths` check treats `frontend/.env` as machine-local, so a fresh project no longer grades B- in `/gaia-fitness` before `bootstrap-env` writes that file. Phase 3.5's isolation-policy write and commit live in the isolation-question setup reference, keeping both commands under the 500-line cap CI enforces.

### Verification

Doc guards pin the new sequence (inverted, not deleted, with scratch-copy negative controls): the Step 1 React Doctor step-order guard, the Step 11 subsection order ending on the setup read, the absence of per-machine work and restart wording in init, the closing lines verbatim, and the marker's touch and removal sites. Distribution scenario 05 pins the init CLI sequence. Two real fresh-config create-gaia runs with the change laid over the released bundle (claude-opus-5-5, Medium effort) confirmed React Doctor installed once before the first `frontend/` read, setup running inline in the same session, typescript-lsp and React Doctor usable before and after `/clear`, no setup nudge during setup, and no fitness grade afterward. The Code Audit Team cleared in one round.

## Divergence

- The design expected the `⚙️ /setup-gaia (Required)` nudge to show while setup runs after init finalizes, with the handoff line explaining it. A real run showed that reads as being told to run the command already running, so the `.gaia/local/setup-running` marker hides the nudge during setup, and the handoff line drops its nudge clause.
- The design had the auto-mode line print only when the session is in auto mode. Gating on Claude judging its own mode held in one of two real runs, so the line prints unconditionally with wording true in any mode.
- The fresh-project fitness grade fix (`frontend/.env` as a machine-local path, with the CLI bundle rebuilt) and the closing's onboarding docs link were outside the original design.
