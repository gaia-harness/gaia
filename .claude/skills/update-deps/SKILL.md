---
name: update-deps
description: Remediates dependencies in place of Dependabot version and security updates. Discovers outdated packages and open security advisories, resolves advisories (in-range refresh, chain-head bump, security-floor override, or alert dismissal), audits overrides, applies migrations for major bumps, and runs the quality gate. Trigger when the user clicks the statusline `📦 /update-deps` indicator or asks "update dependencies", "bump deps", "run dependabot", "fix Dependabot alerts", "fix security advisories".
---

Contents: Pre-flight: Worktree check; Pre-flight: Branch check; Package layout; Flags and run modes; Companion groups; Phase 1: Discover, preview, decide (orchestrator); Branch creation (after discovery); Override audit + Wave A: Haiku agent; Phase 5: Wave B (per-group major bumps); Phase 5b: Transitive refresh (Haiku agent); Phase 5c: Security resolutions; Phase 6: Post-update override audit; Phase 7: Final report; Phase 8: Publish.

Dependency remediation: outdated packages and security advisories, through one quality gate, in one record. Discover outdated packages and open advisories, preview them (advisories first, ranked) so you can snooze what you are not ready for, audit overrides, apply codebase migrations for major bumps, resolve dependency conflicts, refresh transitive dependencies within range, resolve each advisory by the least invasive method that clears it or accept it by dismissing its alert, and run the quality gate. In CI it runs unattended (no preview); interactively it shows the preview first. On a `main`/`master` run it works in its own worktree on its own branch, opens the PR, merges it once checks are green, then cleans up locally; on any other branch it pushes and leaves the PR to you. Run by `/gaia-init`, it leaves its changes uncommitted for the init commit.

## Pre-flight: Worktree check

This wrapper writes a new `pnpm-lock.yaml` and opens a PR, which belong on the main checkout or in this command's own update worktree, not a per-SPEC worktree branch. The guard keeps the command out of every other linked worktree, rejecting hard with a message that surfaces the cached state from main so the user knows whether action is even pending. It admits only the command's own `deps/` update worktree, so a re-run continues there.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
. .gaia/scripts/update-state-line-lib.sh
gaia_refuse_if_worktree "/update-deps" gaia_update_deps_state_line "deps/" || exit 1
```

If the detection does not fire, fall through to the existing `## Pre-flight: Branch check` section.

## Pre-flight: Branch check

Decide the run mode in this order. The first matching mode wins, and the `/gaia-init` check comes first so it holds whatever the worktree decision would otherwise be.

1. **`/gaia-init` invoked the run.** Set `INVOKED_BY_INIT=true` and `SHOULD_CREATE_WORKTREE=false`, which disables worktree creation for the whole run. A fresh project has no remote yet, so a branch's push, PR and merge cannot run; the run applies its changes on the current branch and leaves them uncommitted, and `/gaia-init`'s own init commit carries them. It creates no worktree and no branch.
2. **`CI=true`** (set by GitHub Actions, GitLab CI, CircleCI, and most CI providers). Set `SHOULD_CREATE_WORKTREE=false`: the run creates no worktree and no branch, because the workflow owns branch management and pre-creates the appropriate branch before this skill runs.
3. **Inside its own update worktree.** Read the branch with `git branch --show-current`. When it starts `deps/` and `bash .gaia/scripts/main-root-lib.sh --is-worktree` exits 0, this is a worktree run in place. Set `SHOULD_CREATE_WORKTREE=false`. Read `<worktree path>` with `git rev-parse --show-toplevel` and `<main checkout path>` with `bash .gaia/scripts/main-root-lib.sh`, each carried as a literal. Wait for provisioning before discovery, because the session-start hook re-provisions the tree on every entry:
   ```bash
   bash .gaia/scripts/provision-wait.sh --tree <worktree path>
   ```
   Handle the result as `references/worktree.md` step 4 does, with one difference: this run did not create the tree, so exit 3 (`INSTALL_FAILED`) is reported and the run continues. Discovery reads this worktree's manifests. The run creates no worktree, publishes as a worktree run (the PR is opened or reused, merged when green, and cleaned up by path), and never takes the push-only arm of Phase 8.
4. **On `main` or `master`.** Set `SHOULD_CREATE_WORKTREE=true` but **do not create the worktree yet**: creation is deferred until the run has confirmed work, right after the Phase 1 decision when the apply set is non-empty or the security plan has a resolution to apply, before anything is installed, or before Phase 5b on a refresh-only run (see Branch creation). Creating a worktree when there is nothing to update pollutes the branch list. Read the main checkout's root once with `git rev-parse --show-toplevel` and carry it as the literal `<main checkout path>`. Before discovery, check for an update worktree a run left behind:
   ```bash
   git worktree list --porcelain
   ```
   When any record holds a `refs/heads/deps/` branch, or a `refs/heads/worktree-deps+` branch (a run interrupted between creating the worktree and renaming its branch), stop before discovery and create nothing. Report its path and branch with two next steps: re-run `/update-deps` inside it, which continues there; or remove it with the removal commands in the worktree notice (`references/worktree.md`, `## The worktree notice`).

   Then, still before discovery, run the pull gate:

   ```bash
   . .gaia/scripts/main-only-lib.sh
   gaia_pull_gate "/update-deps"
   ```

   On a non-zero exit, read `.claude/skills/update-gaia/references/pull-gate.md` and follow it with `/update-deps`, this run's original arguments and the exit code, before anything below creates a branch, worktree, claim or SPEC id.
5. **Any other branch.** The run works in place: no worktree, no branch, push only. `SHOULD_CREATE_WORKTREE=false`, and `<main checkout path>` is `git rev-parse --show-toplevel`.

In modes 1 and 2 `<main checkout path>` is also `git rev-parse --show-toplevel`: the cache bust in Branch creation needs it in every mode.

## Package layout

The repository is a pnpm workspace with one lockfile at the root. App dependencies (everything the React app imports or builds with) are declared in `frontend/package.json`; harness dependencies (lint-staged, prettier, `typescript` for the harness helpers) and the `gaia.updateDepsHold` map are in the root `package.json`. `overrides:` and `minimumReleaseAge` stay in the root `pnpm-workspace.yaml`. Add or bump an app dependency with `pnpm -C frontend add <pkg>@<spec>`, a harness dependency with `pnpm add -w <pkg>@<spec>` from the root. The quality gate runs the root `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm pw`, and `pnpm build`, which proxy to `frontend`.

## Flags and run modes

Parse the arguments before any other work. `--security` together with `--scope` refuses at once, before discovery, printing `/update-deps: --security and --scope cannot be combined; pass one or the other.` and stopping.

| Run                                    | Preview                                           | Phase 0                     | Waves                         | Phase 5b                    | Security phase | Phase 6                                                  | Acceptance       | Reads alerts          |
| -------------------------------------- | ------------------------------------------------- | --------------------------- | ----------------------------- | --------------------------- | -------------- | -------------------------------------------------------- | ---------------- | --------------------- |
| Interactive, no flag                   | yes, Security section first                       | yes                         | yes                           | yes (default)               | applies        | keys retained in Phase 0 plus every security override    | ask per advisory | yes                   |
| Interactive `--security`               | Security section plus the chain-head bumps needed | no                          | only those chain-head bumps   | no                          | applies        | only if a security override landed, those overrides only | ask per advisory | yes                   |
| `--scope <group>`                      | no                                                | no                          | the group                     | no                          | report-only    | unchanged                                                | no               | yes (enrichment only) |
| `CI=true` (with or without --security) | no                                                | yes / no under `--security` | yes / none under `--security` | yes / no under `--security` | report-only    | unchanged                                                | no               | no                    |
| `--security --scope`                   | refused, naming both flags                        |                             |                               |                             |                |                                                          |                  |                       |

**Report-only.** Under `CI=true` and `--scope <group>`, which both skip the preview, the security phase is report-only: every advisory is listed still open with `report-only run`, and the security phase adds, edits, and removes no `overrides:` key and applies no advisory-driven bump. The existing Phase 0 and Phase 6 override audit is unchanged in those runs and may still prune an obsolete key exactly as it does today, so report-only is a property of the security phase, not a promise that the whole run leaves the `overrides:` map untouched. In CI the advisories call runs with `--no-alerts` (the verb also refuses alerts by itself under CI), so no Dependabot output reaches the run.

**`--security`** runs Phase 1 (preview), the Wave A/B agents only for the chain-head bumps an accepted advisory needs, the security phase, Phase 6 only when the security phase landed an override, Phase 7, and Phase 8. It runs neither Phase 0 nor Phase 5b, and leaves every other outdated package untouched.

### --scope &lt;group-name&gt;

When invoked with `--scope <group-name>` (e.g. `/update-deps --scope react-router`):

- Skip Phase 0 (override audit), out of scope for a single-group run.
- Skip the preview, no preview runs in `--scope`; the group's members are
  the discovery payload's entries whose `group` is the named group.
- Skip wave classification, the run is implicitly a single group; treat it
  as Wave A if all members are minor/patch, else Wave B.
- Wave A / Wave B still apply, scoped to the named group's members
  in the package manifest that declares them (see Package layout).
- Skip Phase 5b (transitive refresh), a single-group run does not re-resolve
  the whole tree.
- The security phase is report-only (see Report-only above).
- Quality gate, return value, and final report still run.

Invoked manually, one group per run, when a maintainer wants a single
major-bump group's own PR rather than the combined Wave A/B run.

## Companion groups

`gaia update-deps run` owns the group table: every emitted entry carries its
resolved `group`, and a group's members that a manifest declares but `pnpm
outdated` did not flag are pulled in with it. **When any member of a group is
outdated, all members present in a manifest update together**, so a group
moves as one unit (and snoozes as one unit).

After any change to the installed `msw` version (Wave A or Wave B), run `pnpm -C frontend msw:init` (`pnpm -C frontend exec msw init` when the project has no such script) so the regenerated `frontend/public/mockServiceWorker.js` joins the change; msw 3 has no postinstall that keeps it current.

Packages not matched form singleton groups. `typescript` is deliberately one of
them: a compiler bump and an ambient type-definition bump (`@types/node`) carry
independent risk and independent migration guides, so they never move as a unit.

## Phase 1: Discover, preview, decide (orchestrator)

Discover deterministically via the CLI primitive, the single source of truth for
grouping, the ESLint 9.x cap, the `gaia.updateDepsHold` config hold, and the
release-age cooldown (all already applied). The two payloads land at fixed paths
under `.gaia/local/cache/shared/`, so every block stays a plain command that
runs the same inside a worktree; every later reference to a payload is that
literal path:

```bash
mkdir -p .gaia/local/cache/shared
```

```bash
.gaia/cli/gaia update-deps run --emit-updates .gaia/local/cache/shared/update-deps-updates.json
```

```bash
.gaia/cli/gaia update-deps advisories --emit .gaia/local/cache/shared/update-deps-advisories.json --updates .gaia/local/cache/shared/update-deps-updates.json
```

Under `CI=true` add `--no-alerts` to the advisories call. It runs in every mode and writes a payload even when no source answered (`source: "unavailable"`). Keep from it, for later phases: the `source` and `reasonText`, whether alerts were read (`source` is `dependabot`), `rejectedCount`, the opening advisory key set (every `advisories[].key`, every `auditKeys` entry, and every `dismissedGhsas` entry), and the opening `dismissedGhsas`. `auditKeys` lists every key the opening `pnpm audit` reported, so in alerts mode it also carries the advisories already in the lockfile that no open Dependabot alert backs; without it the final-tree `pnpm audit` would read those as introduced by this run.

### Global tools (before any exit below)

Run this once, right after the discovery call and before every exit branch
that follows (`total_count` `0`, `--scope`, the Skip answer), so it also runs on
an otherwise up-to-date run:

```bash
.gaia/cli/gaia update-deps global-tools
```

It prints `{"rows":[...]}` and exits 0 even when a probe fails. Keep the
playwright-cli row for the Phase 7 `### Global tools` section. This step never
changes `outdatedCount`, never writes the update-check cache, and never creates
a branch by itself: a global tool cannot be cleared through pnpm, so it stays
out of the discovery payload and the statusline count.

- **In CI (`CI=true`)**: report the row only. Never run `npm install -g`.
- **Under `--scope`**: report the row only.
- **`status` is `not-installed`**: report `not installed, skipped` with the
  row's `installCommand` as text. No prompt, no error.
- **`status` is `current` or `unknown`**: report the row only.
- **Interactively with `offerInstall: true`**: show the row, then ask with
  `AskUserQuestion` (single-select): **Upgrade playwright-cli to `<latest>`
  globally** or **Skip**. Only after the Upgrade answer, run
  `npm install -g @playwright/cli@latest`. Record `upgraded` or `declined` as
  the action taken.

<!-- gaia:maintainer-only:start -->

### Vendored skill sync (GAIA maintainer repository, before any exit below)

`frontend/.claude/skills/playwright-cli/` is a verbatim copy of the upstream
package's skill folder, pinned by `.gaia/vendor/playwright-cli.json`. This phase
also runs on an otherwise up-to-date run. Compare that marker's `version` with
the global-tools row's `latest`. When `latest` is unknown or equal, report
`Vendored skills: current` (or `unknown`) and move on. Otherwise:

1. When `SHOULD_CREATE_WORKTREE=true` and no worktree exists yet, run
   `references/worktree.md` now. The re-vendor and verify below, the rest of
   discovery, the preview and the decision all continue in that worktree.
2. Re-vendor, then verify offline:
   ```bash
   bash .gaia/scripts/revendor-playwright-cli.sh --version <latest>
   bash .gaia/scripts/verify-vendored-skills.sh
   ```
3. Keep the result for the Phase 7 `Vendored skills` row. A re-vendor diff is
   something Phase 8 publishes even when no package moved.

<!-- gaia:maintainer-only:end -->

Read the payload. **A zero `total_count` with at least one advisory** (a
non-empty `advisories[]`) is a real run, not "nothing to do": interactively it
goes to the full preview below (Security section, then the transitive refresh
line), never to the refresh-only prompt and never to `All packages are up to
date.`; in CI it continues as a refresh-only run whose security phase is
report-only. With zero advisories the paths below stand.

If `total_count` is `0` and `advisories[]` is empty, print `All packages are up to date.`
(the Phase 7 `### Security` section, and `### Global tools` when it has a row to show, are still printed first). Under `--scope`, exit (no branch, no changes). Otherwise the apply set is empty
and the run is **refresh-only** (see Decision): in CI it proceeds straight to
Phase 5b; interactively, print `Transitive refresh: re-resolve every
transitive dependency to the newest in-range version past the release-age
window; reverted whole if the quality gate fails.` and ask with `AskUserQuestion`
(single-select): **Refresh transitive dependencies** (default, first option) or
**Skip** (exit now, no branch, no changes, no ledger write). Each `wave_a[]` and `wave_b[].packages[]` entry
carries `bucket` (`patch` | `minor` | `major` | `nonsemver`), `current`, `latest`,
`is_pinned`, and `kind` (a `wave_a[]` entry also carries `group`; a `wave_b[]` element carries `group` once). `total_count` is the genuine-upgrade count;
`actionable_count` is for the statusline only (it already subtracts local
snoozes), ignore it here.

`snoozed[]` lists the groups the human deferred earlier that still match the
currently-offered targets. Each entry carries `group`, `targets`, `snoozed_at`,
and `resurfaces_at` (ISO stamp when the snooze lapses). Build `snoozedGroups`,
the set of their `group` ids, this is what you mark and default-skip below. It
is empty in CI and whenever no active snooze matches the current offer.

`skipped[]` entries with `reason: "held"` are packages capped by the committed
`gaia.updateDepsHold` map in the root `package.json` (a durable version ceiling, distinct
from a snooze: it holds in CI too and never lapses until the maintainer lifts
it). They are already excluded from both waves, never installed, so nothing to
apply. Surface them once (see Preview) so the maintainer remembers a hold is
active.

A hold caps only the package it names; a coupled sibling in the same companion
group (e.g. `@vitejs/plugin-react` beside a held `vite`) still updates on its own
line. If a sibling release's peer range demands a version above the ceiling, hold
the sibling too by adding it to the map. The quality gate catches a peer conflict
before merge regardless.

**In CI (`CI=true`) or with `--scope <group>`, skip the preview and decision
entirely.** The apply set is the full payload (CI) or the named group
(`--scope`); jump straight to the apply phases with an empty skip set and no
ledger write.

### Preview

Group the entries for display into five sections in this order: **Security**,
**Major**, **Non-semver**, **Minor**, **Patch**. The Security section comes
first, one row per advisory in the payload's ranked order, built as
`references/security.md` (`### Security preview`) describes; it is omitted only when
`advisories[]` is empty. Under `--security` the preview shows the Security
section plus only the chain-head bumps the advisories need.

A companion group (any `group` not prefixed
`singleton:`) renders as ONE block under the section of its most-severe member
(severity major > nonsemver > minor > patch) and is a single choice that updates
together. Render each row as `name  current → next`; for a companion group, list
its members under one labelled block (e.g. "react-router group, updates
together").

Mark every group in `snoozedGroups` with a trailing `[snoozed until <date>]`
(the entry's `resurfaces_at`, rendered as a plain date). Snoozed groups are
**default-skipped**: they are excluded from the default apply set, so a group the
human already deferred is not silently re-applied each run. The human can still
choose to refresh them.

If `skipped[]` has any `reason: "held"` entries, print one line above the
sections listing them, e.g. `Held by config (not offered): vite (current
8.0.16, ceiling 8.0)`. This is informational, held packages are never part of
any apply set; the line just keeps the active holds visible.

Below the sections, print one line for the transitive refresh (Phase 5b),
which runs by default after the waves: `Transitive refresh: re-resolve every
transitive dependency to the newest in-range version past the release-age
window; reverted whole if the quality gate fails. Name transitive-refresh under
"Choose what to skip" to skip it this run.`

Then ask with `AskUserQuestion` (single-select). **When `snoozedGroups` is
non-empty**, offer these options in this order:

- **Update the rest** (default, first option): apply every group EXCEPT the
  snoozed ones; leave the snoozes intact.
- **Choose what to skip**: the human names further package or group names to
  skip; the snoozed groups stay skipped too.
- **Update everything incl. snoozed**: apply every group AND clear the snoozes.
- **Cancel**: exit now, no branch, no changes, no ledger write.

**When `snoozedGroups` is empty**, offer the original three:

- **Update all** (default, first option): apply every group.
- **Choose what to skip**: the human names the package or group names to skip;
  everything else applies.
- **Cancel**: exit now, no branch, no changes, no ledger write.

### Decision

The **skip set** is `snoozedGroups` plus whatever the human names; the **apply
set** is every remaining group. The ledger is full-replace, so any `decline
--skip` call must name every group that should stay snoozed (the pre-existing
snoozes AND any newly named), or the omitted ones are dropped from the ledger.

- **Update the rest** (snoozed groups present) → apply set = payload minus
  `snoozedGroups`. Leave the ledger untouched (the snoozes already match the
  current targets), no `decline` call. **If the apply set is empty** (every
  outstanding group is snoozed), print
  `Snoozed N group(s); nothing else to update.` and continue as a refresh-only
  run.
- **Update all** (no snoozed groups) → clear any prior snoozes, apply
  everything:
  ```bash
  .gaia/cli/gaia update-deps decline --clear
  ```
  Apply set = the full payload.
- **Update everything incl. snoozed** → same action as Update all: clear the
  snoozes (`decline --clear`) and apply the full payload.
- **Choose what to skip** → collect the names, union with `snoozedGroups`, then
  record the whole skip set:
  ```bash
  .gaia/cli/gaia update-deps decline --source .gaia/local/cache/shared/update-deps-updates.json --skip "<snoozed…,named…>"
  ```
  Each name expands to its whole companion group (a partial group cannot be
  skipped); an unknown name errors so you can re-ask. Apply set = the payload
  minus the skip set. Echo the resulting apply set back for confirmation.
  **If the apply set is now empty** (everything is skipped), print
  `Snoozed N group(s); nothing else to update.`, then continue as a
  refresh-only run, or exit (no branch) when `transitive-refresh` was also
  named.
  The name `transitive-refresh` is not a group: strip it from the names before
  the `decline` call and skip Phase 5b for this run only, it is never recorded
  in the ledger. If it was the only name given, handle the choice as **Update
  all** (or **Update the rest** when snoozed groups are present) with Phase 5b
  skipped. An advisory key named here is not a group either: strip it the same
  way and decline that advisory in the security plan (`references/security.md`,
  `### Security preview`).
- **Cancel** → stop here.

The snooze ledger (`.gaia/local/declined-updates.json`) is local-only and
gitignored: it suppresses the statusline nudge and default-skips the group in
this preview until a newer version ships or 14 days pass. It never HARD-gates a
run, the human can always choose to refresh a snoozed group, and CI ignores it
entirely (CI is the freshness backstop and keeps opening PRs).

Carry the **apply set** (filtered `wave_a` and `wave_b`) into the phases below,
together with whether Phase 5b runs: yes by default and in CI, no when the human
skipped `transitive-refresh`, never under `--scope` or `--security`. Carry the
**security plan** too (empty in a report-only run), with the opening advisory
key set, the opening `dismissedGhsas`, whether alerts were read, and the source
from the advisories call.

A **refresh-only run** has an empty apply set but still runs Phase 5b: every
direct dependency is current, or every outstanding group is snoozed or skipped.
It skips the Override audit + Wave A agent and Phase 5, and creates its
worktree before Phase 5b (see Branch creation), then runs Phase 5b first. Phase 0 does not run, so Phase 6
runs only after a landed refresh or a landed security override, and treats
every key in the `overrides:` map as retained.

## Branch creation (after discovery)

Phase 1 already exited if the human cancelled, or declined the transitive
refresh with nothing else to apply, so reaching here means the apply set is
non-empty, the security plan has a resolution to apply, or the run is
refresh-only. The branch is cut inside a worktree, never in the main checkout.

- **Apply set non-empty, or the security plan has at least one resolution to
  apply.** Run this section right after the decision, before the Override audit
  + Wave A agent, so no install, lockfile rewrite, or quality gate runs on
  `main`/`master` (a `/gaia-init` run stays where it is, see Pre-flight: Branch
  check). A security-only run (an empty apply set, or `--security` with no
  chain-head bump) then goes on to the security phase even when Phase 5b reports
  `Nothing moved` or `Reverted (<reason>)`.
- **Refresh-only run.** The refresh installs, rewrites the lockfile and gates,
  so the worktree exists before Phase 5b starts. Run `references/worktree.md`
  (step 2 below) as soon as an interactive run becomes refresh-only: the human picks **Refresh transitive
  dependencies** at the zero-outdated prompt, **Update the rest** leaves an empty
  apply set because every group is snoozed, or **Choose what to skip** leaves an
  empty apply set. In CI nothing creates a worktree. When Phase 5b then reports
  `Nothing moved` or `Reverted (<reason>)` and the security plan owes nothing,
  skip every phase up to Phase 7 and go straight to the report (Phase 8's
  nothing-updated rule skips publish); the worktree stays in place and its
  notice is printed, as the stop rule says.

Do the following in order:

1. **Cache bust, once updates are confirmed.** Bust the update-check cache so the
   statusline reflects the post-update state on the next session regardless of
   whether this run completes. It always names the main checkout's cache by its
   absolute path, so the same call works from the main checkout and from a
   worktree:
   ```bash
   bash .gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode deps
   ```
   The script sets `outdatedCount` to `0` and `checkedAt` to now, and carries
   every other field across unchanged: the cache holds fields this step has no
   reason to know about, and several are observations nothing later can
   reconstruct (`cleanseMemoryBaseline` and the two `codify*` counts), so
   dropping one silently disarms the nudge it belongs to instead of causing a
   visible error. It prints `BUSTED` or `SKIPPED no cache` (the cache file does
   not exist) and exits 0, or prints `BUST_FAILED <reason>` and exits 3 with the
   file left as it was. A non-zero exit is reported and never stops the run. Then
   read the file back (the `Read` tool, at that main-checkout path) and confirm
   `outdatedCount` is `0`. Where this step runs depends on the path:
   - Post-decision path: before step 2, in the main checkout.
   - Refresh-only path: after Phase 5b reports `landed`, in the worktree.
   - After a vendored-sync worktree: at the decision, in the worktree.
   (Snoozed groups are already excluded by the ledger on the next real check.)
2. **Worktree.** Create it with `references/worktree.md` now, when `SHOULD_CREATE_WORKTREE=true` and no worktree was created
   earlier in this run (the vendored-skill sync may already have created it).
3. **Otherwise** (`SHOULD_CREATE_WORKTREE=false`) create nothing and proceed in
   place. Remember whether this run created a worktree (`CREATED_WORKTREE=true`),
   runs inside its own update worktree (mode 3), or works in place; Phase 8
   branches on it.

## Override audit + Wave A: Haiku agent

Spawn a **Haiku agent** (`model: "haiku"`, `effort: "medium"`) to run the override audit and the
Wave A batch install on the **apply set** computed above. Its prompt tells it to
read `.claude/skills/update-deps/references/override-audit.md` and
`.claude/skills/update-deps/references/wave-a.md`, run Phase 0 (skipped under
`--scope` and `--security`) then Wave A exactly as written, and gives it the
apply set's Wave A entries as the Wave A input, marking each chain-head bump
an advisory needs.

**Security chain-head bumps ride the waves.** A minor or patch chain-head bump
an advisory needs joins Wave A; a major one runs in Phase 5 as that group's
Wave B agent. Nothing looks up beforehand whether the head's new release admits
the patched version: after each wave returns, run `advisory-landed` (see
`references/security.md`, step 5) for every advisory that wave was meant to
clear, and that check is what verifies admission. A head bump that landed but
did not clear its advisory falls through to the advisory's next candidate in
the security phase. When Wave A reverts its batch (or a Wave B agent its group)
and the reverted set carried a security chain-head bump, that advisory also
falls through to its next candidate; with none left it is reported still open
with `wave reverted (Wave A)` or `wave reverted (<group>)`, not `quality gate
failed`.

## Phase 5: Wave B (per-group major bumps)

Use the **Wave B groups from the apply set** (the payload's `wave_b` minus any
group the human skipped). If there are none, skip to Phase 5b.

For each Wave B group, classify complexity and assign a model:

**Opus** (`model: "opus"`, `effort: "medium"`): `react-router`, `react`, `storybook`,
`singleton:typescript`

**Sonnet** (`model: "sonnet"`, `effort: "medium"`): `eslint`, all other groups

Spawn one agent per group, on its model above and `effort: "medium"` (or sequentially if resource-constrained). Its prompt tells it to read `.claude/skills/update-deps/references/wave-b-group.md` and follow it exactly, with GROUP, FROM and TO filled in.

## Phase 5b: Transitive refresh (Haiku agent)

Waves A and B move direct specs only, and pnpm keeps a transitive dependency's locked version for as long as its parent's range still admits it, so a vulnerable transitive whose patched release is already in range survives every earlier phase. This phase asks pnpm for the newest in-range version of every transitive dependency. It runs before Phase 6 so the post-update override audit reads the refreshed tree.

Skip it when the human skipped `transitive-refresh` in the preview (report `Declined in preview`), under `--scope` (report `Not run (--scope)`), or under `--security` (report `Not run (--security)`). An advisory this refresh clears (its `advisory-landed` check exits 0 afterwards) is resolved by `in-range refresh` and gets no further resolution. Otherwise spawn a **Haiku agent** (`model: "haiku"`, `effort: "medium"`). Its prompt tells it to read `.claude/skills/update-deps/references/transitive-refresh.md` and follow it exactly, with the frozen names as FROZEN_NAMES. The **frozen names** are every package in `skipped[]` with `reason: "held"`, plus every member of a group in the skip set (empty when nothing was held or skipped).

## Phase 5c: Security resolutions

Resolve the advisories the security plan still owes by following `.claude/skills/update-deps/references/security.md` (`### Security resolutions`): in-range refresh and security-floor override resolutions, gated as a batch with a per-resolution revert, then acceptance. It runs after Phase 5b and before Phase 6, so Phase 6 audits every override it adds. The orchestrating session runs it itself, because acceptance asks the human; the resolution steps may be delegated to an agent only while no question is pending. In a report-only run it only records every advisory as still open with `report-only run`.

## Phase 6: Post-update override audit

The key scope is every key retained in Phase 0 plus every security override Phase 5c landed. Phase 6 runs whenever Phase 5c landed an override, including a zero-outdated run and a `--security` run (there, only those overrides). For each key in scope, repeat the full Phase 0 audit (both the peer-dep and the security-floor check, re-capturing a fresh advisory baseline against the now-updated tree) now that surrounding packages have moved. A version that landed in Wave A, Wave B, or the Phase 5b refresh may have resolved the original peer-dep conflict or carried the patched transitive dependency that made a security-floor pin obsolete. The toggle test re-resolves with `pnpm dedupe`, never a bare `pnpm install`, exactly as in Phase 0. This is the last phase that mutates the `overrides:` map, so the lockfile settles here: close it with the same assertion Phase 0 runs, the lockfile's `overrides:` block must list exactly the keys in `pnpm-workspace.yaml`, repairing any drift with `pnpm dedupe`.

On a refresh-only run Phase 0 did not run: Phase 6 runs only when Phase 5b reported `landed` or Phase 5c landed an override, and treats every key in the `overrides:` map as retained. Under `--security` it treats only the Phase 5c overrides as in scope.

Run this as a **Haiku agent** (`model: "haiku"`, `effort: "medium"`). Its dispatch carries every Phase 6 duty, so pass it all four of these:

- **The recipe.** `.claude/skills/update-deps/references/override-audit.md` (tell the agent to read it), restricted to the keys in scope above, so every quality-gate run it owes runs those same commands. Pass each security override with the advisory id Phase 5c recorded for it, so a retained floor is reported by that id.
- **When to gate.** Run the quality gate once, after the lockfile assertion, whenever it removed any key or repaired lockfile drift. No Wave agent gated that change. This replaces the drift-only trigger in the Phase 0 section.
- **On a failed gate.** Restore every key it removed to the value it held when this Phase 6 run began, run `pnpm dedupe` to apply the restore, and re-run the lockfile assertion. This is the counterpart of Wave A reverting its whole batch: one gate run cannot say which key broke it, so the restore takes them all. Report each restored removal as **retained (quality gate failed)**. When it changed no key and the gate ran only for a drift repair, there is nothing to restore: report the failure for the maintainer to resolve.
- **What to return.** The override audit results (removed / retained) and the quality gate results, including a failed gate and whatever restore followed it, so the Phase 7 Quality gate section has the Phase 6 run to report.

<!-- gaia:maintainer-only:start -->

In this checkout `run --emit-updates` also lists `.gaia/cli` member entries carrying `"workspace": ".gaia/cli"`. Apply each with `pnpm -C .gaia/cli add <name>@<spec>`, never `pnpm -C frontend add`, then run `pnpm -C .gaia/cli typecheck`, `pnpm -C .gaia/cli lint`, `pnpm -C .gaia/cli exec vitest run` and `pnpm -C .gaia/cli bundle`. A decline or snooze is per package name and covers both workspaces (when the two disagree on `latest`, the higher one is recorded). Shared devDependencies may drift between the two importers; align them by hand when noticed.

<!-- gaia:maintainer-only:end -->

## Phase 7: Final report

The orchestrating session builds and prints the report itself, from the agent reports, the Phase 1 decisions, the Phase 5c result, and a final-tree `pnpm audit` it runs inline: read `.claude/skills/update-deps/references/final-report.md` and follow it exactly. It never commits.

## Phase 8: Publish

Except on a run `/gaia-init` invoked, which publishes nothing, the orchestrating session commits, pushes, and, on a worktree run (one that created its worktree, or runs inside its own update worktree), opens or reuses the PR, merges it once checks are green, and cleans up the worktree and branch, because the merge-gate hooks fire only in the invoking session: read `.claude/skills/update-deps/references/publish.md` and follow it exactly.
