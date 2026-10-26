# Isolation policy question

`/setup-gaia --reconfigure` reads this file, whole, in Phase 3.5 to ask the team git isolation-policy question and map the answer to a value; a plain run and `/gaia-init` never ask it, because an unset policy is GAIA's default, `always-worktree`. The calling command says what no answer does; on a choice it runs the write and the commit below.

## The question

Show this explainer in the user's language:

> GAIA lets you work on several tasks at once (features, fixes, updates), each in its own copy of your project called a git worktree. Tasks run in parallel without touching each other or your own checkout, so you can keep coding while they run.
>
> GAIA is built for this, and it's the fastest way to work. The alternative is one task at a time on a branch in your current checkout: slower, but everything happens in one place.

Then use `AskUserQuestion`, header **`Isolation policy`**, question "How do you want to work: tasks in parallel, or one at a time?", with these three options in this exact order, the header, question, labels and descriptions all in the user's language:

- **Always use worktrees (Recommended)**: every task uses its own worktree, so they can always run in parallel.
- **Prefer worktrees**: GAIA suggests a worktree for each task, or you can choose a branch instead.
- **Prefer branches**: GAIA suggests a branch for a task, or you can choose a worktree instead. Note that if you attempt to start a parallel task while on a branch, GAIA will automatically use a worktree for that task.

## The answer

Map the answer by the chosen option's position, never by its label text, which the user saw in their own language:

- The first option, `Always use worktrees (Recommended)`, is `always-worktree`.
- The second option, `Prefer worktrees`, is `prefer-worktree`.
- The third option, `Prefer branches`, is `prefer-branch`.

"Other" or a dismissal is no answer.

## The write

```bash
.gaia/cli/gaia setup write-isolation-policy <always-worktree|prefer-worktree|prefer-branch>
```

If this exits non-zero, surface the structured-error JSON verbatim and skip **The commit** below. Do not retry, do not hand-write the key. On success, record it: `[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record isolation-policy applied`.

## The commit

This clause carries its own commit, including the main-branch hook standdown. HEAD is on the default branch; when that branch is `main` or `master`, the `block-main-destructive-git.sh` PreToolUse hook denies `git commit` and `git push` there, so a machine-local sentinel in `.gaia/local/` (gitignored, never reaching a teammate's clone) suspends it for this one commit+push. The hook does not recognize a custom default-branch name, so on one the sentinel is inert but harmless.

**Separate Bash call, first** (the `block-main-destructive-git.sh` PreToolUse hook reads this sentinel before the command runs, so bundling it into the same call as `git commit` would not yet exist when the hook checks):

```bash
mkdir -p .gaia/local
touch .gaia/local/setup-in-progress
```

**Then, in its own call:**

```bash
git add .gaia/project.json
git commit -m "chore(gaia): set the team git isolation policy to <value>"
git push origin <current-branch>
```

**Then, in its own call, unconditionally** (even if the commit or push failed, a lingering sentinel keeps main-branch protection suspended on this machine):

```bash
rm -f .gaia/local/setup-in-progress
```

**Branch on the push result honestly.** A repository ruleset can reject even an admin's direct push (`GH013`). If the push fails, say so in one line and tell the admin the value is committed locally and needs a push (or a PR); do not report success on a failed push. The commit itself makes the policy real for this machine's next run; the push is what makes it real for the team.
