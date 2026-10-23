# Work lifecycle

The one statement of how committed work moves from its first edit to a cleaned-up checkout: claim, name, isolate, enter the worktree, commit and open the draft PR, audit, merge, clean up. A session working outside any GAIA skill follows it in full, and every skill that drives its own PR points here for the steps it shares.

Contents: When this applies; 1. Claim; 2. Name; 3. Isolate; 4. Enter the worktree; 5. Commit and open the draft PR; 6. Audit; 7. Merge (when asked); 8. Cleanup (worktree entered by name in this session, worktree entered by path or in an earlier session, feature branch, sub-agent context, leftover-file cleanup after an update merge); Releasing the claim on an unmerged ending; Releasing an empty worktree; The git worktree add backstop.

## When this applies

A session working outside a GAIA skill reaches the first edit it will commit. Every committed change needs a branch, because `main` is commit-guarded, so cut the branch before that edit rather than meeting the commit denial after it. An edit the user said they will review or commit themselves stays on `main`, uncommitted, and never enters this lifecycle.

A draft PR is part of every committed ad-hoc task, whether or not the request asked for one.

Skills that drive their own PR (`/gaia-debt`, `/gaia-plan`'s orchestrator, `/gaia-fitness`, `/gaia-cleanse`, `/gaia-codify`, `/gaia-residue`, `/gaia-wiki`, `/update-deps`) point at the steps below for what they share and keep their own extras. Where a skill's own contract differs from this page, the skill's contract governs.

**Edits already on `main`.** The main checkout (the clone's primary working directory, whatever branch it has checked out) may already hold uncommitted edits for this work when the lifecycle starts. A feature branch cut from HEAD carries them as they are. `EnterWorktree` cuts the worktree fresh from the default base and does not carry them, so in worktree mode move them as a patch. Before entering, write the diff of tracked files to a scratch file outside the repository:

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

A fresh start runs the pull gate before the claim, with `ad-hoc work` as the command name. Work whose branch already exists locally or as a worktree is a resume and skips the gate.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_pull_gate "ad-hoc work"
```

On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `ad-hoc work`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.

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

Run isolation.md every time, its policy read first, even when the request names the isolation. Isolation words in the request ("in a worktree", "on a branch") are only the stated answer isolation.md takes in place of its question; they never skip the policy read. The arms isolation.md walks ahead of the question still run and can override a stated answer: under `always-worktree`, a stated branch becomes a worktree, said in one line.

## 4. Enter the worktree

This section is the project instruction that directs the use of `EnterWorktree` and `ExitWorktree` for lifecycle work. Each tool's own description limits it to cases the user or the project's instructions direct; when isolation.md's policy, not the user, chose worktree mode, this line is what satisfies that condition.

Creating the worktree, renaming its `worktree-<x>` branch to `<branch-name>`, and reading `RESOLVED_ROOT` are isolation.md's `## Worktree creation` and `## Export`, unchanged: follow them there. Entering provisions the tree (`.gaia/local` linked to the main checkout's, among the rest) through `.claude/hooks/provision-worktree.sh`, which fires on `EnterWorktree`.

Never create a lifecycle worktree with a plain `git worktree add`. A tree made that way is handled by `## The git worktree add backstop` below.

Feature-branch mode skips this step.

## 5. Commit and open the draft PR

Commit through the Quality Gate (`.claude/rules/quality-gate.md`). Push the branch with `git push -u origin <branch-name>`, then open the PR with `gh pr create --draft` and a Conventional Commits title per `wiki/decisions/Naming Conventions.md`. `.claude/hooks/block-invalid-pr-title.sh` and `.claude/hooks/block-pr-create-without-draft.sh` enforce the title and the draft; their headers own the rules.

When the work closes an issue, the PR body carries `Closes #<n>`, and no commit message on the branch carries a closing keyword against it. A squash merge concatenates the branch's commit bodies into the merge commit, and GitHub reads closing keywords from that message, so a keyword in a commit closes the issue whatever the PR body says. The PR body is the sole carrier.

The PR title, the PR body and every commit message describe the change in words, never by a SPEC, UAT or plan id or a path under `.notebook/` or `.gaia/local/`: those name documents only this machine has (`.claude/rules/working-doc-ids.md`). The `commit-msg` hook refuses a message that cites one.

In worktree mode, every command runs from inside the worktree.

## 6. Audit

Read `wiki/concepts/PR Merge Workflow.md` and run it, not a remembered version of it, to a posted `GAIA-Audit` success status. The full gate applies to an ad-hoc PR; there is no lighter path. The success post (`.claude/hooks/post-audit-status.sh`) marks the draft ready for review, so the session runs no `gh pr ready`.

When the request did not ask to merge, stop here. Report the PR URL as ready to merge, and leave the branch, the worktree and the PR in place. Merging a PR the request did not ask to merge waits for the user to ask; a later message asking to merge counts.

## 7. Merge (when asked)

Squash merge per `wiki/concepts/PR Merge Workflow.md`: its `### 4. Merge` and `## Post-merge verification before cleanup` own the flags, `--auto` over `--admin`, and every verdict arm. Then wait:

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N>
```

Add `--attempts 20` when the merge was queued with `--auto`; that page says why. Only `MERGED` (exit 0) reaches `## 8. Cleanup`. Every other verdict, and the exit-2 refusal, follows that page's arm for it and stops before cleanup.

## 8. Cleanup

Runs only after the merge wait prints `MERGED`. Pick the arm by how the session holds the branch.

Rules every arm shares:

- Never force a pull, and never stash.
- Every arm resolves the default branch before it reads HEAD: the branch `refs/remotes/origin/HEAD` names, else whichever of `main` and `master` the remote has, else `main`. Never compare against a literal `main`: on a repository whose default branch is `master` every pull would be skipped.
- When a pull fails (a dirty tree, a diverged default branch), report it and stop.
- When the main checkout's HEAD is a branch other than the default branch and other than the merged branch, a peer session holds it: skip the checkout and the pull, and say so.
- Every worktree arm runs the pre-removal check, `bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>`, before it removes anything. It stops on uncommitted changes (untracked files included), and on commits ahead of the branch's upstream while that ref exists. A non-zero exit ends cleanup with the worktree and branch kept: no `ExitWorktree` removal, no `git worktree remove --force`, no branch delete, no pull, no install.
- After the branch delete, every arm runs `state-cleanup.sh --branch <branch-name>`, which removes the merged branch's own audit, run and PR-cache state. It refuses while the branch or a worktree holding it still exists, so a cleanup that stopped early leaves that state to the daily backstop reaper, and it never touches the `protected/` folder of `.gaia/local`.
- A stop is reported, never swallowed. Relay the check's whole output (the paths, the unpushed count, and the next step with the exact removal commands), and the calling run's report names the kept worktree. An unattended run puts it in its final report, so kept worktrees never pile up silently.
- The worktree arms run `pnpm install --frozen-lockfile` in the main checkout only when the pull ran and `pnpm-lock.yaml` differs between the pre-pull and post-pull HEAD. When the pull fails or is skipped, run no install and print the pull and the install as the next steps. A failed install is reported with its next step and does not undo the removal.

Why the worktree arms carry no `git checkout`, why the worktree removal needs `--force`, why the check stops before it, and why the install is conditional: `wiki/concepts/PR Merge Workflow.md`, `### Cleanup under worktree isolation`.

### Worktree entered by name in this session

The session entered the tree with `EnterWorktree({name})` in this session. First run the pre-removal check from inside the tree, one plain call; `<worktree path>` is the session's `RESOLVED_ROOT`:

```bash
bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>
```

A non-zero exit stops here: relay its output and call nothing below. A tree whose branch predates the script has no copy of it (exit 127): then run the plain `git -C <worktree path> status --porcelain`, and stop, relaying the output and the matching next step above, when it lists anything. An empty status is clear.

On a clear check, call:

`ExitWorktree({action: "remove", discard_changes: true})`

Gate the call on the confirmed `MERGED`. The squash absorbed every commit on the branch without making them ancestors of the default branch, and the check found nothing uncommitted or unpushed, so `discard_changes` loses nothing. Never call `ExitWorktree` first and treat its refusal as the trigger.

`ExitWorktree` deletes only the branch name it created, so the renamed `<branch-name>` survives it. The session is back in the main checkout; from there run:

```bash
if git show-ref --verify --quiet refs/heads/<branch-name>; then
  git branch -D <branch-name>
fi
bash .gaia/scripts/state-cleanup.sh --branch <branch-name>
git fetch --prune origin
default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
for candidate in main master; do
  [ -z "$default_branch" ] && git show-ref --verify --quiet "refs/remotes/origin/$candidate" && default_branch=$candidate
done
[ -n "$default_branch" ] || default_branch=main
head_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = "$default_branch" ]; then
  pre_pull_head=$(git rev-parse HEAD)
  if ! git pull --ff-only origin "$default_branch"; then
    printf 'The pull failed. Next steps, from the main checkout: git pull --ff-only origin %s, then pnpm install --frozen-lockfile.\n' "$default_branch" >&2
    exit 1
  fi
  if ! git diff --quiet "$pre_pull_head" HEAD -- pnpm-lock.yaml; then
    if ! pnpm install --frozen-lockfile; then
      printf 'The install failed; the worktree and branch stay removed. Next step: run pnpm install --frozen-lockfile in the main checkout and read its output.\n' >&2
      exit 1
    fi
  fi
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull and the install. Next steps, from the main checkout: git pull --ff-only origin %s, then pnpm install --frozen-lockfile.\n' "$head_branch" "$default_branch"
fi
```

### Worktree entered by path or in an earlier session

`ExitWorktree` will not remove a tree entered with `EnterWorktree({path})`, the backstop's route; the tool's own documentation says so. A tree created in an earlier session and re-entered in this one takes this arm too, because the tool's behavior on such a tree is not settled.

When the session is inside the tree, leave it with `ExitWorktree({action: "keep"})`. Then, from the main checkout, read the worktree records:

```bash
git -C <main checkout path> worktree list --porcelain
```

Every git and pnpm command in the first and third fences takes the `-C <main checkout path>` form, with `<main checkout path>` a typed literal, so the arm works when the session was launched inside the tree it removes (a re-run of an update command inside its own worktree reaches cleanup this way, with no `EnterWorktree` entry to exit and `cd` banned by `.claude/rules/shell-cwd.md`).

Take the tree's path from its `worktree <path>` line as `<worktree path>`, and the branch from the same record's `branch refs/heads/<branch>` line as `<branch-name>`. Address the tree by that path and the branch by that name; never derive one from the other, because the directory name and the branch name can differ. Then run the pre-removal check; a non-zero exit stops here, so run nothing below and relay its output:

```bash
bash .gaia/scripts/worktree-removal-check.sh --tree <worktree path>
```

On a clear check, run:

```bash
git -C <main checkout path> worktree remove --force <worktree path> || exit 1
if git -C <main checkout path> show-ref --verify --quiet refs/heads/<branch-name>; then
  git -C <main checkout path> branch -D <branch-name>
fi
bash <main checkout path>/.gaia/scripts/state-cleanup.sh --branch <branch-name>
git -C <main checkout path> fetch --prune origin
default_branch=$(git -C <main checkout path> symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
for candidate in main master; do
  [ -z "$default_branch" ] && git -C <main checkout path> show-ref --verify --quiet "refs/remotes/origin/$candidate" && default_branch=$candidate
done
[ -n "$default_branch" ] || default_branch=main
head_branch=$(git -C <main checkout path> rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = "$default_branch" ]; then
  pre_pull_head=$(git -C <main checkout path> rev-parse HEAD)
  if ! git -C <main checkout path> pull --ff-only origin "$default_branch"; then
    printf 'The pull failed. Next steps, from <main checkout path>: git pull --ff-only origin %s, then pnpm install --frozen-lockfile.\n' "$default_branch" >&2
    exit 1
  fi
  if ! git -C <main checkout path> diff --quiet "$pre_pull_head" HEAD -- pnpm-lock.yaml; then
    if ! pnpm -C <main checkout path> install --frozen-lockfile; then
      printf 'The install failed; the worktree and branch stay removed. Next step: run pnpm install --frozen-lockfile in <main checkout path> and read its output.\n' >&2
      exit 1
    fi
  fi
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull and the install. Next steps, from <main checkout path>: git pull --ff-only origin %s, then pnpm install --frozen-lockfile.\n' "$head_branch" "$default_branch"
fi
```

### Feature branch

The session holds the branch in the main checkout. Run this script from a shell there. It checks out the default branch only when HEAD is the merged branch and no linked worktree holds the default branch; when one does, it says so and exits non-zero having deleted nothing.

```bash
default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
for candidate in main master; do
  [ -z "$default_branch" ] && git show-ref --verify --quiet "refs/remotes/origin/$candidate" && default_branch=$candidate
done
[ -n "$default_branch" ] || default_branch=main
head_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$head_branch" = "<branch-name>" ]; then
  if git worktree list --porcelain | awk -v held_line="branch refs/heads/$default_branch" '/^worktree / { n++ } n > 1 && $0 == held_line { held = 1 } END { exit !held }'; then
    printf 'A linked worktree holds %s, so the main checkout cannot check it out. Nothing was deleted.\n' "$default_branch" >&2
    exit 1
  fi
  git checkout "$default_branch" || exit 1
  head_branch=$default_branch
fi
if [ "$head_branch" = "$default_branch" ]; then
  git pull --ff-only origin "$default_branch" || exit 1
else
  printf 'The main checkout is on %s, held by a peer session: skipped the pull.\n' "$head_branch"
fi
if git show-ref --verify --quiet refs/heads/<branch-name>; then
  git branch -D <branch-name>
fi
bash .gaia/scripts/state-cleanup.sh --branch <branch-name>
git fetch --prune origin
```

### Sub-agent context: continuation prompt

The runtime refuses `ExitWorktree` from an agent dispatched with `isolation: "worktree"` or a `cwd` override; the refusal text is `ExitWorktree cannot be called from a subagent with a cwd override`. Detect that context before either worktree arm calls the tool:

- **Primary signal:** the session was dispatched through `Agent(...)` with `isolation: "worktree"` or a `cwd` override: it runs as a sub-agent task and its cwd is a worktree path under `.claude/worktrees/`.
- **Fallback:** when uncertain, attempt the arm's `ExitWorktree` call. When the response contains `cannot be called from a subagent`, treat the call as never issued (a refusal, not a destructive action) and take the continuation-prompt path.

When detected, print this continuation prompt inside a bare fenced block and stop:

```
The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
PR #<N> squash-merged as <short-sha>. From a shell at
<ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

    bash .gaia/scripts/worktree-removal-check.sh --tree <ABSOLUTE-PATH-TO-WORKTREE>   # stop and report its output when it exits non-zero
    git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
    git branch -D <branch-name>   # if it still exists
    bash <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>/.gaia/scripts/state-cleanup.sh --branch <branch-name>
    git -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> fetch --prune origin
    git -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> pull --ff-only origin <DEFAULT-BRANCH>   # only when `git rev-parse --abbrev-ref HEAD` there prints <DEFAULT-BRANCH>
    pnpm -C <ABSOLUTE-PATH-TO-MAIN-CHECKOUT> install --frozen-lockfile   # only when that pull ran and changed pnpm-lock.yaml
```

`<DEFAULT-BRANCH>` is the default branch, resolved the way the arms above resolve it. A caller with steps of its own appends its lines to the end of that command list; the plan orchestrator appends its two post-merge close lines.

The prompt carries no `ExitWorktree({...})` call because it runs from another context, a shell or a fresh session in the main checkout, not from the session that entered the tree; the tool's schema also rejects a `worktree` parameter. The plain `git worktree remove --force` is the cleanup that works from any context.

### Leftover-file cleanup after an update merge

Runs after any arm above when the merged branch is a `/update-gaia` branch (its name starts with `update/`) and the arm's pull ran and succeeded. The merged `.gaia/state-registry.json` names the `.gaia/local` state that retired features left behind, and only the pulled main checkout holds that registry with a real `.gaia/local` directory, so the cleanup runs there. From the main checkout:

```bash
bash <main checkout path>/.gaia/scripts/state-registry-lib.sh residue-sweep
```

Show its output. When its Residue section lists paths, ask once with `AskUserQuestion` (question `Delete the leftover files listed above?`, header `Leftovers`, options `Delete them` (Recommended) and `Keep them`), and on `Delete them` run the same command with `--apply`. Unknown paths are listed, never deleted. A non-zero exit names its cause on stderr: relay it and finish cleanup. When the pull was skipped or failed, run nothing and add `ask Claude to run the leftover-file cleanup once the main checkout is pulled` to the printed next steps. The sub-agent continuation prompt has no one to ask, so on an update branch it appends the listing command above with the note `review the list, then re-run it with --apply to delete the leftover files`.

## Releasing the claim on an unmerged ending

`.claude/hooks/issue-claim-release.sh` releases an `in-progress` claim only on a `gh pr merge`. Claude releases it on every other ending of work that claimed an issue (`.claude/rules/issue-claim.md`): when it closes the pull request unmerged (`gh pr close`), and when the user says the work is dropped, with or without a pull request. For each issue the work claimed, the issues its PR body closes by keyword:

```bash
gh issue edit <n> --remove-label in-progress
```

Say which issues were released. A `tech-debt` issue is left alone: `/gaia-debt` owns its claim and releases a stale one in its reconcile. A pull request closed so that a replacement takes over the same issue keeps the claim: the replacement still holds it.

## Releasing an empty worktree

`.claude/skills/gaia/references/isolation.md` (`## Releasing an isolation that holds nothing`) sends a worktree it created in this session here only after both of its reads came back empty: nothing uncommitted, and no commit past the base. That emptiness stands in for the `MERGED` gate of `## 8. Cleanup`. `/update-gaia`'s claim flow also sends one here when its claim loses: that worktree's only commit is the claim commit, already pushed to a pull request now closed with its remote branch deleted, so it holds none of the user's work either. In both cases, call:

`ExitWorktree({action: "remove", discard_changes: true})`

`discard_changes` loses nothing, because both reads were empty or the only commit is that claim. `ExitWorktree` deletes only the branch name it created, so from the main checkout, which the call returned the session to, delete the renamed branch with the plain `git branch -D <branch-name>`. No fetch, pull or install follows: nothing merged.

## The git worktree add backstop

A Bash `git worktree add` under `.claude/worktrees/` triggers a context injection from `.claude/hooks/workflow-doctrine-inject.sh`: follow it (enter the tree with `EnterWorktree({path: "<absolute path>"})`, and rename a non-minted branch per step 2 before the first push). Cleanup for such a tree is `### Worktree entered by path or in an earlier session`.

A tree created outside `.claude/worktrees/` gets no backstop: those are deliberate side trees, not lifecycle worktrees. Without `jq` the hook injects nothing on PostToolUse, so on a machine without `jq` the backstop is absent.
