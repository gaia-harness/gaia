---
type: concept
status: active
created: 2026-10-13
updated: 2026-10-13
tags: [concept, setup, update-gaia, config]
---

# Setup Features

A setup feature is one decision `/setup-gaia` owns: a machine tool, a GitHub setting, a team preference. GAIA ships the list of them with each release and records, per project and per machine, which ones have been decided. Comparing the two lets a project or machine whose setup is already complete learn about a feature a later release adds.

## The list

`.gaia/setup-features.json` is the shipped list; this page names no id, the file is the list. Each entry carries:

- `id`: kebab-case and unique. Ids are stable forever. A feature whose behavior changes gets a new id and the old one retires from the list. A recorded id no longer listed is ignored and kept.
- `scope`: `machine` (gitignored or user-level state) or `project` (the committed `.gaia/project.json` or a GitHub setting).
- `required`: mirrors what the feature's phase does today. True means the phase applies it without asking, false means it asks. The list reclassifies nothing.
- `admin`: applying it needs a repository admin.
- `standalone`: its reference runs on what it probes itself, with nothing from the calling phase. Every feature added after 2.0.0 must be standalone, so `/update-gaia` can apply or ask it without the full setup flow.
- `reference`: the repo-relative file that holds the feature's logic.

## Decisions

A decision is `applied`, `declined` or `not-applicable`. `not-applicable` records a feature that cannot apply here: no global statusline, an incapable sandbox, an origin that is not on github.com.

Project-scope decisions live in `.gaia/project.json` under `setup_decisions` (see [[Project Config]]); machine-scope decisions live in `.gaia/local/setup-state.json` under `decisions` (see [[Local Working State]]).

- `gaia setup record <id> <value>` writes one decision to the scope the list gives the id, and refuses an unknown id or a value outside the three.
- `gaia setup drift` compares a feature list with the records and reports the undecided ids, each with the action that settles it.

## Who uses it

- **`/gaia-init`** records the shipped defaults for the sandbox recommendation and the isolation policy, asking nothing.
- **`/setup-gaia`** treats a phase whose id is undecided as owed on every run, even once setup is complete, and probes first: a feature already in place is recorded with no question. The command routes; the phase bodies live in its setup references (`.claude/skills/gaia/references/setup/`), and `.claude/commands/setup-gaia.md` is the map. Project-scope records are made only by an admin run on the default branch, and that run lands them there. A standalone feature is run by its own reference.
- **`/update-gaia`**'s drift step compares the target bundle's list with the records. It applies or asks only standalone features, names every other undecided feature as "run /setup-gaia", and never applies or asks a non-admin what needs an admin. See [[Update Workflow]].
- **Pull mode** applies the machine-scope features the pulled release lists, with the same `APPLY`, `ASK` and `SETUP` handling as the update's drift step, and leaves project-scope features to the full update. See [[Update Workflow]] (`## Pull mode`).
- **The statusline** arms a `/setup-gaia` nudge on the main checkout when setup is complete and a machine-scope id has no recorded decision. Project ids never arm it.

## Precedence

A feature's own state (the sandbox marker, the user's statusline setting, a `.gaia/project.json` key, a GitHub setting) governs behavior and its phase's own gate. The record only answers whether the id has been decided.

- A `declined` record satisfies the phase's gate on a plain run, so only `--reconfigure` re-asks a declined feature. The one exception is a `sandbox` record with no sandbox marker: that is the shipped default-off, not an answer, so a later team recommendation still asks the machine.
- A feature with a shipped default (the isolation policy, the sandbox recommendation, and the sandbox when the team does not recommend it) records the default on a plain run without asking.
- An `applied` or `not-applicable` record never suppresses a gate that says the feature is owed. The phase asks or applies again and the new answer overwrites the record.

## Known limits

- On a non-GitHub origin the team settings (the isolation policy and the sandbox recommendation) are never recorded by `/setup-gaia`, so on a project `/gaia-init` did not record them they stay undecided and `/update-gaia` names them as "run /setup-gaia" on every update.
- A non-admin's run, and any run off the default branch, records machine decisions only. Project ids wait for an admin run of `/setup-gaia` on the default branch.

## See also

- [[Migration Notes]]: the other thing a release carries to an existing project.
- [[Project Config]]: where project-scope decisions are stored.
