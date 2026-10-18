Contents: When it runs; Create the worktree; The rules after creation; The worktree notice; The stop rule.

# Create the update worktree

This is the one place `/update-deps` creates a worktree. `SKILL.md` routes three points here: the maintainer-only vendored-skill sync, the post-decision point in `## Branch creation (after discovery)`, and the refresh-only path (before Phase 5b). Every other arm of the command (CI, `/gaia-init`, a non-default branch, a run already inside its own update worktree) creates no worktree and no branch.

## When it runs

Run it only when `SHOULD_CREATE_WORKTREE=true` and no worktree was created earlier in this run (`CREATED_WORKTREE` is not yet set). A second branch point that reaches this file after the first created the worktree does nothing: it is this run's tree.

## Create the worktree

1. Mint the branch name in the main checkout and carry it as `<branch-name>`:
   ```bash
   bash .gaia/scripts/branch-name-lib.sh name deps
   ```
2. Enter the worktree, passing the name:
   ```
   EnterWorktree({name: "<branch-name>"})
   ```
   Then rename the harness's `worktree-` spelling to `<branch-name>` with the three plain commands in `.claude/skills/gaia/references/isolation.md` (`## Worktree creation`), each value typed as a literal. Carry the path `git rev-parse --show-toplevel` prints as `<worktree path>`. Set `CREATED_WORKTREE=true`.
3. Print the worktree notice (below).
4. Wait for provisioning before any further step, because the discovery command and every later step run `pnpm`. Call it as a bounded series of single Bash calls; on exit 4 call again:
   ```bash
   bash .gaia/scripts/provision-wait.sh --tree <worktree path>
   ```
   Exit 0 continues. Exit 3 (`INSTALL_FAILED`) stops here, because this run created the tree: the stop rule below applies. Exits 5, 6 and 2 stop the same way. A stop prints the worktree path, the `Log:` path the script printed, the next step (read the log, then re-run `/update-deps` inside the worktree), and the worktree notice.
5. Reconcile discovery with the worktree. The worktree is cut from the default branch on `origin`, while discovery read the main checkout's manifests. Re-read each apply-set package's declared version from the worktree's `package.json` files (`package.json` and `frontend/package.json`) and compare it with what discovery read. Where it differs, the worktree's value is the current version every agent prompt and the final report use; a package the worktree already declares at or above its target leaves the apply set; the final report lists each difference. A refresh-only run has no apply set to reconcile.

## The rules after creation

- **Command shape.** Every command runs in the worktree as one plain command with every value typed as a literal, or as a call to a tracked script at a literal path. The runtime refuses a captured command substitution, a shell variable interpolated into a path, and a heredoc inside a worktree session.
- **Agents get the worktree.** Every agent dispatched from here on, without exception (the Override audit + Wave A agent, each Wave B agent, the Phase 5b agent, Phase 5c's delegated resolution agent, the Phase 6 agent), receives `<worktree path>` in its prompt as the tree it works in.
- **Main-anchored writes.** A write to a path in the main checkout follows the tool-choice contract in `.claude/skills/gaia/references/spec.md` (`## Operational primitives`, the `Tool-choice contract` paragraph): `Bash` at the main-checkout absolute path, then read it back.
- **Re-read against the worktree.** Discovery's payload reflects the main checkout. After reconciling in step 5, treat the worktree's manifests as the source of truth for the rest of the run.

## The worktree notice

Print this text right after the worktree is created and renamed, again when a skill-controlled stop ends the run, and again when the run opens its PR. Fill in the paths and the branch:

```text
Update worktree: <worktree path>
Branch: <branch>
To discard it, run from the main checkout (<main checkout path>):
  git worktree remove --force <worktree path>
  git branch -D <branch>
Warning: --force discards any uncommitted changes in the worktree.
```

## The stop rule

Every skill-controlled stop after creation that ends the run before the PR (a failed quality gate, a failed install, a provisioning stop, a refresh that did not land, a decline at a prompt) leaves the worktree in place, changes nothing in the main checkout, and prints the worktree notice. A stop never removes the tree.
