---
type: concept
status: active
created: 2026-04-21
updated: 2026-11-24
tags: [concept, git, workflow]
---

# Git Workflow

The rules below are machine-enforced by `.claude/hooks/block-main-destructive-git.sh` (a PreToolUse `Bash` hook that short-circuits on any command whose command word is not `git`, so only real `git` invocations are evaluated). The hook emits `permissionDecision: "deny"` with a reason string, so Claude cannot bypass it without explicit user override.

The guard is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it governs this repo only. A `git` command positively aimed at a different repository (`git -C <other>` or `cd <other> &&`) is allowed; that sibling repo's own policy applies there, not this one's. The verdict covers the whole tool call, so a call that also holds a command acting on this repository, even a read-only one, is enforced: run the sibling command as its own call. A linked worktree of this repository is not a different repository, whichever checkout the command runs from. Scoping is fail-closed: any ambiguity still enforces.

## 1. Never commit directly to `main` or `master`

Always work on a feature branch. Work reaches `main`/`master` only through a pull request, where the audit gate reviews it before it merges ([[PR Merge Workflow]]). If HEAD is on `main`/`master`, create one first:

```bash
git switch -c <type>/<issue>-<slug>
```

The branch name, the commit subject, and the PR title follow [[Naming Conventions]].

Branches GAIA's own commands create, and branches for any committed work a session does outside a skill, are not hand-named: every one takes its name from `.gaia/scripts/branch-name-lib.sh`, whose header holds that convention. The lifecycle for such work, from claim to cleanup, is `.claude/skills/gaia/references/work-lifecycle.md`.

## 2. Never force-push to `main` or `master`

No `--force`, `--force-with-lease`, or `-f` to `main`/`master`; upstream history is shared, so rewriting it pulls commits out from under every clone and branch built on it. Fix conflicts with a merge or rebase on the feature branch, then open a PR.

## 3. Never push directly to `main` or `master`

A push from `main`/`master` lands local commits on the shared branch without the pull request and audit every change passes through.

The hook denies several independent conditions on `git push`, each with its own message and its own repair: a plain push while HEAD sits on `main`/`master` (switch to a feature branch and open a PR); a push whose refspec names `main`, `master`, or `HEAD` as the source (bare, or before a colon), or names `main`/`master` as the destination (`feature:main`, `+feature:main`, `:main`, `heads/main`, `refs/heads/main`, `--delete refs/heads/main`), or pushes every shared branch (`:`) or a glob destination that covers `main`, from any branch (name the branch being pushed explicitly and open a PR instead); and a push the hook cannot place, because the command names a directory it cannot read and one of the checkouts that directory could name is on `main`/`master` (spell the directory literally, or create a feature branch).

They answer in that order, and the order is by how much of the verdict each message can stand behind. Standing on `main` answers first, since its repair settles the refspec too. The refspec answers ahead of the unreadable directory because it holds whatever checkout the push turns out to run from, where the unreadable-directory message reports an unanswered question and offers repairs that do nothing for a refspec.

## 4. Approved by a classifier, bounded by hooks

`.claude/settings.json` carries no blanket `Bash(git *)` rule, and must not: git runs programs named in its config, so a blanket rule is an unprompted shell (`git -c 'alias.x=!cmd' x` runs `cmd`). Its narrower `git ...` allow entries stay as they are. Instead `classify-git-command.sh`, a PreToolUse Bash hook, approves the git commands it can vouch for, so a session, interactive or driven unattended by `/loop`, does not stall on an ordinary commit, push, rebase or merge. It returns an allow or nothing. Nothing leaves the normal permission flow: a settings rule, else the prompt.

It approves a command only when all of these hold, and falls through otherwise:

- **Structure.** Simple commands joined by `&&`, `||`, `;` or a newline. A command may end in one pipe into `head` or `tail` (at most a numeric `-N` or `-n N`) or `wc -l`, and `git commit -F -` may read a heredoc whose delimiter is quoted (`<<'EOF'`), since its body never expands. Any other pipe, a background `&`, a redirect other than one that discards or duplicates a stream (`2>&1`, `2>/dev/null`), a `$` or backtick, a glob, a brace list, a subshell, a backslash or a comment outside single quotes all fall through, as does a substituted commit message (`-m "$(cat <<'EOF' …)"`): pass it with `-F -` and a quoted heredoc, `-F <file>` or a quoted `-m`.
- **Every segment is git.** It starts with the bare word `git`. An env prefix, a wrapper (`command`, `env`), a path to git, or any other program in the command falls through.
- **Globals.** Only one `-C <directory>`, `-c <key>=<value>` for a key on the safe list, `--no-pager`, `-P` and `--no-optional-locks`. Any `--config-env`, `--git-dir`, `--work-tree` or other global falls through.
- **This repository.** The directory git runs in (the payload cwd, or `-C` read against it) belongs to this repository: the main checkout or a linked worktree. Git run anywhere else reads that repository's config and hooks, which nothing here has read.
- **The allow list.** The subcommand is listed, and carries none of the entry's fall-through options: those that run a program (`--exec`, `--upload-pack`, `--receive-pack`, `rebase -x`, a merge strategy), open an editor or pager (`rebase -i`, `grep -O`), write a named file (`--output`, `archive -o`), or write a path the edit prompts guard (`restore --source`, a `checkout` with a pathspec). `config` and `remote` are approved only in their read forms. `apply`, `rm` and `mv` are not listed: a patch can edit a path the edit prompts guard, and an `rm` or `mv` operand does not say which path git resolves it to.
- **No table deny, no branch question.** None of these matches: a deny in the guard's table below; a commit, push, merge, cherry-pick, revert, rebase, pull other than `--ff-only` from its upstream, or a reset with an operand other than `HEAD` or `@` before `--`, from `main`/`master` (or from a branch an earlier checkout, switch or symbolic-ref segment of the same command may have changed); a push refspec rule 3 denies; a fetch or pull operand with a colon (a refspec, or a URL) or `--refmap` (a refspec destination can force-move `main`); a hard reset that moves HEAD.

Fail to fall-through, never fail to allow: a missing library, a missing jq, or a parse the hook cannot finish leaves the call to the prompt.

The lists, one definition each:

- **Allow list** (subcommands and their fall-through options): `.claude/hooks/lib/git-allow-list.sh`. Chosen from what GAIA's commands, skills, rules, agents and executed wiki pages tell Claude to run, plus a scan of real session transcripts.
- **Command-running config keys** and the **safe `-c` keys**: `.claude/hooks/lib/git-command-config.sh`, read by this hook, the destructive-git guard and `block-no-verify.sh`.

**Precedence.** A PreToolUse deny from any hook beats another hook's allow, and settings `deny` and `ask` rules still apply after a hook's allow (Claude Code hooks reference). So `block-main-destructive-git.sh`, `block-no-verify.sh`, `block-rm-rf.sh`, `pr-merge-audit-check.sh` and every other deny hook keep working beside it, and the settings file's `deny` rows stay a second layer. A live `claude -p` run in default permission mode bears this out: `block-no-verify.sh` refuses a `--no-verify` commit the classifier allows with the two hooks registered in either order, and a settings `deny` or `ask` row for `git commit` still refuses a commit the classifier allows.

Beyond rules 1 to 3 and its deny of a hard reset that moves HEAD, the guard denies, on any branch, the operations whose damage reaches past the feature branch the session is working on. `.claude/hooks/lib/main-git-guard-history.sh` holds them, and each deny names its repair:

| Denied | Why | Allowed instead |
| --- | --- | --- |
| `git push --mirror`, `git push --all` / `--branches` | Overwrites or advances remote `main`, and `--mirror` deletes every remote branch the clone lacks | `git push -u origin <branch-name>` |
| `git clean` with `-x` or `-X` | Deletes ignored files: the `.env` files, GAIA's local working state and the notebook, none of which git can restore | `git clean -fd` |
| `git config` setting `core.hooksPath` to anything but `.githooks` (an empty value included), or unsetting it | Switches off GAIA's git hooks for every later commit, the persistent form of the inline override `block-no-verify.sh` denies | `git config core.hooksPath .githooks`, and reads |
| A `-c` or `--config-env` override, or a `git config` write in any scope (`--file`, `--global`, `--system` included), of a key git runs as a command: an `alias.*` with a `!` value, `core.sshCommand`, `core.pager`, `core.editor`, `core.fsmonitor`, `sequence.editor`, `diff.external`, `filter.*`, `*.textconv`, `credential.helper`, `gpg.program`, `include.path`, `includeIf.*.path` and the rest of the list | Plants a command the next approved git call runs with no prompt | Run the command directly, where its own permission rule applies; `git --no-pager` for a pager |
| `git update-ref` naming `main`/`master` or writing `HEAD`, or `--stdin` | Moves or deletes the shared branch outside every guard | `git branch` / `git switch` on the feature branch |
| `git branch` deleting, renaming, copying over or force-moving `main`/`master`, `git checkout -B` / `git switch -C` / `git worktree add -B` onto it, and `git symbolic-ref` deleting or re-pointing it | The local base every branch, worktree and cleanup step reads | The same operations on any other branch |
| `git reflog expire`, `delete` or `drop`, `git gc --prune…`, `git prune` | Erase the record or the objects that recover a dropped commit | `git reflog`, `git gc` |
| `git filter-branch`, `git filter-repo` | Rewrite history across branches | Ask the user to run it |

`block-no-verify.sh` reads the inline `core.hooksPath` override from the parsed globals, so a quoted `-c 'core.hooksPath=x'` and `--config-env=core.hooksPath=X` are denied as the plain spelling is. `block-git-internals-write.sh` denies an Edit, Write or MultiEdit anywhere in `.git/` and on a linked worktree's `.git` file: its config and hooks run commands, and its pointer files (`.git`, `commondir`, `gitdir`) decide which repository git reads.

Allowed on purpose: a force-push of a feature branch (the rebase repair), deleting a tag, `git worktree remove --force`, and the commands that discard uncommitted work on the session's own branch (`git checkout -- .`, `git restore .`, `git stash drop`/`clear`), which stay ordinary editing.

The rules read the parsed operands, never the raw text, so a flag quoted inside a commit message is not an invocation, and match a long option in any prefix git accepts (`--mirr`). They inherit the parser's honest limits (an unexpanded variable or an unlisted value-taking global option reads no subcommand and allows), which the classifier does not: it falls through on both. Residuals: the env-prefixed config forms (`GIT_CONFIG_*`, `GIT_SSH_COMMAND`) are never approved, so they still prompt; an approved commit, push, merge or checkout runs the tracked hooks under `.githooks/` and whatever they call, which are the project's own reviewed code, so an edit to them is an ordinary file edit no rule here vouches for. A sub-agent runs the same hooks, so the execution doctrine's rule that executors run no state-changing git is held by that doctrine, not by a permission prompt.

## Setup standdown

The rules above have one temporary, explicit exception. `/setup-gaia` provisions a greenfield repo by landing GAIA's own CI-install commit directly on the default branch: that commit has nothing to audit and the branch is not yet a collaboration surface. An admin run also lands the project's recorded setup decisions the same way, and `/gaia-init` lands its own init output as one commit before any remote exists. For each such commit (and push, when there is a remote) the command suspends the hook via a machine-local, gitignored sentinel `.gaia/local/setup-in-progress`, then removes it. The sentinel is honored only while fresh (mtime within 10 minutes), so a stale one left behind by a crashed setup self-heals and enforcement resumes on its own; it is gitignored, so it never rides into a clone. Resting state is fully enforcing.

## Splitting an already-staged tree into commits

A bare `git commit -m "..."` with no pathspec commits the entire index, not just the files staged by the most recent `git add`. When only some staged files belong in a commit, pass explicit pathspecs: `git commit -m "..." -- <file1> <file2>`. The `-m` flag must come before the `--`; `-- <paths> -m "msg"` makes git treat `-m` and the message itself as pathspecs, and the commit silently does nothing. Confirm with `git status --short` before and after any split-commit sequence to verify only the intended files landed.

See [[PR Merge Workflow]], [[Claude Hooks]].
