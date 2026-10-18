# update-gaia: merge execution (Steps 6 to 9)

The execution agent that `/update-gaia` spawns follows this file. **Before Step 6, read `merge-report.md`, `merge-generated.md` and this file in full**, from the run directory's `instructions/` snapshot when the orchestrator names it: the Step 7 walk can overwrite all three partway through the run, and the agent keeps executing the copies it read. The orchestrator has already downloaded every bundle and verified each against its release checksum, so this file downloads nothing.

The agent asks nothing. A dispatched agent has no way to put a question to the user, so every decision the merge cannot make lands in the report as an open item, with candidate files for its options, and the orchestrator asks it, applies the answer and prints the summary. Nothing persists outside the run directory except the merged tree and `.gaia-backup/`. Steps 9b onward run in the orchestrator and live in `../SKILL.md`.

Contents:

- Inputs
- Re-runs converge
- Command resolution
- Step 6: Load the manifests
- Step 7: The walk (the three-way merge, the judgment pass, open items, chunking; 7a to 7c field-aware files; 7d and 7e generated content; 7f upstream removals)
- Step 8: The version is written by the orchestrator
- Step 9: The report
- Judgment-only agent (chunk 2 and later)

## Inputs

The orchestrator passes:

- `BASELINE`, `LATEST` (versions without the leading `v`) and `LATEST_TAG`.
- `BASELINE_DIR` and `LATEST_DIR`, the verified, freshly extracted trees.
- Zero or more `EXTRA_DIR=<tag>:<path>` lines, one per deferred baseline tag: the verified tree for a bundle an earlier update deferred a path from.
- The acting tree, the update worktree on a default-branch run. It is this agent's working root: every path in this file is relative to it, and the agent runs nothing against any other checkout.
- The run directory (`RUN_DIR`), the absolute literal `merge-report.md` names, and the report path inside it, already cleared.
- The decision-log path (`DECISIONS`, the acting tree's `.gaia/update-decisions.json`; an absent file means no decisions).
- The saved CHANGELOG range file path (`CHANGELOG_RANGE`).
- When judgment is chunked, the `chunk-1.txt` path.

Every write into the run directory goes through Bash (`jq ... >`, `git merge-file -p ... >`, `cp`), never Edit or Write: from a linked worktree the run directory resolves into the main checkout, where those tools are refused. Scratch files go in this agent's own scratch directory, emptied first:

```bash
WORK_DIR="$RUN_DIR/work-1"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
```

## Re-runs converge

A re-dispatch, or the orchestrator's inline fallback, runs against the tree as it stands. The walk is safe to re-run on a partially walked tree: an overwritten file reads as already latest, an applied key as `alreadyLatest`, a deleted file as `removed`, and a clean merge re-merges to itself because identical changes on both sides merge cleanly. So never assume a pristine tree, and never reset one: no `git checkout`, `git restore`, `git stash` or `git reset` against the acting tree.

## Command resolution

Three facts, stated here once; `merge-generated.md` and the orchestrator apply them.

1. **A CLI subcommand resolves from `$LATEST_DIR`, never from the working-tree copy of the CLI.** This covers `update merge-package`, `merge-workspace`, `merge-audit-ci`, `merge-region` and `regen-regions`. An adopter whose installed binary predates a subcommand cannot reach it any other way, and that is the only reason the rule exists.
2. **A regeneration program named by a declaration's `argv` is the exception, and resolves from the adopter's own tree.** Step 7d passes `--root .` so the runner executes the copy of the program the walk just wrote. A region's body is derived from the adopter's post-merge tree, so resolving that program from the release copy would be the defect, not the rule.
3. **A CLI invocation is never printed as a follow-up command for the adopter, in either form.** The release-resolved form points into the update cache, which a later run's prune removes; the working-tree form is banned by rule 1.

The GAIA helper scripts this file calls (`update-decisions.sh`, `update-gaia-report.sh`) run from the acting tree, `bash .gaia/scripts/<name>`.

## Step 6: Load the manifests

```bash
LATEST_MANIFEST="$LATEST_DIR/.gaia/manifest.json"
BASELINE_MANIFEST="$BASELINE_DIR/.gaia/manifest.json"
BACKUP_DIR=".gaia-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
```

**The expected set.** The report's `files[]` holds one entry per path in keys(baseline manifest `.files`) ∪ keys(latest manifest `.files`) ∪ the path of every `deferred` decision-log entry. Non-deferred decision-log entries add no path. A deferred path absent from both manifests (a deferred upstream removal) gets `class: null` and is evaluated as an upstream removal against its deferred baseline copy (`deleted`, `removed`, or an open `removal` item).

**Deferred entries.** `bash .gaia/scripts/update-decisions.sh deferred --file "$DECISIONS"` prints one `DEFERRED <baselineTag> <path> [<key>]` line per deferred entry. A line without a key defers a whole file: for that path, B is `<EXTRA_DIR path for baselineTag>/<path>` instead of `$BASELINE_DIR/<path>`, and its entry's `baselineTag` is that tag. A line with a key defers one key of a field-aware file (Step 7a to 7c). Every other entry's `baselineTag` is `v$BASELINE`.

**Region declarations.** Load them as `merge-generated.md` describes (`Load the region declarations`), before the walk.

**Recording entries.** Append each path's entry, as one compact JSON object per line, to `$WORK_DIR/entries.jsonl` (`jq -nc ... >> "$WORK_DIR/entries.jsonl"`); Step 9 assembles the report from it. Every path in the expected set gets exactly one line.

## Step 7: The walk

**Design-system sentinel (runs first).** Read the `established` field from the acting tree's `wiki/concepts/Design System.md` frontmatter:

```bash
design_established=false
if [ -f "wiki/concepts/Design System.md" ] && grep -qE '^established:[[:space:]]*true' "wiki/concepts/Design System.md"; then
  design_established=true
fi
```

If `design_established=true`, the adopter has committed their design system, and both `wiki/concepts/Design System.md` and `frontend/.claude/rules/design-baseline.md` are adopter-owned from then on: record each as `skip` with note `design-system` and leave it out of the rest of the walk (no overwrite, no merge, no question, no backup). Otherwise both take the table below as their manifest class dictates.

**Field-aware files are walked separately.** Every `package.json` (the root and each registered package), `pnpm-workspace.yaml` and `.gaia/audit-ci.yml` takes Step 7a to 7c instead of the table below, because a whole-file comparison cannot separate the adopter's identity fields and intentional removals from the real upstream delta. The package directories:

```bash
PKG_DIRS="$(
  {
    printf '.\n'
    jq -r '.[].path' .gaia/packages.json 2>/dev/null || printf 'frontend\n'
  } | grep -E '^(\.|[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*)$' | grep -v '\.\.' | sort -u
)"
```

The registry is `.gaia/packages.json` (adopter-owned, a JSON array of `{name, path}`; absent means the stock `frontend` package); the filter rejects any `path` that is not a plain relative directory, so a hand-edited registry cannot steer the merge outside the tree. A package's generated `<path>/.claude/settings.json` is not in the manifest at all (Step 7e regenerates it), so the walk never sees it.

**The decision table.** Iterate every `<path>: <class>` entry of `$LATEST_MANIFEST`'s `.files`. Let A be `<path>` in the acting tree, B the baseline copy (as Step 6 chose it), L `$LATEST_DIR/<path>`. Use `cmp -s` for equality and `mkdir -p` before writing. A declared region path compares through the region oracle instead (`merge-generated.md`, `Compare a declared path`). Match in order; the first matching row wins:

| Class | Condition | Action | Status |
|---|---|---|---|
| any | A missing and B missing (new in latest) | Copy L to `<path>` | `add` |
| any | A missing and B exists (the adopter deleted it) | Respect the deletion, leave it absent | `removed` |
| `owned` | B missing, A exists (the release newly owns this path) | Back up A to `$BACKUP_DIR/<path>`; copy L over it | `overwrite` |
| `shared` / `wiki-owned` | B missing, A equals L | Nothing | `skip`, note `already-latest` |
| `shared` / `wiki-owned` | B missing, A differs from L | Nothing; record the question | `open`, kind `absent-baseline` |
| any | B equals L (no upstream change) | Nothing | `skip`, note `no-upstream-change` |
| any | A equals B (no adopter drift) | Back up A; copy L over it | `owned` → `overwrite`; `shared` / `wiki-owned` → `merge` |
| any | A equals L (already at latest) | Nothing | `skip`, note `already-latest` |
| any | A differs from B, B differs from L | The three-way merge and judgment pass below | `auto-merged`, `open` or `pending-judgment` |

The B-equals-L row short-circuits every class before anything is merged: an adopter-drifted file the release never touched has nothing to merge, so it stays as it is. An `absent-baseline` item's options are `keep, gaia, defer`, recommending `keep`, with `candidates/<path>.gaia` a copy of L. Back up before each overwrite and set `backedUp: true` on that entry.

Paths in the baseline manifest (or a deferred entry) but not the latest manifest are upstream removals, handled in Step 7f.

### The three-way merge

Every path where A differs from B and B differs from L, in every class (owned included), runs `git merge-file -p` to stdout into a run-dir temp file, **never into A**:

```bash
mkdir -p "$(dirname "$WORK_DIR/<path>")"
git merge-file -p "<A>" "<B>" "<L>" > "$WORK_DIR/<path>.merged"
```

B is the deferred entry's baseline copy (the `EXTRA_DIR` path for its `baselineTag`) when the decision log defers the path. The exit status is 0 for a clean merge and 1 to 127 for that many conflicting hunks; the scratch output can hold conflict markers and is never copied anywhere as it is. A binary file (`git merge-file` reports it cannot merge binary files) becomes an open item of kind `binary`, and any other failure (an exit status above 127) kind `merge-error`; both take the class-fallback order (`keep, gaia, defer` for shared and wiki-owned, `gaia, keep, defer` for owned) with `candidates/<path>.gaia` a copy of L.

### The judgment pass

Run it on every such file, whether the text merge was clean or not. A clean text merge is not enough: two changes can solve the same problem on different lines, and `git merge-file` merges them silently into duplicate or contradictory instructions. Read the adopter's change (B to A) and GAIA's change (B to L) and classify how they relate:

| Relation | Outcome |
|---|---|
| Independent concerns, clean text merge | Write the merge to A (see Chunking for who writes it); status `auto-merged`, no question |
| Independent concerns, the text merge conflicts | `open`, kind `text-conflict`: `combine, keep, gaia, defer` with the resolved combination as the `combine` candidate; when combining is not meaningful, the class-fallback order with no `combine` |
| Same concern, GAIA's covers it | `open`, kind `same-concern-gaia`: `combine` is GAIA's version of that concern with the adopter's other edits to the file kept |
| Same concern, the adopter's covers something GAIA's misses | `open`, kind `same-concern-adopter`: `combine` keeps both parts, and `suggestion` is the one line "open an issue on gaia-react/gaia describing what yours covers" |
| Contradictory | `open`, kind `contradictory`: recommend whichever fits, with a one-line `reason`; the rest of `combine, keep, gaia` follow in that order, then `defer` |

Claims about the adopter's change stay factual: "yours also catches X; GAIA's does not", never that theirs is superior. Option orders follow the option order table in `merge-report.md` exactly.

Write an auto-merged file with `cp "$WORK_DIR/<path>.merged" "<path>"`, after backing A up. A `combine` candidate is the agent's resolved combination of both changes, never conflict markers; its option's `preview` carries the combined lines. Build candidates in the run directory only:

```bash
mkdir -p "$(dirname "$RUN_DIR/candidates/<path>")"
cp "<L>" "$RUN_DIR/candidates/<path>.gaia"
```

and write the `combine` content to `"$RUN_DIR/candidates/<path>.combine"` the same way (a `cp` of a resolved scratch file, or a `printf` redirect). A combination the agent cannot write without leaving a conflict marker means combining is not meaningful: the item takes the class-fallback row instead.

### Filling an open item

Every open item, whatever produced it, carries the fields `merge-report.md` lists:

- **`adopterChange` and `gaiaChange`**: what each side did, in plain words, never a diff.
- **`changelogReason`**: search the file at `$CHANGELOG_RANGE` for an entry naming the path or its basename, and copy that entry's text. When none does, or the range file is absent, it is null; the orchestrator renders "no CHANGELOG entry names this file".
- **`earlierDecision`**: run `bash .gaia/scripts/update-decisions.sh context --file "$DECISIONS" --path <path>`, adding `--key <key>` on a field-aware item. An `EARLIER <tag> <decision>` line fills `{tag, decision}` exactly as printed; no output means null. Write no sentence; the orchestrator formats it.
- **`reason`**: one line saying why the recommended option comes first.
- **`options`**: in the table's order, each with its `label` and `decision` from `merge-report.md`, and its `candidate` (file items) or `value` (field-aware items).

### Chunking

When the orchestrator passes `chunk-1.txt`, judge only the paths it lists. Every other path that reaches the judgment pass is recorded with status `pending-judgment`: its three-way merge still runs into the scratch directory, but nothing is written to A and no candidate is built. A judgment-only agent judges those paths later (see the last section). This agent writes each auto-merged file in its own chunk to A itself and sets no `autoCandidate`.

### Step 7a to 7c: Field-aware files

Each manifest path among the root `package.json`, `<PKG_DIR>/package.json` for every directory in `$PKG_DIRS`, `pnpm-workspace.yaml` and `.gaia/audit-ci.yml` takes the walk's presence rows first (`add`, `removed`, the newly-owned and absent-baseline rows; an L-missing file is an upstream removal for Step 7f). Only when A, B and L all exist does it run the CLI verdict:

```bash
"$LATEST_DIR/.gaia/cli/gaia" update merge-package \
  --baseline "<B>" \
  --latest "$LATEST_DIR/<path>" \
  --current "<path>" \
  ${deferred_baseline_flags} \
  --json
```

`merge-package` serves every `package.json`, `merge-workspace` serves `pnpm-workspace.yaml`, and `merge-audit-ci` serves `.gaia/audit-ci.yml`, each with the same flags. `${deferred_baseline_flags}` holds one `--deferred-baseline <key>=<EXTRA_DIR path>/<path>` per `DEFERRED <baselineTag> <path> <key>` line Step 6 read for this file, the `EXTRA_DIR` path being the one for that `baselineTag`, so a deferred key is merged against the bundle it was deferred from.

The commands are read-only and print `{applied, conflicts, alreadyLatest, keptRemoved, removedUpstream}`. Each item is `{kind, section?, key, baseline?, latest?, adopter?, reason?, versionValued?, recommendation?}`. They visit only keys in B or L, so an adopter-only key is never visited and never clobbered; identity fields (`name`, `version`, `description`, `author` and every other unmanaged key) are never compared.

- **`applied`** (GAIA changed a key the adopter still tracked at the baseline, or GAIA added a key the adopter lacks): write each to A with the **Edit** tool, so the key's value becomes `latest`. Preserve the file's formatting, comments, key order and quote style; never reserialize with `jq` or a YAML dump, which reorders keys or strips every comment. An added key (`reason: "added"`) is inserted into its section matching its neighbors, creating the section when A lacks it. In `.gaia/audit-ci.yml` an `auditors` roster member is one unit: an existing member's mapping is edited to match latest exactly, deleting any field latest does not carry, and a new member is appended as a whole `- name: ...` list item matching its neighbors' indentation and key order.
- **`alreadyLatest`**: nothing to write.
- **`keptRemoved`** (GAIA changed a key the adopter had removed): never re-added. The adopter already decided; it is reported, not asked.
- **`removedUpstream`** (GAIA dropped a key the adopter still has): left in place, the adopter's choice. Step 9's adopter actions read these.
- **`conflicts`**: one open item each, on the file's entry. A CLI item with `versionValued: true` is kind `version-pin`: when `recommendation.option` is `higher`, options `higher, keep, gaia, defer`, otherwise `keep, gaia, defer`. Every other conflict is kind `field-conflict` with options `keep, gaia, defer`. The item's `key` and the suffix of its `id` (`<path>#<key>`) are the CLI item's `section.key`, or its bare `key` when it has no section, exactly. Each option carries its `value`: `keep` the adopter's, `gaia` latest's, `higher` the recommendation's `value`, with decision `gaia` when `recommendation.side` is `gaia` and `keep` when it is `adopter`. `reason` is the recommendation's reason.

Record the entry with status `field-aware`, `fieldMerge` holding the four non-conflict buckets as the CLI printed them, and `items` holding the conflicts. A CLI failure (a missing or unparsable file, such as an adopter YAML syntax error) is not field-aware at all: record the whole file as `open` with one item of kind `merge-error` in the class-fallback order, `candidates/<path>.gaia` a copy of L.

**7a: every `package.json`.** Managed per entry: `dependencies`, `devDependencies`, `scripts`, `engines`, and `packageManager` as one value. Every adopter diverges this file at init and GAIA bumps its own `version` every release, which is why it is never compared whole-file. Resolution, `overrides` and build-approval settings live in `pnpm-workspace.yaml`, not here.

**7b: `pnpm-workspace.yaml`.** A mixed file: GAIA-authored settings (supply-chain and resolution keys, compared whole-value) and the adopter-extensible `overrides` and `allowBuilds` maps (compared per entry), so an adopter who adds one override never sees the whole file asked.

**7c: `.gaia/audit-ci.yml`.** One managed section, the `auditors` roster: GAIA-authored and adopter-extensible at once, parsed into members by exact name, each member's whole mapping compared as one unit. A GAIA-authored member this release adds lands in `applied`, so a new auditor always reaches an existing adopter's file. A 1.x roster, whose members carry unprefixed `app/**` globs, never reaches this step: the orchestrator refuses a 1.x baseline before anything is fetched.

### Step 7d and Step 7e: Generated content

After Step 7c, regenerate declared regions (Step 7d), then the package settings (Step 7e), both as `merge-generated.md` describes. Step 7d passes every `open` or `pending-judgment` declared path as `--conflicted`, so an unresolved file's region waits for the orchestrator's regeneration after the answers. Step 7e reports `settings.state = "pending-resolution"` when `.claude/settings.json` is unresolved.

### Step 7f: Upstream removals

Every path in the baseline manifest but not the latest manifest, and every deferred path absent from both manifests, is an upstream removal with `class: null`. Its B is the deferred entry's baseline copy when the decision log defers it, else `$BASELINE_DIR/<path>`:

- **A missing:** already reconciled. Status `removed`.
- **A equals B** (the adopter never edited it): back up A to `$BACKUP_DIR/<path>`, delete it, status `deleted` with `backedUp: true`.
- **A differs from B:** an open item of kind `removal`. Run `bash .gaia/scripts/update-gaia-report.sh references --tree <acting tree> --path <path>`. `UNREFERENCED` orders the options `remove, keep, defer`; `REFERENCED <file>` orders them `keep, remove, defer`, and the `reason` names that referencing file. Neither option needs a candidate.

## Step 8: The version is written by the orchestrator

The execution agent never writes `.gaia/VERSION`, the manifest copy or the update ping. The orchestrator writes `.gaia/VERSION` last, after the answers, the follow-ups, the after-merge notes and the setup drift, so an interrupted run leaves the version at the baseline and the next run resumes on its update branch. Step 8c, the GitHub label sync, runs here as `merge-generated.md` describes.

## Step 9: The report

**Adopter actions from the saved CHANGELOG range.** A dependency GAIA dropped that the adopter still has (a `removedUpstream` key) and an upstream-removed file the adopter edited (a `removal` item) are follow-ups the merge deliberately leaves to the adopter. Recover their intent from the CHANGELOG range the orchestrator saved; the release bundle withholds `CHANGELOG.md`, so `$LATEST_DIR` holds no copy, and this step fetches nothing:

```bash
if [ -f "$CHANGELOG_RANGE" ]; then
  cat "$CHANGELOG_RANGE"
else
  echo "CHANGELOG_RANGE_UNAVAILABLE"
fi
```

On `CHANGELOG_RANGE_UNAVAILABLE`, leave `adopterActions` empty and add that line to the digest; it is not an empty range. Otherwise match **only** convention-anchored entries: bullets under a `### Removed` or `### Changed` heading that carry an explicit `**Action required:**` line or a literal `pnpm` command in backticks. Key on the heading plus that anchored phrasing; do not free-parse prose. Keep an action only while it still applies: a `pnpm remove <pkg>` or `pnpm uninstall <pkg>` while `<pkg>` is still in one of the adopter's `package.json` files, an action naming a file while that file is still present. Record each survivor as `{subject, command, changelog}`. This stays opt-in: it never removes a dependency or deletes a file.

**Write the report** to `$RUN_DIR/report.json` with Bash, assembling `files` from the entries Step 6 to 7f recorded:

```bash
jq -n \
  --slurpfile files "$WORK_DIR/entries.jsonl" \
  --arg baseline "$BASELINE" --arg latest "$LATEST" --arg latestTag "$LATEST_TAG" \
  --arg backupDir "$BACKUP_DIR" \
  --argjson regions "<regions object>" \
  --argjson settings "<settings object>" \
  --argjson labels "<labels object>" \
  --argjson adopterActions "<adopterActions array>" \
  '{schemaVersion: 1, baseline: $baseline, latest: $latest, latestTag: $latestTag,
    backupDir: $backupDir, files: $files, regions: $regions, settings: $settings,
    labels: $labels, adopterActions: $adopterActions}' > "$RUN_DIR/report.json"
```

**Validate it yourself**, adding `--final` only when judgment was not chunked:

```bash
bash .gaia/scripts/update-gaia-report.sh validate --report "$RUN_DIR/report.json" --run-dir "$RUN_DIR" \
  --baseline-dir "$BASELINE_DIR" --latest-dir "$LATEST_DIR" --decisions "$DECISIONS"
```

`REPORT_OK <n>` means done. Each `REPORT_INVALID <reason>` line names a defect to fix in the entries or candidates; fix it, rewrite the report, and validate again.

**Return a thin digest and stop**: the report path, the count of entries per status, the open item count, and `CHANGELOG_RANGE_UNAVAILABLE` when it applied. Print no summary table for the user and ask nothing. The orchestrator classifies and validates the report, asks the open items, applies the answers, runs the follow-ups, records the update and prints the summary, in `../SKILL.md`.

## Judgment-only agent (chunk 2 and later)

For each later chunk the orchestrator dispatches a judgment-only agent with these same instructions, the inputs above, the `chunk-<k>.txt` path and a cleared `judgment-<k>.json` path. It runs only the parts of Step 7 that judge a path, and only for the paths its chunk lists:

- Use `WORK_DIR="$RUN_DIR/work-<k>"`, `<k>` being the number in its chunk file's name, emptied first. Chunk agents can run at the same time, so each keeps to its own scratch directory.
- For each path: choose B as Step 6 does (deferred entries included), run the three-way merge, and run the judgment pass. A declared region path goes through the region oracle first (`merge-generated.md`); a normalized verdict other than `conflict` is recorded as the row it names, except that `no-adopter-drift` becomes `auto-merged` with the latest copy as its `.auto` candidate, since this agent never writes A.
- **Never write A.** For each independent clean merge, copy the merged content to `candidates/<path>.auto` and set `autoCandidate: "candidates/<path>.auto"` on the `auto-merged` entry; the orchestrator copies it with `update-gaia-report.sh apply-auto` after validating.
- Build every open item and candidate exactly as above, including `changelogReason` and `earlierDecision`.
- Write `judgment-<k>.json` with Bash as a top-level JSON array of file entries, one per path in the chunk (`jq -s '.' "$WORK_DIR/entries.jsonl" > "<judgment path>"`), check that its length equals the chunk file's line count, and return a thin digest: the judgment path, counts per status, the open item count.
