# update-gaia: the merge report

The contract between the execution agent and the orchestrator. The agent writes the report and its candidate files; the orchestrator classifies the report, validates it, turns its open items into questions, and applies each answer by copying a candidate or writing a value. Both read this file in full: the orchestrator before it dispatches the agent, the agent before Step 6 of `merge-execution.md`. The merge walk can overwrite this file partway through the run, so each keeps following the copy it read.

Contents:

- The run directory
- Writing into the run directory
- The report
- File entries and statuses
- Open items
- Options and the option order table
- Candidates
- Chunked judgment
- How the orchestrator renders the report's sections

## The run directory

Every write of an update run other than the merged tree itself and `.gaia-backup/` lands in one directory, always named by this absolute literal:

```text
<main checkout path>/.gaia/local/cache/shared/update-gaia/run
```

```text
run/
  instructions/merge-execution.md   snapshot taken before dispatch
  instructions/merge-generated.md   snapshot taken before dispatch
  instructions/merge-report.md      snapshot taken before dispatch
  report.json                       the merge report
  judgment-<k>.json                 chunk judgments (top-level JSON array of file entries), k >= 2
  both-changed.txt                  every both-changed path, one per line
  chunk-<k>.txt                     the k-th chunk's paths, one per line
  candidates/<path>.<option id>     one file per non-trivial option
  candidates/<path>.auto            a later chunk's clean merge for an auto-merged path
  work-<k>/                         one agent's scratch (k is 1 for the execution agent); never read by the orchestrator
```

`bash .gaia/scripts/update-gaia-report.sh prepare` empties and recreates the directory once, before the first dispatch. A re-dispatch or the inline fallback clears only `report.json` and `judgment-*.json` (`rm -f` each) and keeps `instructions/`, the chunk files and `candidates/`. Each agent empties its own `work-<k>/` when it starts.

**The tree is never reset.** The mechanical walk is safe to re-run on a partially walked tree: each write moves the adopter's file toward its merged state, and a re-run reads it as already applied (an overwritten file is already latest, an applied key is `alreadyLatest`, a deleted file is `removed`, and a clean merge re-merges to itself because identical changes on both sides merge cleanly). So a re-dispatch and the inline fallback run against the tree as it stands, and nothing resets it.

## Writing into the run directory

The run directory sits under `.gaia/local`, which a linked worktree reaches through a symlink into the main checkout. The Edit and Write tools refuse a path outside the session's worktree, so every write into the run directory goes through Bash: `jq ... > <file>` for the report and judgments, `git merge-file -p ... > <file>` for a merge, `cp` for a copy. The adopter's own files in the acting tree are edited with the Edit tool as usual.

## The report

`<run dir>/report.json`, one JSON object:

```jsonc
{
  "schemaVersion": 1,
  "baseline": "2.0.4", "latest": "2.0.7", "latestTag": "v2.0.7",
  "backupDir": ".gaia-backup/20261018-120000",
  "files": [ FileEntry ],          // exactly the expected set, one entry per path
  "regions": { ... },              // see "regions" below
  "settings": { "state": "regenerated" | "stale" | "pending-resolution", "detail": "..." },
  "labels": { "state": "applied" | "degraded" | "nonzero", ... },
  "adopterActions": [ { "subject": "...", "command": "...", "changelog": "..." } ]
}
```

**The expected set.** `files[]` holds one entry per path in keys(baseline manifest `.files`) ∪ keys(latest manifest `.files`) ∪ the path of every `deferred` decision-log entry. Non-deferred decision-log entries add no path. A deferred path absent from both manifests (a deferred upstream removal) gets `class: null` and is evaluated as an upstream removal against its deferred baseline copy (`deleted`, `removed`, or an open `removal` item). `bash .gaia/scripts/update-gaia-report.sh expect-count` prints the size of that set and `expected-paths` prints the set itself.

The orchestrator classifies the file with `audit-noop-detect.sh --shape agent-report-file --report-key files --expect-count <n>` and validates it with `update-gaia-report.sh validate` (with `--final` once every chunk is folded in). `validate` checks: `schemaVersion` is 1; the path set equals the expected set; no path repeats; every status is one of the list below; an `open` entry carries items; every item's `recommended` equals `options[0].id` and its last option is `defer`; every candidate an option requires exists; every candidate and `autoCandidate` resolves inside the run directory (no absolute path, no `..` segment, no symlink escape) and holds no line starting `<<<<<<<` or `>>>>>>>`; `autoCandidate` appears only on `auto-merged` entries; and with `--final`, no entry is `pending-judgment`.

**`regions`** carries what the declared-region handling found (`merge-generated.md`): `awarenessOff` (boolean), `declarationsLoaded` (number), `droppedDeclarations` (region ids), `fallbacks` (`{path, reason}` with reason `absent-markers`, `malformed-markers` or `oracle-failed`), `malformedDeclarations` (`{index, reason}`), `regen` (the regeneration runner's report, absent when it did not run), `rewrittenPaths` and `unregeneratedPaths`.

**`settings`** is the generated package settings outcome: `regenerated` when the sync and the drift check both exited 0, `stale` when either failed (`detail` holds the error text or the drift output), and `pending-resolution` when `.claude/settings.json` itself is unresolved (an open item or `pending-judgment`), so the orchestrator re-runs the sync after the answer.

**`labels`** is the GitHub label sync outcome: `state` plus, for `applied`, the counts `created`, `renamed`, `descriptions` and `colorDrift`; for `degraded`, `degradedAt` (`read`, `write` or `unknown`), `manualCount` and `manualCommands` (the literal commands, in order); `nonzero` carries nothing else.

**`adopterActions`** holds the documented, opt-in follow-ups the release CHANGELOG names that still apply to this adopter: `subject` (what it acts on), `command` (the literal `pnpm ...` command, when the entry has one) and `changelog` (the entry's text). It is empty both when nothing applies and when the saved CHANGELOG range was unavailable.

## File entries and statuses

```jsonc
{
  "path": "<manifest-relative path>",
  "class": "owned" | "shared" | "wiki-owned" | null,   // null: in neither latest manifest class (an upstream removal)
  "baselineTag": "v2.0.4",                              // the tag whose copy was B (a deferred entry's baselineTag when deferred)
  "status": "...",                                      // one of the statuses below
  "note": "no-upstream-change" | "already-latest" | "design-system" | "...",   // optional, for skip
  "backedUp": true,                                     // optional
  "autoCandidate": "candidates/<path>.auto",            // auto-merged entries from a judgment-only chunk agent only
  "fieldMerge": {                                       // field-aware entries only: the CLI buckets, minus conflicts
    "applied": [Item], "alreadyLatest": [Item], "keptRemoved": [Item], "removedUpstream": [Item]
  },
  "items": [ OpenItem ]                                 // non-empty when status is open; a field-aware entry's
                                                        // per-key conflicts; absent or empty otherwise
}
```

Here A is the adopter's file in the acting tree, B the baseline copy (a deferred entry's baseline copy when the decision log defers the path) and L the latest copy.

- `skip`: nothing to write. `note` says why: `no-upstream-change` (B equals L), `already-latest` (A equals L), `design-system` (the adopter's committed design system owns the path).
- `overwrite`: an owned file replaced with L, A backed up first.
- `merge`: a shared or wiki-owned file the adopter never edited, replaced with L, A backed up first.
- `add`: a file new in the latest release, copied in.
- `removed`: a file absent from the tree that B holds: the adopter deleted it, or it was removed upstream and is already gone. Left absent.
- `auto-merged`: a file both sides changed whose clean three-way merge belongs in the tree because the judgment pass found independent concerns. The execution agent (chunk 1, or the only chunk) writes it to A itself and sets no `autoCandidate`. A judgment-only agent for chunk k >= 2 never writes A: it writes the clean merge to `candidates/<path>.auto` and sets `autoCandidate`; the orchestrator copies every `autoCandidate` over its path with `update-gaia-report.sh apply-auto` after `validate --final`. The review summary names every auto-merged file.
- `deleted`: a file removed upstream that the adopter never edited (A equals B), deleted from the tree after a backup.
- `field-aware`: a `package.json`, `pnpm-workspace.yaml` or `.gaia/audit-ci.yml` merged per key. `fieldMerge` carries the keys applied, already at latest, kept removed and removed upstream; `items` carries one open item per key conflict.
- `open`: a whole-file question. `items` holds exactly one open item, and A is unchanged until the answer is applied.
- `pending-judgment`: a both-changed path a later chunk's judgment-only agent judges. Allowed only between the mechanical walk and the chunk fold; `validate --final` rejects it.

## Open items

```jsonc
{
  "id": "<path>" | "<path>#<section>.<key>",
  "kind": "...",                            // one of the kinds below
  "key": "<section>.<key>" | "<setting>",   // field-aware items only; exactly the CLI item's section.key (or key)
  "adopterChange": "<plain words>",
  "gaiaChange": "<plain words>",
  "changelogReason": "<text>" | null,       // null renders: no CHANGELOG entry names this file
  "recommended": "<option id>",             // always equals options[0].id
  "reason": "<one line>",
  "suggestion": "<one line>",               // same-concern-adopter only
  "earlierDecision": { "tag": "v2.0.4", "decision": "keep" | "blend" } | null,
  "options": [ Option ]
}
```

An open item lives either in an `open` entry (one item, `id` is the path) or in a `field-aware` entry (one item per conflicting key, `id` is `<path>#<key>`). The orchestrator asks every one.

- `text-conflict`: both sides changed overlapping lines for independent reasons, so the text merge conflicts.
- `same-concern-gaia`: both sides address the same concern and GAIA's change covers it.
- `same-concern-adopter`: both sides address the same concern and the adopter's change covers something GAIA's misses. `suggestion` is set.
- `contradictory`: the two changes pull the file in opposite directions.
- `binary`: a binary file both sides changed; no text merge exists.
- `merge-error`: `git merge-file` or a field-aware CLI call failed, so the whole file is asked.
- `absent-baseline`: a shared or wiki-owned file present in A and L but absent from B, so no three-way merge has a base.
- `version-pin`: a field-aware key conflict on a version-valued key (`dependencies`, `devDependencies`, `engines` entries, `packageManager`, `overrides` entries).
- `field-conflict`: a field-aware key conflict on any other key (scripts, workspace settings, `allowBuilds` entries, audit roster members).
- `removal`: a file removed upstream that the adopter edited.

`adopterChange` and `gaiaChange` say in plain words what each side did (B to A, B to L), never as a diff. `changelogReason` is the text of a CHANGELOG entry in the saved range that names the path or its basename, or null. `reason` is one line saying why the recommended option comes first. `earlierDecision` copies the two fields `update-decisions.sh context` prints on its `EARLIER <tag> <decision>` line, or is null when it prints nothing; the orchestrator formats the sentence.

Claims about the adopter's change stay factual: "yours also catches X; GAIA's does not", never that theirs is better. A `same-concern-adopter` item's `suggestion` is one line: open an issue on gaia-react/gaia describing what yours covers.

## Options and the option order table

```jsonc
{ "id": "combine" | "keep" | "gaia" | "higher" | "remove" | "defer",
  "label": "<button text>",
  "decision": "blend" | "keep" | "gaia" | "deferred",
  "candidate": "candidates/<path>.<id>",   // run-dir-relative; required for combine, gaia, higher on file items
  "value": <json>,                          // field-aware items: the value this option writes
  "preview": "<text>" }                     // combine: the combined lines
```

| Option id | Label | Decision | What applying it does |
|---|---|---|---|
| `combine` | Combine both | `blend` | copies `candidates/<path>.combine` over the path |
| `keep` | Keep mine | `keep` | leaves A as it is (a field-aware item writes the adopter's own value, already in A) |
| `gaia` | Take GAIA's | `gaia` | copies `candidates/<path>.gaia` over the path, or writes the option's `value` on a field-aware item |
| `higher` | Use the higher version | `gaia` when the value is GAIA's, `keep` when it is the adopter's | writes the option's `value` |
| `remove` | Remove | `gaia` | deletes the file after a backup |
| `defer` | Decide later | `deferred` | leaves A as it is and records the path for the next update |

A dismissed question counts as `defer`.

**Option order table.** Every item: `recommended` equals `options[0].id`; `defer` is present and last; `remove` maps to decision `gaia`; `keep` and `remove` need no candidate.

| Kind | Recommended | Options, in order |
|---|---|---|
| `text-conflict` (combining meaningful) | `combine` | `combine, keep, gaia, defer` |
| `text-conflict` (combining not meaningful) | class fallback: `keep` for shared and wiki-owned, `gaia` for owned | recommended, then the other of `keep`/`gaia`, then `defer` (no `combine`) |
| `same-concern-gaia` | `combine` (GAIA's version of that concern, the adopter's other edits kept) | `combine, keep, gaia, defer` |
| `same-concern-adopter` | `combine` (both parts kept), with `suggestion` set | `combine, keep, gaia, defer` |
| `contradictory` | whichever fits, with `reason` | recommended, then the rest of `combine, keep, gaia` in that order, then `defer` |
| `binary`, `merge-error` | class fallback as above | recommended, then the other of `keep`/`gaia`, then `defer` |
| `absent-baseline` | `keep` | `keep, gaia, defer` |
| `version-pin` with a strictly higher side | `higher` | `higher, keep, gaia, defer` |
| `version-pin` without one (equal lower bounds, a non-semver spec) | `keep` | `keep, gaia, defer` |
| `field-conflict` (any non-version key) | `keep` | `keep, gaia, defer` |
| `removal`, nothing references the file | `remove` | `remove, keep, defer` |
| `removal`, a tracked file references it | `keep` | `keep, remove, defer` |

Every version-valued key conflict is kind `version-pin`; `higher` is offered only when the CLI found a strictly higher side. A re-pin whose sides have equal lower bounds or a non-semver spec is asked without a "higher" option, since no ordering exists to recommend.

## Candidates

A candidate is the full file content an option writes, stored under the run directory and named `candidates/<path>.<option id>` (for example `candidates/wiki/concepts/X.md.combine`), or `candidates/<path>.auto` for a later chunk's clean merge. The report names it run-dir-relative, never absolute.

- `combine`: the agent's resolved combination of both changes. For `same-concern-gaia` it is GAIA's version of that concern with the adopter's other edits kept; for `same-concern-adopter` it keeps both parts. Its `preview` carries the combined lines the question shows.
- `gaia`: a copy of L.
- `higher`, `keep`, `remove`, `defer`: no candidate on a file item; a field-aware option carries its `value` instead of a candidate.

**No candidate holds a conflict marker.** A candidate is what lands in the adopter's file, so a line starting `<<<<<<<` or `>>>>>>>` never appears in one; `validate` rejects it. When the agent cannot write a resolved combination, the item takes the class-fallback row (no `combine` option) instead.

## Chunked judgment

When the both-changed files are many, the orchestrator splits them with `update-gaia-report.sh chunk` into `chunk-1.txt` .. `chunk-<k>.txt`. The execution agent judges only the paths in `chunk-1.txt` and records every other both-changed path as `pending-judgment` (its text merge still runs; nothing is written to A). For each later chunk the orchestrator dispatches a judgment-only agent that follows the same instructions for its chunk's paths only, never writes A, and writes `judgment-<k>.json`: a top-level JSON array of file entries, one per path in its chunk. For each independent clean merge it writes the merged content to `candidates/<path>.auto` and sets `autoCandidate` on the `auto-merged` entry. The orchestrator folds every judgment in with `update-gaia-report.sh merge-judgments`, validates with `--final`, then copies the auto merges with `apply-auto`.

## How the orchestrator renders the report's sections

The review summary carries four sections the adopter cannot see any other way. Each backticked row below is the whole literal to print.

**Package settings.** `regenerated` → `Package settings: regenerated and drift-clean`. `stale` → `Package settings: stale (<detail>); run ./.gaia/cli/gaia packages sync-settings by hand`. `pending-resolution` is resolved by the orchestrator's own sync re-run after the answer; render the outcome of that re-run the same two ways. Never render a clean row for a sync that did not run.

**Labels.**

- `nonzero` → `Labels: unknown (gaia labels sync exited non-zero; some labels may already have been applied)`. A non-zero sync can stop partway through with earlier creates and renames already written, so the row never says nothing happened.
- `applied`, all four counts `0` → `Labels: no changes (already in sync)`.
- `applied`, any count non-zero → `Labels: <created> created, <renamed> renamed, <descriptions> descriptions updated, <colorDrift> color drift found (color drift not applied; your own recolor wins)`.
- `degraded` → the row for `degradedAt`, then `manualCommands` beneath the summary inside a fenced code block:
  - `write` → `Labels: could not write (token lacks label scope); <manualCount> manual commands still owed, listed below. The mutations applied before the refusal are not repeated.`
  - `read` → `Labels: could not read or write (token lacks label scope); the <manualCount> commands below are the whole registry, not the work remaining, because the repository's labels could not be read. A create for a label you already have fails harmlessly.`
  - `unknown` → `Labels: could not complete (token lacks label scope); <manualCount> manual commands, listed below. This CLI does not record which refusal degraded it, so the list is either the mutations still owed or the whole registry. A create for a label you already have fails harmlessly either way.`

The `read` and `unknown` rows claim no remainder because computing one needs the read that was refused.

**Regions.** Counts come from `regions.regen` (`ran`, `failed`, `skipped`, `refused`) and `regions.fallbacks`.

- `awarenessOff` true → `Regions: awareness off for this run (GAIA_UPDATE_NO_REGIONS=1); every declared path used the whole-file comparison`, and nothing else in this section.
- `regen.refused` carries a `kind: 'manifest'` entry → `Regions: this release's manifest could not be read (<reason>); no region guarantee applied to this run`. This row outranks the next one: a `regions` key present but not an array loads zero declarations, so the other order would tell the adopter the release declares no regions when it declares regions this run could not read.
- `declarationsLoaded` 0 → `Regions: none declared by this release`.
- Every count zero → `Regions: all declared regions current (no regeneration needed)`.
- Otherwise `Regions: <r> regenerated, <f> failed, <s> skipped, <x> refused`, then `Region fallbacks: <n>` counting only `malformed-markers` and `oracle-failed` (the paths that took the whole-file comparison), and `Pre-region paths: <n>` counting `absent-markers` (normalized per side, nothing wrong). Omit either of the last two rows when its count is zero.

Then, whenever each applies:

1. **Rewritten regions.** Name every path in `rewrittenPaths` and state that those files now intentionally differ from the release copy because their region is derived from this adopter's own configuration.
2. **Failed or refused regenerations.** One entry per region with the literal argument vector from its `argv`, inside a fenced code block (for the region GAIA ships today, `bash .gaia/scripts/write-audit-remits.sh`). Report each `failed[].kind` distinctly (`exit`: read what the program said; `spawn`: install the interpreter or make it executable; `killed`: cut short by a signal, its paths may hold half-written output), and on `killed` report `cause` too (`timeout` or `maxBuffer`: a ceiling this flow imposes, so make the command finish sooner or say less; `external`: something on the adopter's machine stopped it). A `kind: 'declaration'` refusal has no `argv`: print the defect and say the remedy is upstream, never a fabricated command.
3. **Skipped regenerations.** The region, the runner's reason, and the literal command from its `argv` in a fenced code block. The follow-up is always the regeneration program, never a CLI invocation: the release-resolved CLI points into the update cache, which a later run prunes.
4. **Un-regenerated regions.** Every path in `unregeneratedPaths`, whatever its status, as carrying a generated block that does not match what this adopter's own configuration would produce. Suppression is region-granular, so a sibling path that took GAIA's copy can carry GAIA's region instead of the adopter's.
5. **Whole-file fallbacks.** Every `fallbacks` entry by reason: `oracle-failed` and `malformed-markers` returned that path to pre-region behavior for this run, so a divergence confined to its region reads as ordinary drift; `absent-markers` means the file does not carry the region yet, the expected state before its first regeneration.
6. **Dropped declarations.** Every id in `droppedDeclarations`: its paths return to whole-file comparison from now on.
7. **Malformed declarations.** Each entry with its index and reason, paired with the off switch: `GAIA_UPDATE_NO_REGIONS=1` disables region awareness for one run.
8. **Audit gate clearance.** The paths carrying a shipped region are audit gate machinery, so a regeneration write on a resumed update changes files the gate already cleared: earlier clearance markers on the same pull request are invalidated and the Code Audit Team members are re-spawned on the new HEAD.
9. **Confined writes.** Each `regen.confined` entry with its action. `restored` and `removed` are writes outside the region's declared paths that the runner undid; `reported` is one it left alone (a write outside the region's directories, or a restore it could not complete), and that is the one the adopter has to look at.

**Adopter actions.** When `adopterActions` is non-empty, print each as an opt-in suggestion naming its subject and its literal command (for example: GAIA removed `react-router-dom` this release, run `pnpm remove react-router-dom`? It is still in your `package.json`), and say they are advisory. When the saved CHANGELOG range file does not exist, print `Adopter-action suggestions skipped: the release CHANGELOG could not be fetched.` instead, so an empty list never reads as "this release documents nothing to do".
