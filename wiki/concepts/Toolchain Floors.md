---
type: concept
title: Toolchain Floors
status: active
created: 2026-10-31
updated: 2026-11-20
tags: [concept, setup, update]
---

# Toolchain Floors

GAIA runs on tools it cannot always install itself. `.gaia/toolchain-floors.tsv` holds the lowest version of each that works, as data, and `.gaia/scripts/toolchain-check.sh` is the only reader. The file is tab-separated because jq is one of the tools checked, and the script is bash builtins for the same reason. No command states a floor in its own prose.

## Who checks, and when

- **`/setup-gaia`** checks at the start of Phase 0 on every run, and halts on any miss the walk-through below does not fix, with no fallback for an older tool. Clones run setup, and `/gaia-init` flows into it, so init holds no copy.
- **`/gaia-init`** needs pnpm for its own install, so it runs the one pnpm section it shares with setup, in `.claude/skills/gaia/references/toolchain.md`.
- **`/update-gaia`** checks before its Proceed question, because an existing project never reruns setup. It runs the verified target bundle's copy of the script, so the incoming release sets the floor, not the older skill doing the update. A miss the walk-through does not fix stops the update, as it halts setup.
- **The first crossing** runs an older skill with none of this, so the release's blocking migration note carries the floors and the walk-through in its own text.

## Guidance

Whatever Claude can install, it installs after confirming with the user. What only the user can do, Claude hands over as a `! <command>` to type in the prompt, or says plainly when it needs a fresh terminal. That holds for any GAIA flow that needs a tool installed. For the floors, `toolchain-check.sh` prints a `ROUTE` line for each short tool that has an exact command, and its class says which of the three applies, and `.claude/skills/gaia/references/toolchain.md` (`## Below a floor`) walks the user through it and checks again in the same run.

The floor is only the pass or fail line. Each message says why GAIA needs the tool. For git, jq and pnpm it says to update to the latest release, and every route reaches one: where a package manager stays behind, as apt does on Debian stable, the route is another source. For node, the message and the route install the floor's Node major as read from `.gaia/toolchain-floors.tsv`, never the version `.nvmrc` or `.node-version` pins, since during an update those pins hold the old release's Node until the update merges. They make that Node the default and reinstall pnpm under it, and the route writes no tracked file. A shell that switches Node per folder (fnm `--use-on-cd`, nvm auto-use, asdf or mise reading `.nvmrc` or `.node-version`) can reselect the old pin in the project root, so the message tells that user to select the new Node in the project shell before starting Claude Code. lsof and ss need only be present, so their messages say how to get them; `.gaia/scripts/toolchain-check.sh` holds the exact text. Apart from node's floor major, no message names a version number.

## At runtime

A machine below the git floor is not supported. Light audit review needs `git merge-tree --merge-base`, so on a machine that skipped the check the router still sends every review full with the reason `git-too-old` (`.gaia/scripts/audit-light-route.sh`) rather than failing.
