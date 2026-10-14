---
type: concept
title: Update Workflow
status: active
created: 2026-04-22
updated: 2026-10-13
tags: [release, claude, adopter, drift]
---

# Update Workflow

How `/update-gaia` pulls a newer GAIA release into an initialized project without clobbering customizations. Modeled on GSD's update pattern: explicit confirmation, three-way diff per file, sidecar patches for conflicts, no silent overwrite.

## Primitives

| File                  | Role                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `.gaia/VERSION`       | Adopter's current baseline: which GAIA version `my-app/` was scaffolded from (or last `/update-gaia`d to).          |
| `.gaia/manifest.json` | Ships with every release. Maps each file in the release to a class.                                                 |
| `.gaia/local/cache/shared/update-gaia/` | Gitignored, shared across worktrees. Holds the verified baseline and target bundles for the 3-way comparison: per tag, the release tarball, its `.sha256`, and a `tree/` extracted again from the verified tarball on every run, plus, for the target tag, the CHANGELOG range the confirm step fetched, which the merge agent's adopter-action suggestions read because the bundle withholds `CHANGELOG.md`. The prune at the start of each confirmed update keeps both tags and removes every other cached tag dir (`update-check.json` lives one level up at `.gaia/local/cache/shared/`, outside it). |
| `.gaia-merge/`        | Gitignored. Sidecar `.patch` files emitted for files the update can't safely auto-merge. Adopter resolves manually. Removed at the start of an update only when empty; a populated dir is kept and its leftover patches flagged. |
| `.gaia-backup/`       | Gitignored. Per-timestamp backups of every file the walk overwrites. Prior runs' backups are pruned at the start of each confirmed update, except on a resumed run, whose backups are the only copy of what the interrupted merge overwrote; once an update is committed git history is the durable recovery. |

## File classes

The manifest assigns each shipped file exactly one class. Anything **not** in the manifest is implicitly adopter-owned and invisible to `/update-gaia`.

| Class        | Meaning                                                                                                                                    | Drift handling                                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `owned`      | GAIA controls fully: skills, commands, rules, hooks, config files.                                                                         | Pristine → overwrite silently. Drifted → write `.gaia-merge/<path>.patch`, skip, let adopter resolve.                                                                                  |
| `shared`     | GAIA seeds; adopter customizes: `package.json`, `CLAUDE.md`, `README.md`, `.claude/settings.json`, `.github/workflows/*`, `wiki/index.md`. | Pristine → overwrite silently. Drifted → write `.gaia-merge/<path>.patch`, skip, let adopter resolve. The field-aware exceptions are listed in `.claude/skills/update-gaia/references/merge-execution.md` Step 7. |
| `wiki-owned` | GAIA-seeded wiki pages adopter may edit: concepts, decisions, modules, flows, dependencies.                                                | Same as `shared`.                                                                                                                                                                      |
| _(implicit)_ | Adopter-owned. `wiki/log.md`, `CHANGELOG.md`, and any file the adopter created.                                             | Never touched by `/update-gaia`.                                                                                                                                                       |

**Drift handling is identical across all three classes**: a drifted file the release also changed gets a sidecar patch and the working tree is left alone. No class prompts on drift. The class decides two other things: which summary bucket a clean overwrite reports under (`owned` → overwritten, `shared` / `wiki-owned` → merged), and what happens when the release newly owns a path the adopter already has, where `owned` backs the file up and overwrites it while the other two fall through to the ordinary rows.

Sentinel paths (always adopter-owned regardless of what GAIA ships): `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`, `.gaia/packages.json`.

A package's generated `<path>/.claude/settings.json` (`frontend/.claude/settings.json`) ships in the tarball but has no manifest class: it is regenerated from the root settings and the package's `settings.overlay.json` after the merge, never three-way merged. The overlay, `frontend/gaia.package.json`, `frontend/package.json`, and `frontend/CLAUDE.md` are `shared`.

## Flow

The step list, its order, and every command live in the `update-gaia` skill (`.claude/skills/update-gaia/SKILL.md` for the orchestrator, `references/merge-execution.md` for the merge agent it spawns). The shape that order guarantees:

- **Nothing changes before the adopter confirms.** Version resolution, the 1.x refusal, the bundle download and verification, and the migration-note selection all run before the Proceed question. An early exit (up to date, refused, a failed verification, a blocking note, an Abort) leaves no branch and no prune; only the verified update cache remains.
- **Every bundle is verified in the run that reads it.** The baseline and target tarballs are checked against the release's `.sha256` asset, and the trees the merge reads are extracted again from those verified tarballs. A cached tarball skips only the download. The tarball name, `gaia-bundle-<tag>.tar.gz`, is also the 2.0.0 release fence: a 1.6.1 `/update-gaia` asks for `gaia-<tag>.tar.gz`, finds nothing, and stops at its fetch step before it writes a file.
- **A 1.x baseline migrates through the bundled 2.0.0 note.** The 2.0.0 layout moved the app into `frontend/`, and a three-way merge across that move would read every baseline app path as an upstream deletion. The refusal prints a command that downloads, verifies and extracts the v2.0.0 release, and points at the migration note inside it.
- **Migration notes come from the verified target bundle only.** The target release's own selector picks the notes the update crosses, so a mode a later release adds is judged by that release. A blocking note stops the run before anything is branched, pruned or merged, and owns the hop to its own version. After-merge notes are followed after the three-way merge and before the version bump. See [[Migration Notes]] for the note format and what each mode obliges.
- **The adopter sees the full CHANGELOG range** from the baseline to the target, and confirms. On `main`/`master` the update branch is created only after that confirmation.
- **The merge agent merges and reports.** It walks the target manifest with the decision table below, regenerates declared regions and package settings, syncs labels, and prints the summary. Its summary cross-references `**Action required:**`-anchored CHANGELOG entries and surfaces opt-in cleanup suggestions; it never auto-removes a dependency or deletes a file.
- **Setup drift carries new setup features.** The target bundle's feature list is compared with the project's decision records: a standalone feature is applied or asked through its own setup reference and recorded, an admin-gated one met by a non-admin is left owed, and the rest are handed to `/setup-gaia`. See [[Setup Features]].
- **The version is written last.** The manifest copy and the update ping come first, then `.gaia/VERSION`. The adopter then reviews `.gaia-merge/`, runs the [[Quality Gate]], and commits by hand.

## Decision table

For every file `P` in the latest manifest. **Rows match in declared order; the first matching row wins**, which is what keeps a file the release never touched from being overwritten or patched:

| Condition                                                 | Action                                                                 |
| --------------------------------------------------------- | ---------------------------------------------------------------------- |
| Not in adopter, not in baseline                           | **New file**: added, no prompt.                                        |
| Not in adopter, present in baseline                       | Adopter deleted: **skip** (respect intent).                            |
| Not in baseline, `owned`, adopter has the path            | Release newly owns it: back up, then **overwrite** with latest.        |
| `baseline[P] == latest[P]`                                | **Skip** (no upstream change), drifted or not.                          |
| `adopter[P] == baseline[P]`                               | Back up, then **overwrite** with latest (any class).                   |
| `adopter[P] == latest[P]`                                 | **Skip** (already at latest).                                          |
| Adopter drifted, latest changed (any class)               | Write `.gaia-merge/<path>.patch`. Adopter resolves. No prompt.         |

Files deleted upstream (in baseline, not in latest):

| Condition                   | Action                                                          |
| --------------------------- | ---------------------------------------------------------------- |
| Not in adopter              | Already gone. Counted as reconciled, no prompt.                 |
| Present in adopter          | Ask before removing. Never auto-deleted, drifted or not.        |

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

Per managed entry key `k`:

| Condition                                         | Action                                                           |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| GAIA didn't change `k` (`baseline == latest`)     | No-op: adopter's value stands (kept, re-pinned, or **removed**). |
| GAIA changed `k`, adopter still at baseline pin   | Apply latest to the working tree.                                |
| GAIA changed `k`, adopter re-pinned independently | Conflict: leave adopter's value, note both pins.                 |
| GAIA changed `k`, adopter had removed it          | Suggestion: never re-add; note as opt-in.                        |
| GAIA added `k` (latest only)                      | Suggestion: never auto-insert; note as opt-in.                   |
| GAIA removed `k` (baseline only)                  | No-op: if adopter still has it, leave it.                        |

The load-bearing guarantee: a dependency the adopter removed is **never re-added** unless GAIA changed it this release _and_ the adopter opts in, the JSON-key analog of the file-level "respect adopter deletions" rule. Clean applies are written surgically (the changed line only, preserving the adopter's formatting). Re-pin conflicts and dep suggestions go to `.gaia-merge/package.json.notes`. A version-only release touches nothing and emits no notes.

## Audit configuration merge

`/update-gaia` re-renders no workflow and nudges for no audit mode: the audit runs locally, so there is no audit workflow to refresh. The one audit-related file it merges is `.gaia/audit-ci.yml`, a `shared` file handled field-aware (Step 7c of the command) because it mixes GAIA-authored values with adopter-extensible ones. The merge covers the `auditors` roster; top-level keys an older adopter file still carries are ignored. A conflict or suggestion is recorded in `.gaia-merge/audit-ci.yml.notes` rather than written over the adopter's value, mirroring the `package.json` rule above.

`.gaia/project.json` is not in the manifest, so the merge walk never sees it; see [[Project Config]].

## Safety invariants

- **Never touch adopter-owned paths.** Anything not in the manifest is invisible.
- **Never auto-clobber drift.** Drift in any class writes a `.gaia-merge/<path>.patch` and leaves the working tree alone; the adopter resolves it by hand. Nothing about drift prompts.
- **Verify before reading.** No unverified tarball or tree is read, and no migration note is read from anywhere but the verified target bundle.
- **A blocking note stops before any change.** Nothing is branched, pruned or merged when the update crosses a blocking note; the adopter follows the note or stops.
- **Version marker last.** `.gaia/VERSION` flips to the target only after the merge, the after-merge notes, the setup drift, the manifest copy and the update ping. An interruption anywhere before that write leaves the version at the baseline; the next run finds the update branch for the same target and resumes on it, keeping `.gaia-backup/` and repeating the idempotent merge, notes and drift. An interruption between the ping and the version write can repeat the ping, which beats losing it. A version bumped but not committed is detected at the compare step and surfaced.
- **No auto-commit.** `/update-gaia` leaves the working tree dirty; the adopter reviews + commits.

## Rollback

`/update-gaia` does not commit, so the rollback path depends on whether the adopter has already committed the merge.

**Before commit**: discard the entire update:

```bash
git restore --staged --worktree .
rm -rf .gaia-merge .gaia-backup
```

`git restore` reverts every overwritten file (including `.gaia/VERSION` and `.gaia/manifest.json`) to its committed baseline. The sidecar `.gaia-merge/` and `.gaia-backup/` directories are gitignored, so `git restore` does not touch them; the `rm -rf` is the cleanup pass.

**After commit**: revert the commit:

```bash
git revert <update-commit-sha>
```

A single revert undoes the merge cleanly because `/update-gaia` lands its changes as ordinary edits, not a merge commit. The revert restores `.gaia/VERSION` and `.gaia/manifest.json` to baseline alongside everything else.

In both cases the adopter is back at the prior baseline and can retry `/update-gaia` against the same release. Local customizations made AFTER the rollback point survive (`git restore` and `git revert` only undo the update walk's edits, not subsequent commits or unstaged changes touching files outside the manifest).

## When to run

After a new GAIA release is announced (watch releases on `gaia-react/gaia`). Cadence is fully at the adopter's discretion; skipping versions is fine; the three-way diff works with any gap.

## See also

- [[Quality Gate]]: run the gate after the `update-gaia` skill finishes and before committing.
- [[Migration Notes]]: the authoring guide for the notes a release ships in its bundle.
- [[Setup Features]]: the setup feature list and decision records the drift step compares.
- [[Worktrees]]: the shared-state model `.gaia/local/cache/shared/update-gaia/` follows.

<!-- gaia:maintainer-only:start -->
## Communications Guidance (User-Facing Docs)

The update flow is **fully automatic from the adopter's perspective**: the GAIA statusline (`.gaia/statusline/gaia-statusline.sh`) runs `.gaia/scripts/check-updates.sh` as a background refresher and renders a `Run /update-gaia (GAIA <version> available)` indicator from `.gaia/local/cache/shared/update-check.json` when a newer release exists. **Do not mention `/update-gaia`, the `update-gaia` skill, or any manual update step in user-facing release notes, README, CHANGELOG, or marketing docs.** Surfacing a manual command implies adopters need to remember to run it, which is wrong.

The skill and command files in `.claude/skills/update-gaia/` exist as the implementation but must not be promoted as a user-invoked workflow in external-facing copy.
<!-- gaia:maintainer-only:end -->
