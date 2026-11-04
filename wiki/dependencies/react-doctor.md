---
type: dependency
status: active
package: react-doctor
role: react-quality-scanner
created: 2026-06-23
updated: 2026-11-04
tags: [dependency, quality, ci]
---

# react-doctor

Deterministic scanner for React security, performance, correctness, and accessibility issues. Scores the codebase 0-100 and emits per-rule diagnostics. Devtime/CI-only, advisory.

## Conventions

- Config: `apps/web/doctor.config.ts`. GAIA ships exactly one config file (see Single config below).
- Run: `npx -y react-doctor@<version> .`, at the version `.gaia/react-doctor-version` pins; the audit oracle and the skill's commands both run it. react-doctor is not a project dependency, so the config stays a plain `export default` and does not import react-doctor's config type.
- Install (`/gaia-init`, `/setup-gaia`): `/gaia-init` runs the script at the end of its dependency step, before anything reads `apps/web/`, so the session that runs onboarding lists the skill; `/setup-gaia`'s install-tools probe then finds the skill and records the step, and installs it only when the probe finds none. A `/setup-gaia` run in a session that already read a file under `apps/web/` installs the skill after that folder's skill scan, so it appears from the next session. `.gaia/scripts/install-react-doctor.sh` renders GAIA's own skill from `.gaia/templates/react-doctor/` into `<web member path>/.claude/skills/react-doctor/` (`apps/web` in a stock project; gitignored, kept per-machine, never committed), substituting the pinned version. It never runs react-doctor's own installer: that skill claims Claude Code's built-in `/doctor` and fetches instructions from react-doctor's website at run time, and the installer's other writes (CI workflow, commit-hook block, package script, devDependency, lockfile churn) are project churn. `--refresh`, which the cleanup after a `/update-gaia` merge runs, replaces the whole skill directory, including a skill react-doctor's installer wrote.
- Runs automatically pre-merge inside the [[Code Review Audit Agent]] (alongside [[knip]] and [[pnpm-audit]]). Findings are advisory and never block the audit marker.
- Not part of the [[Quality Gate]] (pre-commit).

- The audit invocation uses `--scope changed`; `--diff` is a deprecated hidden alias for it. The command lives in `.gaia/scripts/audit-frontend-oracles.sh`.

## Moving the pin

`/update-deps` does not see the pin, because it is not in `package.json`. Move it by hand:

1. Read the new release's changes and the skill it bundles (`dist/skills/react-doctor/` in `npm pack react-doctor@<version>`).
2. Port any new command or flag worth having into `.gaia/templates/react-doctor/`. Never port a `/doctor` trigger, a remote fetch or an unpinned version.
3. Write the version to `.gaia/react-doctor-version`, run `bash .gaia/scripts/install-react-doctor.sh --refresh`, then a full scan to confirm `apps/web/doctor.config.ts` still loads and its suppressions still match the ruleset.

## Single config, highest precedence

react-doctor resolves config in extension-precedence order (`.ts > .mts > .cts > .js > .mjs > .cjs > .json > .jsonc`) and uses the first file it finds, silently ignoring the rest. Two config files means the lower-precedence one is shadowed with no warning.

The canonical config is `apps/web/doctor.config.ts`:

- `.ts` matches the repo's `*.config.ts` convention (vite/knip/playwright/react-router), so it lives where config is expected and is found.
- `.ts` is the highest-precedence extension, so a stray `doctor.config.json`/`.jsonc` cannot shadow it.
- Comments are native, carrying the evidence for each suppression.

### Duplicate-config guard

A deterministic check fails when more than one `doctor.config.*` or `react-doctor.config.*` file exists, because react-doctor itself gives no warning: `.githooks/pre-commit` ([[Pre-commit Hooks]]) fails the commit before a duplicate lands.

## Acting on output

Findings fall into three buckets:

1. **Real issue**: fix the code. Security and correctness rules take priority over performance and a11y.
2. **Domain mismatch**: a rule that does not apply to a path (e.g. a web-input rule firing on Node CLI tooling, or a generated artifact). Add a scoped `ignore.overrides` entry naming the rule and files, or `ignore.files` for output that should never be scanned (e.g. `build/**`).
3. **Tool overlap**: dead-code analysis (`deslop`) duplicates [[knip]], the single dead-code authority. `deadCode: false` disables it.

Suppress with the narrowest control: prefer a per-path `ignore.overrides` entry over a blanket rule-off. Every suppression carries a comment with the evidence so it can be re-evaluated when the ruleset changes (rules drift between versions, so re-check suppressions whenever the pin moves).

See [[Quality Gate]], [[Code Review Audit Agent]].
