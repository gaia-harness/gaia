---
paths:
  - '.claude/hooks/**'
  - '.gaia/scripts/**'
---

# File Placement

## `.claude/hooks/**`

**Add a new hook at the root of `.claude/hooks/`. Do not create a subdirectory.**

## Register the hook

Two obligations, each with its check in your own tree, so you can verify either one locally.

### No bare `.gaia/local` or `.notebook` literal

**A hook reaches `.gaia/local` or `.notebook` only by joining a root from `main-root-lib.sh`** (or a caller-supplied root, in a lib under `.claude/hooks/lib/`). A bare literal resolves against whatever tree the hook runs in, so from a linked worktree the write lands in the wrong tree with no error.

```bash
bash .gaia/scripts/check-hook-scope-manifest.sh
```

It walks the whole directory, so a new hook is checked the moment it exists.

### A cwd-independent command, when you register it in `.claude/settings.json`

**The command has to name the script by a path that resolves wherever the shell happens to be.** `/bin/sh` runs the command string against a working directory that persists for the whole session, so a bare relative registration becomes unfindable after a single `cd`. The script then exits 127, and 127 neither blocks nor is reported, so the guard fails open in silence and the hook you just wrote protects nothing.

```bash
bash .gaia/scripts/check-hook-command-rooting.sh .
```

Copy the form from a registration already in the file rather than inventing one; the check reads every registered command, so it tells you either way.

## `.gaia/scripts/**`: do not add files here

`.gaia/` is GAIA's own machinery; put project scripts outside it.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: in this repo `.gaia/scripts/` is GAIA's own source tree, and adding a script there is ordinary work; the line above is for adopters.
<!-- gaia:maintainer-only:end -->

<!-- gaia:maintainer-only:start -->
## Maintainer: the rest of the obligations and the other trees

**A new file under `.claude/hooks/lib/**` or `.claude/rules/**` needs a tier, and a registered hook owes a jq-availability arm.** `.claude/rules/maintainers/hook-registration.md` owns both and names the checks.
<!-- gaia:maintainer-only:end -->
