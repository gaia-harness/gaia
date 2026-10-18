# Isolation policy question

`/setup-gaia --reconfigure` reads this file, whole, in Phase 3.5 to ask the team git isolation-policy question and map the answer to a value; a plain run and `/gaia-init` never ask it, because an unset policy is GAIA's default, `always-worktree`. The calling command says what to do with a value and what no answer does.

## The question

Show the explainer (this block stays English regardless of UI language, it's the canonical contract):

> Worktrees buy you the ability to run a GAIA task without touching your current checkout, so you can keep
> coding, or run a second GAIA task, while it works. They cost:
>
> - a separate checkout per task, whose first quality-gate run installs its own `node_modules` (a one-time
>   install; the real disk cost ranges from tens of megabytes on a copy-on-write filesystem to the full
>   install size elsewhere);
> - your editor indexes that second checkout as well as the main one;
> - a dev server started inside a worktree collides on the same port as one in the main checkout;
> - a crashed session can leave a worktree behind for you to remove by hand.
>
> Scope limit: this policy governs `/gaia-plan`, `/gaia-debt` and ad-hoc committed work. `/gaia-cleanse`, `/gaia-codify`, and
> `/gaia-wiki` still work in the main checkout. And while a GAIA task holds your session in a worktree,
> `/update-deps` and `/update-gaia` refuse to run there; run them from a separate session on the main
> checkout.

Then use `AskUserQuestion`, header **`Isolation policy`** (in the user's language), question "How should this team isolate `/gaia-plan`, `/gaia-debt` and ad-hoc committed work?", with these three options in this exact order:

- **Always use worktrees (Recommended)**: GAIA always works in a worktree, no question asked.
- **Prefer worktrees**: GAIA leads with a worktree, so you can keep working, or run another GAIA task, at the same time.
- **Prefer branches**: GAIA leads with a feature branch and works in the current checkout.

## The answer

- `Always use worktrees (Recommended)` is `always-worktree`.
- `Prefer worktrees` is `prefer-worktree`.
- `Prefer branches` is `prefer-branch`.

"Other" or a dismissal is no answer.
