# Work lifecycle

The one statement of how committed work moves from its first edit to a cleaned-up checkout: claim, name, isolate, enter the worktree, commit and open the draft PR, audit, merge, clean up. A session working outside any GAIA skill follows it in full, and every skill that drives its own PR points here for the steps it shares.

Contents: When this applies; 1. Claim; 2. Name; 3. Isolate; 4. Enter the worktree; 5. Commit and open the draft PR; 6. Audit; 7. Merge (when asked); 8. Cleanup (worktree entered by name in this session, worktree entered by path or in an earlier session, feature branch, sub-agent context); The git worktree add backstop.

## When this applies

A session working outside a GAIA skill reaches the first edit it will commit. Every committed change needs a branch, because `main` is commit-guarded, so cut the branch before that edit rather than meeting the commit denial after it. An edit the user said they will review or commit themselves stays on `main`, uncommitted, and never enters this lifecycle.

A draft PR is part of every committed ad-hoc task, whether or not the request asked for one.

Skills that drive their own PR (`/gaia-debt`, `/gaia-plan`'s orchestrator, `/gaia-fitness`, `/gaia-cleanse`, `/gaia-codify`, `/gaia-residue`, `/update-deps`) point at the steps below for what they share and keep their own extras. Where a skill's own contract differs from this page, the skill's contract governs.

**Edits already on `main`.** The main checkout may already hold uncommitted edits for this work when the lifecycle starts. A feature branch cut from HEAD carries them as they are. `EnterWorktree` cuts the worktree fresh from the default base and does not carry them, so in worktree mode move them as a patch. Before entering, write the diff of tracked files to a scratch file outside the repository:

```bash
git diff --binary HEAD > <scratch file>
```

After step 4, from inside the worktree, apply it and confirm it landed:

```bash
git apply <scratch file>
git status --short
```

A new file git does not yet track is not in that diff: copy it into the worktree at the same relative path. Then tell the user the main checkout still holds the original edits, and leave them there: never discard, stash or reset the main checkout's copies. When `git apply` fails, report the failure and stop.

## 1. Claim

Work that closes a GitHub issue claims it per `.claude/rules/issue-claim.md` before step 3. That rule owns the label read and the claim command.

A `tech-debt` issue is never claimed by hand. Tell the user to run `/gaia-debt <n>` instead, adding `worktree` or `branch` when they named an isolation mode, because `/gaia-debt` owns that claim and the stale-claim reconcile that reads it.

## 2. Name

Mint the branch name with the ad-hoc kind, never by hand:

```bash
bash .gaia/scripts/branch-name-lib.sh name adhoc --type <type> --issue <n> --slug "<slug>"
```

- `--issue` is omitted when the work closes no issue.
- `<type>` is the Conventional Commits type of the change, from the `types` list in `.gaia/conventional-commits.json`. The PR title in step 5 uses the same type.
- `<slug>` is a two-to-four-word reduction of the change.

On exit 2 the library prints one reason on stderr; read it. When the slug would read as another kind of GAIA branch, choose a different slug and mint again. The library owns the name's shape, length and character set (its header states them); take the printed name as `<branch-name>` from here on.

## 3. Isolate

Read `.claude/skills/gaia/references/isolation.md` and apply it with these slot bindings, passing the step-2 name as the branch name:

| Slot | Binding |
|---|---|
| `{{SUBJECT}}` | `this change` |
| `{{WORKER}}` | `this session` |
| `{{OWNER}}` | `this change` |
| `{{SIBLING}}` | `another task` |

Isolation words in the request ("in a worktree", "on a branch") are the stated answer isolation.md takes in place of its question. Without them, isolation.md runs unchanged, and its policy read decides whether the question is asked at all. Arms that isolation.md walks ahead of the question can override a stated answer; isolation.md names which, and says so in one line when one does.

## 4. Enter the worktree

This section is the project instruction that directs the use of `EnterWorktree` and `ExitWorktree` for lifecycle work. Each tool's own description limits it to cases the user or the project's instructions direct; when isolation.md's policy, not the user, chose worktree mode, this line is what satisfies that condition.

Creating the worktree, renaming its `worktree-<x>` branch to `<branch-name>`, and reading `RESOLVED_ROOT` are isolation.md's `## Worktree creation` and `## Export`, unchanged: follow them there. Entering provisions the tree (`.gaia/local` linked to the main checkout's, among the rest) through `.claude/hooks/provision-worktree.sh`, which fires on `EnterWorktree`.

Never create a lifecycle worktree with a plain `git worktree add`. A tree made that way is handled by `## The git worktree add backstop` below.

Feature-branch mode skips this step.

## 5. Commit and open the draft PR

Commit through the Quality Gate (`.claude/rules/quality-gate.md`). Push the branch with `git push -u origin <branch-name>`, then open the PR with `gh pr create --draft` and a Conventional Commits title per `wiki/decisions/Naming Conventions.md`. `.claude/hooks/block-invalid-pr-title.sh` and `.claude/hooks/block-pr-create-without-draft.sh` enforce the title and the draft; their headers own the rules.

When the work closes an issue, the PR body carries `Closes #<n>`, and no commit message on the branch carries a closing keyword against it. A squash merge concatenates the branch's commit bodies into the merge commit, and GitHub reads closing keywords from that message, so a keyword in a commit closes the issue whatever the PR body says. The PR body is the sole carrier.

In worktree mode, every command runs from inside the worktree.

## 6. Audit

Read `wiki/concepts/PR Merge Workflow.md` and run it, not a remembered version of it, to a posted `GAIA-Audit` success status. The full gate applies to an ad-hoc PR; there is no lighter path. The success post (`.claude/hooks/post-audit-status.sh`) marks the draft ready for review, so the session runs no `gh pr ready`.

When the request did not ask to merge, stop here. Report the PR URL as ready to merge, and leave the branch, the worktree and the PR in place. Merging a PR the request did not ask to merge waits for the user to ask; a later message asking to merge counts.

## 7. Merge (when asked)

Squash merge per `wiki/concepts/PR Merge Workflow.md`: its `### 4. Merge` and `## Post-merge verification before cleanup` own the flags, `--auto` over `--admin`, and every verdict arm. Then wait:

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N>
```

Only `MERGED` (exit 0) reaches `## 8. Cleanup`. Every other verdict, and the exit-2 refusal, follows that page's arm for it and stops before cleanup. A caller may pass its own `--attempts`, as a skill that waits on a full CI run does.

## 8. Cleanup

Runs only after the merge wait prints `MERGED`. Pick the arm by how the session holds the branch.

Rules every arm shares:

- Never force a pull, and never stash.
- When a pull fails (a dirty tree, a diverged `main`), report it and stop.
- When the main checkout's HEAD is a branch other than `main` and other than the merged branch, a peer session holds it: skip the checkout and the pull, and say so.

Why the worktree arms carry no `git checkout` and why the worktree removal needs `--force`: `wiki/concepts/PR Merge Workflow.md`, `### Cleanup under worktree isolation`.

### Worktree entered by name in this session

The session entered the tree with `EnterWorktree({name})` in this session. Call:

`ExitWorktree({action: "remove", discard_changes: true})`

Gate the call on the confirmed `MERGED`. The squash absorbed every commit on the branch without making them ancestors of `main`, so `discard_changes` loses nothing. Never call `ExitWorktree` first and treat its refusal as the trigger.

`ExitWorktree` deletes only the branch name it created, so the renamed `<branch-name>` survives it. The session is back in the main checkout; from there run:

```bash
if git show-ref --verify --quiet refs/heads/<branch-name>; then
  git branch -D <branch-name>
fi
git fetch --prune origin
head_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = main ]; then
  git pull --ff-only origin main
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull.\n' "$head_branch"
fi
```

### Worktree entered by path or in an earlier session

`ExitWorktree` will not remove a tree entered with `EnterWorktree({path})`, the backstop's route; the tool's own documentation says so. A tree created in an earlier session and re-entered in this one takes this arm too, because the tool's behavior on such a tree is not settled.

When the session is inside the tree, leave it with `ExitWorktree({action: "keep"})`. Then, from the main checkout, read the worktree records:

```bash
git worktree list --porcelain
```

Take the tree's path from its `worktree <path>` line as `<worktree path>`, and the branch from the same record's `branch refs/heads/<branch>` line as `<branch-name>`. Address the tree by that path and the branch by that name; never derive one from the other, because the directory name and the branch name can differ. Then run:

```bash
git worktree remove --force <worktree path> || exit 1
if git show-ref --verify --quiet refs/heads/<branch-name>; then
  git branch -D <branch-name>
fi
git fetch --prune origin
head_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = main ]; then
  git pull --ff-only origin main
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull.\n' "$head_branch"
fi
```

### Feature branch

The session holds the branch in the main checkout. Run this script from a shell there. It checks out `main` only when HEAD is the merged branch and no linked worktree holds `main`; when one does, it says so and exits non-zero having deleted nothing.

```bash
head_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = "<branch-name>" ]; then
  if git worktree list --porcelain | awk '/^worktree / { n++ } n > 1 && $0 == "branch refs/heads/main" { held = 1 } END { exit !held }'; then
    printf 'A linked worktree holds main, so the main checkout cannot check it out. Nothing was deleted.\n' >&2
    exit 1
  fi
  git checkout main || exit 1
  head_branch=main
fi
if [ "$head_branch" = main ]; then
  git pull --ff-only origin main || exit 1
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull.\n' "$head_branch"
fi
if git show-ref --verify --quiet refs/heads/<branch-name>; then
  git branch -D <branch-name>
fi
git fetch --prune origin
```

### Sub-agent context: continuation prompt

The runtime refuses `ExitWorktree` from an agent dispatched with `isolation: "worktree"` or a `cwd` override; the refusal text is `ExitWorktree cannot be called from a subagent with a cwd override`. Detect that context before either worktree arm calls the tool:

- **Primary signal:** the session was dispatched through `Agent(...)` with `isolation: "worktree"` or a `cwd` override: it runs as a sub-agent task and its cwd is a worktree path under `.claude/worktrees/`.
- **Fallback:** when uncertain, attempt the arm's `ExitWorktree` call. When the response contains `cannot be called from a subagent`, treat the call as never issued (a refusal, not a destructive action) and take the continuation-prompt path.

When detected, print this continuation prompt inside a `text` fence and stop:

```text
The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
PR #<N> squash-merged as <short-sha>. From a shell at
<ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

    git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
    git branch -D <branch-name>   # if it still exists
    git -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> fetch --prune origin
    git -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> pull --ff-only origin main   # only when `git rev-parse --abbrev-ref HEAD` there prints main
```

A caller with steps of its own appends its lines to the end of that command list; the plan orchestrator appends its two post-merge close lines.

The prompt carries no `ExitWorktree({...})` call because it runs from another context, a shell or a fresh session in the main checkout, not from the session that entered the tree; the tool's schema also rejects a `worktree` parameter. The plain `git worktree remove --force` is the cleanup that works from any context.

## The git worktree add backstop

A session that creates a tree under `.claude/worktrees/` with a Bash `git worktree add` gets a context injection from `.claude/hooks/workflow-doctrine-inject.sh` right after the command. It names the new tree's absolute path and the branch it holds, and instructs entering it with `EnterWorktree({path: "<absolute path>"})` before working there. When that branch is not a minted name, it also instructs renaming the branch to a minted ad-hoc name (step 2) before the first push.

Entering provisions the tree. Cleanup for such a tree is `### Worktree entered by path or in an earlier session`.

A tree created outside `.claude/worktrees/` gets no backstop: those are deliberate side trees, not lifecycle worktrees. Without `jq` the hook injects nothing on PostToolUse, so on a machine without `jq` the backstop is absent.
