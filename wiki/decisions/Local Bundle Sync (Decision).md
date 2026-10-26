---
type: decision
status: active
created: 2026-10-27
updated: 2026-10-27
promoted_at: 2026-10-26T20:41:00Z
promoted_hash: sha256:4bf391fceaabb84cb26394c99283cd6cc30096964c3572a1db70f6545dc524f3
pr_number: 3110
tags: [update-gaia, distribution, promoted]
---

# Local Bundle Sync

`/update-gaia --local <tarball>` merges a GAIA bundle built from an unreleased, committed GAIA checkout into a 2.x project through the same updater a release update runs: the same manifest-class three-way merge, conflict flow, migration notes, setup drift and record steps. A pre-release sync of a real project therefore tests the shipped merge code on a dev bundle, and no second merge implementation exists to drift from it.

## Decisions

The local path is reached only through the explicit `--local` argument. Without it, on a project that carries no build record, `/update-gaia` resolves, downloads and verifies the latest release exactly as a release update always does.

## Build identity

A local bundle is identified by its build id, `dev.<sha>`: the first twelve hex characters of the commit it was built from. The project's version file keeps a plain `x.y.z` release version, because many readers of that file parse it strictly and several fail silently on a suffix. The build is recorded instead in a committed sidecar, the `VERSION-dev` file in the project's `.gaia` folder, which only `/update-gaia` reads. Wherever the updater needs a tag (the update cache key, the run's target tag, the update branch prefix, a deferred item's baseline tag), a local build uses the prerelease-shaped tag `v<core>-dev.<sha>`, where `<core>` is the bundle's plain release version. That tag never reaches the version file.

The build record is adopter-owned: the release manifest never lists it, the merge walk never overwrites or flags it, and the release manifest build refuses a GAIA source tree that tracks it, because a release tarball is staged from tracked files.

## How a local sync runs

1. **Source.** The tarball path is resolved to an absolute regular file. The archive must hold a single top-level directory with a plain `x.y.z` version file and a well-formed build record; members are listed before extraction, and absolute, parent-relative, symlink and hardlink entries are refused. A refused tarball leaves no cache entry. An accepted one is copied with a locally computed checksum into the update cache under its dev tag and extracted there. That checksum guards only against cache corruption; it says nothing about origin, so the run labels the source a local, unverified bundle in the Proceed question and in the review summary.
2. **Version gate.** A bundle whose release version is below the project's is refused before any worktree, branch, prune or merge, naming both versions. A bundle whose build id equals the project's recorded build is reported already synced and changes nothing. A same-version bundle with a different build id is the normal case and proceeds, since the GAIA source keeps the last release's version during development.
3. **Baseline.** When the project carries a build record, the recorded build's dev tag is the merge baseline, resolved from this machine's update cache only and never downloaded. When that build is no longer cached, the run falls back to the plain release of the project's version and names the fallback in the Proceed question. A release used as the baseline, or a deferred item's bundle, is fetched and verified against its published checksum exactly as on a release update.
4. **Notes.** Migration notes at or below the bundle's release version run exactly as a release update selects them. Each newer note the bundle carries is named "not run, follow it by hand to test it" in the Proceed question and the review summary, and an unreleased blocking note never runs.
5. **Merge to record.** The merge, conflict flow, after-merge notes, setup drift and manifest copy are the release update's own. A local sync sends no adoption ping, writes no fitness blend record, and prints the build commit in place of a changelog range. The version file gets the bundle's plain release version and the build record gets the build id, written last so an interrupted run resumes.

A local sync's update branch is `update/v<core>-dev.<sha>-<timestamp>`. Because a same-version sync never changes the version file, branch-state classification on a local run compares the build record against the target build id to decide whether the update is resumable, applied or committed; a release run treats the update as recorded once the build record is gone. A release run's branch lookup skips local-sync branches.

## After a local sync

The next update, local or release, merges against the synced build while this machine still caches it, so only the changes between the two builds reach the project. A release update reads the recorded build as its baseline, bypasses the "up to date" exit when the project's version equals the latest release, and removes the build record in its record step. The cache prune keeps the run's baseline tag, dev or release, alongside the latest release and every deferred item's tag. Dev tags are ranked by semver, where `v2.2.0-dev.<sha>` sorts below `v2.2.0`; nothing ranks cached tags with `sort -V`, which orders them the other way.

A deferral made on a local sync records the run's baseline tag, the tag the deferred file was last merged against, so the next run merges that item against the same tree. Rolling back a broken dev sync is a revert of its update pull request.

<!-- gaia:maintainer-only:start -->
## Building a local bundle (maintainer)

A release-excluded builder beside the distribution staging build produces the tarball. It refuses a checkout with uncommitted tracked changes ("commit first, any branch is fine"), so the build id truthfully identifies the content; stages the tree the way a release does, regenerating the manifest into the staged tree only and checking CLI bundle freshness; writes the build record into the staged tree after the scrub and manifest steps; and tars it with its checksum in the release tarball's shape. The builder never ships to adopters.
<!-- gaia:maintainer-only:end -->

## Decision: a sidecar build record, not a version suffix

The build could have been recorded in the version file itself, as a `+dev.<sha>` build suffix. That was rejected: a sweep of the version file's readers found ten that reject a `+` suffix, three of them silently, and a version ordering that would rank a suffixed version above its release. Keeping the version file a plain release version and recording the build in a separate committed file leaves every reader untouched, at the cost of one file `/update-gaia` must treat as adopter-owned and remove on the next release update. The prerelease-shaped `-dev` tag, rather than a `+` build tag, is what the updater's existing tag validators already accept and what semver ranks below its release.

The local path ships to adopters behind the explicit opt-in rather than living in a maintainer-only section, because the project it serves runs the scrubbed adopter bundle, where a maintainer-only section would never arrive.

## Divergence

The stated contract said a `-dev` tag sorts below its plain release "under sort -V and semver". GNU and BSD `sort -V` rank `v2.2.0-dev.<sha>` above `v2.2.0`, so the shipped code ranks cached tags by semver only and uses `sort -V` on no tag. The stated contract also left open which tag a deferral records on a local sync; it records the run's baseline tag, never the target build's.

## Related

Promoted from the same source:

- [[Local Bundle Sync (Concept)|Local Bundle Sync]]
