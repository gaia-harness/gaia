# /gaia-cleanse apply procedure

The Stage 2 procedure: apply the report's actions mechanically, verify they landed, file out-of-scope findings, finalize the report. Read whole by the Stage 2 subagent (the entry file's dispatch block says so).

Contents: Step 5 Apply procedure (pre-flight, per-action loop); Post-apply verification; Dispose out-of-scope findings; Post-flight; Guardrails.

## Step 5, Apply procedure (Stage 2, Sonnet)

**Paths.** The report was written from the main checkout, so every in-repo path it names sits under `$PROJECT_ROOT`. You write `$TREE_ROOT`, which is `$PROJECT_ROOT` itself or the run's isolated worktree. Read, drift-check and write every in-repo path, the report's and this procedure's own (`wiki/log.md`, `wiki/index.md`), at the same relative path under `$TREE_ROOT`, and run every `git` command in `$TREE_ROOT`. Run the owner check on the report's path as written, with `--root "$PROJECT_ROOT"`, since ownership follows the relative path and the memory directory is keyed by `$PROJECT_ROOT`. Paths under `$MEMORY_DIR` and `$AGENT_MEMORY_DIR` are used as written. The report and the cleanse state stay under `$PROJECT_ROOT/.gaia/local/`, one copy shared by every worktree.

### Pre-flight

1. Run `bash .gaia/scripts/knowledge-inventory.sh relocate-reports`, then find the most recent non-`applied` report under `$PROJECT_ROOT/.gaia/local/cleanse/`: the newest `KNOWLEDGE-*.md` whose frontmatter `status:` is `draft`, `applied-partial`, or `scoped-partial` (an `applied` or `scoped-applied` report has already been executed and must not be re-applied; skip it). If none, stop and print `no fresh report, run /gaia-cleanse first`. Otherwise check its mtime:
   - mtime ≤ 24h → proceed normally.
   - 24h < mtime ≤ 72h → print `WARNING: draft is {age}h old; drift checks will catch any staleness` and continue.
   - mtime > 72h → stop and print `draft too old (>72h), re-run /gaia-cleanse`.
2. Parse the report's frontmatter. Verify `project_root`, `memory_dir`, and `agent_memory_dir` match the values you resolved at startup. If any differ, stop and print a clear error, the report was generated on a different machine or in a different clone.
3. Run `git rev-parse HEAD`, if it differs from `git_head` in the report, print a warning but continue. Run `git status --short`, any file that is currently dirty AND appears as a target in the report is marked `SKIP (dirty)` before any action runs.
4. Read the report's `## Ordering` section. Process actions in that order.

### Per-action loop

For each unchecked action block:

1. Dependency gate (`delete-entry` carrying `depends_on` only; every other action skips this step): look up the `depends_on` action id's checkbox in the report. If it is anything other than `[x]` (skipped `[~]`, failed `[!]`, still unchecked `[ ]`, or the id is not found), mark this delete-entry `[~]` skipped, record reason `paired action {id} not applied`, and move on WITHOUT removing anything. The `## Ordering` guarantees the referenced `promote`/`delete` is already processed by the time this runs, so its checkbox is authoritative.
2. Verify drift signal. The first three bullets below cover every action type: each names its field-to-file pairings, so a type whose fields are spelled differently is not a separate case. A field the block omits is not checked.
   - **owner** (every action): re-run `bash .gaia/scripts/knowledge-inventory.sh classify --root "$PROJECT_ROOT"` on the files the action writes, as the report names them (the block's `path`, or a promote's `target_page` plus, unless `source_action: keep`, its `source_path`). Any class other than `project-memory` / `adopter`, a non-zero exit, or an `owner:` that disagrees with the result → `[~]` skipped, `owner drift`, move on. An `adopter` file missing from the `Owner-approved files:` line → `[~]` skipped, `owner declined`, move on.
   - **sha field** (`expect_sha256` over `path`, `source_expect_sha256` over `source_path`): compute sha256 of the named file. Mismatch → `[~]` skipped, `sha drift`, move on.
   - **verbatim snippet field** (`expect` and `before` over `path`, `target_expect` over `target_page`, `source_before` over `source_path`): confirm the snippet appears verbatim in the named file. Missing → `[~]` skipped, `snippet drift`, move on.
   - **`promote` only:** confirm `source_action` is one of `delete` / `replace` / `keep`, and that a `replace` carries both `source_before` and `source_after`. Absent, unrecognized, or missing one of that pair → `[!]` failed, reason `unknown source_action`, **source untouched, do not apply**; never guess which was meant. This is a schema-validity check rather than a drift signal, and it runs here because its input is knowable before any write: in the apply step it would fail only after the wiki page, `wiki/log.md` and `wiki/index.md` had already been written.
3. Apply the change using the exact operation:
   - `type: delete` → remove the file
   - `type: delete-entry` → read file, locate the `expect` block, remove it, write back
   - `type: promote` → perform the `target_action` (use Edit or Write as appropriate), then prepend `log_entry` to `wiki/log.md`, then append `index_entry` to the right section of `wiki/index.md`, then act on the source **last**, per `source_action`: `delete` removes `source_path`, `replace` edits it with `old_string: source_before` / `new_string: source_after` (disambiguated the way `type: replace` below disambiguates its `before`), `keep` leaves it alone. The source goes last so a wiki write that fails leaves it intact.
   - `type: replace` → Edit with `old_string: before`, `new_string: after`. If `before` is not unique, prepend additional context from the file until unique.
4. Flip the checkbox: `[ ]` → `[x]` on success, `[~]` on skip, `[!]` on error. Record the reason inline on the checkbox line.

### Post-apply verification (mechanical, no judgment)

Before printing the summary, verify each flipped action landed:

1. **Every `promote` flipped `[x]`:**
   - If the action's `target_action: create_new`: confirm `target_page` exists and is non-empty (the `body` *is* the new page).
   - Otherwise (`append_section` / `insert_after_heading`): confirm the inserted `body` snippet appears in `target_page`.
   - Then verify the source per `source_action`: `delete` → confirm `source_path` is gone; `replace` → confirm `source_after` appears in `source_path` **and** that the file's sha256 now differs from `source_expect_sha256`; `keep` → nothing to verify. The `replace` arm asserts no absence, matching the `body` check above: `source_before` can legitimately survive elsewhere in the file, so asserting its absence would downgrade a correct apply. The sha is what carries the other half, since `source_after` is typically a wikilink the file may already contain, which would pass a bare presence check whether or not the edit landed.
   - On **any** failure, downgrade the checkbox `[x]` → `[!]`, note `promote unverified` on the checkbox line, and the report's terminal `status` is `applied-partial`.
2. **Every `delete` / `delete-entry` flipped `[x]`:** confirm the path (delete) or the `expect` block (delete-entry) is gone. On failure, downgrade to `[!]`, note `delete unverified`, terminal `status` = `applied-partial`.
3. **If a `shrink`/`replace` ran on root `CLAUDE.md`:** re-run `.gaia/cli/gaia fitness check --json --scope all --only claudemd.budget`; if the file is still reported over budget, note `still over budget` (informational only, does NOT downgrade the checkbox or change status).

This verification is the single authority for the report's terminal `status`: after running it, `status` is `applied` only if every action is `[x]`, and `applied-partial` if any action ended `[~]` skipped or `[!]` failed (including a `promote`/`delete` downgraded to `[!]` here).

### Dispose out-of-scope findings (Stage 2)

After applying the in-scope actions, file every finding in the report's `## Out-of-scope findings` section as a `tech-debt` issue: **you file, you never fix**, and never edit the working tree for one. If that report section reads `None.`, skip this step entirely.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: before filing a finding on a harness path, Read `.claude/maintainers/harness-triage-threshold.md`; file none it waives, and name each waived one in your summary so the PR body lists it under `## Waived below triage threshold (not filed)`.
<!-- gaia:maintainer-only:end -->

Filing goes through `.gaia/scripts/file-tech-debt.sh` and nothing else; the file-tech-debt skill (`.claude/skills/file-tech-debt/SKILL.md`, section 0) owns the security screen, the issue-backend check, the dedup, the labels and the divert. For each finding, write one finding JSON to a scratch file under `.gaia/local/cleanse/` and run, with one outcome file for the whole run:

```bash
bash .gaia/scripts/file-tech-debt.sh file --finding <finding.json> --outcome-file .gaia/local/cleanse/filing-outcomes-<unique>.jsonl
```

Map the block's fields onto the finding JSON as follows; the mapping is the whole audit-specific part:

- `member` is the literal `gaia-cleanse`; `finding_class` (or `holistic/unclassified`), `path`, `line`, `title`, `failure_mode`, `suggested_fix`, `footprint` and `audience` carry over by name; `difficulty` becomes `grade`; `severity` (`critical | major | minor`) becomes `issue_severity` (`Critical | Major | Minor`); `security_sensitive` becomes `security`, set from the block's flag alone, since `holistic/unclassified` is the expected class for a doc finding and never a trigger.

Record the filed, diverted and deduped counts (the script's stdout words: `filed <n>`, `matched <n>`, `diverted <count> <record-path>`, `absent`, `transient`, `failed <reason>`) for the final summary. `matched <n>` is the deduped count: issue `<n>` already carries the finding and nothing was filed, so it never counts as filed. `absent` and `transient` are never fatal: file what you can, note the rest, and let the main conversation publish regardless. A diverted finding is reported as a count and a record path only.

### Post-flight

Set the report frontmatter `status:` to the terminal value the verification step above decided: `applied` if every action is `[x]`, otherwise `applied-partial`; on a report whose `scope:` is not `full`, write `scoped-applied` / `scoped-partial` instead, so a scoped run never advances the statusline's last-audit anchor (it reads only `applied` and `applied-partial`). The partial forms are kept so `--apply` can retry the remainder.

Then bust the statusline cache so the audit nudge clears and a fresh check is triggered on the next render (mirrors the `/update-deps` post-run cache-bust). This runs on every Stage 2 completion: the gated Apply path, the `--apply` path, and the 0-action auto-apply path.

```bash
# The resolver's executable entry propagates the function's status: it prints
# the main root and exits 0, or prints nothing and exits non-zero. A missing
# lib fails the same way, so one `||` covers both degradations and the cache
# falls back to this tree.
CACHE_ROOT="$(bash "$PROJECT_ROOT/.gaia/scripts/main-root-lib.sh" "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")"
CACHE="$CACHE_ROOT/.gaia/local/cache/shared/update-check.json"
if [ -f "$CACHE" ]; then
  if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '.cleanseNudge = false | .cleanseNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp" && mv "$tmp" "$CACHE"
  else
    rm -f "$CACHE"
  fi
fi
```

Then print a final summary to stdout:

```

applied: {n} shrink · {n} delete-entry · {n} promote · {n} delete | skipped: {n} | failed: {n}
out-of-scope: filed {n} · diverted {n} · deduped {n} (tech-debt issues)
diff footprint:
{git status --short}
handoff: changes are uncommitted in TREE_ROOT; the main conversation runs Publish next (commit → PR → merge on the run's own branch). An empty diff footprint means Publish no-ops.

```

## Guardrails

- Never delete a memory entry unless the action's `reason` cites a canonical wiki location. (Stage 1 must supply this; Stage 2 doesn't judge.)
- Never edit `wiki/log.md` anywhere except prepending a new line at the top.
- Never write a committed instruction file (a CLAUDE.md file, rule, skill, command or agent) on CONFLICT grounds: a report action that does so is skipped and noted.
- Never improvise: if drift-check fails, skip and report. Do not search for the "right" target.
- Never merge two actions: each block is atomic.
- If an action targets a path that doesn't exist, mark `[!]` with `target missing` and continue.
