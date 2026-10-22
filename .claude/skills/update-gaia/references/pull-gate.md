# Pull gate

Every gated command reads this file when `gaia_pull_gate "<command>"` exited non-zero. The gate stops a fresh start of new work while the main checkout's GAIA version lags origin's, because that work would branch from a stale default branch. The function already printed its message line; this file decides what happens next. A resume never reaches it: continuing an earlier run, a half-finished plan or an owed publish passes ungated.

## Inputs

- **Command**: the gated command's name, as passed to the gate.
- **Arguments**: the arguments the command was invoked with, kept verbatim, an `auto` token included.
- **Exit code**: the gate's exit code, `1` or `2`.

## Step 1: A linked worktree (exit 2)

The session is inside a linked worktree, and the gate already printed a `Next step:` line naming the main checkout. Stop the command. Nothing was created. Never offer to pull and never restart: pull mode never runs from a linked worktree, so the only way forward is the printed next step, run in the main checkout.

## Step 2: Ask (exit 1)

Ask once with `AskUserQuestion`: "Pull now and restart <command> (Recommended)" or "Stop". In auto mode, which means the command was invoked with its `auto` token, choose the Recommended option without asking, and keep the `auto` token in the restart arguments.

## Step 3: Stop

On "Stop", end the command. Nothing was created.

## Step 4: Pull

On "Pull now", follow `pull-mode.md` with caller `gate`, the command and the arguments. A pull mode refusal or failure stops here with pull mode's reason and next step. It never restarts.

## Step 5: Restart

Pull mode returns here after a successful pull. Restart the command by its kind:

- **A Skill-invocable command**: invoke it again through the Skill tool with the arguments forwarded verbatim.
- **A command marked `disable-model-invocation`** (`/gaia-codify`, `/gaia-fitness`, `/gaia-residue`): the Skill tool cannot start it, so print its re-run command, arguments included, in a bare fenced block, for the user to paste.
- **The generated plan orchestrator**: print, in a bare fenced block, `Read <absolute KICKOFF.md path> and execute it.`
- **Ad-hoc work** under `.claude/skills/gaia/references/work-lifecycle.md`: continue the lifecycle at its step 1, now on the pulled checkout.
