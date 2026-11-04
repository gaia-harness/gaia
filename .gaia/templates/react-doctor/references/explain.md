# Explaining and configuring rules

## Workflow

1. Take the rule key from the diagnostic (e.g. `react-doctor/no-array-index-as-key`).
2. Explain it before changing anything:

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules explain react-doctor/no-array-index-as-key
```

3. Pick the narrowest control that matches the intent (decision guide below).
4. Apply it: a `rules` subcommand edits `doctor.config.ts` in place; an `ignore.overrides` entry or a `surfaces` change is a hand edit to the same file.
5. Confirm the change did what the user wanted:

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} --verbose --scope changed
```

## Commands

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules list                         # every rule and its effective severity
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules list --configured            # only what the config changed
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules list --category Performance  # filter by category
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules explain <rule>               # why it matters, how to configure it
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules disable <rule>               # the rule never runs
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules enable <rule>                # back on at its recommended severity
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules set <rule> warn              # off | warn | error
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules category "React Native" off  # a whole category
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules ignore-tag design            # a rule family (design, test-noise, ...)
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} rules unignore-tag design
```

A rule reference accepts the full key (`react-doctor/no-danger`), the bare id (`no-danger`) or a legacy key (`react/no-danger`).

## Decision guide

Prefer the narrowest control:

- **The user disagrees with one rule, or it is a false positive for one path**: a scoped `ignore.overrides` entry naming the rule and files; `rules disable <rule>` only when it is wrong everywhere.
- **Right rule, wrong severity**: `rules set <rule> warn|error`.
- **A disabled-by-default rule they want on**: `rules enable <rule>`.
- **A whole area is unwanted** (e.g. React Native): `rules category "<Category>" off`.
- **A noisy family** (`design`, `test-noise`, `migration-hint`): `rules ignore-tag <tag>`.
- **Keep it locally but hide it from the score or CI gate**: do not disable it; edit `surfaces` in the config (`surfaces.score.excludeTags`, `surfaces.ciFailure.excludeCategories`). The rule still shows in CLI output.

How the layers combine: `ignore.tags` disables every rule with that tag before linting, so a rule-level setting cannot re-enable it. Otherwise `rules` overrides `categories`, which overrides the rule's default. `surfaces` changes visibility only.

## Config

The config is `doctor.config.ts` in the web package, a plain `export default`. Never add a second `doctor.config.*` or `react-doctor.config.*` file: react-doctor reads only the highest-precedence one, and the pre-commit hook rejects a duplicate. Every suppression carries a comment with its evidence.

## Educating the user

Lead with the "Why it matters" text from `rules explain`. Offer to disable a rule only after the user understands it: many rules that look wrong catch real issues.
