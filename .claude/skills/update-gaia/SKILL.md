---
name: update-gaia
description: Pulls the latest GAIA release into this project without clobbering customizations, with a three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `🚀 /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
---

Contents: Pre-flight: Worktree check; Pre-flight: Branch check (run modes); Step 1: Read baseline version; Step 2: Resolve latest release; Step 3: Compare versions (default branch, worktree run in place, in place); Pre-flight: Pull check (reads `references/pull-mode.md`); Pre-flight: Decision log check; Pre-flight: Claim check (reads `references/claim-flow.md`); Step 3b: Refuse a 1.x baseline; Step 3c: Download and verify the bundles; Step 3d: Select migration notes; Step 4: Show the release notes and confirm (on Proceed: the update worktree, the worktree notice, the stop rule, the claim); Step 4b: Prune prior-run artifacts; Conflict flow (reads `references/conflict-flow.md`: dispatch, questions, decisions, follow-ups); Step 9b: Follow the after-merge notes; Step 9c: Carry new setup features; Step 9d: Record the update; Quality gate; Review point; Step 11 (orchestrator, after the review-point commit); Step 12: Offer the residue sweep.

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`**: GAIA controls fully.
- **`shared`**: GAIA seeds, you customize.
- **`wiki-owned`**: GAIA-seeded wiki pages.
- **adopter-owned (implicit)**: anything not in the manifest, plus sentinels like `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`, `.gaia/update-decisions.json`. The merge walk never touches them; Step 9d rewrites `.gaia/manifest.json` and `.gaia/VERSION` once the merge is done, and the decision steps below write `.gaia/update-decisions.json`.

The first three take the same Step 7 rows. The class changes only two of them: which status a clean overwrite reports (`owned` → `overwrite`, the other two → `merge`), and what happens when the release newly owns a path the adopter already has (`owned` backs up and overwrites, the other two fall through to the ordinary rows). Step 7 is authoritative.

Backups land in `.gaia-backup/<timestamp>/` in the acting tree (the update worktree on a default-branch run). The merge report, its candidate files and the instruction snapshot land in the run directory, `<main checkout path>/.gaia/local/cache/shared/update-gaia/run` (gitignored, written only through Bash), which the run removes after Step 11.

**Who runs what.** This file runs the pre-flight through Step 4b, then dispatches the execution agent for Steps 6 to 9 (`references/merge-execution.md`), which merges and writes a JSON report but asks nothing. Every step after that runs here, in the orchestrator: the questions, applying the answers and recording the decisions, the follow-ups, Steps 9b to 9d, the quality gate, the review point with its single commit confirm, and Steps 11 and 12. On a default-branch run everything from Step 4b on runs inside the update worktree, so the main checkout's branch, files and `node_modules` stay as the user left them. Every orchestrator step lives in this file or in `references/conflict-flow.md`, which the orchestrator reads in full before the dispatch, because the merge walk can overwrite this skill's own files partway through the run and the orchestrator keeps following the copy it already read. The draft PR's merge and cleanup run later, through the PR Merge Workflow.

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
2. **Default branch.** On `main` or `master`: set `SHOULD_CREATE_WORKTREE=true` and read `<main checkout path>` once with `git rev-parse --show-toplevel`, but **do not create the worktree yet**: creation is deferred until after the Step 4 Proceed confirmation. Steps 1 to 4 can exit early (already up to date, an invalid decision log, a refused baseline, a failed Step 3c verification, a Step 3d stop, or the user aborts); creating it before then leaves an orphan worktree and branch when there was nothing to update.
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
  - **First, detect an uncommitted bump.** If `.gaia/VERSION` differs from the last commit (`git diff --quiet HEAD -- .gaia/VERSION` exits non-zero, this catches a staged or unstaged bump), a previous in-place `/update-gaia` already bumped the version but the update was never committed. Do **not** print "up to date", the bumped VERSION makes every re-run look current, so saying it dead-ends the user. Instead read the committed baseline (`git show HEAD:.gaia/VERSION`) for context, tell the user the update to `v<LATEST>` is already applied to the working tree but not committed. In mode 3 that is a stopped run of this command: go to `## Quality gate`, then `## Review point`. In any other mode, tell the user to review `git diff` and commit it, and exit. Either way, to start over instead, the user runs `git checkout -- .gaia/VERSION` to discard the bump and re-runs `/update-gaia`.
  - Otherwise print "You are up to date on GAIA v<BASELINE>." and exit.
- If `semver(LATEST) < semver(BASELINE)` → print a warning that the installed version is ahead of the latest release and exit. Never downgrade.
- If `LATEST` is above `BASELINE`, look for an earlier run's update branch by the mode's subsection below. The branch is found by its `update/<LATEST_TAG>-` prefix, never by minting its name again: a minted name carries the current minute, so it never equals the earlier run's.

### Step 3, default branch: classify the update branch

Mode 2. From the main checkout:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST>
```

It classifies the most recently committed `update/<LATEST_TAG>-*` branch by the branch's own state and never reads the main checkout's `.gaia/VERSION`. Branch on its one line:

- **`NONE`**: a fresh run. Continue to the pull check.
- **`RESUME_IN_WORKTREE <branch> <path>`**: tell the user a prior run to `<LATEST_TAG>` stopped after its merge and before its `.gaia/VERSION` write, and that this run resumes inside that worktree, keeps its `.gaia-backup/`, and repeats the merge, the questions, the after-merge notes and the setup drift through to the version write. Persist both values. Continue to the decision log check.
- **`RESUME_ADD_WORKTREE <branch>`**: the same message, except that the run resumes in a worktree it adds for the branch at Step 4. Persist the branch. Continue to the decision log check.
- **`APPLIED_UNCOMMITTED <branch> <path>`**: report the update as applied but not committed, with the worktree path and the branch. The next step is re-running `/update-gaia` inside that worktree, which runs the quality gate and the review point there and then opens the PR. Exit. Never resume the merge or write the version again.
- **`COMMITTED <branch> <path or ->`**: read the PR state with `gh pr list --head <branch> --state all --json number,state,url`. A claim PR may exist before Step 11, so report the branch, the PR's state (or that none exists), the worktree path when one holds it, and the removal commands from the worktree notice in Step 4 (only `git branch -D <branch>` when the path is `-`). Exit, creating no worktree. When the PR is `MERGED`, the next step is pulling the main checkout's default branch, not removal.

### Step 3, worktree run in place

Mode 1. The current branch must start `update/<LATEST_TAG>-`; otherwise stop: this worktree updates to an older release, so print the worktree notice (Step 4) and tell the user to remove it with those commands and re-run `/update-gaia` from the main checkout. Then, from the worktree:

```bash
bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST> --branch <current branch>
```

- **`RESUME_IN_WORKTREE`**: continue to the decision log check in place, as a resumed run.
- **`APPLIED_UNCOMMITTED`**: the merge, the answers and the version write are done. Go straight to `## Quality gate`, then `## Review point`; the run directory still holds the report when the earlier run stopped at the gate or the review point.
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

The current branch wins when it carries the prefix; otherwise the most recently committed matching local branch does. On `RESUME <branch>`, tell the user this is a merged-but-unbumped tree and that this run keeps `.gaia-backup` and repeats the merge, the questions, the after-merge notes and the setup drift through to the version write. Persist `RESUME_UPDATE`. The run stays on its current branch either way. Continue to the decision log check.

## Pre-flight: Pull check

Applies only in mode 2 when the classifier printed `NONE`: a fresh default-branch run in the main checkout. A worktree run in place, an in-place run on another branch and every resume skip it. Before the decision log check and any download, read origin's version:

```bash
bash .gaia/scripts/update-claim.sh origin-version --tree <main checkout path>
```

Exit 3 (`ORIGIN_VERSION_UNAVAILABLE`) continues to the decision log check: the check fails open. When `ORIGIN_VERSION <x.y.z>` is above `BASELINE`, the checkout lags origin: read `references/pull-mode.md` and follow it with caller `update-gaia` and the main checkout path, creating no worktree and downloading nothing. The run ends there; pull mode's continue offer invokes this skill again from the pulled copy. Otherwise continue to the decision log check.

## Pre-flight: Decision log check

`.gaia/update-decisions.json` is the committed decision log: the adopter's earlier answers, including the items they chose to decide later. A `deferred` entry is merged against the bundle it was deferred from, so this run has to fetch that bundle too, and its tags reach download commands, so the log is validated before anything else reads it. Run this in the checkout the run starts in (the main checkout in modes 2 and 3, the worktree in mode 1), before Step 3b and any download:

```bash
bash .gaia/scripts/update-decisions.sh check --file <starting checkout>/.gaia/update-decisions.json
```

- **Exit 1** (`DECISIONS_INVALID <file>: <error>` and a `Next step:` line): relay both lines and stop, writing nothing: no download, and no worktree, branch, prune or cache change.
- **`DECISIONS_ABSENT`**: no decisions and no extra baseline tags. Continue to Step 3b.
- **`DECISIONS_OK <n>`**: read the deferred baselines with the two calls below, then continue to Step 3b.

```bash
bash .gaia/scripts/update-decisions.sh deferred-tags --file <starting checkout>/.gaia/update-decisions.json
```

Persist each printed tag, in the order printed (oldest first), as an **extra baseline tag**. None printed means none.

```bash
bash .gaia/scripts/update-decisions.sh deferred --file <starting checkout>/.gaia/update-decisions.json
```

Persist its `DEFERRED <baselineTag> <path> [<key>]` lines: Step 3c names these paths when a tag fails, and the review summary lists the items still deferred.

Pull mode never reads the log, so a pull can repair a log already fixed on origin.

From Step 4b on, the acting tree's copy, `<acting tree>/.gaia/update-decisions.json`, is the one every step reads and writes. On a fresh default-branch run it matches the main checkout's: the Step 4 baseline check confirms the worktree sits at the same release, and the log changes only in an update commit.

## Pre-flight: Claim check

Before Step 3b and any download, in every mode, read `references/claim-flow.md` `## Claim check` and follow it in the checkout the run starts in. It reads the live update claims and the current login with `update-claim.sh`; a teammate's claim stops the run, creating no worktree, branch or cache entry; the user's own claim resumes the run, or is closed to start fresh; a skipped check continues with no claim.

## Step 3b: Refuse a 1.x baseline

GAIA 2.0.0 moved the React app into `frontend/`, and the 2.x release manifest is keyed on those paths. A three-way merge from a 1.x baseline would read every baseline app path as an upstream deletion and offer to delete the adopter's app, so a 1.x project migrates through the 2.0.0 migration note bundled in the checksum-verified v2.0.0 release, never through this command. Run this before any download and before the Step 4 prompt:

```bash
bash .gaia/scripts/update-gaia-preflight.sh refuse-1x --baseline <BASELINE>
```

On `REFUSED`, stop and relay the message: no worktree, no branch, no prune, no download. For a 1.x baseline, offer to run the printed command, and only after the user says yes run it and follow the note it extracts, in this session.

## Step 3c: Download and verify the bundles

Every bundle this run reads is verified against its release's `.sha256` asset in this run, before the Proceed question, and every tree it reads is extracted again from that verified tarball. Each tag's cache directory, `.gaia/local/cache/shared/update-gaia/<tag>/` (gitignored, shared across worktrees), holds the tarball, its checksum and `tree/`; the target's directory also holds the `changelog-range.md` Step 4 saves.

Print the extra baseline tags the decision log check found (or that there are none), then run, adding one `--extra-tag <tag>` per extra baseline tag:

```bash
bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <BASELINE> --latest-tag <LATEST_TAG>
```

It prints `VERIFIED <tag>` per bundle, then `BASELINE_DIR=...`, `LATEST_DIR=...` and one `EXTRA_DIR=<tag>:<path>` line per extra tag. Persist `BASELINE_DIR`, `LATEST_DIR` and each `EXTRA_DIR` line exactly as printed. Only the update cache changes before the Proceed question.

The asset is `gaia-bundle-<tag>.tar.gz` from 2.0.0 on; releases before 2.0.0 published `gaia-<tag>.tar.gz` and are out of reach on purpose (Step 3b refuses a 1.x baseline, and the different name is what makes a 1.6.1 `/update-gaia` fail at its fetch step, before it writes anything, instead of misreading the moved layout as deletions).

Each failure line names the tag and removes that tag's cache directory, so a re-run starts clean. On any of them, stop: nothing was branched, pruned or merged, and no worktree was created.

- `FETCH_FAILED <LATEST_TAG>` or `CHECKSUM_MISSING <LATEST_TAG>`: the latest release is unreachable (network, auth) or lacks an asset. Tell the user, then re-run once it is reachable.
- `FETCH_FAILED v<BASELINE>` or `CHECKSUM_MISSING v<BASELINE>`: the baseline bundle is unavailable (an older release, or one published without a checksum). The three-way merge cannot run without a baseline, so stop and explain that the adopter can cherry-pick changes by hand, comparing their project to the release.
- `FETCH_FAILED`, `CHECKSUM_MISSING` or `VERIFY_FAILED` for an extra baseline tag: the deferred items need that bundle as their baseline. Name each deferred path whose `DEFERRED` line carries that tag, and give the next step: re-run once the release is reachable, or resolve those paths by hand (merge each one yourself, then delete its entry from `.gaia/update-decisions.json` and commit) and re-run.
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

Show the human the **full baseline-to-latest CHANGELOG range**, not just the single latest tag's GitHub body, an adopter several versions behind needs every intervening entry. When there are extra baseline tags, add `--save-from <oldest extra tag's version, without its leading v>` (the first tag `deferred-tags` printed; the script cuts a prerelease to its core version itself):

```bash
bash .gaia/scripts/update-gaia-preflight.sh changelog --baseline <BASELINE> --latest <LATEST> --latest-tag <LATEST_TAG>
```

It reads GAIA's own `CHANGELOG.md` at `<LATEST_TAG>` and prints every `## [x.y.z]` section strictly newer than `<BASELINE>` through `<LATEST>`, without the `[Unreleased]` block or the bottom link-reference list, or the single-tag GitHub release body when the fetch fails. It saves the range as `changelog-range.md` beside the target's `tree/` for the execution agent's CHANGELOG reasons and documented adopter actions, since the release bundle withholds `CHANGELOG.md`; with `--save-from` the saved file starts at the oldest deferred baseline, so a deferred item's reason can come from a release older than `<BASELINE>`. A failed fetch removes the file, so the agent reports the range as unavailable rather than reading a stale one. Print the range to the user. When Step 3d printed `AFTER_MERGE` lines, name each `AFTER_MERGE` note (its version and its path) as a note this run follows after the merge. Then use `AskUserQuestion`:

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

`<branch>` is the update branch: `<branch-name>`, the resumed branch, or the current branch in mode 1. When `CLAIM_PR` is set, the notice also lists `gh pr close <CLAIM_PR> --delete-branch` before the removal commands.

**The stop rule.** Every skill-controlled stop after the worktree exists and before Step 11 pushes the update (a failed baseline check, a provisioning stop, a failed dispatch or report check, a note that cannot be completed, a manifest copy failure, a red quality gate the user stops at, a "Not yet" at the review point, a failed Step 11 check or push, the user declining at a prompt) leaves the worktree in place, changes nothing in the main checkout, leaves the claim PR open when `CLAIM_PR` is set, and prints the worktree notice again. Nothing is removed automatically, and the run directory stays for the next run's prune. A stop after the Step 9d version write gives the next step as re-running `/update-gaia` inside the worktree (in mode 3, in this checkout), which classifies the update as applied but uncommitted and resumes at the quality gate.

**Baseline check.** On a fresh run, run `cat .gaia/VERSION` in the worktree. The worktree is cut from the default branch on `origin`, so when it does not print `<BASELINE>` (the local default branch lags or leads `origin`), stop: print what each holds, the worktree notice, and the next step (pull or push the main checkout's default branch, then re-run). Skip it on a resume: classification already placed the branch at the baseline.

**Provisioning wait.** Before Step 4b and the merge agent, wait for the worktree's background `pnpm install --frozen-lockfile`: the merge agent rewrites `package.json` and the lockfile in the same tree, and a slow install would read a half-merged pair.

```bash
bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>
```

Line 1 is the verdict, line 2 the `Log:` path. `STILL_RUNNING` (exit 4): call it again. `FINISHED`: continue. `INSTALL_FAILED` stops when `CREATED_WORKTREE=true`; otherwise report it and continue, since a re-entered tree whose manifest and lockfile disagree fails a frozen install by design. `DEADLINE_PASSED`, `STOPPED` and a refusal (exit 2) stop. A stop prints the worktree path, the `Log:` path, the next step (read the log, then re-run `/update-gaia` inside the worktree) and the worktree notice.

**Claim.** In modes 1 and 2, unless the claim check was skipped (mode 3 makes no claim), read `references/claim-flow.md` `## Claim after Proceed` and follow it: it makes the one empty claim commit and the draft PR, persists the PR number as `CLAIM_PR`, and settles a race with another run. A run that loses stops there; a claim that cannot be made prints a warning and continues with no claim.

## Step 4b: Prune prior-run artifacts

Two gitignored directories accumulate across updates: `.gaia-backup/` and `.gaia/local/cache/shared/update-gaia/` (which also holds a stopped run's run directory). Prune the prior runs' leftovers at the start of a confirmed update, before this run creates any merge artifact of its own (Step 7 creates `$BACKUP_DIR`), so its fresh safety net is never touched. Only a Step 4 `Proceed` reaches here, so an abort, an already-up-to-date exit, and an uncommitted bump never prune. Run it in the acting tree, adding `--resume` on any resumed run (a mode 2 resume, mode 1, or mode 3 with `RESUME_UPDATE=true`), which keeps `.gaia-backup/` as the only copy of what the interrupted merge overwrote, and one `--keep-tag <tag>` per extra baseline tag, so the deferred items' bundles survive:

```bash
bash .gaia/scripts/update-gaia-preflight.sh prune --baseline <BASELINE> --latest-tag <LATEST_TAG>
```

It keeps the baseline and target bundles Step 3c verified, plus each kept tag, and removes every other entry of the update cache. On a default-branch run it prunes the worktree's own `.gaia-backup/`; copies an earlier in-place run left in the main checkout are left alone.

## Conflict flow: dispatch, questions, decisions, follow-ups

Read `references/conflict-flow.md` and follow it in full. It covers model selection and dispatch, the run directory and instruction snapshot, the execution agent, the report check, judgment chunks, clean merges, the questions, applying the answers and recording the decisions, and the follow-ups. It ends with the decisions recorded and the follow-ups done; then continue at Step 9b.

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

The merge, the answers, the follow-ups, the notes and the drift are done, so record the update. Run these three commands in the acting tree as separate calls; the order is the contract:

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

`.gaia/VERSION` is written last. An interruption anywhere before that write leaves it at the baseline, so the next run finds the update branch and resumes (Step 3), repeating the idempotent merge, the answers, the after-merge notes and the drift. An interruption between the ping and the version write can repeat the ping on that re-run, which beats losing it. The ping records the version transition for adoption analytics and is best-effort; it never gates the update.

The manifest copy carries the `GAIA_MANIFEST_WRITE=` marker, a bare edit is blocked by `.claude/hooks/block-manifest-write.sh`, and this wholesale replace is the release-only write the guard exempts. This refreshes `.gaia/manifest.json` from the release copy so the next `/update-gaia` has the right baseline. A deferred item or a migration action item does **not** block this bump: the decision log carries the deferred item to the next update, and `.gaia/VERSION` tracks the file merge, which is done.

Then bust the update-check cache so the statusline and the next SessionStart reflect the post-update state. After the version write, from the acting tree, run:

```bash
bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode gaia --version <LATEST>
```

Then read the file back and confirm `gaiaCurrent` and `gaiaLatest` are `<LATEST>` and `gaiaHasUpdate` is `false`. The cache is main-anchored, so from a worktree the write takes the tool-choice contract's route, Bash at the main-checkout absolute path followed by a read-back (`.claude/skills/gaia/references/spec.md`, `## Operational primitives`). The script carries every field it does not set, because several are observations nothing later can reconstruct. `SKIPPED no cache` means there was nothing to bust; a non-zero exit is reported and never fails the update. The post-run values hold until the statusline refresher next recomputes after its TTL; it reads the main checkout, so until the PR merges it then reports the main checkout's own, not yet updated, state.

Keep this addendum for the review summary:

- each migration note followed, by version and path;
- the setup features applied, asked (with the answer), owed by an admin, failed, and handed to `/setup-gaia`, each by id, or the `DRIFT_FAILED` reason.

## Quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md` in the acting tree, applying its auto-fixes. Green: continue to the review point.

Red: ask with `AskUserQuestion` whether to fix it, options `Fix it now (Recommended)` and `Stop here`, with the failing output in the question. On `Fix it now`, the orchestrator fixes the failures and runs the gate again, at most two fix attempts in all. Still red after the second: ask once more with only `Stop here`, showing the failing output. `Stop here` ends the run per the stop rule: the worktree is kept, the update stays uncommitted with its version written, the worktree notice is printed, and the next step is re-running `/update-gaia` inside the worktree (in mode 3, in this checkout), which resumes at this gate.

## Review point

On a worktree run, wait for provisioning again first:

```bash
bash <main checkout path>/.gaia/scripts/provision-wait.sh --tree <worktree path>
```

It normally returns `FINISHED` at once, since Step 4 already waited. `STILL_RUNNING`: call it again. `INSTALL_FAILED` stops only when `CREATED_WORKTREE=true` (a re-entered tree whose manifest and lockfile disagree fails the frozen install by design, so report it and continue); `DEADLINE_PASSED`, `STOPPED` and a refusal stop. A stop prints the worktree path, the `Log:` path, the next step and the worktree notice. Mode 3 runs no wait.

Then show the summary, built from `<run dir>/report.json` and this run's own steps, naming the provisioning `Log:` path on a worktree run:

- the count of files per status, and the backup directory;
- every `auto-merged` file by name: a customized file GAIA also changed, combined with no question;
- every key `applied`, `keptRemoved` and `removedUpstream` from each `field-aware` entry;
- every answer, and every item still deferred (this run's Decide later answers and the earlier `DEFERRED` entries no answer replaced);
- the follow-ups run: the lockfile command, the region regeneration, the settings sync, and any that failed with the command to run;
- the report's `regions` (awareness off, dropped or malformed declarations, rewritten paths, and each unregenerated path with its command), `settings` and `labels` states, and each `adopterActions` entry with its command and CHANGELOG line, which the adopter runs only if they choose;
- the Step 9d addendum and the quality gate's result.

When the report is gone (an earlier run's stop, then a prune), say so and build the summary from the diff alone. Then show what the commit would hold, a stat first:

```bash
git -C <acting tree> diff --stat
```

```bash
git -C <acting tree> status --short
```

```bash
git -C <acting tree> diff
```

The status lists the untracked files the merge added, which `git diff` never shows; in mode 3 it also shows any change the user had before the run, which the commit would include. Then ask once with `AskUserQuestion`:

- **Question**: "Commit this update?"
- **Options**: `Commit` / `Not yet`.

On `Commit`, run in the acting tree, as two calls:

```bash
git -C <acting tree> add -A
```

```bash
git -C <acting tree> commit -m "chore(gaia): update to <LATEST_TAG>"
```

The commit includes `.gaia/update-decisions.json` and `.gaia/project.json` when this run changed them; say so. A commit a hook refuses is relayed and stops per the stop rule. On `Not yet`, stop per the stop rule. Never commit without the `Commit` answer.

---

## Step 11 (orchestrator, after the review-point commit)

The execution agent's work ends at Step 9, with its report; the orchestrator runs everything after it. Step 11 runs in the **orchestrator** right after the review-point commit lands.

### Step 11: Open a pull request

After the review-point commit lands, `/update-gaia` must not leave the branch stranded: open a PR so the update can be reviewed and merged. The checks below are a backstop for that commit. `<branch>` is the update branch (`<branch-name>`, the resumed branch, or the current branch in modes 1 and 3). Run each as its own plain command, in order, stopping on a failure and printing the worktree notice on a worktree run.

`<default branch>` is the repository's default branch, never a literal `main`. Read it first with `git -C <acting tree> symbolic-ref --quiet --short refs/remotes/origin/HEAD`, which prints `origin/<name>`; carry `<name>` as a typed literal. When it prints nothing, take `main` when `git -C <acting tree> show-ref --verify --quiet refs/remotes/origin/main` exits 0, else `master` when `git -C <acting tree> show-ref --verify --quiet refs/remotes/origin/master` exits 0, else `main`.

1. `git -C <acting tree> fetch origin <default branch>`
2. `git -C <acting tree> show <branch>:.gaia/VERSION` must print `<LATEST>`; otherwise the update commit is not on `<branch>`, so say so and stop.
3. `bash <main checkout path>/.gaia/scripts/update-claim.sh list --tree <main checkout path>`: a live claim on another branch by a different login stops before the push, the commit left local, as the claim reference's Step 11 section details. Exit 3 continues.
4. `git -C <acting tree> push -u origin <branch>`; on a failure, relay git's error and tell the user to open the PR manually: `<branch>` → `<default branch>`. Never force the push.
5. When `CLAIM_PR` is set, the push updated the claim PR: follow `references/claim-flow.md` `## Step 11: the claim-aware pull request` to rewrite its body and drop the claim from the cache. Otherwise run `gh pr list --head <branch> --state open --json number,url`: when one is open, report that the push updated it; else run `gh pr create --draft --base <default branch> --head <branch> --title "chore(gaia): update to <LATEST_TAG>" --body "Pulls GAIA <LATEST_TAG> into the project. Per-file outcomes are in the update summary above."`
6. On a worktree run, print the worktree notice: a PR later closed unmerged leaves the user with the removal commands already in hand. Nothing is removed automatically; the PR's merge and cleanup run later through the PR Merge Workflow (`.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`).

If `gh` is unavailable or errors, tell the user to open the PR manually: `<branch>` → `<default branch>`.

Then remove the run directory; a run that stopped earlier leaves it for the next run's prune:

```bash
rm -rf <main checkout path>/.gaia/local/cache/shared/update-gaia/run
```

### Step 12: Offer the residue sweep

The merged `.gaia/state-registry.json` names the `.gaia/local` state that retired features left behind.

**Worktree run.** Run no residue sweep: it refuses whenever `.gaia/local` is a symlink, as it always is in a provisioned worktree, and it resolves the registry at the main checkout, which holds the old release's registry until the PR merges. Print as the next step, once the PR merges and cleanup pulls the main checkout: run `bash .gaia/scripts/state-registry-lib.sh residue-sweep --apply` from the main checkout.

**Mode 3.** Run `bash .gaia/scripts/state-registry-lib.sh residue-sweep` and show its output. When its Residue section lists paths, ask once with `AskUserQuestion` (question `Delete the residue paths listed above?`, header `Residue`, options `Delete them` and `Keep them`) and on `Delete them` run the same command with `--apply`. It deletes only the Residue paths; Unknown paths are listed, never deleted. A non-zero exit names its cause on stderr: relay it and finish, since the update itself is done.
