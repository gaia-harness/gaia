---
name: naming-conventions
description: Applies descriptive, self-documenting naming in any language (TypeScript, bash, workflow YAML, Dockerfiles). Use this skill whenever naming or renaming an identifier, variable, constant, function, parameter, env var, workflow job, or Dockerfile ARG/ENV, or reviewing names for vagueness, abbreviations, or redundant type noise.
---

# Naming Conventions

Follow Apple's Swift API Design Guidelines: names should be clear at the point of use, reading like prose. Favor long, descriptive names over short or abbreviated ones.

- **Functions and methods**: imperative verb phrases: `calculateProgressPercentageFromCompletedSets`, `processUserOnboardingProfile`
- **Parameters**: role, not type: `totalSeconds` not `n`, `emailAddress` not `s`
- **Variables**: what they hold: `restDurationInSeconds`, `submitButton`, `weightInputValue`
- **No abbreviations**: owned by `.claude/rules/no-abbreviations.md`
- **No type noise**: `availableExercises` not `exerciseArray`, and never so short it loses clarity

Casing is each language's own convention; for TypeScript, see the typescript skill.

> **Exception, React event handlers** follow `handle{Action}{Element}` from the react-code skill
> (e.g. `handleClickSave`, `handleChangeInput`), the `{Element}` is required, since a bare
> `handleClick` or `handleChange` says when it fires, not what it does. The descriptive
> naming guidelines above apply to utilities, hooks, callbacks, and non-event-handler functions.

Read `references/examples.md` for extended BAD/GOOD examples of each naming pattern.
