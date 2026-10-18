---
type: concept
status: active
created: 2026-10-01
updated: 2026-10-14
tags: [concept, claude, config, workflow]
---

# Project Config

`.gaia/project.json` is the committed, team-shared file where a GAIA project records its own preferences. It holds answers a repository owner gives once and every clone then reads, as opposed to a per-machine choice, which lives in gitignored local settings. The audit loop's context checkpoint line is one such per-machine choice: it lives in `.gaia/local/protected/checkpoint-override.json`, not here, because teammates can run different models with different context windows, so no single committed value fits them all. That file is machine-local, human-edited, can only lower the shipped default, and Claude tool writes to it are denied; see [[Local Working State]].

## Keys

All keys are optional except `version`, which is `1`.

| Key | Values | Meaning |
| --- | --- | --- |
| `sandbox_recommended` | `true` or `false` | The owner's recommendation to run Claude Code's OS sandbox; absent means not recommended. Each machine still resolves it for itself; see [[OS Sandbox]]. |
| `isolation_policy` | `always-worktree`, `prefer-worktree`, `prefer-branch` | How a session isolates work that closes an issue, runs a plan, or is ad-hoc committed work (through `## 3. Isolate` in `.claude/skills/gaia/references/work-lifecycle.md`); absent means `always-worktree`. The reading rules live in `.claude/skills/gaia/references/isolation.md`. |
| `setup_decisions` | an object of setup feature id to `applied`, `declined` or `not-applicable` | The project-scope decisions made through `/gaia-init`, `/setup-gaia` and `/update-gaia`. See [[Setup Features]]. |

A reader treats an unknown or invalid value as absent, so a typo or a value a newer GAIA wrote never breaks the file. The known values are enforced when the file is written.

## Writers

These CLI commands write the file, each creating it (with `version` set) when it does not exist:

- `gaia init write-project-config`, called by `/gaia-init` to write the not-recommended sandbox default (see [[GAIA Init Workflow]]).
- `gaia setup write-isolation-policy`, called by `/setup-gaia --reconfigure` when a repo admin answers the isolation policy.
- `gaia setup write-sandbox-recommendation`, called by `/setup-gaia --reconfigure` when a repo admin answers the team sandbox recommendation.
- `gaia setup record`, which merges one setup decision into `setup_decisions`.

A writer merges into the raw file, so a key or a `setup_decisions` entry it does not know survives, and writes atomically.

## Readers

`/setup-gaia` reads the sandbox recommendation to decide whether a machine is asked about the sandbox. The isolation policy is also read at the start of work that cuts a branch or worktree. `gaia setup drift` reads `setup_decisions` to report the undecided setup features, and `/setup-gaia` uses that to route owed phases.

## Ownership

The file is adopter-owned. It is absent from `.gaia/manifest.json`, so `/update-gaia`'s merge never overwrites or deletes it, and it is committed so the whole team shares one answer. `/update-gaia`'s setup drift step records decisions into it, and those records ride the update commit. `/setup-gaia` lands its project decisions on the default branch. No GAIA command creates it before something has a value to record.

See [[Update Workflow]] for the merge rules the file sits outside.
