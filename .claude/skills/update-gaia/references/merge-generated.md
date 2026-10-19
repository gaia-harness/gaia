# update-gaia: generated content during the merge

The execution agent reads this file in full before Step 6 of `merge-execution.md`, alongside that file and `merge-report.md`. It holds the mechanics for content the merge never hand-merges because a machine regenerates it: declared generated regions (loaded in Step 6, compared in the Step 7 walk, regenerated in Step 7d), the generated package settings (Step 7e), and the GitHub label sync (Step 8c). Each outcome lands in the report's `regions`, `settings` or `labels` object; nothing here asks the user anything, and the orchestrator renders those objects as `merge-report.md` describes.

Every CLI call here follows **Command resolution** in `merge-execution.md`.

Contents:

- Load the region declarations (Step 6)
- Compare a declared path (Step 7)
- Step 7d: Regenerate declared regions
- Step 7e: Regenerate package settings
- Step 8c: Sync GitHub labels

## Load the region declarations (Step 6)

A few shipped files carry a marker-delimited region whose body is machine-generated: a shipped command rewrites it, so an adopter who runs that command diverges from the release copy without ever hand-editing the file. The manifest declares each one under an optional top-level `regions` key, and the Step 7 walk compares a declared path with its region masked out instead of whole-file.

```bash
REGION_AWARE=true
if [ "${GAIA_UPDATE_NO_REGIONS:-}" = "1" ]; then
  REGION_AWARE=false
fi

REGION_DECLS='[]'
BASELINE_REGION_DECLS='[]'
if [ "$REGION_AWARE" = true ]; then
  REGION_DECLS="$(jq -c 'if type == "object" and has("regions") then .regions else [] end' \
    "$LATEST_MANIFEST" 2>/dev/null || echo '[]')"
  BASELINE_REGION_DECLS="$(jq -c 'if type == "object" and has("regions") then .regions else [] end' \
    "$BASELINE_DIR/.gaia/manifest.json" 2>/dev/null || echo '[]')"
fi
```

**`has("regions")`, not `.regions // []`.** jq's `//` also fires on `false` and `null`, so a wrong-typed `regions` would collapse to `[]`, skip the Step 7d runner, and render `Regions: none declared by this release` instead of the runner's `kind: 'manifest'` refusal. Testing presence lets every wrong-typed value reach the runner, which classifies it.

**A manifest whose top level is not an object** yields `[]` through the `type == "object"` half of the guard, so the runner never sees it and no `kind: 'manifest'` refusal is produced. The Step 7 walk finds no `.files` in it either, so the whole update has failed: report an unusable manifest, not a refused region.

Each declaration is `{id, startMarker, endMarker, paths[], regenerate: {interpreter, operand, args[]}}`. Build a lookup of declared path to declaration so the Step 7 walk can test each path in one step, and fill the report's `regions` object as you go (`declarationsLoaded` counts the declarations loaded, `awarenessOff` records the off switch).

- **Parse defensively.** There is no manifest validation on the adopter side; this flow reads raw JSON and iterates the file map. A `regions` key that is absent or an empty list means the same thing: zero declarations, no oracle call, no regeneration, and every file classified by the unmodified whole-file comparison exactly as it is without region awareness. A key that is **present but not an array** loads zero declarations too but is **not** the same thing: it is a manifest this flow could not read, and Step 7d's runner refuses it by name (`refused[]`, `kind: 'manifest'`). A manifest whose top level is not an object takes the separate path described above and never reaches the runner.
- **Ignore a malformed declaration, do not abort.** A declaration that is not an object, is missing `id` / `startMarker` / `endMarker` / `regenerate` / `paths`, carries an empty or whitespace-only marker, or repeats an `id` already seen, is skipped: its paths take the unmodified whole-file comparison and no regeneration runs for it. Record each as `regions.malformedDeclarations[]` (`{index, reason}`).
- **The off switch.** `GAIA_UPDATE_NO_REGIONS=1` set in the environment for one run makes the flow load zero declarations, and the update otherwise behaves exactly as it does without region awareness. Record `regions.awarenessOff: true`. This is the adopter-facing remedy for a bad declaration or an oracle bug in the field: it needs no edit to the write-blocked `.gaia/manifest.json` and no flag on the command.
- **Dropped declarations.** Any `id` the **baseline** manifest declared that the latest manifest does not is a dropped declaration. Its paths return to the unmodified whole-file comparison, so a divergence that region awareness had been absorbing comes back. Record each id in `regions.droppedDeclarations[]` so the return is announced rather than discovered.
- **Region awareness governs the next update, not this one.** The walk is prose the agent holds from the acting tree's **installed** copy of these instructions (the orchestrator's snapshot is of that copy), and nothing re-reads instruction prose out of the staged release. So the first update that installs a change to region handling still runs the handling that predates it. Resolving the CLI subcommands from `$LATEST_DIR` does not shorten the lag; it only makes a newly shipped subcommand reachable at all.

## Compare a declared path (Step 7)

A path that appears in one of the declarations takes a single oracle call in place of the whole-file `cmp -s` comparisons, so a divergence confined to the machine-generated region does not read as adopter drift.

**Presence triage still runs first, unchanged.** The walk's presence rows (`add`, `removed`, the owned newly-owned overwrite and the absent-baseline rows) resolve before the oracle is consulted. A path the adopter deleted, a path the release no longer ships, and a path absent from the baseline are settled there: no oracle call; Step 7d's suppression flags (below) decide which of them are regenerated.

For a declared path that survives triage:

```bash
region_json="$("$LATEST_DIR/.gaia/cli/gaia" update merge-region \
  --baseline "<B>" \
  --latest "$LATEST_DIR/<path>" \
  --current "<path>" \
  --start-marker "<declaration startMarker>" \
  --end-marker "<declaration endMarker>" \
  --json 2>/dev/null)" || region_json=''
```

`<B>` is the same baseline copy the walk uses for the path (the deferred entry's copy when the decision log defers it). Read `.verdict` and take the matching row of the Step 7 decision table, applied to the normalized content instead of raw content:

| `verdict`            | Row it takes                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------- |
| `no-upstream-change` | `skip`, note `no-upstream-change`                                                                       |
| `no-adopter-drift`   | Back up A to `$BACKUP_DIR/<path>`; copy L over it. `owned` → `overwrite`, `shared` / `wiki-owned` → `merge` |
| `already-latest`     | `skip`, note `already-latest`                                                                           |
| `conflict`           | The three-way merge and judgment pass on the normalized bodies (below)                                  |

**Merge and judge the normalized bodies.** The oracle emits the three normalized bodies because nothing else in this flow can parse a region. Write them into your scratch directory and run the three-way merge on them, never on the raw files:

```bash
printf '%s' "$region_json" | jq -r '.normalized.current'  > "$WORK_DIR/<path>.A"
printf '%s' "$region_json" | jq -r '.normalized.baseline' > "$WORK_DIR/<path>.B"
printf '%s' "$region_json" | jq -r '.normalized.latest'   > "$WORK_DIR/<path>.L"
git merge-file -p "$WORK_DIR/<path>.A" "$WORK_DIR/<path>.B" "$WORK_DIR/<path>.L" > "$WORK_DIR/<path>.merged"
```

The judgment pass then reads B to A and B to L in those normalized bodies. A divergence confined to the region is never an open item: the verdict above already absorbs it, and the region body is rewritten by Step 7d or by the orchestrator's regeneration after the answers. An auto-merged write and a `combine` or `.auto` candidate for a region path are built from the normalized merge, so they carry the oracle's one placeholder line between the markers where the region body was; regeneration writes the body. The `gaia` candidate is the latest copy itself.

**Marker anomalies.** Read `.markers` and record a fallback in `regions.fallbacks[]` under a reason that keeps two states apart:

- `.markers.bailed` is `true` → reason `malformed-markers`. Some side's marker pair is duplicated, unbalanced, or out of order, so the oracle normalized **no** side, its verdict is the row the unmodified whole-file comparison produces, and it still exited 0.
- `.markers.bailed` is `false` and some side reports `"scan": "absent"` → reason `absent-markers`. That side carries no marker pair at all, which is the **expected pre-region state**, not a defect. Normalization still applied per side.

**Oracle failure.** When the command exits non-zero (`region_json` empty: a CLI predating the subcommand, an unreadable file, a missing flag), fall back to the **unmodified whole-file comparison** for that path, never to a forced open item. Record reason `oracle-failed`: that path has returned to its pre-region behavior, which for an adopter carrying a region-only divergence is exactly the question region awareness exists to remove.

## Step 7d: Regenerate declared regions

**This step runs after the field-aware merges (Step 7c) and before Step 8, and the ordering is the whole point of the step.** A declared region's body is derived from the adopter's own post-merge tree, and for the shipped audit-remit region that source is the `auditors` roster in `.gaia/audit-ci.yml`, which Step 7c merges. Regenerating before Step 7c would derive every region from the **pre-merge** roster, so a GAIA-authored member this release just added would be missing from the region the adopter ends up with. Running before Step 8 keeps the whole merge, including this write, inside the window `.gaia/VERSION` still names the baseline, so an interrupted run stays resumable.

```bash
if [ "$REGION_AWARE" = true ] && [ "$REGION_DECLS" != "[]" ]; then
  regen_json="$("$LATEST_DIR/.gaia/cli/gaia" update regen-regions \
    --manifest "$LATEST_MANIFEST" \
    --root . \
    --backup-dir "$BACKUP_DIR" \
    ${conflicted_flags} \
    ${absent_path_flags} \
    ${skip_region_flags} \
    --json 2>/dev/null)" || regen_json=''
fi
```

Both resolutions in that call follow **Command resolution**: the `regen-regions` subcommand resolves from `$LATEST_DIR` (rule 1), and `--root .` points the runner at the acting tree so it runs the copy of the regeneration program the walk just wrote (rule 2).

Build the three repeatable flag groups from this run's own entries:

- `${conflicted_flags}`: one `--conflicted <path>` per declared path whose entry is `open` or `pending-judgment`. An unresolved path is **not** regenerated on this run; regenerating would discard whatever the adopter is about to choose. The orchestrator re-runs regeneration after the answers, with no `--conflicted` flag for a path the answers resolved.
- `${absent_path_flags}`: one `--absent-path <path>` per declared path whose entry is `removed`. A path the adopter deliberately deleted must not be resurrected, and the runner cannot infer that on its own: mid-run, a deliberately deleted file and an ordinary pre-region absence look identical on disk. Passing them explicitly is what makes "deletions are respected" a property of the mechanism rather than a coincidence of one writer's behavior.
- `${skip_region_flags}`: one `--skip-region <id>` per region whose inputs this run did not reconcile. Today that means the `.gaia/audit-ci.yml` entry carries an open item (a roster conflict, an absent baseline, or a `merge-error` fallback), so the roster the audit-remit region derives from is not yet the merged one.

**Suppression is region-granular.** One `--conflicted` or `--absent-path` hit suppresses the **whole region**, not just that path, and the region lands in `skipped[]` with the reason naming the paths responsible. Its sibling declared paths may already carry the release copy from the walk, so they now hold GAIA's version of the region rather than the adopter's. Every declared path of a skipped, refused, or failed region goes into `regions.unregeneratedPaths`, whatever status its own entry has.

The runner exits `0` for every refusal, skip, spawn failure, and non-zero program exit; only unusable flags or an unusable manifest are a non-zero exit. **A failed or refused regeneration never fails the update.** If `regen_json` is empty, leave `regions.regen` absent and continue: the expected cause is a CLI that predates the subcommand.

Store the parsed report as `regions.regen`, and flatten `ran[].rewrote` into `regions.rewrittenPaths`. The report shape:

```ts
type RegenRegionsReport = {
  backedUp: string[];   // declared paths the runner copied into $BACKUP_DIR itself
  confined: Array<{     // entries outside a region's declared paths
    action: 'removed' | 'reported' | 'restored';
    path: string;
    regionId: string;
  }>;
  failed: Array<{argv: string[]; cause?: 'external' | 'maxBuffer' | 'timeout'; kind: 'exit' | 'killed' | 'spawn'; message: string; regionId: string; signal?: string; status?: number}>;
  ran: Array<{argv: string[]; regionId: string; rewrote: string[]}>;
  refused: Array<{argv?: string[]; kind: 'declaration' | 'manifest' | 'operand'; reason: string; regionId: string}>;
  skipped: Array<{argv: string[]; reason: string; regionId: string}>;
};
```

Every bucket the summary prints a command for carries its own `argv`, because the region id alone cannot be turned back into a command. `refused` declares `argv` optional because a `kind: 'declaration'` refusal has none. A `kind: 'manifest'` refusal is about the manifest itself rather than any one region, so it likewise has no `argv` and carries the sentinel `regionId` `(manifest)`.

`failed[].kind` has three values, each with its own remedy. `exit` is a program that ran and refused, and its `message` carries the program's own stderr. `spawn` is an interpreter that never launched. `killed` is a program that ran and was cut short by a signal (`signal` names it), so its declared paths may hold half-written output. On a `killed` entry, `cause` says which of the runner's own ceilings ended it: `timeout` (5 minutes) or `maxBuffer` (32 MiB of output), against `external` for a kill from anywhere else. Neither ceiling is adjustable from the invocation this flow makes.

What the step guarantees, and what it does not:

- **The regeneration is authoritative.** A declared region's body is machine-authored, so regeneration overwrites whatever sits between the markers, including an adopter's hand edits inside them. `regions.rewrittenPaths` names every path whose region this run rewrote, so the overwrite is stated rather than silent.
- **Writes are confined and backed up.** A region's regeneration command legitimately rewrites the paths it declares and nothing else, and **scope decides how a write outside them is handled**. Before the spawn the runner records every file and symlink under the region's own directories, the run's **snapshot**, in which each path's recorded state is its **pre-image**; anywhere else in the tree it records nothing. Inside the snapshot, a path the command left changed is restored to its pre-image and a path it created is removed; a path the command deletes is left deleted and not reported. Anywhere else there is no pre-image to restore from, so a write is reported and left where the command put it. The runner also copies every declared path it is about to rewrite into `$BACKUP_DIR` first, unless the walk already backed that path up.

  Symlinks take the same rule, because a link's pre-image is the target string it holds: one the command retargets or swaps for a regular file is put back as a link on its original target, and one it creates is removed. Restoring a link writes no content and follows nothing.
- **The operand guard is well-formedness, not security.** The runner refuses an operand that is absolute, carries a parent-directory segment, resolves through a symlink out of the repository, or is not an exact key of the same manifest's shipped file map. This guards against a stale, corrupt, or hand-edited declaration. It is **not** a defense against anyone who controls the manifest: the flow already runs the release tarball's bundled tool.

## Step 7e: Regenerate package settings

**Runs after Step 7d and before Step 8**, so the root `.claude/settings.json` the walk just merged is the input and an interrupted run stays resumable. A registered package's `<path>/.claude/settings.json` (`frontend/.claude/settings.json` in a stock tree) is **generated** from the root settings plus the package's `settings.overlay.json`, never merged: it is not in the release manifest, so a root hook, deny rule, or permission this release changed reaches the package only through this step. A session launched inside `frontend/` reads that file and never the root one, so skipping the step leaves a guard silently absent there.

```bash
./.gaia/cli/gaia packages sync-settings \
  && bash .gaia/scripts/check-settings-drift.sh
```

By now the walk has replaced `.gaia/cli/gaia` and `.gaia/scripts/check-settings-drift.sh` with the release's copies, so the acting tree's commands are the right ones here (unlike the region subcommands, which resolve from `$LATEST_DIR` because the walk has not run yet at their call sites).

Record the report's `settings` object:

- **`.claude/settings.json` is unresolved** (its entry is `open` or `pending-judgment`): `state: "pending-resolution"`, whatever the commands returned, with their outcome in `detail`. The regeneration ran from the adopter's pre-answer root settings, so the orchestrator re-runs the sync and the drift check after the answer.
- **Otherwise, exit 0 from both:** `state: "regenerated"`.
- **`sync-settings` exits non-zero** (a malformed registry, or an overlay that tries to remove a root deny): do not retry or edit the overlay. `state: "stale"`, with the error text in `detail`.
- **The drift check exits 1:** the generated file still disagrees with the root settings. `state: "stale"`, with the drift output in `detail`.
- **The package has no `settings.overlay.json`:** not an error, the overlay is optional.

## Step 8c: Sync GitHub labels

Runs after the walk and Step 7d have settled the tree, and before Step 9. The walk is what delivers a new release's `.gaia/labels.json`, so syncing before it would sync the registry the adopter is upgrading away from.

```bash
labels_sync_err="$(mktemp)"
labels_sync_json="$(.gaia/cli/gaia labels sync --json 2>"$labels_sync_err")" || labels_sync_json=''
```

Keep the stderr rather than discarding it. Under `--json` the plan owns stdout alone, so the marker saying the sync could not write goes to stderr; a step that drops it cannot tell a sync that reconciled the repository from one that only described what it would have done.

No `--adopt` flag. Color drift stays reported, never applied, on every run this step makes: an adopter's own recolor of a label always wins over the registry's suggested color.

This step is advisory and never fails the update; a token without label-write scope is common on an org-owned repository. A sync that cannot write still exits 0. Under `--json` the manual `gh label create` / `gh label edit` commands survive only as `manual-command` actions inside the plan, so recording them is this step's job.

```bash
count_kind() {
  printf '%s' "$labels_sync_json" \
    | jq "[.actions[]? | select(.kind == \"$1\")] | length" 2>/dev/null \
    || printf '0'
}

if [ -z "$labels_sync_json" ]; then
  LABELS_STATE=nonzero
elif grep -q '^labels-sync: degraded' "$labels_sync_err"; then
  LABELS_STATE=degraded
  LABELS_MANUAL_CMDS=$(printf '%s' "$labels_sync_json" | jq -r '.actions[]? | select(.kind == "manual-command") | .command' 2>/dev/null)
  LABELS_MANUAL=$(count_kind manual-command)
  LABELS_DEGRADED_AT=$(printf '%s' "$labels_sync_json" | jq -r '.degradedAt // "unknown"' 2>/dev/null || printf 'unknown')
else
  LABELS_STATE=applied
  LABELS_CREATED=$(count_kind create)
  LABELS_RENAMED=$(count_kind rename)
  LABELS_DESC=$(count_kind drift-description)
  LABELS_DRIFT=$(count_kind drift-color)
fi
rm -f "$labels_sync_err"
```

Record the report's `labels` object from those values: `state` from `LABELS_STATE`; for `applied`, `created`, `renamed`, `descriptions` and `colorDrift`; for `degraded`, `degradedAt`, `manualCount` and `manualCommands` (one string per line of `LABELS_MANUAL_CMDS`).

The empty test comes first. `$labels_sync_json` is emptied by the `||` on **any** non-zero exit, and that case writes no degraded marker either, so a block testing the marker first would fall to the `applied` arm, count zeros, and report a sync that never applied anything as already in sync. Do not read `nonzero` as "the sync never ran": it covers a CLI predating the subcommand, a usage or environment error, and a real `gh` failure that can stop partway through with earlier creates and renames already written.

**Count all four applied kinds, not three.** Description drift is written on every sync (the registry wins on description), while color drift is withheld without `--adopt` and only reported. Counting creates, renames, and color drift alone would render a repository whose descriptions were just rewritten as unchanged.

**Read `degradedAt`** (`"read"` or `"write"`) before treating the manual list as the remainder: it is the remainder only after a refused write, and `merge-report.md`'s three `degraded` rows own the literal each case prints. The fallback is `unknown`, not `write`: a CLI predating the field gives no way to tell which refusal degraded it.
