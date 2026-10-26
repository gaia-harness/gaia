# Local bundles and recorded builds

SKILL.md reads this file at Step 1 when the invocation carries `--local <tarball>` or the checkout the run starts in holds `.gaia/VERSION-dev`, and then applies the section below at each step that names it. It covers two situations:

- **A local run**: `/update-gaia --local <tarball>`. The source is a bundle the maintainer built from an unreleased, committed GAIA checkout. No target release is looked up, downloaded or checked against a release checksum. The run records the bundle's plain release version in `.gaia/VERSION` and its build id (`dev.<sha>`) in `.gaia/VERSION-dev`, last.
- **A release run after a local sync**: no `--local`, and the project holds a committed `.gaia/VERSION-dev`. The run merges against the recorded build when this machine still caches it (else against the plain release, with a warning), does not stop as up to date when the latest release equals the project's version, and removes `.gaia/VERSION-dev` last.

This file never replaces a step's merge logic. Every merge runs through `conflict-flow.md` and the snapshot of `merge-execution.md` exactly as a release update does; only the source, the baseline tag, the questions' wording and the record step differ. Every command block below is one plain command with each value typed as a literal, as in SKILL.md.

**Values.** A local run carries `LOCAL_TAG` (`v<core>-dev.<sha>`), `LOCAL_CORE`, `LOCAL_BUILD` (`dev.<sha>`), `LOCAL_COMMIT` (the sha) and `LATEST_DIR` from the source step, and sets `LATEST_TAG` = `<LOCAL_TAG>` and `LATEST` = `<LOCAL_CORE>`, so every SKILL.md step that names `<LATEST_TAG>` or `<LATEST>` takes the local values. Every run that reads this file carries `BASELINE_TAG` from the baseline step; any other run's `BASELINE_TAG` is `v<BASELINE>`. A **dev tag** is a tag of the form `v<core>-dev.<sha>`.

## Trust label at invocation

On a local run, before any other command after Step 1, print:

```text
Source: a local, unverified bundle at <tarball path>. Its code runs from here on (the migration-note selector and the merge's CLI calls come from the bundle), and nothing about it is checked against a published release.
```

The label stays true for the whole run, and the Proceed question and the review summary repeat it.

## The source step

On a local run this replaces Step 2. Resolve the tarball path the user gave as one literal, then run in the checkout the run starts in (the main checkout in mode 2, the worktree in mode 1). In mode 2:

```bash
bash .gaia/scripts/update-gaia-local.sh source --tarball <tarball path>
```

In mode 1 (running in place on an `update/` branch) the call carries `--resume`:

```bash
bash .gaia/scripts/update-gaia-local.sh source --tarball <tarball path> --resume
```

Mode 1 is the only path that resumes an applied or committed sync (Step 3 sends `APPLIED_UNCOMMITTED` and `COMMITTED` to a re-run inside the worktree), and once the record step ran, the worktree's `.gaia/VERSION-dev` already holds the target build: without `--resume` the call would stop at `ALREADY_SYNCED` instead of reaching the quality gate, the review point or Step 11. Mode 2 never passes it, because the main checkout keeps the previous record until the update PR merges.

The step runs before Step 3, the pull check, the decision log check, the claim check and Step 3b, and only the update cache can change. Its outcomes:

- **The six lines** (`LOCAL_SOURCE unverified`, `LOCAL_TAG=`, `LOCAL_CORE=`, `LOCAL_BUILD=`, `LOCAL_COMMIT=`, `LATEST_DIR=`): persist each value as printed, and set `LATEST_TAG` and `LATEST` as **Values** says.
- **`ALREADY_SYNCED <build id>`**: tell the user the project already runs this build, and stop. Nothing was branched, pruned or merged, and no worktree was created.
- **`LOCAL_REFUSED <reason> ...`**: relay the line and its `Next step:` line, and stop the same way. `older-than-project <bundle version> <project version>` names both versions: a local bundle never downgrades a project.

## The baseline

On every run that reads this file, right after the source step (local run) or Step 2 (release run), run in the checkout the run starts in:

```bash
bash .gaia/scripts/update-gaia-local.sh baseline
```

Persist `BASELINE_TAG=<tag>` as `BASELINE_TAG`, then branch on the second line:

- **None**: no build is recorded; the baseline is the plain release `v<BASELINE>`.
- **`RECORDED_BUILD <build id>`**: the merge baseline is the recorded build, `<BASELINE_TAG>`, from this machine's update cache.
- **`BASELINE_FALLBACK <build id>`**: the recorded build is not cached on this machine. The run falls back to the plain release `v<BASELINE>`, and the Proceed question says so, naming the uncached build by its id. The id carries no core, because an uncached record's core is unknown; a stale uncached record looks the same and falls back the same way.
- **`RECORDED_BUILD_STALE <build id> <core>`**: a blocking migration note moved `.gaia/VERSION` after the recorded build. The record is ignored, the plain release is the baseline, and this run's record step replaces or removes the stale file.
- **`BUILD_ID_INVALID .gaia/VERSION-dev`** or **`VERSION_INVALID .gaia/VERSION`** (exit 1): relay the line and its `Next step:` line, and stop. Nothing was branched, pruned or merged.

A deferred item whose baseline tag is a dev tag that this machine no longer caches surfaces as `CACHE_MISSING` at Step 3c and is resolved by hand, exactly like an unreachable deferred release (Step 3c's extra-tag bullet).

## Step 3 on a local run

Never print "up to date" on version alone: the source step owns the already-synced exit, and it already refused a lower version.

**Mode 2.** First detect an uncommitted sync, comparing both files:

```bash
git diff --quiet HEAD -- .gaia/VERSION .gaia/VERSION-dev
```

A non-zero exit means an earlier in-place run wrote them and never committed: tell the user, as Step 3's uncommitted-bump bullet does, to review `git diff` and commit it (or discard both files with `git checkout -- .gaia/VERSION .gaia/VERSION-dev` and re-run), and exit. Otherwise classify with the build marker:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LOCAL_TAG> --latest <LOCAL_CORE> --build <LOCAL_BUILD>
```

Branch on its line exactly as `### Step 3, main checkout: classify the update branch` does.

**Mode 1.** The branch prefix is `update/<LOCAL_TAG>-`; any other branch stops as Step 3's mode 1 check stops. Then:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LOCAL_TAG> --latest <LOCAL_CORE> --branch <current branch> --build <LOCAL_BUILD>
```

Branch on its line exactly as `### Step 3, worktree run in place` does.

**A local sync's branch on a release run.** In mode 1 without `--local`, a branch that starts `update/v` and carries `-dev.` in its tag is a local sync's branch: stop, and tell the user to re-run `/update-gaia --local <tarball>` with the tarball the branch was started from. In particular, a release run's mode 1 prefix check (`update/<LATEST_TAG>-`) never accepts a branch that continues `update/<LATEST_TAG>-dev.`: it stops exactly as it does for a branch to another release. The classifier's mode 2 branch lookup skips such branches on a release tag too.

## Step 3 on a release run after a local sync

When `LATEST` equals `BASELINE` and `.gaia/VERSION-dev` exists, do not stop as up to date: the release still has to merge against the recorded build and remove the record. The uncommitted check covers both files, with the same command and handling as `## Step 3 on a local run`. Then classify exactly as Step 3 does (`classify --tag <LATEST_TAG> --latest <LATEST>`, with `--branch <current branch>` in mode 1, and no `--build`: the release predicate requires the record to be gone). When `LATEST` is above `BASELINE`, Step 3 runs unchanged. When `LATEST` is below `BASELINE`, Step 3's never-downgrade exit stands.

## Pull check on a local run

The same check, under the same conditions. When pull mode runs, its continue offer re-invokes `/update-gaia --local <tarball path>` with the tarball this run was given (`pull-mode.md` Step 7), whatever the cache's `gaiaLatest` says.

## Claim on a local run

A local run claims exactly like a release run, under `<LOCAL_TAG>`: the claim tag, the `update/<LOCAL_TAG>-` branch prefix and the PR title all use it, and the claim script's tag check accepts a dev tag. A teammate's claim stops a local run as it stops a release run. The own-claim classify in `claim-flow.md` carries `--build <LOCAL_BUILD>` on a local run, as Step 3 and Step 11 do: a finished local claim always carries `.gaia/VERSION-dev`, so without the marker it never reads `COMMITTED` and would be resumed instead of reported.

## Step 3c with a local build

A local build's bundle resolves from this machine's update cache only, never from a release download. Its checksum was computed locally by the source step (or the run that cached the recorded build), so it guards only against cache corruption, never authenticity; every release bundle is still verified against its release `.sha256` asset. On a local run whose `BASELINE_TAG` is a dev tag:

```bash
bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --baseline-tag <BASELINE_TAG> --latest-tag <LOCAL_TAG>
```

On a local run whose baseline is a release:

```bash
bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --latest-tag <LOCAL_TAG>
```

On a release run whose `BASELINE_TAG` is a dev tag:

```bash
bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --baseline-tag <BASELINE_TAG> --latest-tag <LATEST_TAG>
```

Each adds one `--extra-tag <tag>` per extra baseline tag, as Step 3c does. Persist `BASELINE_DIR`, `LATEST_DIR` and each `EXTRA_DIR` line as printed. Beyond Step 3c's lines:

- `VERIFIED_LOCAL <tag>`: a bundle checked only against its locally computed checksum.
- `CACHE_MISSING <LOCAL_TAG>`: the cache lost the bundle since the source step. Stop and tell the user to re-run with the tarball.
- `CACHE_MISSING <BASELINE_TAG>`, or `VERIFY_FAILED` for it: the recorded build is gone or damaged (a failed check removes its directory). Stop; a re-run falls back to the plain release and says so.
- `CACHE_MISSING` for an extra baseline tag: resolve those deferred paths by hand, as Step 3c's extra-tag bullet says.
- `VERIFY_FAILED <LOCAL_TAG>`: the cached copy is damaged and was removed. Stop and re-run with the tarball.

Each stop leaves nothing branched, pruned or merged, and no worktree.

## Step 3d on a local run

Select the notes with Step 3d's call and `--latest <LOCAL_CORE>`: only notes at or below the bundle's release version run, exactly as a release selects them. Handle its lines as Step 3d does. Then list the notes the bundle carries above that version:

```bash
bash .gaia/scripts/update-gaia-local.sh notes-not-run --latest-dir <LATEST_DIR> --core <LOCAL_CORE>
```

Persist every `NOT_RUN <version> <mode> <path>` line. None of them runs on this sync, a blocking one included; the real release runs each one once. `NOTES_FAILED` stops as Step 3d's does.

## Step 4 on a local run

Skip Step 4's changelog call: the run has no release CHANGELOG range, and the execution agent reports the range as unavailable. Print the build commit instead:

```text
Build commit: <LOCAL_COMMIT>
```

Name each `AFTER_MERGE` note as Step 4 does, and each `NOT_RUN` note as `<version> (<mode>) <path>: not run, follow it by hand to test it`. Then use `AskUserQuestion`:

- **Question**: "Sync GAIA v<BASELINE> to the local, unverified bundle <LOCAL_TAG>?"
- **Options**: `Proceed` (Recommended) / `Abort`.

The question's text adds one line for the baseline:

- On `RECORDED_BUILD`: the baseline is the recorded local build `<BASELINE_TAG>`.
- On `BASELINE_FALLBACK`: the recorded build `<build id>` is not cached on this machine, so the merge uses the plain release `v<BASELINE>` as its baseline and may raise more questions.
- On `RECORDED_BUILD_STALE`: the stale record is ignored and the baseline is the plain release `v<BASELINE>`.

On `Abort`, exit cleanly: nothing changes outside the update cache.

## Step 4 on a release run after a local sync

Step 4 runs as written, and the Proceed question adds one line for the baseline. On `RECORDED_BUILD`: the baseline is the recorded local build `<BASELINE_TAG>`, whose bundle was checked only against a locally computed checksum, not a release checksum. On `BASELINE_FALLBACK`: the recorded build `<build id>` is not cached on this machine, so the merge uses the plain release `v<BASELINE>` and may raise more questions. Either way, the line says the update removes `.gaia/VERSION-dev`.

## Step 4 worktree check with a recorded build

Step 4 creates or re-enters the update worktree as written, through `.claude/skills/gaia/references/isolation.md`, on a local run too: the branch is minted from `<LOCAL_TAG>`. After Step 4's baseline check in a fresh mode 2 worktree, when the starting checkout held `.gaia/VERSION-dev`, read the worktree's copy:

```bash
cat .gaia/VERSION-dev
```

When it does not print the build id the baseline step read (the main checkout's record lags or leads `origin`), stop as Step 4's baseline check stops: print what each holds, the worktree notice, and the next step (pull or push the main checkout's default branch, then re-run).

## Step 4b with a local build

Whenever `BASELINE_TAG` is a dev tag, on either kind of run, the prune keeps it, so the recorded build survives for this run and for a deferred item. Add `--resume` and the `--keep-tag <tag>` flags as Step 4b says:

```bash
bash .gaia/scripts/update-gaia-preflight.sh prune --baseline <BASELINE> --baseline-tag <BASELINE_TAG> --latest-tag <LATEST_TAG>
```

## Conflict flow with a local build

`conflict-flow.md` runs unchanged, and its dispatch passes `BASELINE_TAG`. A non-deferred entry's `baselineTag` is `BASELINE_TAG`, so a deferral made against a recorded build records that build's dev tag, and the next run merges that item against it. A deferral's `--tag <LATEST_TAG>` is the local tag on a local run, its `--baseline-tag` is the entry's own `baselineTag`, and reconcile's `--latest-tag <LATEST_TAG>` writes the local tag. The target build is never recorded as an unmerged file's baseline: the next merge would read GAIA's changes as the adopter's reverts.

## Step 9d on a local run

These replace Step 9d's four calls, in this order, as separate calls in the acting tree. A local sync sends no update ping and writes no blend record: it never feeds adoption analytics or the `/gaia-fitness` nudge. The manifest copy, unchanged:

```bash
GAIA_MANIFEST_WRITE=release cp <LATEST_DIR>/.gaia/manifest.json .gaia/manifest.json
```

The plain release version:

```bash
echo <LOCAL_CORE> > .gaia/VERSION
```

The build id, last:

```bash
echo <LOCAL_BUILD> > .gaia/VERSION-dev
```

A failed manifest copy is the `MANIFEST_COPY_FAILED` stop, as in Step 9d. `.gaia/VERSION-dev` is the written-last marker: an interruption before its write leaves the earlier record (or none), so the next run classifies the branch as a resume and repeats the idempotent steps. Then bust the update-check cache as Step 9d does, with the local core:

```bash
bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode gaia --version <LOCAL_CORE>
```

Read it back as Step 9d says, and keep its addendum.

## Step 9d on a release run after a local sync

Step 9d's four calls run unchanged, ending with `echo <LATEST> > .gaia/VERSION`. Then, as the last act, remove the record:

```bash
rm .gaia/VERSION-dev
```

It runs after the version write so an interruption before it still finds the record, and a resume still merges against the recorded build. A stale record and an uncached one are removed the same way. Then the bust runs as Step 9d says.

## Review point with a local build

On a local run the summary opens with the source: `local, unverified bundle <LOCAL_TAG>`, build commit `<LOCAL_COMMIT>`. It names the baseline (the recorded build `<BASELINE_TAG>`, or the fallback to `v<BASELINE>` with the uncached build's id) and lists every `NOT_RUN` note as `<version> (<mode>) <path>: not run, follow it by hand to test it`. The commit message is Step 4's pattern with the local tag, `chore(gaia): update to <LOCAL_TAG>`.

On a release run after a local sync, the summary names the baseline the same way and says `.gaia/VERSION-dev` was removed.

## Step 11 with a local build

Check 2 classifies the committed branch instead of reading `.gaia/VERSION` alone, since a same-version sync leaves that file unchanged. On a local run:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-branch-state.sh classify --tag <LOCAL_TAG> --latest <LOCAL_CORE> --branch <branch> --build <LOCAL_BUILD>
```

On a release run after a local sync:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST> --branch <branch>
```

Either must print `COMMITTED`; otherwise the update commit is not on `<branch>`, so say so and stop. A release run that started with no record keeps Step 11's `git show` check.

On a local run the PR title is `chore(gaia): update to <LOCAL_TAG>`, and the body's first line, for a new PR and for the claim PR's body rewrite alike, is:

```text
Syncs a local, unverified GAIA build <LOCAL_TAG> (commit <LOCAL_COMMIT>) into the project.
```

When no PR is open and there is no claim, Step 11's create call becomes:

```bash
gh pr create --draft --base <default branch> --head <branch> --title "chore(gaia): update to <LOCAL_TAG>" --body "Syncs a local, unverified GAIA build <LOCAL_TAG> (commit <LOCAL_COMMIT>) into the project. Per-file outcomes are in the update summary above."
```

## Rollback

A broken local sync is undone with `git revert` of the update PR's merge commit, merged like any other change, then `/update-gaia` again (with or without `--local`). The revert restores both `.gaia/VERSION` and `.gaia/VERSION-dev`, so the next run merges against the build the project held before.

## Run ends

Every stop this file adds appends the cost record like SKILL.md's other run ends: already synced, a source refusal, an invalid record or version at the baseline step, an uncommitted sync, a cache miss or failed check at Step 3c, a mode 1 branch whose sync needs `--local`, and a failed worktree record check.
