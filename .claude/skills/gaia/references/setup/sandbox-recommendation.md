# Sandbox recommendation question

`/setup-gaia --reconfigure` reads this file, whole, in Phase 3.5 to ask the team sandbox-recommendation question and map the answer to a value; a plain run and `/gaia-init` never ask it, because an unset recommendation means not recommended. The calling command says what to do with a value and what no answer does.

The value is a committed **recommendation** only, never an enablement: each machine still decides for itself at `/setup-gaia`.

## The question

Use AskUserQuestion (in the user's language; this configuration block stays in English):

> Recommend Claude Code's OS-level Bash sandbox to your team? Each machine still decides at /setup-gaia; this only records the recommendation.
>
> - **No, don't recommend (Recommended).** No team-level nudge; every machine still decides independently at `/setup-gaia`.
> - **Yes, recommend the sandbox.** `/setup-gaia` shows this as the suggested answer on each machine.

List the two options in this exact order.

## The answer

- `No, don't recommend (Recommended)` is `false`.
- `Yes, recommend the sandbox` is `true`.

"Other" or a dismissal is no answer.
