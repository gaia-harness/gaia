---
type: concept
title: GAIA CLI
status: active
created: 2026-07-14
updated: 2026-10-28
tags: [concept, cli]
---

# GAIA CLI

GAIA ships a single bundled CLI binary that hooks and slash commands invoke, plus a fire-and-forget adoption ping that reports coarse setup usage back to the GAIA team. The ping is the only unattended call GAIA makes to a GAIA-operated service. The only other unattended GAIA network calls are the session-start janitor's git fetch of the repository's own configured `origin` (see below) and the statusline's background update check (`.gaia/scripts/check-updates.sh`), which queries GitHub and the package registry, never a GAIA-operated service. Cost pricing opens no network connection.

## CLI workspace

`.gaia/cli/` houses the CLI. Adopters receive a self-contained bundled binary at `.gaia/cli/gaia` (`#!/usr/bin/env node` shebang), invoked by hooks and slash-command emits. The subcommand router uses a static handler map (no switch; the project's `no-switch` rule). Adopters receive only the `gaia` binary; source, tests, and fixtures are excluded from the release tarball.

<!-- gaia:maintainer-only:start -->
Maintainer source lives at `.gaia/cli/src/`. `pnpm bundle` runs `bundle:adopter` then `bundle:maintainer` (esbuild, ESM); the maintainer build emits a separate `.gaia/cli/gaia-maintainer` binary that adds the release namespace and is excluded from the adopter tarball. A commit that stages CLI source rebuilds and stages both bundles through the pre-commit hook, and `.gitattributes` marks the bundles as generated.
<!-- gaia:maintainer-only:end -->

Run `gaia --help` for the current, authoritative list of top-level subcommands.

## Migrating stories to CSF Next

`gaia migrate-csf4 [--update-merge] [--json]` converts a project's CSF3 stories to CSF Next (CSF4), repairs what Storybook's own codemod leaves wrong, rewires the preview and `.storybook/main.ts`, and verifies each story file by typecheck, lint and a Storybook Vitest run. A factory-built story export becomes a direct `meta.story({...})` call under the same export name, because Storybook's indexer cannot attach `.test()` to an export a factory function builds. The preview repair, `rewirePreview(ts, source, mainAddons?)`, rewrites a CSF3 `Preview` object to `definePreview` and wires each known addon the preview imports or `mainAddons` lists; the command passes the addon specifiers `mainAddonSpecifiers(ts, mainSource)` reads from `.storybook/main.ts`, so an addon registered only in main (such as `@storybook/addon-links`) still gets its `addonLinks()` entry, and an addon it does not know is reported for a hand fix. It refuses a dirty tree; `--update-merge` is the form the after-update migration note passes, which tolerates the update's uncommitted merge and refuses only when a file it would write is itself dirty. It prints the command that restores what it changed. Exit codes and the `--json` report shape live in `gaia migrate-csf4 --help`. The target story format is described in [[Stories as Tests]].

## Adoption ping

The adoption ping exists to steer GAIA's roadmap: knowing which setup options and platforms adopters actually use tells the team where feature work will pay off. `gaia ping` sends a fire-and-forget POST to `https://telemetry.gaiaharness.com/ping` when `/gaia-init`, `/setup-gaia`, and `/update-gaia` complete, and the 2.0.0 migration note sends an install event and then an update event once its `/setup-gaia` handoff is done. `/setup-gaia` sends its setup event on a provisioned re-run only when it recorded a new decision, with no `--type`. The body carries the event name (`init`, `setup`, or `update`), a per-install `projectId` (the deterministic id at `.gaia/local/.project-id`), the GAIA version, the coarse OS platform (`macos`/`windows`/`linux`, else `other`), and a handful of low-cardinality categorical fields specific to the event (`gaia ping --help` lists them). `GAIA_TELEMETRY_PING_DISABLE=1` suppresses it; there is no other opt-out. Set it where every session sees it so it persists: the `env` key of `.claude/settings.local.json` for one machine, the committed `.claude/settings.json` for the whole team, or the shell profile that launches Claude Code. The stable `projectId` makes the pixel pseudonymous-per-install rather than fully anonymous, correlating one install's `init` -> `setup` -> `update` events; it never carries user paths or free text. A network failure, timeout, or unreadable manifest never affects the caller's exit code.

## The unattended git fetch

The session-start janitor ([[Local Working State]]) makes one bounded `git fetch --prune` of the repository's own configured `origin`. It contacts no GAIA service and sends nothing about the machine or its contents; it is a plain git fetch of the remote the adopter already pushes to. It is gated on a local wiki landing branch (`wiki/<YYYY-MM-DD-HHMM>`) being present, so a session with no outstanding wiki landing makes no call at all, and it is bounded at 5 seconds by default and rate-limited between sessions. `GAIA_WIKI_FETCH_TIMEOUT_SECONDS=0` disables it outright.

## Pairs with

- [[Claude Hooks]]: the hook surface that invokes the CLI binary.
