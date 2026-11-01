---
type: concept
title: Toolchain Floors
status: active
created: 2026-10-31
updated: 2026-10-31
tags: [concept, setup, update]
---

# Toolchain Floors

GAIA runs on tools it cannot always install itself. `.gaia/toolchain-floors.tsv` holds the lowest version of each that works, as data, and `.gaia/scripts/toolchain-check.sh` is the only reader. The file is tab-separated because jq is one of the tools checked, and the script is bash builtins for the same reason. No command states a floor in its own prose.

## Who checks, and when

- **`/setup-gaia`** checks at the start of Phase 0 on every run, and halts on any miss, with no fallback for an older tool. Clones run setup, and `/gaia-init` flows into it, so init holds no copy.
- **`/gaia-init`** needs pnpm for its own install, so it runs the one pnpm section it shares with setup, in `.claude/skills/gaia/references/toolchain.md`.
- **`/update-gaia`** checks before its Proceed question, because an existing project never reruns setup. It runs the verified target bundle's copy of the script, so the incoming release sets the floor, not the older skill doing the update. A `block` row stops the update and a `warn` row is told to the user: a row blocks when the updated harness would not work without the tool, and warns when GAIA degrades safely.
- **The first crossing** runs an older skill with none of this, so the release's blocking migration note carries the floors in its own text.

## Guidance

The floor is only the pass or fail line. Every message tells the user to update to the latest release, and every route reaches one: where a package manager stays behind, as apt does on Debian stable, the route is another source. No message pins a version number.

## At runtime

A machine still below the git floor keeps working. Light audit review needs `git merge-tree --merge-base`, so the router sends every review full with the reason `git-too-old` (`.gaia/scripts/audit-light-route.sh`).
