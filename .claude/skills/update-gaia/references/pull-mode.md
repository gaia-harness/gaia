# Pull mode

SKILL.md reads this file at its pull check. Pull mode brings a main checkout that lags origin's GAIA version up to it, without a full update: it fast-forwards the default branch, installs the lockfile when it changed, applies the machine-scope setup the pulled release lists, and offers the residue sweep. It never stashes, never forces and never switches branches, and it never runs from a linked worktree. It never reads `.gaia/update-decisions.json`, so a pull can repair a decision log that origin already fixed. It does not absorb Step 12: the updater's own main checkout is pulled by the work-lifecycle cleanup after the merge.

## Inputs

- **Caller**: `update-gaia`. A later caller is added as another value here.
- **Main checkout path**: `<main checkout path>`, carried as a literal in every command below.

Every command is one plain command with each value typed as a literal.

## Step 1: Check

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-pull.sh check --tree <main checkout path>
```

`PULL_READY <default branch>` continues. Exit 1 prints `PULL_REFUSED <code>`, a `Reason:` line and a `Next step:` line: relay all three and stop, changing nothing.

## Step 2: Pull

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-pull.sh pull --tree <main checkout path>
```

It prints `PULLED <old version> <new version>` and `LOCKFILE_CHANGED yes` or `no`. Persist the new version as `<new version>`. `PULL_REFUSED` (a diverged branch, with nothing merged) or `PULL_FAILED`: relay its lines and stop.

## Step 3: Install when the lockfile changed

Only on `LOCKFILE_CHANGED yes`:

```bash
pnpm -C <main checkout path> install --frozen-lockfile
```

A failure is reported with its next step (read the install output, fix the manifest, run the command again) and does not undo the pull.

## Step 4: Machine-scope setup drift

With the working directory at the main checkout, so the call uses the pulled `.gaia/cli/gaia`:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-drift.sh --features <main checkout path>/.gaia/setup-features.json --scope machine
```

Handle `APPLY`, `ASK`, `SETUP` and `DRIFT_FAILED` exactly as SKILL.md Step 9c does, reading each feature's reference from the main checkout. The records land in `.gaia/local/setup-state.json`. Project-scope features are not touched here; the full update carries them.

## Step 5: Offer the residue sweep

Offer it as SKILL.md Step 12's mode-3 block does:

```bash
bash <main checkout path>/.gaia/scripts/state-registry-lib.sh residue-sweep
```

Show its output. When its Residue section lists paths, ask once with `AskUserQuestion` (question `Delete the residue paths listed above?`, header `Residue`, options `Delete them` and `Keep them`), and on `Delete them` run the same command with `--apply`. Unknown paths are listed, never deleted. A non-zero exit names its cause on stderr: relay it and continue.

## Step 6: Refresh the update-check cache

```bash
bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode pull --version <new version>
```

Then read the cache file back and confirm `gaiaCurrent` is `<new version>`. `SKIPPED no cache` means there was nothing to refresh; a non-zero exit is reported and never undoes the pull.

## Step 7: Offer the full update

When the cache's `gaiaLatest` is above `<new version>`, ask with `AskUserQuestion`: "Continue to the full update to <tag> (Recommended)" or "Stop here". On continue, invoke `/update-gaia` again through the Skill tool so the update runs from the pulled copy of the skill. Otherwise report the pull and finish.
