# /gaia-cleanse research procedure

The Stage 1 procedure and the report schema Stage 2 parses. Read whole by the Stage 1 subagent (the entry file's dispatch block says so). Audit the knowledge stores for duplication, stale entries, and auto-load bloat. **Wiki is the source of truth.** Memory is machine-local only. Auto-loaded files carry a token cost every session, keep them as pointers, push detail behind lazy wikilinks.

The report you produce is a **contract** to a Sonnet-level executor. Assume it can read, edit, and run bash, but will not reason about intent. Every action needs a literal before/after.

Contents: Stores and load behavior; Step 0 Prune old reports; Step 1 Inventory; Step 2 Cross-store duplication; Provenance-marked rules; Ownership; Step 3 Auto-load budget; Step 4 Report (template, out-of-scope findings, ordering, re-apply).

## Stores and load behavior

| Store                                          | Path                                            | Auto-loaded?                                                |
| ---------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| Machine-local project memory                   | `$MEMORY_DIR/`                                  | `MEMORY.md` (first 200 lines), individual entries on demand |
| Machine-local agent memory                     | `$AGENT_MEMORY_DIR/`                            | Per-agent, on demand                                        |
| Project agent memory                           | `$PROJECT_ROOT/.claude/agent-memory/`           | Per-agent, on demand                                        |
| Project CLAUDE.md (root)                       | `$PROJECT_ROOT/CLAUDE.md`                       | Auto at session start                                       |
| Wiki README                                    | `$PROJECT_ROOT/wiki/README.md`                  | On demand only                                              |
| Project rules                                  | `$PROJECT_ROOT/.claude/rules/*.md`              | Auto at session start, or on a `paths:` match               |
| Project commands                               | `$PROJECT_ROOT/.claude/commands/*.md`           | On invocation only                                          |
| Wiki index                                     | `$PROJECT_ROOT/wiki/index.md`                   | On demand                                                   |
| Wiki domain pages                              | `$PROJECT_ROOT/wiki/<domain>/`                  | On demand                                                   |
| Nested `CLAUDE.md` files (any monorepo layout) | any `$PROJECT_ROOT/**/CLAUDE.md` below the root | Auto when cwd matches                                       |

## Step 0, Prune old reports

Run `bash .gaia/scripts/knowledge-inventory.sh relocate-reports` first, then self-maintain `$PROJECT_ROOT/.gaia/local/cleanse/` before writing the new report. The prune applies to finalized reports only (`applied`, `applied-partial`, and their scoped forms `scoped-applied`, `scoped-partial`):

- **Never prune a `draft`** (live, unfinished work; it is resumable via `--apply`). Treat a missing `status:` as non-`applied`, do not prune it either.
- Of the finalized reports: **keep the newest 5 regardless of age** (floor, protects long gaps between runs); of anything beyond the newest 5, **delete those older than 30 days**.

```bash
if [ -d ".gaia/local/cleanse" ]; then
  # Select only finalized reports, newest first; drafts and
  # status-less reports are never candidates for prune.
  ls -t .gaia/local/cleanse/KNOWLEDGE-*.md 2>/dev/null | while IFS= read -r f; do
    status="$(sed -n 's/^status:[[:space:]]*//p' "$f" 2>/dev/null | head -n1)"
    case "$status" in
      applied|applied-partial|scoped-applied|scoped-partial) printf '%s\n' "$f" ;;
    esac
  done | tail -n +6 | while IFS= read -r f; do
    if [ -n "$(find "$f" -mtime +30 -print 2>/dev/null)" ]; then
      rm -- "$f"
    fi
  done
fi
```

Report the count pruned in the summary line at the end of the run (e.g. `pruned 2 stale reports`).

## Step 1, Inventory

Run the CLI once and work from its output; do not list or count the stores any other way:

```bash
.gaia/cli/gaia fitness inventory --json --root "$PROJECT_ROOT"
```

It prints `{ stores, findings }`. `stores` holds `memory`, `user_agent_memory`, `project_agent_memory`, `rules`, `wiki` and `claude_md`, each `{ count, files: [{ path, words, lines, mtime }] }`. A path outside the project root is written with a symbolic root: `<memory>/` is `$MEMORY_DIR/` and `<agent-memory>/` is `$AGENT_MEMORY_DIR/`; expand both to absolute paths before writing an action. Work from every file it lists and compute totals per store. A non-zero exit, or stdout that does not parse as JSON, is a could-not-run stop: print the CLI's error and write no report.

Write the counts as the report's `store_counts:` with this command, whose output is `<store>=<count>` per store in the inventory's order, space separated (a 0-action report auto-applies only when a fresh recount matches it):

```bash
.gaia/cli/gaia fitness inventory --json --root "$PROJECT_ROOT" | jq -r '[.stores | to_entries[] | "\(.key)=\(.value.count)"] | join(" ")'
```

## Step 2, Cross-store duplication

For every memory entry and every rules file, check whether the same fact lives in the wiki. Use `Grep` with 2–3 representative phrases from each entry. Classify each hit:

- **DUPLICATE**: fact already canonical in wiki → mark memory/rules entry for deletion
- **PROMOTE**: durable knowledge only in memory → propose moving to a specific wiki page (name the page)
- **KEEP-LOCAL**: genuinely machine-local (personal pref, machine path, unique dev env) → keep in memory
- **STALE**: references a file/branch/feature no longer present → mark for deletion. Start from the CLI's dead-path findings, then confirm each against the repo: `.gaia/cli/gaia fitness check --json --scope all --only claudemd.dead-path --only rules.dead-path --only wiki.dead-paths` for files inside the project (read `findings` and `upstream`), and the inventory's `memory.dead-path` findings for memory entries.
- **CONFLICT**: a store asserts a policy that *contradicts* another canonical source on the same subject; opposed, not merely duplicated. Only conflicts across stores are judged here:
  - **Cross-store, memory entry vs wiki page**: a memory entry contradicts the wiki's canonical statement on the same subject. **Resolution favors the wiki.** Emit a `replace` swapping the contradicting line for a wikilink to the canonical page, or a `delete` if the contradicting entry has no residual value. Cite the canonical wiki page + line range in `reason` and note the superseded value inline (e.g. `reason: contradicts wiki/decisions/Foo.md L12-15 (canonical); local store asserted the opposite`).
  - **Cross-store, instruction file vs wiki page**: a rule, skill, command or CLAUDE.md file contradicts a wiki page. No action is emitted for the file: record it in `## Out-of-scope findings` with `severity: major` and a `suggested_fix:` that names the file to reconcile and says `/doctor prompt-audit` owns conflicts between instruction files.
  - **Instruction file vs instruction file** (CLAUDE.md files, rules, skills, commands, agents against one another) is not judged here and yields nothing; the Summary carries one line pointing to `/doctor prompt-audit`.
  - **Two exclusions.** (a) A live `paths:`-scoped rule (including any provenance-marked `gaia-harden:` rule) that differs from the wiki is the sanctioned Rules-vs-wiki duplication case, never a CONFLICT; do not propose editing it on contradiction grounds. (b) If the conflict is **wiki-page-vs-wiki-page**, do NOT act; record it in `## Out-of-scope findings` (suggested fix: `run /gaia-wiki`) so Stage 2 files it, and move on.

Rules-vs-wiki: a `.claude/rules/*.md` file is allowed to duplicate wiki content **only** if it exists to enforce auto-loading for a specific `paths:` glob. Otherwise it should link to the wiki page.

### Provenance-marked rules (`gaia-harden:`)

A `.claude/rules/*.md` rule that carries a line starting with the provenance marker prefix `<!-- gaia-harden: promoted from recurring finding_class`, whichever tail follows (`pruned by /gaia-cleanse ...`, or the 1.x `pruned by /gaia-audit ...`), is recognized by that prefix alone. The current form:

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-cleanse on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

A marked rule is an **ordinary rule** for this cleanse: inventory it, budget it, and apply DUPLICATE / obsolescence / supersession exactly as for a hand-authored rule. The marker grants **no policy-memory exemption**. Such a rule always carries a `paths:` glob, so it is the path-scoped case the Rules-vs-wiki note already permits to duplicate wiki content, no special-casing needed.

The marker is documentation of WHY the rule exists, not a magic token. It also encodes one guardrail: **do NOT classify the rule STALE merely because its anti-pattern is no longer recurring.** A suppressed pattern going quiet is the rule working, not evidence it is stale, and lessons do not expire. The STALE definition already keys on "references a file/branch/feature no longer present", which does not include "the pattern stopped recurring"; non-recurrence is never a prune signal. Prune a provenance-marked rule only on **obsolescence** (its `paths:`-governed surface was removed), **redundancy** (a lint rule, hook, or test now enforces the same thing), **supersession**, or **duplication**.

### Ownership (every action)

A project mixes files GAIA ships, files a third party installed, and the project's own. Classify every file an action would write (its `path`, or a promote's `target_page` plus, unless `source_action: keep`, its `source_path`) in one call, `bash .gaia/scripts/knowledge-inventory.sh classify <file>...`; the script header defines the classes. Only `project-memory` and `adopter` files are editable: write the action with `owner: adopter` when any file it writes is `adopter`, else `owner: project-memory`. Every other class gets no action, only a line in the Summary's `Report-only` list naming the class, the file, the problem, and the remediation: `third-party` is upstream-owned and out of scope (name the vendor pin's package or the plugin); `ignored` goes to the tool that installed it or the machine's owner; `user-memory` is shared by every project on the machine, so the human edits it by hand; `gaia-shipped` is fixed by `/update-gaia`, or `/gaia-forensics` when the latest release still carries the defect. A non-zero exit from the script makes every action on an in-repo file report-only; quote its stderr line in the Summary.

No action may write a committed instruction file (a CLAUDE.md file, rule, skill, command or agent) on CONFLICT grounds, whatever its class: a conflict that involves one is report-only.
<!-- gaia:maintainer-only:start -->
In the GAIA source repo there is no upstream: report a `gaia-shipped` finding with the remediation "fix it in an ordinary pull request". Scrubbed from adopter bundles.
<!-- gaia:maintainer-only:end -->

## Step 3, Auto-load budget

The CLI owns the budgets; this playbook states no numbers. Run:

```bash
.gaia/cli/gaia fitness check --json --scope all --only claudemd.budget
```

Each `claudemd.budget` finding, in `findings` or in `upstream`, names an over-budget file and its message says by how much. Exit 0, or exit 1 with stdout that parses as a check report, is a result (exit 1 only means findings exist). Exit 1 with any other stdout, exit 2, or exit 3 is a could-not-run stop: print the CLI's error and write no report. The same reading applies to every `check` call in this playbook.

For each over-budget file, propose one of: inline facts → wiki, consolidate duplicated sections, or split into narrower files. A `gaia-shipped` file is report-only under the Ownership step.

## Step 4, Report

Write `$PROJECT_ROOT/.gaia/local/cleanse/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md`. Create `$PROJECT_ROOT/.gaia/local/cleanse/` if missing. Also snapshot `git status --short` into the report's frontmatter so Stage 2 can detect drift.

Derive the timestamp from the shell, never guess the current date/time: `date '+%Y-%m-%d-%H%M'` for the `{YYYY-MM-DD-HHMM}` filename, `date '+%Y-%m-%d %H:%M'` for the `generated:` field.

### Report template (strict schema, Stage 2 parses this)

Stage 1 writes `audit_hardened: false`; the classification-verification round flips it to `true` after it hardens the report. A report with the field absent is treated as unhardened.

````markdown
---
generated: {YYYY-MM-DD HH:MM}
generator: audit-knowledge stage-1 sonnet
status: draft
audit_hardened: false
scope: {the scope hint verbatim, or full}
store_counts: {verbatim output of the Step 1 jq command}
project_root: {resolved PROJECT_ROOT}
memory_dir: {resolved MEMORY_DIR}
agent_memory_dir: {resolved AGENT_MEMORY_DIR}
git_head: {commit hash}
git_status_snapshot: |
  {verbatim output of `git status --short` at research time}
---

# Knowledge Audit, {YYYY-MM-DD HH:MM}

Resolved paths (Stage 2 must match these):

- project_root: {resolved PROJECT_ROOT}
- memory_dir: {resolved MEMORY_DIR}
- agent_memory_dir: {resolved AGENT_MEMORY_DIR}

## Summary

- Stores scanned: {N files, M words total}
- Actions proposed: {count of action blocks under ## Actions}
- Cross-store duplicates: {X}
- Auto-load total: {Z words}
- Over-budget files: {list}
- Stale entries: {count}
- Conflicts: {count of cross-store conflicts only}
- Instruction-file conflicts: not audited here; run `/doctor prompt-audit`
- Out-of-scope findings: {count} (filed as tech-debt issues by Stage 2)
- Applied scope: {scope hint, or "full"}
- Report-only: {None., or one sub-bullet per finding the Ownership step allows no action on: class, file, problem, remediation}

## Actions

Each action is a fenced YAML block prefixed with a checkbox line. Stage 2 flips the checkbox from `[ ]` to `[x]` on success, `[~]` on skip, `[!]` on failure. Every block MUST carry the drift signals and, where applicable, the verbatim replacement that its own schema below names. Paths MUST be absolute (already expanded, no `$PROJECT_ROOT` placeholders in action bodies). Every block also carries the `owner:` field the Ownership step decided, after its `type:`.

### Delete

- [ ] `delete-{nnn}`
  ```yaml
  type: delete
  path: {absolute path}
  reason:
    {one line, cite canonical wiki page + line range where the same fact lives}
  expect_sha256: {sha256 of the file's current content}
  ```
````

### Delete-entry (remove a specific block from a multi-entry file, e.g. a heading section in MEMORY.md)

Set `depends_on` when this delete-entry removes an index/pointer line for a file that a `promote` or `delete` action removes (e.g. a `MEMORY.md` line pointing at a promoted or deleted memory file). It names that action's id; Stage 2 removes the pointer only if the referenced action landed (`[x]`), so a `promote`/`delete` that skips on drift never strands the source file with its index line already gone. Omit `depends_on` for a standalone delete-entry that removes content in its own right (nothing else removes a file the entry points at).

- [ ] `delete-entry-{nnn}`
  ```yaml
  type: delete-entry
  path: {absolute path}
  expect: |
    {verbatim block to remove, including heading, must match exactly}
  depends_on: {action id this removal is contingent on, e.g. promote-001 or delete-001; omit the key entirely if standalone}
  reason: {…}
  ```

### Promote (source → wiki)

Within a promote, `source_action` is the only field that touches `source_path`, and it decides what happens to it once the wiki write lands: `delete` removes the whole file (a machine-local memory file lifted onto a wiki page), `replace` swaps one block for another (a section lifted out of a file that stays, leaving a wikilink behind), `keep` leaves it untouched. **A same-file extraction is this one action, never a promote plus a `shrink` on `source_path`.**

- [ ] `promote-{nnn}`
  ```yaml
  type: promote
  source_path: {absolute path}
  source_expect_sha256: {sha256 of source content}
  target_page: {absolute wiki path}
  target_action: {append_section | insert_after_heading | create_new}
  target_heading: {e.g. "## Bar", only if insert_after_heading}
  target_expect: |
    {verbatim snippet at insertion point, omit for create_new}
  body: |
    {verbatim content to insert, frontmatter-ready if target_action=create_new}
  index_entry: {one-line addition to wiki/index.md, or null}
  log_entry: {one-line to prepend to wiki/log.md}
  source_action: {delete | replace | keep}
  source_before: |
    {verbatim block to remove from source_path, must match byte-for-byte; omit unless source_action=replace}
  source_after: |
    {verbatim replacement, typically a wikilink line; omit unless source_action=replace}
  ```

### Shrink / Convert (replace inline content with a wikilink)

- [ ] `shrink-{nnn}`
  ```yaml
  type: replace
  path: {absolute path}
  before: |
    {verbatim current block, must match byte-for-byte}
  after: |
    {verbatim replacement, typically a wikilink line}
  reason: {…}
  ```

## Out-of-scope findings

Real, durable problems Stage 1 surfaced that **none** of the four action types above can fix. Stage 2 **files** each as a `tech-debt` issue (the apply procedure's disposal section); it never edits the working tree for one. Not actions, so no checkbox and no `## Ordering` entry. Write `None.` when there are none, so Stage 2 knows there is nothing to file.

One fenced YAML block per finding:

- `oos-{nnn}`
  ```yaml
  finding_class: {seeded code-audit-frontend finding_class, or holistic/unclassified when it maps to none (the usual case for a knowledge/doc finding)}
  path: {repo-relative POSIX path of the offending file}
  line: {integer line the finding anchors to}
  severity: {critical | major | minor, using the code-audit tier meaning; most knowledge-hygiene findings are minor, a genuine cross-page contradiction is major}
  failure_mode: {one line, concrete: what is wrong and the bad outcome}
  suggested_fix: {one line, e.g. "run /gaia-wiki" for wiki-internal redundancy, a page-vs-page conflict, or a broken wikilink, "reconcile <file> with <page>; /doctor prompt-audit owns conflicts between instruction files" for an instruction file that contradicts a wiki page, or a specific rewrite}
  footprint: {narrow | wide, narrow when the fix is a single logical unit confined to one file with no cross-module ripple, else wide}
  difficulty: {easy | medium | hard, graded against the rubric in .claude/skills/file-tech-debt/SKILL.md, assigned at filing time, not by a later pass}
  security_sensitive: {true only if the finding's CONTENT reads as a security concern or is secret-shaped, else false; the filing script's `security` field takes this value}
  ```
<!-- gaia:maintainer-only:start -->

On the GAIA maintainer repository the block carries one more field, between `difficulty` and `security_sensitive`:

```yaml
audience: {adopter | maintainer, against the rubric in .claude/skills/file-tech-debt/SKILL.md step 6: who can observe the defect, not how bad or how hard it is. Mandatory, unlike difficulty}
```
<!-- gaia:maintainer-only:end -->

## Ordering

Stage 2 must apply actions in this order: `shrink` → `promote` → `delete` → `delete-entry`. Rationale: shrinks never reference content that later gets touched; promotes run before the deletes that remove their sources; and index-pointer removals (`delete-entry`) come last so a `delete-entry` carrying `depends_on` is gated on its referenced `promote`/`delete` having already landed. Removing a pointer only after its target is confirmed gone means a `promote`/`delete` that skips on drift never strands a source file with its index line already deleted.

Wiki-internal redundancy and broken-link repair are handled by `/gaia-wiki` (its consolidate and lint stages), `merge` and `fix-link` action types are not part of this workflow. The audit does not fix them, but it does not drop them either: it records each in `## Out-of-scope findings` so Stage 2 files a `tech-debt` issue whose suggested fix names `/gaia-wiki`.

## To re-apply

Apply runs immediately after this report (or at the decision gate). To re-apply later (e.g., after fixing drift): `/gaia-cleanse --apply` within 72h.

End the research run by printing: report path and total actions per category. (Stage 2 runs next automatically.)
