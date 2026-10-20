---
type: concept
title: Update Workflow
status: active
created: 2026-04-22
updated: 2026-10-18
tags: [release, claude, adopter, drift]
---

# Update Workflow

How `/update-gaia` pulls a newer GAIA release into an initialized project without clobbering customizations. Modeled on GSD's update pattern: explicit confirmation, three-way merge per file, every conflict answered during the run, no silent overwrite.

## Primitives

| File                  | Role                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`       | Adopter's current baseline: which GAIA version `my-app/` was scaffolded from (or last `/update-gaia`d to).          |
| `.gaia/manifest.json` | Ships with every release. Maps each file in the release to a class.                                                 |
| `.gaia/local/cache/shared/update-gaia/` | Gitignored, shared across worktrees. Holds the verified baseline and target bundles for the 3-way comparison: per tag, the release tarball, its `.sha256`, and a `tree/` extracted again from the verified tarball on every run, plus, for the target tag, the CHANGELOG range the confirm step fetched, which the merge agent's adopter-action suggestions read because the bundle withholds `CHANGELOG.md`. The prune at the start of each confirmed update keeps both tags and removes every other cached tag dir (`update-check.json` lives one level up at `.gaia/local/cache/shared/`, outside it). |
| `.gaia/update-decisions.json` | Committed and adopter-owned. The decision log: one entry per path (or per path and key, for a field-aware file) recording the answer to a conflict question, including Decide later. A `deferred` entry is merged on the next update against the baseline it was deferred from, and a teammate who pulls the file sees the same decisions. An entry whose file or key is back in line with GAIA's copy is dropped. |
| `.gaia-backup/`       | Gitignored, in the same tree. Per-timestamp backups of every file the walk overwrites. Prior runs' backups are pruned at the start of each confirmed update, except on a resumed run, whose backups are the only copy of what the interrupted merge overwrote; once an update is committed git history is the durable recovery. It never stops the worktree cleanup. A branch left by an earlier in-place run keeps its backups in the main checkout's `.gaia-backup/`, which a resumed run names and leaves in place. |

## File classes

The manifest assigns each shipped file exactly one class. Anything **not** in the manifest is implicitly adopter-owned and invisible to `/update-gaia`.

| Class        | Meaning                                                                                                                                    | Drift handling                                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `owned`      | GAIA controls fully: skills, commands, rules, hooks, config files.                                                                         | Pristine → overwrite silently. Drifted → three-way merge; see [Conflict handling](#conflict-handling).                                                                                 |
| `shared`     | GAIA seeds; adopter customizes. `.gaia/manifest.json` lists each file's class. | Pristine → overwrite silently. Drifted → three-way merge; see [Conflict handling](#conflict-handling). The field-aware exceptions are listed in `.claude/skills/update-gaia/references/merge-execution.md` Step 7. |
| `wiki-owned` | GAIA-seeded wiki pages adopter may edit.                                                | Same as `shared`.                                                                                                                                                                      |
| _(implicit)_ | Adopter-owned. `wiki/log.md`, `CHANGELOG.md`, and any file the adopter created.                                             | Never touched by `/update-gaia`.                                                                                                                                                       |

**Drift handling is identical across all three classes**: a drifted file the release also changed is three-way merged, and any part the merge cannot settle becomes a question asked during the run. The class decides two other things: which summary bucket a clean overwrite reports under (`owned` → overwritten, `shared` / `wiki-owned` → merged), and what happens when the release newly owns a path the adopter already has, where `owned` backs the file up and overwrites it while the other two fall through to the ordinary rows.

Sentinel paths (always adopter-owned regardless of what GAIA ships): `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`, `.gaia/packages.json`.

A package's generated `<path>/.claude/settings.json` (`frontend/.claude/settings.json`) ships in the tarball but has no manifest class: it is regenerated from the root settings and the package's `settings.overlay.json` after the merge, never three-way merged. The overlay, `frontend/gaia.package.json`, `frontend/package.json`, and `frontend/CLAUDE.md` are `shared`.

## Flow

The step list, its order, and every command live in the `update-gaia` skill (`.claude/skills/update-gaia/SKILL.md` for the orchestrator, `references/merge-execution.md` for the merge agent it spawns, `references/merge-report.md` for the report the agent hands back). The shape that order guarantees:

- **Nothing changes before the adopter confirms.** Version resolution, the 1.x refusal, the bundle download and verification, and the migration-note selection all run before the Proceed question. An early exit (up to date, refused, a failed verification, a blocking note, an Abort) leaves no branch and no prune; only the verified update cache remains.
- **Every bundle is verified in the run that reads it.** The baseline and target tarballs are checked against the release's `.sha256` asset, and the trees the merge reads are extracted again from those verified tarballs. A cached tarball skips only the download. The tarball name, `gaia-bundle-<tag>.tar.gz`, is also the 2.0.0 release fence: a 1.6.1 `/update-gaia` asks for `gaia-<tag>.tar.gz`, finds nothing, and stops at its fetch step before it writes a file.
- **A 1.x baseline migrates through the bundled 2.0.0 note.** The 2.0.0 layout moved the app into `frontend/`, and a three-way merge across that move would read every baseline app path as an upstream deletion. The refusal prints a command that downloads, verifies and extracts the v2.0.0 release, and points at the migration note inside it.
- **Migration notes come from the verified target bundle only.** The target release's own selector picks the notes the update crosses, so a mode a later release adds is judged by that release. A blocking note stops the run before anything is branched, pruned or merged, and owns the hop to its own version. After-merge notes are followed after the three-way merge and before the version bump. See [[Migration Notes]] for the note format and what each mode obliges.
- **The adopter sees the full CHANGELOG range** from the baseline to the target, and confirms. The update worktree and its branch are created only after that confirmation.
- **A run in the main checkout works in its own worktree, on any branch.** Everything before Proceed runs read-only in the main checkout. Proceed creates a linked worktree on the update branch, cut from the default branch on `origin`, and the merge, backups, questions, version write, the adopter's commit and the draft PR all happen there; the main checkout's branch, files and `node_modules` do not move, whichever branch it holds. A re-run classifies an existing update branch from its own state: merged but not bumped resumes in a worktree holding it, and applied but uncommitted, or committed, is reported with its next step and never re-merged. See [Worktree isolation](#worktree-isolation).
- **The merge agent merges and reports.** It walks the target manifest with the decision table below, applies what merges cleanly, and writes a report of every file it could not settle. The orchestrator asks those questions, applies the answers, and runs the follow-ups. The summary cross-references `**Action required:**`-anchored CHANGELOG entries and surfaces opt-in cleanup actions; it never auto-removes a dependency, and it deletes a file only when the adopter never edited it.
- **Setup drift carries new setup features.** The target bundle's feature list is compared with the project's decision records: a standalone feature is applied or asked through its own setup reference and recorded, an admin-gated one met by a non-admin is left owed, and the rest are handed to `/setup-gaia`. See [[Setup Features]].
- **The version is written last.** The manifest copy and the update ping come first, then `.gaia/VERSION`. The adopter then reviews the diff and the summary and answers one "Commit this update?" confirm; the [[Quality Gate]] runs before that confirm.

## Worktree isolation

`/update-deps` and `/update-gaia` share one shape on an interactive run from the main checkout, whichever branch it holds: every mutating step runs in a fresh linked worktree on the command's own branch (`deps/` or `update/`). The reason is that the user keeps editing, keeps a dev server running and keeps running main-only skills in the main checkout while an update runs, and none of that should see a half-merged tree or a switched branch. A run started on a feature branch cuts its worktree from the default branch on `origin` like any other, so the update lands in its own pull request rather than inside the feature work.

- **The guard admits only its own worktree.** The main-only guard (`.gaia/scripts/main-only-lib.sh`) admits a session inside the command's own update worktree and refuses every other linked worktree, including the other command's, with the cached update state from the main checkout.
- **The worktree notice.** Each skill prints the worktree path, the branch, and the two removal commands, with a warning that `--force` discards uncommitted changes, right after creation, at every skill-controlled stop, and when the run opens its PR. A stop never removes the tree.
- **Provisioning wait.** A new worktree installs its dependencies in the background. Before the first `pnpm` step, or the hand-off, the skill waits through `.gaia/scripts/provision-wait.sh`, as a series of bounded calls rather than one open-ended wait, so a stalled or dead install surfaces as a stop with the log path instead of hanging the run.
- **Main-anchored writes.** The update-check cache lives in the main checkout's `.gaia/local`, which every worktree shares. After a run the skill busts it through `.gaia/scripts/update-check-bust.sh` at the main checkout's absolute path. The statusline keeps the post-run state until its refresher next recomputes from the main checkout, which reports the main checkout's own state until the PR merges.
- **Who finishes the run.** `/update-deps` merges its PR and cleans up itself. `/update-gaia` stops at its draft PR and is cleaned up through the PR Merge Workflow. Cleanup stops while the worktree holds uncommitted or unpushed work, and installs in the main checkout only when the pull changed the lockfile; the reasons are in [[PR Merge Workflow]] (`### Cleanup under worktree isolation`).

## Team claim

Two teammates never update at once: an update run claims its release with a draft pull request, and every other run sees the claim before it downloads anything. The steps live in `.claude/skills/update-gaia/SKILL.md` and its claim-flow reference; the shape is:

- **A live claim is a same-repository open PR** whose head branch is `update/v<semver>-<suffix>`. Fork PRs and other `update/*` branches are ignored, and an entry whose tag or author login fails validation is dropped.
- **Preflight checks for one.** A live claim by someone else stops the run, naming the PR, its author and its age, whatever its tag.
- **Own claims route, they do not duplicate.** A claim by the current GitHub user for the latest release's tag is resumed (the branch is fetched first when only origin has it). One for an older tag is reported, and the run offers to close that PR and delete its remote branch before starting fresh. A run never opens a second PR while its own claim is open.
- **The claim follows the provisioning wait.** On a default-branch run, after Proceed and the worktree's provisioning wait, the run makes one empty claim commit, pushes it (never forced) and opens a draft PR for the update branch. The claim commit is not the update, so the adopter's commit confirm still gates the update commit.
- **A tie-break leaves one PR.** The run re-lists after opening its PR. When a claim with a lower PR number exists, it closes only its own PR and remote branch, removes its own worktree and local branch, and stops, naming the other claim.
- **Every gh failure fails open.** A missing or unauthenticated gh, a failed list, a refused claim commit, a rejected push or a failed create warns, skips the claim and continues the update.
- **Step 11 pushes into the existing PR.** The update commit goes onto the claim's branch and fills in the same draft PR rather than opening another.
- **The statusline shows it.** A teammate's claim renders as an in-progress nudge, the user's own as a resume nudge; see [[Claude Integration]] (`### Statusline (no hook)`).

## Pull mode

A main checkout whose `.gaia/VERSION` lags origin's can catch up without a full update. A fresh `/update-gaia` run on the default branch in the main checkout reads origin's version live, with `update-claim.sh origin-version`, before the decision log check and any download. When origin's version is higher, the run follows `.claude/skills/update-gaia/references/pull-mode.md` and ends there, creating no worktree. The steps live in that reference; the shape is:

- **Guards.** It runs only in the main checkout, on the default branch, with no uncommitted tracked changes, and it never stashes, forces or switches branches. A linked worktree, another branch, a dirty tree or a diverged branch is refused with the reason and the next step.
- **What it applies.** A fast-forward of the default branch, a frozen-lockfile install only when the pull changed the lockfile, and the machine-scope setup features the pulled release lists, under the same rules as the update's drift step ([[Setup Features]]). Project-scope features wait for the full update.
- **The residue sweep.** It offers the sweep once, then refreshes the update-check cache so the statusline stops showing the pull nudge.
- **Fail open.** An unreadable origin version (gh missing, unauthenticated or failing) skips the pull check and the update continues as before.
- **The continue offer.** When a newer release than the pulled version exists, it offers the full update and, on yes, invokes `/update-gaia` again so the update runs from the pulled copy of the skill.
- **It reads no decision log.** `.gaia/update-decisions.json` is never read in a pull, so a pull can repair a log already fixed on origin.
- **The statusline points here.** A lagging main checkout renders a pull nudge; see [[Claude Integration]] (`### Statusline (no hook)`).

## Pull gate

New work started from a main checkout that lags origin's GAIA version would branch from a stale default branch, so a gated command checks first. The shape:

- **What it gates.** A fresh start of a command that creates a branch, a worktree, a claim or a SPEC id. Each gated site calls `gaia_pull_gate` from `.gaia/scripts/main-only-lib.sh` before it creates anything, and the site files name the call.
- **What passes.** A resume, such as an earlier run's branch, a half-finished plan or an owed publish, and every command that creates none of those. The gate also passes when the cached origin version or the checkout's own version is missing or unreadable, when the checkout is at or above origin's version, and when the main checkout does not resolve. It reads only the update-check cache and the local version file, never the network.
- **The question.** In the main checkout, the gate prints the version gap and the command asks to pull now and restart, or stop. Pull mode does the pull, with the gate as its caller. In auto mode the command picks the pull and keeps its `auto` argument in the restart.
- **The restart.** After the pull the command starts again with its original arguments: through the Skill tool where the command allows it, as a printed command to paste where it does not, and as the plan's kickoff line for a generated plan. A refused or failed pull stops with pull mode's reason and next step and never restarts.
- **The linked-worktree arm.** Pull mode never runs from a linked worktree, so a gated command started inside one stops with a next step that names the main checkout, creates nothing, and offers no pull.

`.claude/skills/update-gaia/references/pull-gate.md` owns the steps, and the pull itself is the Pull mode section above.

## Decision table

For every file `P` in the latest manifest. **Rows match in declared order; the first matching row wins**, which is what keeps a file the release never touched from being overwritten or merged:

| Condition                                                 | Action                                                                 |
| --------------------------------------------------------- | ---------------------------------------------------------------------- |
| Not in adopter, not in baseline                           | **New file**: added, no prompt.                                        |
| Not in adopter, present in baseline                       | Adopter deleted: **skip** (respect intent).                            |
| Not in baseline, `owned`, adopter has the path            | Release newly owns it: back up, then **overwrite** with latest.        |
| `baseline[P] == latest[P]`                                | **Skip** (no upstream change), drifted or not.                          |
| `adopter[P] == baseline[P]`                               | Back up, then **overwrite** with latest (any class).                   |
| `adopter[P] == latest[P]`                                 | **Skip** (already at latest).                                          |
| Adopter drifted, latest changed (any class)               | **Three-way merge** the file, then judge it; see [Conflict handling](#conflict-handling). |

Files deleted upstream (in baseline, not in latest):

| Condition                   | Action                                                          |
| --------------------------- | ---------------------------------------------------------------- |
| Not in adopter              | Already gone. Counted as reconciled, no prompt.                 |
| Present in adopter, unedited | Deleted, with a backup.                                        |
| Present in adopter, edited  | Asked: remove it when nothing references it, else keep it.      |

## Conflict handling

Every file both the adopter and the release changed goes through one merge-and-judge pass, and every conflict is answered during the run. Nothing is deferred to a file the adopter must find afterwards.

- **Three-way merge.** The merge agent runs `git merge-file -p` on the adopter's copy, the baseline copy and the latest copy, to stdout and never into the adopter's file. The baseline is the verified baseline tarball's copy, or the copy a `deferred` decision names.
- **Judgment pass.** The agent reads the baseline-to-adopter and baseline-to-latest changes for every such file, clean merge or not, and sorts the pair into one of four classes: independent, the same concern GAIA already covers, the same concern the adopter's change covers more, or contradictory. An independent clean merge is written; the rest become open questions. Claims stay factual, never "superior".
- **Questions.** The orchestrator asks the open questions in batches, recommended option first, with the combined result in the preview. A dismissed question is Decide later. The mechanics, option shapes and wording live in `.claude/skills/update-gaia/SKILL.md` and `references/merge-report.md`.
- **Decision log.** Each answer is recorded in `.gaia/update-decisions.json` (see [Primitives](#primitives)). A `keep` or `blend` entry from an earlier update adds context to the next question about the same path.
- **Automated follow-ups.** After the answers apply, the orchestrator runs the lockfile command the changes call for by rule, regenerates declared regions with no conflicted paths left, syncs package settings when the root settings were resolved, runs the [[Quality Gate]], and offers a fix on a red gate.
- **One confirm.** The run ends at a summary and the diff, then "Commit this update?". The commit happens only on yes.

## Generated regions

Some shipped files carry a marker-delimited region whose body is machine-generated, rewritten by a command rather than edited by hand. The release manifest declares each one: its marker pair, the paths that carry it, and the command that regenerates it. See [[Generated Regions]] for the declaration shape, the marker contract, and the trust model; this section covers only where the merge walk's Step 7 branches for a declared path and where Step 7d's regeneration sits in the flow.

`gaia update merge-region --baseline <file> --latest <file> --current <file> --start-marker <text> --end-marker <text>` compares the three sides with each region body replaced by a single placeholder line, so a divergence confined to a generated region does not read as adopter drift. It returns one of `no-upstream-change`, `no-adopter-drift`, `already-latest`, or `conflict`, and prints the normalized forms alongside the verdict with `--json`. The command only reports; it writes nothing.

Each side is normalized on its own, so a side that carries no marker pair is still compared against masked siblings. When any side's markers are malformed, duplicated, unbalanced, or out of order, no side is normalized at all and the three sides compare as whole files, which is the same answer the walk reaches without region awareness.

`gaia update regen-regions --manifest <path> --root <dir> [--backup-dir <dir>] [--conflicted <path>]... [--absent-path <path>]... [--skip-region <id>]... [--json]` regenerates a declared region by running its shipped regeneration command against the adopter's own post-merge tree, one region at a time. It refuses a region before spawning anything when the declaration itself is malformed, or when the command operand fails a well-formedness check: an absolute path, a parent-directory segment, a path outside the shipped file set, or a path resolving through a symlink out of the repository. A region named by `--skip-region`, or one whose declared paths appear in `--conflicted` or `--absent-path`, is left alone. `--backup-dir` copies each declared path aside before the command runs, without overwriting a copy an earlier step already made. Every write the regeneration command makes outside its declared paths is confined, and where it lands decides how: inside the region's own directories the runner restores what the path held before the run, or removes what the command created; a path the command deletes is left deleted and not reported. Anywhere else in the tree there is no pre-image to restore from, so the write is reported and left where it is. The command writes to the adopter's tree, and it exits `0` for every refusal, skip, or regeneration failure; only its own flags or manifest being unusable is a non-zero exit.

## `package.json` (field-aware merge)

The merge runs once for the root `package.json` and once for each package registered in `.gaia/packages.json` (`frontend/package.json`; an absent registry means the stock `frontend` package). A package whose `package.json` is missing on any of the three sides is skipped, which is how an adopter-added package GAIA does not ship stays untouched. The rest of this section describes one file.

A whole-file three-way merge of `package.json` is pure noise: every adopter rewrites `name` / `description` / `author` and resets `version` at init, and GAIA bumps its own `version` every release, so adopter, baseline, and latest all differ on every release. `package.json` is therefore merged at JSON-key granularity, acting only on the genuine upstream delta `B → L`.

- **Adopter-owned keys**: every top-level key except the managed sections (`name`, `version`, `description`, `author`, `private`, `type`, `bin`, `sideEffects`, …) is left untouched. Identity drift is invisible.
- **Managed sections**: the entries the merge acts on, listed in `.claude/skills/update-gaia/references/merge-execution.md` Step 7a.

Per managed entry key `k`, with `B`, `L` and `A` the baseline, latest and adopter values:

| Condition                                              | Action                                                                     |
| ------------------------------------------------------ | -------------------------------------------------------------------------- |
| GAIA didn't change `k` (`B == L`)                      | No-op: adopter's value stands (kept, re-pinned, or **removed**).           |
| GAIA changed `k`, adopter still at `B`                 | Apply latest to the working tree.                                          |
| GAIA changed `k`, adopter already at `L`               | Already latest: nothing to do, not a conflict.                             |
| GAIA changed `k`, adopter re-pinned independently      | Question: put both values to the adopter, recommending the higher version. |
| GAIA changed `k`, adopter had removed it               | Kept removed: never re-added, named in the summary.                        |
| GAIA added `k` (latest only), adopter lacks it         | Apply silently.                                                            |
| GAIA added `k`, adopter has a different value          | Question: a re-pin of an added key.                                        |
| GAIA removed `k` (baseline only), adopter still has it | Left in place, surfaced as an opt-in adopter action.                       |

The load-bearing guarantee: a dependency the adopter removed is **never re-added**, the JSON-key analog of the file-level "respect adopter deletions" rule. A key GAIA newly adds is applied without asking when the adopter does not have it, because a new GAIA dependency the adopter never receives is a capability silently missing. Clean applies are written surgically (the changed line only, preserving the adopter's formatting). The review summary names, per file, the keys applied and the keys kept removed. A version-only release touches nothing and names nothing.

## Audit configuration merge

`/update-gaia` re-renders no workflow and nudges for no audit mode: the audit runs locally, so there is no audit workflow to refresh. The one audit-related file it merges is `.gaia/audit-ci.yml`, a `shared` file handled field-aware (Step 7c of the command) because it mixes GAIA-authored values with adopter-extensible ones. The merge covers the `auditors` roster; top-level keys an older adopter file still carries are ignored. A conflict is put to the adopter as a question rather than written over their value, mirroring the `package.json` rule above.

`.gaia/project.json` is not in the manifest, so the merge walk never sees it; see [[Project Config]].

## Safety invariants

- **Never touch adopter-owned paths.** Anything not in the manifest is invisible.
- **Never auto-clobber drift.** Drift in any class is three-way merged into a candidate, never into the adopter's file; a clean independent merge is written, and every other case is a question the adopter answers before anything is written over their copy.
- **Verify before reading.** No unverified tarball or tree is read, and no migration note is read from anywhere but the verified target bundle.
- **A blocking note stops before any change.** Nothing is branched, pruned or merged when the update crosses a blocking note; the adopter follows the note or stops.
- **Version marker last.** `.gaia/VERSION` flips to the target only after the merge, the after-merge notes, the setup drift, the manifest copy and the update ping. An interruption anywhere before that write leaves the version at the baseline; the next run finds the update branch for the same target and resumes in a worktree holding it, keeping `.gaia-backup/` and repeating the idempotent merge, notes and drift. An interruption between the ping and the version write can repeat the ping, which beats losing it. A version bumped but not committed is detected from the update branch's own state, never from the main checkout's `.gaia/VERSION`, and surfaced.
- **A default-branch run leaves the main checkout alone.** It makes no change to the main checkout's branch, HEAD, index or working tree, and none to its installed dependencies until cleanup.
- **Commit only on confirm.** `/update-gaia` leaves the working tree dirty until the adopter answers the "Commit this update?" confirm; no answer, no commit.

## Rollback

`/update-gaia` commits only after the adopter confirms, so the rollback path depends on whether the merge has been committed.

**Before commit, default-branch run**: remove the update worktree and its branch with the commands the run printed, from the main checkout:

```bash
git worktree remove --force <worktree path>
git branch -D <branch>
```

`--force` discards any uncommitted changes in the worktree, which here is the whole update. The main checkout was never touched, so nothing else needs undoing. To discard the update but keep the worktree, scope the restore to it explicitly; never run it location-free from the main checkout, where it would discard the user's own edits:

```bash
git -C <worktree path> restore --staged --worktree .
rm -rf <worktree path>/.gaia-backup
```

`git restore` reverts every overwritten file (including `.gaia/VERSION` and `.gaia/manifest.json`) to its committed baseline. The `.gaia-backup/` directory is gitignored, so `git restore` does not touch it; the `rm -rf` is the cleanup pass.

**After commit**: close the PR unmerged and run the same removal commands, or, once it has merged, revert the commit:

```bash
git revert <update-commit-sha>
```

A single revert undoes the merge cleanly because `/update-gaia` lands its changes as ordinary edits, not a merge commit. The revert restores `.gaia/VERSION` and `.gaia/manifest.json` to baseline alongside everything else.

In every case the adopter is back at the prior baseline and can retry `/update-gaia` against the same release. Local customizations made AFTER the rollback point survive (removal and `git revert` only undo the update walk's edits, not subsequent commits or changes in the main checkout).

## When to run

After a new GAIA release is announced (watch releases on `gaia-react/gaia`). Cadence is fully at the adopter's discretion; skipping versions is fine; the three-way diff works with any gap.

## See also

- [[Quality Gate]]: run the gate after the `update-gaia` skill finishes and before committing.
- [[Migration Notes]]: the authoring guide for the notes a release ships in its bundle.
- [[Setup Features]]: the setup feature list and decision records the drift step compares.
- [[PR Merge Workflow]]: the cleanup an update worktree goes through.
- [[Worktrees]]: the shared-state model `.gaia/local/cache/shared/update-gaia/` follows.

<!-- gaia:maintainer-only:start -->
## Communications Guidance (User-Facing Docs)

How release notes and `CHANGELOG.md` present `/update-gaia`: the CHANGELOG gate in `.claude/rules/pr-merge.md` and rule 11 of `.claude/skills/release-notes/SKILL.md`.
<!-- gaia:maintainer-only:end -->
