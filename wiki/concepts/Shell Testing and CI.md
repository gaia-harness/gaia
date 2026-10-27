---
type: concept
title: Shell Testing and CI
status: active
created: 2026-10-27
updated: 2026-10-27
tags: [concept, testing, shell, ci]
---

# Shell Testing and CI

GAIA gives a project three things for the shell it writes: an audit member at the merge gate, a bats stack for tests, and an opt-in shellcheck lint in CI. This page ties them together.

## What GAIA gives an adopter for shell

- **The shell audit member.** `code-audit-shell` (`.claude/agents/code-audit-shell.md`) is a member of the [[Code Audit Team]]. It reviews the shell you author, the hooks you add or edit, and your own edits to a shell file GAIA ships. It skips a change to a file the manifest lists as owned when that change comes from applying a GAIA release, so a GAIA update never dispatches it for GAIA's own shell.
- **The bats stack.** `pnpm test:shell` runs suites under `tests/shell/` with the pinned npm `bats` package.
- **The opt-in lint.** A shellcheck workflow lints the shell a pull request changes, once you turn it on.

## Running bats

```bash
pnpm test:shell
```

With no arguments the runner runs `tests/shell/`; with arguments it passes them to bats, so a single file runs while you iterate. It refuses to run, with one line naming the bash version it found, when the first `bash` on `PATH` is older than 4. `.claude/skills/tdd/references/tests-shell.md` owns the steps for putting bash 5 first on `PATH`, plus the suite layout and fixture conventions.

## Assertions that can fail

A bare `[[ ]]` or arithmetic test inside a bats test passes silently on some bash versions even when false, so write assertions that fail loudly. `.claude/rules/bats-assertions.md` owns the pattern.

## Shellcheck in CI

`.github/workflows/shellcheck-scan.yml` is off until you opt in. Set the repository variable `GAIA_SHELLCHECK` to `true` under the repository's Settings, Secrets and variables, Actions, Variables. A skipped job costs nothing.

When on, it lints the `.sh` and `.bats` files a pull request changes, minus every file the manifest lists as owned. Unchanged files are never linted. A `.shellcheckrc` in the repository applies, so your own policy (disabled codes, severity) is honored. The job is advisory by default; add it as a required check in your own ruleset when you want it to block.

## Keeping suites fast

- Build fixtures in `$BATS_TEST_TMPDIR`, which bats cleans up after each test.
- Keep one suite per script, so a change runs one small file.
- Avoid network calls; stub the command instead.
- Run a single file while iterating, and the whole directory before you push.
- When the suite grows slow, shard by file across CI jobs so each job runs a slice of the suite files.

## Roster interaction

The member sits in the roster after the maintainer-only block and before `unowned:`; `.gaia/audit-ci.yml` owns its globs. Claimants match first-match-wins in roster order, so a shell claimant of your own listed earlier keeps ownership of the paths it claims: `/update-gaia` appends the new member after your members.

Shell and bats files the frontend member used to review anywhere in the tree now belong to the shell member. When the new member makes an `unowned:` entry overbroad, `/update-gaia` removes that entry and reports it in the run summary. The roster mechanics are in [[Code Audit Team]].

## Pairs with

- [[Code Audit Team]]
- [[Customizing GAIA]]
- [[Registering a Code Audit Team Member]]
- [[Update Workflow]]
