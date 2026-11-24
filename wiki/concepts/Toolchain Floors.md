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

The floor is only the pass or fail line. The node row also refuses the 25 line, which `engines.node` (`^24.15.0 || >=26.0.0`) excludes. Each `GUIDE` line says why GAIA needs the tool. For git, jq and pnpm it says to update to the latest release, and every route reaches one: where a package manager stays behind, as apt does on Debian stable, the route is another source. For node, the `GUIDE` line names and the `ROUTE` installs the floor's Node major as read from `.gaia/toolchain-floors.tsv`, never the version `.nvmrc` or `.node-version` pins, since during an update those pins hold the old release's Node until the update merges. Both make that Node the default and reinstall pnpm under it, and the `ROUTE` writes no tracked file. With no version manager the `GUIDE` commands can run through, there is no `ROUTE`, and the `GUIDE` line says to install one first or get that Node another way. A shell that switches Node per folder (fnm `--use-on-cd`, nvm auto-use, asdf or mise reading `.nvmrc` or `.node-version`) can reselect the old pin in the project root, so the `GUIDE` line tells that user to select the new Node in the project shell before starting Claude Code. lsof and ss need only be present, so their `GUIDE` lines say how to get them. `guide()` in `.gaia/scripts/toolchain-check.sh` holds the exact text. Apart from node's floor major, no `GUIDE` line names a version number.

## At runtime

A machine below the git floor is not supported. Light audit review needs `git merge-tree --merge-base`, so on a machine that skipped the check the router still sends every review full with the reason `git-too-old` (`.gaia/scripts/audit-light-route.sh`) rather than failing.
