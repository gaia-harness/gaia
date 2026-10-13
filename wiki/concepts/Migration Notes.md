---
type: concept
status: active
created: 2026-10-13
updated: 2026-10-13
tags: [concept, release, update-gaia, migration]
---

# Migration Notes

A migration note is a markdown file of instructions that a release ships inside its own bundle for `/update-gaia` to follow when a project crosses that release. A note carries the steps a three-way file merge cannot do: moving a directory tree, rewriting a config, removing a retired feature. The notes live in `.gaia/migrations/`; this page lists none of them, the folder is the list.

## File and frontmatter

A note is `.gaia/migrations/<x.y.z>.md`. Each of x, y and z is `0` or a digit run with no leading zero. The file opens with exactly three LF-terminated lines: `---`, then `mode: blocking` or `mode: after-merge` (unquoted, nothing after the value, no trailing space), then `---`. The file has no byte-order mark and no carriage return.

`.gaia/scripts/select-migration-notes.sh` enforces this and fails closed. The folder holds nothing but notes: any other entry (a README, a dotfile, a directory, a symlink, a name that is not a version) or a note it cannot read is malformed. The whole folder is validated whatever the version range, and a malformed entry makes the selector exit non-zero with one stderr line per entry, so `/update-gaia` stops before anything is changed.

## How `/update-gaia` selects notes

`/update-gaia` selects notes only from the checksum-verified target bundle, by that bundle's own selector. It never reads the project's working tree for notes and never fetches one from a URL, so a mode a later release adds is judged by the release that added it. A note is selected when its version is above the baseline and at or below the target, and the notes run in version order. The skill (`.claude/skills/update-gaia/SKILL.md`) owns the steps, and [[Update Workflow]] shows where selection sits in the flow.

## What each mode obliges the author to do

**`after-merge`.** `/update-gaia` follows the note after the three-way merge and before the version bump. The note must be idempotent, because an interrupted run resumes and repeats it.

**`blocking`.** `/update-gaia` stops the update before anything is branched, pruned or merged, tells the user the update crosses the note, and follows it only on the user's yes. The note therefore:

- owns the hop to its own version, ending by writing `.gaia/VERSION` and the manifest at its version;
- provides the seam where the in-range after-merge notes below it are followed: after its own merge step and before its version write;
- when its version is below the run's target, downloads and verifies its own version's bundle, because the run verified only the baseline and target bundles.

After-merge notes above a blocking note wait for the next run.

## Setup features added later

A note does not carry a new setup feature to existing projects. A setup feature added after 2.0.0 ships standalone, and `/update-gaia` reaches it through its drift step; see [[Setup Features]].

## Worked example: the 2.0.0 note

The 2.0.0 note is the blocking example. A 1.6.1 project cannot run its own `/update-gaia` across the layout change, so the first line of the v2.0.0 release body carries a literal fetch-and-verify command. A 1.6.1 session that reads the line offers the migration, and only on the user's yes runs the command, which downloads the release bundle, checks it against its `.sha256` asset and extracts it. The session then follows the note from the extracted, verified bundle. Read the note itself for the shape a blocking note takes.

<!-- gaia:maintainer-only:start -->
## Maintainer facts

- Each new note gets a per-file ship answer from `/distribution-vet` in the pull request that adds it, before that pull request's first push. No glob answer exists, and the runtime-dependency check refuses a push whose shipped script names an unanswered path.
- `.gaia/release-scrub.yml` exempts `.gaia/migrations/**` from the excluded-refs check alone, because a note must name the paths it deletes or moves.
- `.gaia/audit-ci.yml` declares `.gaia/migrations/**` unowned: no audit member has a lens for instruction prose.
- The release-body routing line is defined once, in `.gaia/scripts/compose-release-body.sh` (`--routing-line`). Every check compares against that output.
<!-- gaia:maintainer-only:end -->

## See also

- [[Update Workflow]]: where note selection and the after-merge step sit in `/update-gaia`.
- [[Setup Features]]: the other thing a release carries to an existing project.
