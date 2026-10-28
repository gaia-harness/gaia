# Distribution tests

Maintainer-only validation of the post-scrub GAIA tarball. Excluded from the release bundle via category 3 (`.gaia/tests/`). Audience is the machine; every scenario reports PASS/FAIL with a deterministic exit code.

## When to run

- Before cutting a GAIA release (`/gaia-release`).
- When modifying any file that shapes the staged tarball:
  - `.gaia/release-scrub.yml`
  - `.gaia/release-exclude`
  - `.github/workflows/release.yml`
  - `.gaia/manifest.json`
- Automatically: the pre-push hook runs `01-files-present`, the build-staging leak check and `02-marker-strip` on every branch push, and the verification runner's branch and round modes (`bash .gaia/tests/verify-harness.sh`) run them too.

## Layout

`run-all.sh` is the driver, `lib/` holds its helpers, and each numbered `*.sh` at the root is one scenario whose header comment states what it asserts. `fixtures/` holds files a scenario copies into its staged tree; each fixture folder's README says which scenario uses it.

## Running

```bash
bash .gaia/tests/distribution/run-all.sh
```

Walks `*.sh` (excluding `run-all.sh` and anything under `lib/`) in lexicographic order, each scenario's output captured to a log. Scenarios run in two phases: first every scenario concurrently, up to `DISTRIBUTION_JOBS` at a time (the host's CPU count by default; `1` runs them serially), then each scenario whose header carries the line `# distribution-runner: exclusive`, one at a time with the host to itself. It prints a progress line as each scenario finishes, then every log in scenario order, then the PASS/FAIL summary, and exits non-zero on any failure.

Mark a scenario exclusive when it runs the scaffold's own test suite: Vitest already uses every core, and its per-test timeouts fail under a second suite or the concurrent phase running beside it. A scenario that only installs or runs the CLI stays concurrent.

A scenario whose header carries the line `# distribution-runner: skip` runs in neither phase: the summary lists it as `SKIP` and it never decides the exit status. No scenario carries it today; it is for one that should never run automatically.

`bash .gaia/tests/distribution/run-all.sh --changed-paths <file>` is the change-scoped mode pull requests run, with `<file>` listing the changed paths one per line. A scenario whose header carries one or more `# distribution-runner: paths <glob>...` lines then runs only when a changed path matches one of its globs or is the scenario's own file, and otherwise lists as `SKIP <name> (no declared path changed)`. A scenario with no paths line always runs, and a change to a shared harness input (`run-all.sh` names them) runs everything. Declare paths only on a slow scenario, broadly: a missed path costs a red main run, an extra one costs minutes. Every declared glob must also sit inside the workflow's `code:` filter, which `.gaia/tests/lib/distribution-run-all.bats` checks. Without `--changed-paths` the declarations are ignored and every scenario runs.

Scenarios share no state beyond the pnpm store and the Playwright browser cache, both safe under concurrent installs, so a new scenario keeps its scratch files in its own `mktemp` directories.

Individual scenarios are runnable directly:

```bash
bash .gaia/tests/distribution/01-files-present.sh
```

## Prerequisites

- An executable `.gaia/cli/gaia-maintainer` binary: every scenario builds its staging tree through `build-staging.sh`, which refuses without it.
- `.gaia/cli/gaia` binary built and present; the adopter-flow scenarios shell out to it directly, not to `pnpm -C .gaia/cli`.
- Host has `git`, `tar`, `rsync`, `pnpm` on PATH (Layer 0).

## Layered isolation

Layer 0; host pnpm available, scenarios run with the maintainer's PATH (default). Layer 1; PATH-stripped subshell (`03-clean-env.sh`) verifies the bootstrapper extracts cleanly with only `/usr/bin:/bin`. Adopter-flow regressions (`04-`+) run on the host or runner without Docker and exercise the bundled CLI against a writable copy of the staged tree.

### Layer 1: clean-env bootstrap (`03-clean-env.sh`)

Covers tarball extraction and the corepack-driven pnpm bootstrap inside a PATH-stripped subshell with an isolated `$HOME`. Reuses `lib/build-staging.sh` to produce a release-shape tree, tars it, and extracts into a scratch scaffold; the same shape `create-gaia` runs on an adopter's machine. The subshell's PATH is reduced to `/usr/bin:/bin` plus symlinks to the outer `node`/`corepack`/`tar`/`git`, so any maintainer-local `pnpm`/`uv`/`claude` becomes invisible. The scenario asserts pnpm is _not_ visible before bootstrap, then exercises `corepack enable pnpm` followed by `pnpm install --frozen-lockfile`.

Does not cover `/gaia-init` or `/setup-gaia` execution (no Claude in the subshell), full filesystem isolation (a true Docker run is the answer), or non-host operating systems. The `npm install -g pnpm` fallback path inside `create-gaia`'s `ensurePnpm()` is intentionally untested here; exercising it would mutate the host's global npm state with no clean rollback.

Skips automatically if `corepack` is not on the host PATH (Node 16.13+ ships corepack, so this is rare). Skip is reported as a soft PASS so `run-all.sh` summaries stay green on hosts where the layer cannot run. Setting `GAIA_DISTRIBUTION_REQUIRE_COREPACK=1` turns the skip into a failure; `release.yml` sets it on the distribution gate step, so a release run counts this scenario only when the install executed. A run that installed prints a PASS line containing `frozen install ran`, while the skip's PASS line contains `skipped`. When the install fails, the last 40 lines of pnpm's output are printed to stderr under a `FAIL` line.

### Adopter-flow regressions (`04-`+)

Layers 0+1 prove the release tree stages and bootstraps cleanly, but do NOT prove any GAIA-specific flow works in the shipped tarball. Adopter-flow scenarios fill that gap by running the bundled `.gaia/cli/gaia` binary directly against a writable copy of the staged tree.

`04-gaia-init-strip-branding.sh` runs `gaia init strip-branding --title "Test Project"` and asserts two post-conditions: `README.md` is regenerated from `.gaia/templates/README.md` with the title substituted, and the subcommand exits 0 with no stdout per its contract. Catches the failure mode where `release-exclude` accidentally strips a file the subcommand needs (template source); Layers 0+1 stay green; only this scenario fails.

`05-gaia-init-cli-sequence.sh` runs the full deterministic sequence behind `/gaia-init` Step 3; `strip-branding` → `configure-i18n --strip false` → `rename` → `wire-statusline` → `finalize`; and asserts each step's post-conditions on the staged tree. Catches release-exclude drift on every CLI surface the slash command dispatches to: the `existsSync` guards in `configure-i18n`/`rename`/`finalize` mean a missing target file silently no-ops rather than erroring, so this scenario is the gate that turns a no-op into a failure. The `configure-i18n --strip true` path (full i18n removal via the prose `remove-i18n.md` instruction) is out of scope here; that path is orchestrated by the slash command, not the CLI alone.

#### CI

CI entry points:

- **`distribution-harness.yml` (`Distribution harness (no-Docker) (advisory)` job).** On a `pull_request` it runs `run-all.sh --changed-paths` over the merge commit's diff, path-filtered to the harness's inputs (`.gaia/cli/**`, the release inputs, the harness itself) plus every glob a slow scenario declares: the fast scenarios run whenever the filter matches, and each slow one only when its declared paths changed. Every push to `main` runs every scenario, the backstop for whatever a declaration misses, and a red main run opens or updates a `ci-red-main` issue titled for this workflow through `.gaia/tests/report-main-status.sh`, which also holds `/gaia-release` until main is green. The narrowness is backstopped rather than merely tolerated: the two checks the filter can skip whose real input is the whole shipped surface, the leak check and the marker-strip scenario, both run unfiltered in `cli-tests.yml` below. The job reports green when the filter does not match, so it is branch-protection-safe; it is deliberately NOT a declared-required context (see `.gaia/scripts/verify-required-checks.sh`).
- **PR gate inside `cli-tests.yml` (`Shipped-surface leak check (advisory)` job).** Runs `bash .gaia/tests/distribution/lib/build-staging.sh` (the stage, wiki-sentinel reset, scrub leak check, and runtime-dependency phases), then `02-marker-strip.sh`, which builds its own staging tree and asserts the strip left no surviving fragment. About fifteen seconds of work. The marker-strip scenario runs here as well as in the harness job above, and this is the copy that gates: every file its assertions read (`.claude/hooks/lib/*.sh`, `.gaia/scripts/*.sh`, `.gaia/statusline/gaia-statusline-right.sh`, `.gaia/audit-ci.yml`, `.prettierignore`) sits outside the harness job's filter, so a PR adding a `# gaia:maintainer-only:` block to one of them skipped the harness entirely and first met the assertion at `release.yml`. It carries no paths-filter at all, deliberately. `build-staging.sh` reads every tracked file `.gaia/release-exclude` does not withhold, so the only allowlist that describes its inputs honestly is `'**'`, which gates nothing while still costing a filter step and a `pull-requests: read` round trip, and the complement is a denylist shape both `.gaia/release-scrub.yml`'s `workflow-denylist` check and `.gaia/scripts/tests/workflow-filter-coverage.bats` reject. Running unfiltered is what makes a leak in any shipped file fail at PR review rather than at tag push in `release.yml`. Advisory and deliberately NOT a declared-required context, with `contents: read` as its whole permission set; it admits `workflow_dispatch` so an audit self-heal re-dispatch stamps a real conclusion instead of a bare `skipped`.
- **Pre-publish gate inside `release.yml`.** The tag-triggered release workflow runs `bash .gaia/tests/distribution/run-all.sh` after the staging + scrub + runtime-deps phases and before the tarball is built. If any scenario fails the release halts; the tarball never builds and `gh release create` never runs, so a broken release cannot publish. This is the production gate.

Ad-hoc verification of harness changes on a feature branch (no tag) runs `bash .gaia/tests/distribution/run-all.sh` locally, or dispatches `distribution-harness.yml` (a full run).

## See also

- `wiki/concepts/Release Workflow.md`; what the staged tarball is and how it's built.
