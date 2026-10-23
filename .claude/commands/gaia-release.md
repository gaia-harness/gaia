---
name: gaia-release
description: Maintainer-only. Cuts a new GAIA release. Bumps the version, graduates the CHANGELOG, regenerates the manifest, opens the release PR, then tags on merge.
disable-model-invocation: true
argument-hint: "patch|minor|major"
---

Contents: Required argument; Pre-flight: Worktree check; Workflow; Recovery: I tagged on the wrong commit.

Cut a new GAIA release. Thin orchestrator over the `.gaia/cli/gaia-maintainer release` CLI namespace, which owns every deterministic step (preflight checks, semver bump, CHANGELOG graduation, wiki scrub, manifest regen, commit + tag dance). This command sequences the CLI subcommands and surfaces user-facing prompts where human judgment is required.

This command is **maintainer-only**: it and the `gaia-maintainer` binary are release-excluded.

> [!important] `main` is protected
> Direct pushes to `main` are blocked. The release commit lands on a release branch, goes through a PR, and the tag is created on the squash commit _after_ it lands on `main`. The release PR is subject to the same CI gate and the same Code Audit Team merge handshake as any other PR. Expect `Vitest and Playwright`, `Run Chromatic`, and `Vitest (.gaia/cli)`: a release PR bumps root `package.json`, which that job's paths filter lists, so it always runs the job's full typecheck, lint, vitest, and bundle-freshness path rather than its filter-miss fast pass (it touches `.gaia/cli/**` only when Step 7b rebuilt the bundles). `gh pr merge --squash --auto` is the normal path: the repository allows squash merges only, and base-branch protection rejects a merge without `--auto`, so `--auto` is required to queue the merge until checks pass. See `wiki/concepts/PR Merge Workflow.md`.

## Required argument

Invocation: `/gaia-release patch|minor|major`. The argument is the **sole authority** for the version bump.

If the argument is missing, including when `/gaia-release` is reached as part of a larger batch of work ("ship this then release", a multi-step plan that ends in release, a chained workflow), **STOP and ask the maintainer via `AskUserQuestion`** before any preflight / branch / commit step. Do not infer the bump from commit prefixes, diff size, or the `gaia-maintainer release bump` proposal.

The conventional-commit scan over-proposes `minor` for CI/plumbing commits incorrectly tagged `feat:` that are patch-level in spirit; the maintainer is the only reliable source for semver intent. Never proceed without an explicit `patch|minor|major` from the maintainer.

## Pre-flight: Worktree check

This command bumps `.gaia/VERSION`, commits and tags on `main`, and opens the release PR, all main-checkout operations that must never run from a per-SPEC worktree branch. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-release" || exit 1
```

## Workflow

The CLI surface is the source of truth. The classification rules for `.gaia/manifest.json` live in code (`.gaia/cli/src/release/manifest.ts`); the on-disk manifest is the single source of truth for `/update-gaia` consumers.

### 1. Preflight

```bash
.gaia/cli/gaia-maintainer release preflight
bash .gaia/scripts/verify-required-checks.sh
```

`verify-required-checks.sh` confirms every context in its own `REQUIRED_CONTEXTS` list is required by the default branch's live rules. Exit 1 names the contexts missing from those rules; exit 2 means it could not resolve the repository or read its rules. On non-zero, STOP and report.

Verifies: on `main`, clean working tree, and `wiki/.state.json` is current. The wiki check reads `gaia wiki state --json`: a reachable state passes on `commits_ahead === 0`; an orphaned state (`reachable:false`, the normal post-squash-merge condition, where `commits_ahead` is `0`) is judged on `drift_count`, counted from `suggested_base`, so an un-evaluated window isn't read as a silent zero. Either way, drift that is only wiki-sync squash artifacts passes; substantive drift exits non-zero with an explanation. STOP and report; the maintainer fixes (commit, push, run bare `/gaia-wiki`, which runs sync, consolidate prompts, and lint's fix loop (which can file tech-debt issues) and lands them through its own PR, so expect it to finish before re-running `/gaia-release`).

### 2. Apply the bump

Use the maintainer's argument from "Required argument" as `<BUMP>`. The CLI's `release bump` proposal is **informational only**, print it for awareness, then proceed with `<BUMP>` regardless:

```bash
.gaia/cli/gaia-maintainer release bump            # propose only, informational
```

If the proposal disagrees with `<BUMP>`, surface the disagreement once (e.g. "CLI proposed minor from `feat(ci):` commits; you specified patch, proceeding with patch") but do not re-prompt.

Apply by path:

- **`<BUMP>` equals the proposal and is not major:** `.gaia/cli/gaia-maintainer release bump --auto` writes the proposal's version to `package.json`, `frontend/package.json`, and `.gaia/VERSION`.
- **`<BUMP>` differs from a non-major proposal** (e.g. `patch` override of a `minor` proposal, or `minor` over a `patch` one): `--auto` would write the proposal's version, not `<BUMP>`'s. Compute NEW_VERSION = current with the requested bump applied, then write `package.json`, `frontend/package.json`, and `.gaia/VERSION` directly (the two `package.json` versions must stay equal: a bats case fails the release PR on drift). Preserve `package.json` formatting (2-space indent, trailing newline), use `node -e "const fs=require('fs');const p=require('./package.json');p.version='<NEW>';fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n');"` `node -e` the same line against `frontend/package.json`, and `printf '<NEW>\n' > .gaia/VERSION`.
- **A major proposal:** `--auto` refuses (exit 1) whatever `<BUMP>` is. Compute NEW_VERSION from `<BUMP>` (`v<CURRENT_MAJOR+1>.0.0` for `major`) and write `package.json`, `frontend/package.json`, and `.gaia/VERSION` directly per the form above.

### 3. Quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md`. Stop on failure, fix, recommit, re-run from Step 1.

### 4. Switch to the release branch

Mint the branch name from GAIA's naming convention, which `.gaia/scripts/branch-name-lib.sh` owns; its output is `<RELEASE_BRANCH>` in every later step, including the create-gaia lockstep below:

```bash
bash .gaia/scripts/branch-name-lib.sh name release "<NEW_VERSION>"
```

```bash
git checkout -b "<RELEASE_BRANCH>"
```

If the branch already exists (a previous attempt aborted), STOP and ask the maintainer with `AskUserQuestion`: `Resume from the next pending step (Recommended)` or `Delete it and retry`.

### 5. Graduate the CHANGELOG

```bash
.gaia/cli/gaia-maintainer release changelog --draft   # render to stdout for human review
```

The draft is a **review aid, not the release content**: it is rendered from commit
subjects and is never written to the file. Present it to the maintainer alongside the
hand-written `## [Unreleased]` block and fold anything the block is missing into it by
hand. Then ask with `AskUserQuestion`: `Apply the block (Recommended)` or `Revise`, a
typed revision arriving through the tool's own Other. On approval, apply:

```bash
.gaia/cli/gaia-maintainer release changelog            # graduate Unreleased → vX.Y.Z
```

That renames `## [Unreleased]` to the dated heading, leaving the hand-written entries
beneath it, and opens a fresh empty `## [Unreleased]` above. It refuses (exit 1,
`empty_unreleased_section`) rather than date a section with nothing under it. The
graduation is idempotent, re-running with the same version is a no-op.

### 6. Scrub adopter-facing wiki state

```bash
.gaia/cli/gaia-maintainer release scrub-wiki
```

Overwrites `wiki/log.md` with release-clean content (full frontmatter required by the lint stage of `/gaia-wiki`).

### 7. Regenerate the manifest

```bash
.gaia/cli/gaia-maintainer release manifest --allow-undecided
```

Writes `.gaia/manifest.json`, sorted alphabetically. Walks `git ls-files`, subtracts `.gaia/release-exclude` patterns and adopter-owned sentinels, classifies the remainder as `owned` / `shared` / `wiki-owned`. Adopters use this manifest in `/update-gaia` to decide which files to overwrite, three-way merge, or leave alone.

`--allow-undecided` preserves the release path's unconditional regeneration. The CLI otherwise refuses to produce a manifest while a shipping file has no explicit ship-or-withhold answer; release day is not the moment to relitigate what a file is for, so the release path takes the escape hatch by design. `/distribution-vet` is where that decision gets made, and it never carries this token.

### 7b. Rebuild the bundled CLIs

```bash
pnpm --filter @gaia-react/cli bundle
```

Rebuilds both `.gaia/cli/gaia` (adopter binary) and `.gaia/cli/gaia-maintainer` (maintainer binary, excluded from the tarball). Skip only when no `.gaia/cli/src/` files changed since the last release; when in doubt, rebuild, the script is fast and idempotent. The release tarball ships the committed `gaia` binary as-is, so a stale bundle ships a stale CLI.

### 8. Commit on the release branch

```bash
.gaia/cli/gaia-maintainer release commit-and-tag --commit
```

Stages `package.json`, `frontend/package.json`, `.gaia/VERSION`, `.gaia/manifest.json`, `CHANGELOG.md`, `wiki/log.md` (and `wiki/.state.json` after the amend). The maintainer adds `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer` manually if Step 7b rebuilt them. Commits as `chore(release): vX.Y.Z`, captures the new SHA, records it in `wiki/.state.json`, then amends the commit so the tree contains the state file (the recorded SHA is the pre-amend commit's: a commit cannot contain its own hash).

If the pre-commit hook fails, STOP and report, fix the issue and create a **new** commit; do not `--amend`.

### 9. Push the release branch and open the PR

```bash
git push -u origin "<RELEASE_BRANCH>"
gh pr create --draft --base main --head "<RELEASE_BRANCH>" \
  --title "chore(release): v<NEW_VERSION>" \
  --body "<release summary, link CHANGELOG entry, list highlights>"
```

### 10. Code Audit Team + marker handshake

The release PR is **not** exempt from the merge gate, `.claude/hooks/pr-merge-audit-check.sh` denies `gh pr merge` until every dispatched Code Audit Team member holds a marker for its current branch-own digest. Resolve the members (`bash .gaia/scripts/resolve-audit-members.sh`), then dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`: the unit runs the members, fixes every Critical and Major finding, pushes (the tree changes), and repeats on the new HEAD until every member writes its marker (see `wiki/concepts/Audit Round Procedure.md` `#### Marker key` for the marker filename, keyed to the member's branch-own digest, not the tree sha). Post the status per `#### Posting the status last` before the merge. Knip / react-doctor advisories never block the marker.

Members re-audit from the re-run carry-forward ledger, whose keying, accounting and absent-or-stale fallback `.claude/hooks/lib/audit-member-protocol.md` `## Re-run carry-forward ledger` owns; the fixer is briefed from the round's dispositions file, not the ledger.

Members write their markers only; they do not post the `GAIA-Audit` success status. Once `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last` conditions hold, post it yourself, `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`, before Step 11's merge; otherwise `--auto` queues against a required check nothing ever posts.

### 11. Merge the PR

```bash
gh pr merge <N> --squash --auto --delete-branch
# --squash: the repository allows squash merges only. --auto is mandatory:
# base-branch protection rejects a merge without it, and the Vitest/Playwright
# + Chromatic checks take a few minutes. --auto queues the merge; GitHub
# completes it once checks pass.
```

Then run the merge wait, with a 20-attempt bound in place of its default 5, since the release checks run longer:

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N> --attempts 20
```

The merge above is already queued, and this script issues no `gh pr merge` of its own, so nothing here re-merges. Do not run any local cleanup or tagging until it prints `MERGED` (exit 0). On `CONFLICTING` (exit 3), repair per `wiki/concepts/PR Merge Workflow.md`'s `### Conflict found mid-wait` and run the wait again; on `CHECK_FAILED` (exit 4), inspect the failing check; on `TIMEOUT` (exit 5), inspect `gh pr view <N>` for a stuck merge queue; on `CLOSED` (exit 6), the release pull request was closed without merging, so stop and do not tag. Exit 2 is a refusal rather than a verdict and says nothing about the pull request: read the message, which names what could not be read. The script's `--help` is the authority on that set.

### 11b. Context footprint check

Before tagging, ask with AskUserQuestion: "Context footprint measured for this version and the token-efficiency page updated?" Options: **Done**; **Run it now (stop)**, which stops the release so the maintainer runs `.claude/maintainers/context-footprint-prompt.md` against a probe built from this release candidate; **Skip this release**, which asks for the reason and records it in the release PR. Continue only on Done or Skip.

### 12. Tag the squash commit

**2.0.0 cut only: publish `create-gaia` first.** Releases from 2.0.0 on publish `gaia-bundle-<tag>.tar.gz`, and a `create-gaia` that still downloads `gaia-<tag>.tar.gz` 404s for every `npx create-gaia@latest` the moment the `v2.0.0` release goes live. So before tagging `v2.0.0`, run step 13 in full now, including its 2.0.0 asset-name bullet, through the npm confirmation, then check:

```bash
npm view create-gaia@2.0.0 version    # must print 2.0.0; do not tag until it does
```

Publishing `create-gaia` ahead of the tag is safe: it resolves the latest GAIA release, which is still below 2.0.0 and keeps the old asset name until the tag lands. Every other release tags here first and runs step 13 after.

```bash
git checkout main
git pull --ff-only origin main
git log -1 --oneline    # verify this is the release PR's squash commit
.gaia/cli/gaia-maintainer release commit-and-tag --tag
```

`commit-and-tag --tag` refuses (`REFUSED:`) a tag whose major is below the highest existing `vX.Y.Z` release tag's major, read from local tags and origin's, because a 1.x `/update-gaia` resolves the newest-created release.

`--tag` also pushes the tag to origin, which kicks the GitHub Release workflow (`release.yml`) to build the scrubbed tarball.

### 13. Lockstep `create-gaia`

`create-gaia` (the `npx create-gaia` scaffolder) must stay in **version lockstep** with the GAIA template: its `package.json` `version` and its offline `FALLBACK_VERSION` (`bin/index.js`) both track the release just cut. Its `publish.yml` triggers on a `v*.*.*` tag and refuses to publish unless the tag equals `package.json` version.

On the 2.0.0 cut, step 12 runs this step before the tag, then returns to tag. Reaching it again after the tag, it is already done: go to step 14.

It lives in a sibling checkout (`../create-gaia` relative to the GAIA repo root). If the sibling is absent on this machine, STOP and report, do not silently skip; lockstep is mandatory and a maintainer with the checkout must complete it.

```bash
CG="$(git rev-parse --show-toplevel)/../create-gaia"
[ -d "$CG/.git" ] || { echo "create-gaia checkout not found at $CG, lockstep cannot complete here"; exit 1; }
CG="$(git -C "$CG" rev-parse --show-toplevel)"   # canonical absolute path
echo "create-gaia resolved to: $CG"              # ← note this literal path; inline it (NOT $CG) into the commit and push commands below
git -C "$CG" fetch origin --quiet && git -C "$CG" checkout main --quiet && git -C "$CG" pull --ff-only origin main --quiet
```

Set both version sites to `<NEW_VERSION>` (no `v` in `package.json`, `v`-prefixed in `FALLBACK_VERSION`):

- `$CG/package.json` → `"version": "<NEW_VERSION>"`
- `$CG/bin/index.js` → `const FALLBACK_VERSION = 'v<NEW_VERSION>';`
- For the 2.0.0 cut only: releases from 2.0.0 on publish `gaia-bundle-${version}.tar.gz` (`wiki/concepts/Release Workflow.md`). Make sure `$CG/bin/index.js` downloads `gaia-bundle-${version}.tar.gz` for versions at or above `v2.0.0` and keeps `gaia-${version}.tar.gz` below it; step 12's gate requires this `create-gaia` published before the `v2.0.0` tag.

Commit on a branch, open + merge a PR, then tag. The PR-merge and main-push guards are repo-scoped (`.claude/hooks/lib/repo-scope.sh`), but the two surfaces resolve the sibling differently. `gh pr merge -R gaia-react/create-gaia` is recognized as foreign by repo-**name** (basename) comparison, so this repo's audit gate does **not** fire, no manual-UI detour needed. Raw-git commits and pushes follow the sibling-repo commit and push protocol below. `create-gaia` has no audit infrastructure or branch protection of its own; a plain `--merge` (not `--auto`) is correct there.

> [!important] Sibling-repo commit and push protocol
> The main-branch commit and push guard (`.claude/hooks/block-main-destructive-git.sh`, with `.claude/hooks/lib/repo-scope.sh`) reads the raw command string and never expands it. It stands down for a sibling only when every git command in the Bash call resolves to the sibling; otherwise it reads the call as this repository and judges each `git commit` and `git push` in it against the branch of the checkout it names, which for this checkout, and for website and docs, is `main`. So a Bash call that commits or pushes in a sibling:
>
> 1. **Names the sibling by its literal absolute path on every git command**, the path the discovery step printed (e.g. `git -C /abs/path/to/create-gaia commit …`), never `$CG`, `$WEB` or `$DOCS`. An unexpanded variable resolves nowhere and is read as this checkout.
> 2. **Holds no other git command**: none with a variable path, and none on this repository (a bare `git …`, or `git rev-parse --show-toplevel`). Either one turns the whole call home.
> 3. **Gives each git command one `-C`.** Several literal-path git commands may chain in one call; a second `-C` on one command is read as ambiguous and refused.
>
> A Bash call that neither commits nor pushes (add, fetch, checkout, pull, tag) may keep the variable and combine freely. A `git -C "$CG" checkout -b …` is allowed on its own; chained with a `git -C "$CG" commit` in one call, the commit is refused.

```bash
git -C "$CG" checkout -b "<RELEASE_BRANCH>"
# (edit package.json + bin/index.js as above)
node --check "$CG/bin/index.js"   # smoke: no syntax error
```

Commit, per the commit and push protocol:

```bash
git -C /abs/path/to/create-gaia add package.json bin/index.js && git -C /abs/path/to/create-gaia commit -m "chore: release v<NEW_VERSION>"
```

Branch push, per the commit and push protocol:

```bash
git -C /abs/path/to/create-gaia push -u origin "<RELEASE_BRANCH>"
```

```bash
gh pr create -R gaia-react/create-gaia --base main --head "<RELEASE_BRANCH>" \
  --title "chore: release v<NEW_VERSION>" --body "Lockstep with GAIA v<NEW_VERSION>."
gh pr merge -R gaia-react/create-gaia <CG_N> --merge --delete-branch
bash .gaia/scripts/pr-wait-merge.sh --pr <CG_N> --repo gaia-react/create-gaia \
  --attempts 10 --interval 15 \
  || { echo "create-gaia PR did not confirm as MERGED (read the wait's own message above, which names the verdict or the refusal), investigate before tagging"; exit 1; }
git -C "$CG" fetch origin --quiet && git -C "$CG" checkout main --quiet && git -C "$CG" pull --ff-only origin main --quiet
git -C "$CG" tag "v<NEW_VERSION>"
```

Tag push, per the commit and push protocol:

```bash
git -C /abs/path/to/create-gaia push origin "v<NEW_VERSION>"
```

The tag push triggers `create-gaia`'s `publish.yml` (npm publish with `--provenance`). Confirm it before considering the release complete:

```bash
gh run list -R gaia-react/create-gaia --workflow=publish.yml --limit 1
npm view create-gaia@<NEW_VERSION> version    # registry CDN may lag a minute
```

### 14. Lockstep website

The marketing/docs site (`../website` relative to this repo) embeds two version references plus a public changelog entry that must match the release just cut. Update all of them before considering the release complete.

```bash
WEB="$(git rev-parse --show-toplevel)/../website"
[ -d "$WEB" ] || { echo "website checkout not found at $WEB, lockstep cannot complete here"; exit 1; }
WEB="$(git -C "$WEB" rev-parse --show-toplevel)"   # canonical absolute path
echo "website resolved to: $WEB"                   # ← note this literal path; inline it (NOT $WEB) into the commit and push below
```

**GetStarted page**, update the `GAIA_VERSION` constant:

- `$WEB/src/pages/get-started/sections/GetStarted.tsx` → `const GAIA_VERSION = '<NEW_VERSION>';`

**Structured data (JSON-LD)**, the `SoftwareApplication` schema in the site's root `index.html` carries a `softwareVersion` field. Always set it to `<NEW_VERSION>` (the latest released version; no `v` prefix, matching the existing string form):

- `$WEB/index.html` → `"softwareVersion": "<NEW_VERSION>",`

**Public changelog page (release notes).** The two edits above are version strings; the human-readable "what's new" entry on the site's changelog page is a separate artifact owned by the `release-notes` skill. Generate it for the version just cut:

- Invoke the `release-notes` skill with `<NEW_VERSION>` (no leading `v`). It reads the graduated `## [<NEW_VERSION>]` block from `CHANGELOG.md`, translates it to adopter-facing notes, writes `$WEB/src/pages/changelog/releases/<NEW_VERSION>.ts` (the page auto-discovers the file via `import.meta.glob`; there is no index to update), and prints an editorial-decisions report.
- The report is a human gate: review the **Dropped** and **Consolidated** lists and resolve every **Needs a human ruling** item before accepting, then adjust the file per the maintainer's rulings. Ask each ruling through `AskUserQuestion`, up to 4 questions per call, the skill's suggested reading first and marked `(Recommended)`; then ask `Accept the notes (Recommended)` or `Adjust`.
- The skill only reads `CHANGELOG.md`; never edit the changelog here.

Stage the generated `<NEW_VERSION>.ts` alongside the two version edits so all three land in one website commit.

Commit and push directly to `main` in the website repo (no branch protection on `website`). Both follow Step 13's sibling-repo commit and push protocol.

```bash
git -C /abs/path/to/website add src/pages/get-started/sections/GetStarted.tsx index.html src/pages/changelog/releases/<NEW_VERSION>.ts && git -C /abs/path/to/website commit -m "chore: lockstep GAIA v<NEW_VERSION>"
```

Push, per the commit and push protocol:

```bash
git -C /abs/path/to/website push origin main
```

**GitHub release body (adopter notes).** Step 12's tag fired `release.yml`, which created the GitHub release with the raw `## [<NEW_VERSION>]` CHANGELOG block as a fallback body. That block is contributor-facing (terse, internal, issue-numbered); overwrite it with the same adopter notes just generated. `render-release-md.mjs` derives markdown from the committed `<NEW_VERSION>.ts`, so the GitHub release and the website changelog never drift:

```bash
node "$WEB/scripts/render-release-md.mjs" <NEW_VERSION> > "/tmp/gh-notes-v<NEW_VERSION>.md"
gh release edit "v<NEW_VERSION>" -R gaia-react/gaia --notes-file "/tmp/gh-notes-v<NEW_VERSION>.md"
```

`gh release edit` is neither a push nor a `gh pr merge`, so the repo-scope and audit hooks do not apply; no literal-path treatment is needed here.

**2.x routing line check.** A 1.x `/update-gaia` resolves the newest-created release, so a 1.6.1 project meets whichever 2.x release is newest, not only 2.0.0. The routing line reaches the release body only when this release's `## [<NEW_VERSION>]` CHANGELOG entry carries it: `compose-release-body.sh` then hoists it to the first line, and it refuses to compose without it only for `v2.0.0`. When the entry carries it, the release data `<NEW_VERSION>.ts` must carry a matching `preamble` (the routing line, the Proceed side-effects line, the sha256 line) that the renderer emits verbatim before the headline. After the edit, verify the body still leads with the routing line, and re-render if not:

```bash
gh release view "v<NEW_VERSION>" -R gaia-react/gaia --json body --jq .body | head -1
```

The first line must equal the output of `bash .gaia/scripts/compose-release-body.sh --routing-line`. See `wiki/concepts/Release Workflow.md`.

### 15. Lockstep docs

The documentation site (`../docs` relative to this repo, docs.gaiareact.com) shows the current GAIA version in its sidebar colophon. Update it to match the release just cut.

```bash
DOCS="$(git rev-parse --show-toplevel)/../docs"
[ -d "$DOCS/.git" ] || { echo "docs checkout not found at $DOCS, lockstep cannot complete here"; exit 1; }
DOCS="$(git -C "$DOCS" rev-parse --show-toplevel)"   # canonical absolute path
echo "docs resolved to: $DOCS"                       # ← note this literal path; inline it (NOT $DOCS) into the commit and push below
```

- `$DOCS/src/version.ts` → `export const GAIA_VERSION = '<NEW_VERSION>';` (imported by `src/overrides/PageSidebar.astro`'s colophon)

Commit and push directly to `main` in the docs repo (mirror Step 14's website push; if docs enforces branch protection, route through a PR as in Step 11). Both follow Step 13's sibling-repo commit and push protocol.

```bash
git -C /abs/path/to/docs add src/version.ts && git -C /abs/path/to/docs commit -m "chore: lockstep GAIA v<NEW_VERSION>"
```

Push, per the commit and push protocol:

```bash
git -C /abs/path/to/docs push origin main
```

## Recovery: I tagged on the wrong commit

```bash
git tag -d "v<NEW_VERSION>"           # delete locally
git push origin :"v<NEW_VERSION>"     # only if already pushed
.gaia/cli/gaia-maintainer release commit-and-tag --tag      # re-tag from the actual squash commit
```

Re-tagging after deleting a wrong tag passes the same major guard, since the deleted tag no longer counts.
