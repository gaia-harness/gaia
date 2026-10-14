---
type: concept
status: active
created: 2026-09-20
updated: 2026-10-13
tags: [concept, gaia, scripts]
---

# GAIA Scripts

`.gaia/scripts/` is GAIA's shell layer: the shared libraries its hooks and skills source, the deterministic checks its gates run, and the small command-line helpers its workflows shell out to. It is flat by design, one level of files at the root plus a handful of single-purpose subdirectories, and the flatness is a tested contract rather than a convention, so a script is added beside its siblings rather than filed under a new folder.

The directory carries one structure, the name prefix, and the prefix tracks what a script is for. This page describes each family at that level and names no individual file, so adding a script to a family cannot make it false. Two other sources answer the per-file questions:

- **What a file is.** Its own header comment states what it does, who invokes it, and its exit contract. Read the header, not a table.
- **Whether it ships.** `.gaia/manifest.json` lists every shipped file. A family below that reads "mostly ships" or "mixed" has members on both sides of the release boundary.
<!-- gaia:maintainer-only:start -->
  In GAIA's source, `.gaia/release-exclude` owns the withheld side, and its comment above each withheld entry says why. See [[Bundle-time Scrub]] and [[Release Workflow]].
<!-- gaia:maintainer-only:end -->

A `*-lib` file is sourced and runs nothing on its own. Everything else is run as a command by whatever the family's invoker is.

## Root families

| Family | What it does | Invoked from | Ships |
|---|---|---|---|
| `audit-` | The Code Audit Team's machinery: scope resolution, digests, the single writers for clearance markers and findings sidecars, the audit loop's state, evaluation and records, the dispositions check, the no-op detector, and the Light-route helpers. See [[Code Review Audit Agent]] and [[PR Merge Workflow]]. | Agent definitions, audit hooks, CI, the merge workflow | Mostly ships |
| `check-` | Deterministic checks of a repository invariant: hook command rooting, settings drift, tech-debt filing metadata, the update refresher the statusline starts, and maintainer-side invariant checks over the harness itself. | Hooks, skills, the statusline, GAIA's own invariant harness | Mixed |
| `lint-` | Guard lints over GAIA's own shell and workflow YAML for classes shellcheck cannot model. | The shell lint runner and CI | Maintainer-only |
| `debt-` | The tech-debt backlog: ordering and clustering, batch budgeting, dedup, argument parsing, path probing, stale-claim detection, and the statusline count. | `/gaia-debt`, the file-tech-debt skill, the statusline | Ships |
| `usage-` and `token-` | The usage ledger and its readouts: recording, merging, rendering, and the pricing definitions and rate card the readouts share. Opens no network connection. | Hooks, the statusline, workflows that record or read cost | Ships |
| `verify-` | Drift checks of a repository state against an external authority: the audit roster, the committed CLI bundles, the required-checks ruleset, vendored skills. | Run by hand, CI, release preflight | Mixed, mostly withheld |
| Dev-server plumbing (no shared prefix) | Per-worktree port allocation, background server lifecycle, Storybook launch, a smoke check, and the package prerequisite step. | Skills, the pre-commit hook, the quality gate | Ships |
| `*-lib` shared libraries | The one definition of a cross-cutting rule: main-checkout resolution, branch naming, ledger paths, the state registry, the context checkpoint, the GitHub artifact breadcrumb, the awk interpreter and guard scaffolding. Each is read through whatever sources it. | Sourced by hooks and scripts | Mixed |
| Workflow helpers (no shared prefix) | Single-purpose commands a skill or workflow shells out to: plan archive and resume point, the merge wait, member resolution, findings posting, fitness ownership and publish, the knowledge inventory, summary verification, worktree linking, and the chore(deps) predicate. | Skills, slash commands, the merge workflow, hooks | Mostly ships |
| Release and test tooling (no shared prefix) | Release leak assertion, release-body composition, CLI auto-bundle, vendoring, bats runners, and the changed-file to bats-suite mapping. | `release.yml`, pre-commit, the bats runners, the audit gate | Maintainer-only |

## Subdirectories

The root holds the shell layer; each subdirectory holds one family that is not root shell, or is not a script at all. None is a second tier of the root, and nothing that holds this page to the tree descends into any of them.

| Directory | What it is |
|---|---|
| `spec/` | The spec and plan lifecycle: id allocation, the ledger and its lock, reconcile and archive passes, the UAT gate and divergence check, title normalization, and the working-doc-id scan. Invoked by `/gaia-spec`, `/gaia-plan`, and their close flows. |
| `audit-ledger/` | The Node writer that appends a worthiness verdict to the audit ledger. |
| `classifier/` | The Node helper that classifies a test as deterministic or not. |
| `red-ledger/` | The Node extractors that read test and story signals out of a RED run. |
| `lib/` | Helpers sourced or imported by a root script rather than run on their own. |

<!-- gaia:maintainer-only:start -->
`tests/` is separate, and separate on purpose. It holds the bats suites that guard the root scripts, and it is far larger than everything above it put together. A suite there is the blocking runner for the guard beside it, which is why a guard's conformance lives next to the guard rather than in the general test tree. It is not described here: a suite is discovered from the script it names.
<!-- gaia:maintainer-only:end -->

## Adding a script

A new root file takes the family prefix that matches what it does, and `*-lib` for a file that is sourced rather than run. A script that fits no family takes a plain descriptive name. Its header comment is its documentation; this page needs no edit unless the script opens a new family. The naming rule is `.claude/rules/coding-guidelines.md`.

**Do not reorganize the directory into subfolders.** The single-level glob `.gaia/scripts/*.sh` is a contract several places depend on by value, not a hazard to be tidied away: it is a literal registry entry, and it is what a worktree provisioning step chmods through. A new subdirectory leaves both reading a tree that no longer matches, silently. Reference density compounds it: each member of a family is named across dozens of files, so relocating one family is a several-hundred-file rename for no functional gain.

<!-- gaia:maintainer-only:start -->
In GAIA's source a bats suite asserts the glob too. This directory has already paid for a location change once, recorded in GAIA's own release health taxonomy: moving it across the release boundary added it as a manifest-owned tree without adding it as a scan target to either distribution-boundary primitive, and the repair covered the one file its finding named rather than the tree it had un-excluded.

Three further decisions ride with a new root script in the maintainer repository, and each one is a real edit somewhere else:

- **Ship or withhold**, through `/distribution-vet`. The release CLI refuses to produce a manifest until every newly-shipping file has an answer, so this one cannot be skipped, only deferred to the release that trips over it.
- **Whether a CI job's paths filter arms on it.** A scan surface a job reads that its filter does not arm on reports green having run the assertion zero times, which is the arming-stage failure `.claude/rules/guards-must-fail.md` names: adding a root to a scan is always two edits, the scan and the filter. The bats shards are discovered by glob rather than enumerated, so a sibling suite needs no registration of its own. Read a filter entry for which question it answers before adding one, because the two look alike and are not: whether the job runs at all, and, where a job narrows further, which of its legs run.
- **Whether it folds into `.gaia/tests/shell-lint.sh`** alongside the other guards shellcheck cannot model, and whether it is advisory or blocking there.
<!-- gaia:maintainer-only:end -->

## Why a guard must be able to fail

A guard (a test assertion, a lint script, a CI condition, a hook precondition) is only evidence of anything when red is reachable. A guard that cannot go red says nothing, in the exact voice of one that checked and approved. The failure is silent by construction: it surfaces as a construct nobody defends, discovered when the construct breaks in a place the guard was believed to cover. Three independent stages can lose a guard its power to fail; sound at two of three still proves nothing.

- **Discovery, the input set.** The step that builds the guard's own input set can drop an element and say nothing: a glob that misses an extension, an over-reaching `find` prune, a manifest-derived list that does not enumerate every member, a tracked-file listing that cannot see a file not yet tracked. An empty or short input set reads exactly like a clean pass. The untracked variant is the sharpest case: a new guard and its sibling suite are both untracked at the moment the author first runs the guard to check the tree is clean, and those two files are the ones most likely to carry the class deliberately (a guard's header quotes its own class as worked counter-examples, its suite spells the class out in fixtures), so the very first run reports clean over the set most likely to red.
- **Arming, which inputs reach the check.** The check is correct wherever it runs, but its arming condition covers less than the surface the rule governs: a path filter narrower than the files the rule binds, a changed-files list omitting a directory, a refinement keyed to an optional field's presence. The diff that creates the obligation is the one that skips the check.
- **Match region, what the check accepts.** The assertion runs on the right input but admits a region wider than the construct its own name pins: a needle satisfied by surrounding boilerplate or unrelated prose, a snapshot standing in for the behavioral claim beside it, an exit-code check where the message content is the actual claim. Corrupt the construct and the check stays green.

Correct pattern: prove the guard can fail before relying on it (break the construct, run the guard, confirm red; restore, confirm green; commit an awkward-to-hand-break fixture instead), assert the input set is non-empty and the expected size (derived from the same source the rule binds to, never a hand-maintained parallel list), derive the arming condition from the surface the rule governs, and pin the match region to the construct (anchor the pattern, match the full value, assert on the field carrying the behavioral claim).

Where discovery reads tracked files, the new guard and its suite must be visible to it before the run that validates them: `git add` them first for an index-reading discovery (`git ls-files`, `git grep`); a committed-ref discovery (`git ls-tree HEAD`) needs the commit itself. Run the discovery command on its own and confirm the two new paths appear in its output, which is the only thing distinguishing a clean pass from a pass over a set that never held them.

<!-- gaia:maintainer-only:start -->
Mechanism-level cases on the `.bats` surface, where an assertion's status never reaches the test result at all, are `.claude/rules/bats-assertions.md`.
<!-- gaia:maintainer-only:end -->

See [[Claude Hooks]], [[Code Review Audit Agent]], [[PR Merge Workflow]], [[Quality Gate]].
