---
name: update-gaia
description: Pulls the latest GAIA release into this project without clobbering customizations, with a three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `🚀 /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
---

Contents: Pre-flight: Worktree check; Pre-flight: Branch check (run modes); Step 1: Read baseline version; Step 2: Resolve latest release; Step 3: Compare versions (default branch, worktree run in place, in place); Step 3b: Refuse a 1.x baseline; Step 3c: Download and verify the bundles; Step 3d: Select migration notes; Step 4: Show the release notes and confirm (on Proceed: the update worktree, the worktree notice, the stop rule); Step 4b: Prune prior-run artifacts; Model selection; Step 9b: Follow the after-merge notes; Step 9c: Carry new setup features; Step 9d: Record the update; Step 10: Next steps for the user; Step 11 (orchestrator, after the user commits); Step 12: Offer the residue sweep.

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`**: GAIA controls fully.
- **`shared`**: GAIA seeds, you customize.
- **`wiki-owned`**: GAIA-seeded wiki pages.
- **adopter-owned (implicit)**: anything not in the manifest, plus sentinels like `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. The merge walk never touches them; Step 9d rewrites `.gaia/manifest.json` and `.gaia/VERSION` once the merge is done.

The first three take the same Step 7 rows. The class changes only two of them: which bucket a clean overwrite reports under (`owned` → `overwrite[]`, the other two → `merge[]`), and what happens when the release newly owns a path the adopter already has (`owned` backs up and overwrites, the other two fall through to the ordinary rows). Step 7 is authoritative.

Backups land in `.gaia-backup/<timestamp>/` and conflict patches in `.gaia-merge/`, both in the acting tree: the update worktree on a default-branch run.

**Who runs what.** This file runs the pre-flight through Step 4b, spawns the execution agent for Steps 6 to 9 (`references/merge-execution.md`), runs Steps 9b to 10 itself once the agent returns, and then waits for the user. Once the user confirms the Step 10 commit, run Steps 11 and 12 below. On a default-branch run everything from Step 4b on runs inside the update worktree, so the main checkout's branch, files and `node_modules` stay as the user left them. Every orchestrator step lives in this one file, long as it is, because the merge walk can overwrite this skill's own files partway through the run and the orchestrator keeps following the copy it already read. The draft PR's merge and cleanup run later, through the PR Merge Workflow.

Every command block below is one plain command with each value typed as a literal (written `<NAME>`), or a call to a tracked script by its literal path: inside a worktree session the runtime refuses a captured command substitution, a shell variable in a path, and a heredoc. The one exception is Step 3's in-place block, which only ever runs in the main checkout.

## Pre-flight: Worktree check

This wrapper changes `.gaia/VERSION` and opens a PR, which belong to the main checkout or to this command's own update worktree, never to a SPEC, debt or feature worktree or to `/update-deps`'s `deps/` worktree. Invoked from any other linked worktree, it refuses hard with a message that surfaces the cached version state from main, so the user knows whether a GAIA update is even pending. The `"update/"` argument admits a worktree on an `update/` branch, so a re-run inside this command's own update worktree continues there.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
. .gaia/scripts/update-state-line-lib.sh
gaia_refuse_if_worktree "/update-gaia" gaia_update_gaia_state_line "update/" || exit 1
```

The state-line function lives in `update-state-line-lib.sh` rather than inline here because the runtime inspects a command's text: an inline definition holding captured substitutions would get this whole block refused on a re-run inside the own update worktree, before the guard could admit it.

If the detection does not fire, fall through to `## Pre-flight: Branch check`.

## Pre-flight: Branch check

```bash
git branch --show-current
```

Decide the run mode, in this order:

1. **Worktree run in place.** The branch starts `update/` and `bash .gaia/scripts/main-root-lib.sh --is-worktree` exits 0: a re-run inside this command's own update worktree. Read `<worktree path>` with `git rev-parse --show-toplevel` and `<main checkout path>` with `bash .gaia/scripts/main-root-lib.sh`, each carried as a literal. No worktree is created. Set `WORKTREE_RUN=true`, `CREATED_WORKTREE=false`, `SHOULD_CREATE_WORKTREE=false`. Wait for provisioning now with `bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>`, handled as in Step 4's wait except that `INSTALL_FAILED` is reported and the run continues.
2. **Default branch.** On `main` or `master`: set `SHOULD_CREATE_WORKTREE=true` and read `<main checkout path>` once with `git rev-parse --show-toplevel`, but **do not create the worktree yet**: creation is deferred until after the Step 4 Proceed confirmation. Steps 1 to 4 can exit early (already up to date, a refused baseline, a failed Step 3c verification, a Step 3d stop, or the user aborts); creating it before then leaves an orphan worktree and branch when there was nothing to update.
3. **In place.** Any other branch: set `SHOULD_CREATE_WORKTREE=false` and work on the current branch, creating no branch and no worktree. `<checkout path>` is `git rev-parse --show-toplevel`, which is also `<main checkout path>` for this mode.

The **acting tree** is `<worktree path>` in modes 1 and 2 and `<checkout path>` in mode 3; every later step that names a path names that literal. A **worktree run** is mode 1, or mode 2 once Step 4 has created or entered the worktree.

## Step 1: Read baseline version

```bash
cat .gaia/VERSION 2>/dev/null || echo MISSING
```

In mode 1 this reads the worktree's own file. If the file is missing, stop and tell the user:

> "No `.gaia/VERSION` found, this project was not scaffolded from GAIA, or the marker was deleted. Run `/gaia-init` on a fresh `create-gaia` scaffold first."

Persist the trimmed version as `BASELINE` (e.g., `2.0.0`).

## Step 2: Resolve latest release

```bash
gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName'
```

Persist as `LATEST_TAG` (e.g., `v2.0.1`) and `LATEST` (strip leading `v`).

If `gh` is unavailable, fall back to:

```bash
curl -fsSL https://api.github.com/repos/gaia-react/gaia/releases/latest | jq -r .tag_name
```

If both fail, stop and ask the user to supply the target version explicitly.

## Step 3: Compare versions

In mode 1, run `### Step 3, worktree run in place` first: the worktree's own bump makes an applied update read as current.

- If `LATEST == BASELINE`:
  - **First, detect an uncommitted bump.** If `.gaia/VERSION` differs from the last commit (`git diff --quiet HEAD -- .gaia/VERSION` exits non-zero, this catches a staged or unstaged bump), a previous in-place `/update-gaia` already bumped the version but the update was never committed. Do **not** print "up to date", the bumped VERSION makes every re-run look current, so saying it dead-ends the user. Instead read the committed baseline (`git show HEAD:.gaia/VERSION`) for context and tell the user: the update to `v<LATEST>` is already applied to the working tree but not committed. Review `git diff` and commit it (Step 10 guidance), or run `git checkout -- .gaia/VERSION` to discard the bump and re-run `/update-gaia` to start over. Exit.
  - Otherwise print "You are up to date on GAIA v<BASELINE>." and exit.
- If `semver(LATEST) < semver(BASELINE)` → print a warning that the installed version is ahead of the latest release and exit. Never downgrade.
- If `LATEST` is above `BASELINE`, look for an earlier run's update branch by the mode's subsection below. The branch is found by its `update/<LATEST_TAG>-` prefix, never by minting its name again: a minted name carries the current minute, so it never equals the earlier run's.

### Step 3, default branch: classify the update branch

Mode 2. From the main checkout:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST>
```

It classifies the most recently committed `update/<LATEST_TAG>-*` branch by the branch's own state and never reads the main checkout's `.gaia/VERSION`. Branch on its one line:

- **`NONE`**: a fresh run. Continue to Step 3b.
- **`RESUME_IN_WORKTREE <branch> <path>`**: tell the user a prior run to `<LATEST_TAG>` stopped after its merge and before its `.gaia/VERSION` write, and that this run resumes inside that worktree, keeps its `.gaia-backup/`, and repeats the merge, the after-merge notes and the setup drift through to the version write. Persist both values. Continue to Step 3b.
- **`RESUME_ADD_WORKTREE <branch>`**: the same message, except that the run resumes in a worktree it adds for the branch at Step 4. Persist the branch. Continue to Step 3b.
- **`APPLIED_UNCOMMITTED <branch> <path>`**: report the update as applied but not committed, with the worktree path and the branch. The next step is the commit: review with `git -C <path> diff`, commit in that worktree, then re-run `/update-gaia` inside it to open the PR. Exit. Never resume the merge or write the version again.
- **`COMMITTED <branch> <path or ->`**: read the PR state with `gh pr list --head <branch> --state all --json number,state,url`. Report the branch, the PR's state (or that none exists), the worktree path when one holds it, and the removal commands from the worktree notice in Step 4 (only `git branch -D <branch>` when the path is `-`). Exit, creating no worktree. When the PR is `MERGED`, the next step is pulling the main checkout's default branch, not removal.

### Step 3, worktree run in place

Mode 1. The current branch must start `update/<LATEST_TAG>-`; otherwise stop: this worktree updates to an older release, so print the worktree notice (Step 4) and tell the user to remove it with those commands and re-run `/update-gaia` from the main checkout. Then, from the worktree:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST> --branch <current branch>
```

- **`RESUME_IN_WORKTREE`**: continue to Step 3b in place, as a resumed run.
- **`APPLIED_UNCOMMITTED`**: the merge and the version write are done. Go straight to Step 10's hand-off.
- **`COMMITTED`**: go straight to Step 11, which opens the draft PR or reuses the open one.

### Step 3, in place: an interrupted run's update branch

Mode 3 only, in the main checkout:

```bash
RESUME_UPDATE=false
UPDATE_BRANCH=''
current_branch="$(git branch --show-current)"
case "$current_branch" in
  "update/${LATEST_TAG}-"*) UPDATE_BRANCH="$current_branch" ;;
  *) UPDATE_BRANCH="$(git for-each-ref --count=1 --sort=-committerdate --format='%(refname:short)' "refs/heads/update/${LATEST_TAG}-*")" ;;
esac
if [ -n "$UPDATE_BRANCH" ]; then
  RESUME_UPDATE=true
  echo "RESUME $UPDATE_BRANCH"
fi
echo "RESUME_UPDATE=$RESUME_UPDATE"
```

The current branch wins when it carries the prefix; otherwise the most recently committed matching local branch does. On `RESUME <branch>`, tell the user this is a merged-but-unbumped tree and that this run keeps `.gaia-backup` and repeats the merge, the after-merge notes and the setup drift through to the version write. Persist `RESUME_UPDATE`. The run stays on its current branch either way. Continue to Step 3b.

## Step 3b: Refuse a 1.x baseline

GAIA 2.0.0 moved the React app into `frontend/`, and the 2.x release manifest is keyed on those paths. A three-way merge from a 1.x baseline would read every baseline app path as an upstream deletion and offer to delete the adopter's app, so a 1.x project migrates through the 2.0.0 migration note bundled in the checksum-verified v2.0.0 release, never through this command. Run this before any download and before the Step 4 prompt:

```bash
bash .gaia/scripts/update-gaia-preflight.sh refuse-1x --baseline <BASELINE>
```

On `REFUSED`, stop and relay the message: no worktree, no branch, no prune, no download. For a 1.x baseline, offer to run the printed command, and only after the user says yes run it and follow the note it extracts, in this session.

## Step 3c: Download and verify the bundles

Every bundle this run reads is verified against its release's `.sha256` asset in this run, before the Proceed question, and every tree it reads is extracted again from that verified tarball. Each tag's cache directory, `.gaia/local/cache/shared/update-gaia/<tag>/` (gitignored, shared across worktrees), holds the tarball, its checksum and `tree/`; the target's directory also holds the `changelog-range.md` Step 4 saves.

```bash
bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --latest-tag <LATEST_TAG>
```

It prints `VERIFIED <tag>` per bundle, then `BASELINE_DIR=...` and `LATEST_DIR=...`. Persist `BASELINE_DIR` and `LATEST_DIR` as printed. Only the update cache changes before the Proceed question.

The asset is `gaia-bundle-<tag>.tar.gz` from 2.0.0 on; releases before 2.0.0 published `gaia-<tag>.tar.gz` and are out of reach on purpose (Step 3b refuses a 1.x baseline, and the different name is what makes a 1.6.1 `/update-gaia` fail at its fetch step, before it writes anything, instead of misreading the moved layout as deletions).

Each failure line names the tag and removes that tag's cache directory, so a re-run starts clean. On any of them, stop: nothing was branched, pruned or merged, and no worktree was created.

- `FETCH_FAILED <LATEST_TAG>` or `CHECKSUM_MISSING <LATEST_TAG>`: the latest release is unreachable (network, auth) or lacks an asset. Tell the user, then re-run once it is reachable.
- `FETCH_FAILED v<BASELINE>` or `CHECKSUM_MISSING v<BASELINE>`: the baseline bundle is unavailable (an older release, or one published without a checksum). The three-way merge cannot run without a baseline, so stop and explain that the adopter can cherry-pick changes by hand, comparing their project to the release.
- `VERIFY_FAILED <tag>`: the tarball does not match its release checksum. Never use it. Tell the user and re-run; a second mismatch on a fresh download is a damaged or tampered release, which the user reports upstream.

## Step 3d: Select migration notes

A release can ship migration notes, one per version, in its bundle. The call runs the verified target bundle's own selector, never the project's copy, so a mode or key a later release adds is judged by that release's selector:

```bash
bash .gaia/scripts/update-gaia-preflight.sh select-notes --latest-dir <LATEST_DIR> --baseline <BASELINE> --latest <LATEST>
```

It prints `AFTER_MERGE <version> <path>` for each after-merge note in version order up to the first blocking note, and `BLOCKING <version> <path>` for that first blocking note. A mode this skill does not know reads as blocking, so the note itself says how to follow it. After-merge notes above a blocking note are left for the next run. Each path is inside the verified bundle, `<LATEST_DIR>/.gaia/migrations/<version>.md`.

- **`NOTES_FAILED`**: stop and relay the lines. Nothing was branched, pruned or merged, and no worktree was created.
- **No `BLOCKING` line**: persist the `AFTER_MERGE` lines (possibly none) and continue to Step 4.
- **`BLOCKING <version> <path>`**: stop here, before the Proceed question. Tell the user the update crosses a blocking migration note, name its path inside the verified bundle, and list each `AFTER_MERGE` note as a note to follow after the blocking note's merge step and before its version write. Then ask with `AskUserQuestion` whether to follow the blocking note in this session. On yes, read the note from that path and follow it: it owns the hop to its own version, including its own merge and its `.gaia/VERSION` and manifest write at that version, and the user re-runs `/update-gaia` afterwards for any later notes and the setup drift. On no, stop: nothing was branched, pruned or merged, no worktree was created, `.gaia/VERSION` is unchanged, and only the verified update cache remains.

## Step 4: Show the release notes and confirm

Show the human the **full baseline-to-latest CHANGELOG range**, not just the single latest tag's GitHub body, an adopter several versions behind needs every intervening entry:

```bash
bash .gaia/scripts/update-gaia-preflight.sh changelog --baseline <BASELINE> --latest <LATEST> --latest-tag <LATEST_TAG>
```

It reads GAIA's own `CHANGELOG.md` at `<LATEST_TAG>` and prints every `## [x.y.z]` section strictly newer than `<BASELINE>` through `<LATEST>`, without the `[Unreleased]` block or the bottom link-reference list, or the single-tag GitHub release body when the fetch fails. It saves the range as `changelog-range.md` beside the target's `tree/` for Step 9's documented adopter actions, since the release bundle withholds `CHANGELOG.md`; a failed fetch removes the file, so Step 9 reports the range as unavailable rather than reading a stale one. Print the range to the user. When Step 3d printed `AFTER_MERGE` lines, name each `AFTER_MERGE` note (its version and its path) as a note this run follows after the merge. Then use `AskUserQuestion`:

- **Question**: "Update GAIA from v$BASELINE to $LATEST_TAG?"
- **Options**: `Proceed` / `Abort`.

On `Abort`, exit cleanly: nothing changes outside the verified update cache.

### Step 4, on Proceed: the update worktree

Only when `SHOULD_CREATE_WORKTREE=true` (mode 2). In modes 1 and 3 nothing is created or switched; go to Step 4b. The main checkout never switches branch.

**Fresh run (`NONE`).** Mint the name in the main checkout with `bash .gaia/scripts/branch-name-lib.sh name update <LATEST_TAG>` and carry it as `<branch-name>`. Then create the worktree:

`EnterWorktree({name: "<branch-name>"})`

Rename its branch per `.claude/skills/gaia/references/isolation.md` `## Worktree creation`: three plain commands, each value typed as a literal; a failed rename stops as that section says. Carry its `RESOLVED_ROOT` as `<worktree path>`. Set `CREATED_WORKTREE=true`.

**Resume, a worktree holds the branch (`RESUME_IN_WORKTREE`).** Re-enter that worktree per `isolation.md` `### Resume`; never check the branch out and never create another worktree. `<worktree path>` is the classified path. Set `CREATED_WORKTREE=false`.

**Resume, no worktree holds the branch (`RESUME_ADD_WORKTREE`).** From the main checkout:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh add-worktree --branch <branch>
```

It prints `ADDED <absolute path>`; carry that path as `<worktree path>` and enter it with `EnterWorktree({path: "<worktree path>"})`. Entering provisions such a tree, and its cleanup is the by-path arm (`.claude/skills/gaia/references/work-lifecycle.md` `### Worktree entered by path or in an earlier session`). The branch was left by an earlier in-place run, so when the main checkout holds a `.gaia-backup/`, tell the user that `<main checkout path>/.gaia-backup/` holds that run's backups and leave it in place. Set `CREATED_WORKTREE=false`.

**The worktree notice.** Right after creation and rename, or re-entry, print:

```text
Update worktree: <worktree path>
Branch: <branch>
To discard it, run from the main checkout (<main checkout path>):
  git worktree remove --force <worktree path>
  git branch -D <branch>
Warning: --force discards any uncommitted changes in the worktree.
```

`<branch>` is the update branch: `<branch-name>`, the resumed branch, or the current branch in mode 1.

**The stop rule.** Every skill-controlled stop after the worktree exists and before Step 11 opens the PR (a failed baseline check, a provisioning stop, a note that cannot be completed, a manifest copy failure, a failed Step 11 check or push, the user declining at a prompt) leaves the worktree in place, changes nothing in the main checkout, and prints the worktree notice again. Nothing is removed automatically.

**Baseline check.** On a fresh run, run `cat .gaia/VERSION` in the worktree. The worktree is cut from the default branch on `origin`, so when it does not print `<BASELINE>` (the local default branch lags or leads `origin`), stop: print what each holds, the worktree notice, and the next step (pull or push the main checkout's default branch, then re-run). Skip it on a resume: classification already placed the branch at the baseline.

**Provisioning wait.** Before Step 4b and the merge agent, wait for the worktree's background `pnpm install --frozen-lockfile`: the merge agent rewrites `package.json` and the lockfile in the same tree, and a slow install would read a half-merged pair.

```bash
bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>
```

Line 1 is the verdict, line 2 the `Log:` path. `STILL_RUNNING` (exit 4): call it again. `FINISHED`: continue. `INSTALL_FAILED` stops when `CREATED_WORKTREE=true`; otherwise report it and continue, since a re-entered tree whose manifest and lockfile disagree fails a frozen install by design. `DEADLINE_PASSED`, `STOPPED` and a refusal (exit 2) stop. A stop prints the worktree path, the `Log:` path, the next step (read the log, then re-run `/update-gaia` inside the worktree) and the worktree notice.

## Step 4b: Prune prior-run artifacts

Three gitignored directories accumulate across updates: `.gaia-backup/`, `.gaia/local/cache/shared/update-gaia/`, and `.gaia-merge/`. Prune the prior runs' leftovers at the start of a confirmed update, before this run creates any merge artifact of its own (Step 7 creates `$BACKUP_DIR`), so its fresh safety net is never touched. Only a Step 4 `Proceed` reaches here, so an abort, an already-up-to-date exit, and an uncommitted bump never prune. Run it in the acting tree, adding `--resume` on any resumed run (a mode 2 resume, mode 1, or mode 3 with `RESUME_UPDATE=true`), which keeps `.gaia-backup/` as the only copy of what the interrupted merge overwrote:

```bash
bash .gaia/scripts/update-gaia-preflight.sh prune --baseline <BASELINE> --latest-tag <LATEST_TAG>
```

It keeps the baseline and target bundles Step 3c verified and removes every other cached tag. On a default-branch run it prunes the worktree's own `.gaia-backup/` and `.gaia-merge/`; copies an earlier in-place run left in the main checkout are left alone. When it prints `Heads up: .gaia-merge/ still holds unresolved patches`, relay the listed files: they were not deleted, and the user resolves or deletes them by hand.

## Model selection

After the user confirms, determine the model for the execution agent:

- Compare `LATEST` major vs `BASELINE` major (leading integer).
- **Major bump** → spawn an **Opus agent** (`model: "opus"`).
- **Minor or patch bump** → spawn a **Sonnet agent** (`model: "sonnet"`).
- Either way, pass `effort: "medium"` on the Agent call.

Spawn the agent for Steps 6 to 9, passing `BASELINE`, `LATEST`, `LATEST_TAG`, `BASELINE_DIR`, `LATEST_DIR`, and the acting tree's absolute path. Its prompt tells it that tree is its working root: every path in `merge-execution.md` is relative to it, and it runs nothing against any other checkout. The prompt also tells it to read `.claude/skills/update-gaia/references/merge-execution.md` in full before starting Step 6 (in chunks if the Read tool refuses the size, but every chunk before Step 6) and follow it exactly. It must finish reading before Step 6 because the Step 7 walk can overwrite this skill's own files partway through the run, and the agent keeps executing the copy it read. The agent ends after its Step 9 summary and returns its `UpdateMergeReport`; relay the summary to the user, then continue with Step 9b.

## Step 9b: Follow the after-merge notes

For each `AFTER_MERGE` note Step 3d printed, in version order, read it from its path in the verified target bundle and follow it; the path resolves from the update worktree through its shared `.gaia/local` link. A note may ask the user. After-merge notes are idempotent, so a resumed run repeats them safely. A note that cannot be completed stops the run here, with `.gaia/VERSION` still at the baseline, so the next run finds the update branch and resumes (Step 3); on a worktree run that stop prints the worktree notice.

## Step 9c: Carry new setup features

A release can list setup features an existing project has not decided yet. Compare the verified target bundle's feature list with this project's decision records, with the working directory at the acting tree so the call uses that tree's freshly merged `.gaia/cli/gaia`:

```bash
bash <main checkout path>/.gaia/scripts/update-gaia-drift.sh --features <LATEST_DIR>/.gaia/setup-features.json
```

The main checkout's copy of the script is called because the merge walk may have rewritten or removed the worktree's copy, and the orchestrator keeps following the text it already read; every later call of `provision-wait.sh` or `update-check-bust.sh` uses the `<main checkout path>/.gaia/scripts/` copy for the same reason.

Drift never fails an update: on `DRIFT_FAILED <reason>`, keep the reason for the Step 9d addendum and continue. Otherwise take each token in order:

- **`APPLY <id> <reference>`**: read the reference from the working tree and apply the feature with no question, then run `.gaia/cli/gaia setup record <id> applied`.
- **`ASK <id> <reference>`**: read the reference and ask the user once, then record the answer with `.gaia/cli/gaia setup record <id> <applied|declined|not-applicable>`. A dismissed question records nothing.
- **`OWED_ADMIN <id>`**: a project-scope feature that needs a repository admin, met by a non-admin. Neither apply, ask nor record it.
- **`SETUP <id>`**: the feature needs the full setup flow; name it as "run /setup-gaia". With no decision records at all, drift reports every listed id this way, so the whole set goes to `/setup-gaia`.

A failed apply records nothing, and neither does a `record` that refuses: name that id as failed, and the next run retries it. Project-scope records land in `.gaia/project.json` and ride the update commit; machine-scope records land in `.gaia/local/setup-state.json`.

## Step 9d: Record the update

The merge, the notes and the drift are done, so record the update. Run these three commands in the acting tree as separate calls; the order is the contract:

```bash
GAIA_MANIFEST_WRITE=release cp <LATEST_DIR>/.gaia/manifest.json .gaia/manifest.json
```

```bash
.gaia/cli/gaia ping --event update --from <BASELINE> --to <LATEST> || true
```

```bash
echo <LATEST> > .gaia/VERSION
```

A non-zero exit from the `cp` command is the `MANIFEST_COPY_FAILED` stop: run neither later command, relay it, and print the worktree notice on a worktree run; the version stays at the baseline and a re-run resumes.

`.gaia/VERSION` is written last. An interruption anywhere before that write leaves it at the baseline, so the next run finds the update branch and resumes (Step 3), repeating the idempotent merge, the after-merge notes and the drift. An interruption between the ping and the version write can repeat the ping on that re-run, which beats losing it. The ping records the version transition for adoption analytics and is best-effort; it never gates the update.

The manifest copy carries the `GAIA_MANIFEST_WRITE=` marker, a bare edit is blocked by `.claude/hooks/block-manifest-write.sh`, and this wholesale replace is the release-only write the guard exempts. This refreshes `.gaia/manifest.json` from the release copy so the next `/update-gaia` has the right baseline. Unresolved conflict patches, re-pin notes, or a migration action item do **not** block this bump, they are follow-ups the user resolves against the already-recorded update; `.gaia/VERSION` tracks the file merge, which is done.

Then bust the update-check cache so the statusline and the next SessionStart reflect the post-update state. After the version write, from the acting tree, run:

```bash
bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode gaia --version <LATEST>
```

Then read the file back and confirm `gaiaCurrent` and `gaiaLatest` are `<LATEST>` and `gaiaHasUpdate` is `false`. The cache is main-anchored, so from a worktree the write takes the tool-choice contract's route, Bash at the main-checkout absolute path followed by a read-back (`.claude/skills/gaia/references/spec.md`, `## Operational primitives`). The script carries every field it does not set, because several are observations nothing later can reconstruct. `SKIPPED no cache` means there was nothing to bust; a non-zero exit is reported and never fails the update. The post-run values hold until the statusline refresher next recomputes after its TTL; it reads the main checkout, so until the PR merges it then reports the main checkout's own, not yet updated, state.

Then print a summary addendum after the execution agent's table:

- each migration note followed, by version and path;
- the setup features applied, asked (with the answer), owed by an admin, failed, and handed to `/setup-gaia`, each by id, or the `DRIFT_FAILED` reason.

## Step 10: Next steps for the user

On a worktree run, wait for provisioning again before the hand-off:

```bash
bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>
```

It normally returns `FINISHED` at once, since Step 4 already waited. `STILL_RUNNING`: call it again. `INSTALL_FAILED` stops only when `CREATED_WORKTREE=true` (a re-entered tree whose manifest and lockfile disagree fails the frozen install by design, so report it and continue); `DEADLINE_PASSED`, `STOPPED` and a refusal stop. A stop prints the worktree path, the `Log:` path, the next step and the worktree notice. Mode 3 runs no wait and names its `<checkout path>` wherever the list below says `<worktree path>`.

Then tell the user, naming the provisioning `Log:` path on a worktree run:

1. Review any conflict patches in `<worktree path>/.gaia-merge/` and reconcile manually. Delete the patch file once resolved. If `.gaia-merge/package.json.notes` or `.gaia-merge/pnpm-workspace.yaml.notes` exists there, reconcile the re-pin conflicts and decide on the suggestions, then delete it.
2. If the `package.json` or `pnpm-workspace.yaml` merge applied any change, sync `pnpm-lock.yaml` before the quality gate, but pick the command by what changed. A dependency or `packageManager` bump syncs with `pnpm -C <worktree path> install`. An `overrides`, `allowBuilds`, or resolution-setting change needs `pnpm -C <worktree path> dedupe` instead: `pnpm install` short-circuits with "Already up to date" when only the `overrides:` map moved and leaves the lockfile untouched, so a floor you just accepted would be declared in config and unapplied in the tree, with nothing red to say so (`wiki/dependencies/pnpm-overrides.md`). `pnpm dedupe` is correct for both cases, so prefer it when unsure.
3. If any region regeneration failed, was refused, or was skipped, running the command named in the Step 9 report in `<worktree path>` is a follow-up the adopter owns. Resolve whatever suppressed it first (the conflict patch for that path, most often), then run the command and re-run the roster check to confirm the region is current.
4. If Step 7e reported stale package settings, or you resolved a `.claude/settings.json` conflict patch, run `./.gaia/cli/gaia packages sync-settings` and then `bash .gaia/scripts/check-settings-drift.sh` in `<worktree path>`, and stage the regenerated `frontend/.claude/settings.json`. Never hand-edit that file.
5. Run the quality gate per `wiki/decisions/Quality Gate.md` in `<worktree path>` to verify the updated code still passes.
6. Inspect the diff (`git -C <worktree path> diff`) before committing. When Step 9c recorded a project decision, `.gaia/project.json` belongs in the commit.
7. When satisfied, commit in `<worktree path>` with `chore(gaia): update to <LATEST_TAG>`.

Do **not** auto-commit on behalf of the user, they need to review the changes first.

---

## Step 11 (orchestrator, after the user commits)

The execution agent's work ends at Step 9, it returns its `UpdateMergeReport`, and the orchestrator relays the summary and runs Steps 9b to 10 itself. Step 11 runs in the **orchestrator**, not the spawned agent: it depends on the Step 10 commit, which is the user's manual action and lands after the one-shot agent has already returned. Run it once that commit exists.

### Step 11: Open a pull request

After the Step 10 commit lands, `/update-gaia` must not leave the branch stranded: open a PR so the update can be reviewed and merged. The orchestrator waits for the user to confirm the commit landed; the checks below are a backstop, not a replacement for that confirmation. `<branch>` is the update branch (`<branch-name>`, the resumed branch, or the current branch in modes 1 and 3). Run each as its own plain command, in order, stopping on a failure and printing the worktree notice on a worktree run.

`<default branch>` is the repository's default branch, never a literal `main`. Read it first with `git -C <acting tree> symbolic-ref --quiet --short refs/remotes/origin/HEAD`, which prints `origin/<name>`; carry `<name>` as a typed literal. When it prints nothing, run `git -C <acting tree> branch -r --list origin/main origin/master` and take `main` when it lists `origin/main`, else `master` when it lists `origin/master`, else `main`.

1. `git -C <acting tree> fetch origin <default branch>`
2. `git -C <acting tree> rev-list --count origin/<default branch>..<branch>`: `0` means nothing is committed, so tell the user to finish Step 10 and stop.
3. `git -C <acting tree> show <branch>:.gaia/VERSION` must print `<LATEST>`; otherwise the update commit is not on `<branch>`, so say so and stop.
4. `git -C <acting tree> push -u origin <branch>`; on a failure, relay git's error and tell the user to open the PR manually: `<branch>` → `<default branch>`.
5. `gh pr list --head <branch> --state open --json number,url`: when one is open, report that the push updated it. Otherwise run `gh pr create --draft --base <default branch> --head <branch> --title "chore(gaia): update to <LATEST_TAG>" --body "Pulls GAIA <LATEST_TAG> into the project. Per-file outcomes are in the update summary above."`
6. On a worktree run, print the worktree notice: a PR later closed unmerged leaves the user with the removal commands already in hand. Nothing is removed automatically; the PR's merge and cleanup run later through the PR Merge Workflow (`.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, which stops while `.gaia-merge/` holds a file).

If `gh` is unavailable or errors, tell the user to open the PR manually: `<branch>` → `<default branch>`.

### Step 12: Offer the residue sweep

The merged `.gaia/state-registry.json` names the `.gaia/local` state that retired features left behind.

**Worktree run.** Run no residue sweep: it refuses whenever `.gaia/local` is a symlink, as it always is in a provisioned worktree, and it resolves the registry at the main checkout, which holds the old release's registry until the PR merges. Print as the next step, once the PR merges and cleanup pulls the main checkout: run `bash .gaia/scripts/state-registry-lib.sh residue-sweep --apply` from the main checkout.

**Mode 3.** Run `bash .gaia/scripts/state-registry-lib.sh residue-sweep` and show its output. When its Residue section lists paths, ask once with `AskUserQuestion` (question `Delete the residue paths listed above?`, header `Residue`, options `Delete them` and `Keep them`) and on `Delete them` run the same command with `--apply`. It deletes only the Residue paths; Unknown paths are listed, never deleted. A non-zero exit names its cause on stderr: relay it and finish, since the update itself is done.
