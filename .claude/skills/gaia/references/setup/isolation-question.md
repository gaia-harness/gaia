# Isolation policy question

`/setup-gaia --reconfigure` reads this file, whole, in Phase 3.5 to ask the team git isolation-policy question and map the answer to a value; a plain run and `/gaia-init` never ask it, because an unset policy is GAIA's default, `always-worktree`. The calling command says what to do with a value and what no answer does.

## The question

Show the explainer (this block stays English regardless of UI language, it's the canonical contract):

> GAIA lets you work on several tasks at once (features, fixes, updates), each in its own copy of your project called a git worktree. Tasks run in parallel without touching each other or your own checkout, so you can keep coding while they run.
>
> GAIA is built for this, and it's the fastest way to work. The alternative is one task at a time on a branch in your current checkout: slower, but everything happens in one place.

Then use `AskUserQuestion`, header **`Isolation policy`** (in the user's language), question "How do you want to work: tasks in parallel, or one at a time?", with these three options in this exact order:

- **Always use worktrees (Recommended)**: every task uses its own worktree, so they can always run in parallel.
- **Prefer worktrees**: GAIA suggests a worktree for each task, or you can choose a branch instead.
- **Prefer branches**: GAIA suggests a branch for a task, or you can choose a worktree instead. Note that if you attempt to start a parallel task while on a branch, GAIA will automatically use a worktree for that task.

## The answer

- `Always use worktrees (Recommended)` is `always-worktree`.
- `Prefer worktrees` is `prefer-worktree`.
- `Prefer branches` is `prefer-branch`.

"Other" or a dismissal is no answer.
