---
type: decision
status: active
priority: 1
date: 2026-05-07
created: 2026-05-07
updated: 2026-10-13
tags: [decision, wiki, cli]
---

# Wiki Management

The wiki is critical infrastructure; it decays when drift between code and documentation grows unchecked. To keep it accurate and focused, the CLI provides a set of deterministic primitives for evaluating, logging, and auditing wiki state.

## Primitives

**`gaia wiki state`**: Outputs current sync state: `head_short` (short HEAD SHA), `state_sha`, `commits_ahead` (drift count), `reachable` (whether recorded SHA is in HEAD's history), and `suggested_base`. When `reachable` is false, `suggested_base` is the newest commit on HEAD's first-parent chain at or older than `last_evaluated_at`, a recovery baseline that lets a sync resume the un-evaluated window after a squash- or rebase-merge orphans the recorded SHA, instead of discarding it. It is empty when reachable or when no baseline resolves. Used by hooks and commands to detect when a sync is needed.

**`gaia wiki commit-classify`**: Evaluates commits since a baseline SHA. For each commit, outputs `suggestion` (`WORTHY` or `SKIP`) based on subject and file paths. WORTHY commits warrant deep-read, a wiki update, and a `wiki/log.md` line; SKIP commits get neither. The classification is deterministic; same commit always produces the same suggestion. A git failure while reading the range propagates as a `git_failed` error rather than resolving to an empty commit list, so a transient failure is distinguishable from a genuinely empty `<since>..HEAD` range.

**`gaia wiki state-init <sha>`**: Creates `wiki/.state.json` seeded from `<sha>`; refuses if the file already exists. Bootstrap primitive used during repo onboarding before the first `/gaia-wiki` run.

**`gaia wiki state-bump <field> <value>`**: Atomically updates `wiki/.state.json`, preserving sibling fields and key order. Used by the sync stage of `/gaia-wiki` to advance `last_evaluated_sha` and `last_evaluated_at`; used by its consolidate stage to advance `last_consolidated_sha`.

**`gaia wiki log-prepend`**: Appends a single line to `wiki/log.md` in the format `- <YYYY-MM-DD> <sha> <decision> - <reason>`. Atomic insertion after frontmatter, newest entries on top. One call per commit.

**`gaia wiki page-index`**: Walks `wiki/` frontmatter and counts inbound/outbound wikilinks per page. Used by orphan and redundancy detection.

**`gaia wiki orphans`**: Lists pages with zero inbound links (newline-separated). Candidates for archival or cross-linking.

**`gaia wiki near-collisions`**: Groups pages per domain (decisions, concepts, modules, etc.) and finds near-duplicate titles using Levenshtein distance. Used by the consolidate stage of `/gaia-wiki` to surface redundancy.

**`gaia wiki dead-paths`**: Lists backticked repo paths in `wiki/` body prose that don't exist on disk. Used by the lint stage of `/gaia-wiki` to catch zombie filename references after merges and renames. The scanner owns its exemptions; any absent path outside them is reported, including one absent by design, such as a gitignored machine-local file.

**`gaia wiki broken-links`**: Lists wikilinks whose target page does not exist, with file and line (`--json` for a machine-readable list). A target resolves by slug or H1 title against every page outside `wiki/_archived/`. Used by the lint stage of `/gaia-wiki` for check #17.

**`gaia wiki chain <begin|commit|finish|refresh-nudge>`**: Manages the branch lifecycle for `/gaia-wiki` so every stage (sync, consolidate, lint) lands in one commit and one PR. The stages commit nothing themselves.

- `begin` (before sync): cuts a `wiki/<YYYY-MM-DD-HHMM>` branch (UTC) from `main`; no-op on a feature branch, where the run commits in place.
- `commit` (once, after lint): commits every stage's `wiki/` changes in place as one commit whose subject it mints, `wiki: <YYYY-MM-DD> <HH:MM> UTC`, from the branch's timestamp (from the clock on an in-place run); gracefully no-ops when nothing changed; refuses non-wiki changes; refuses on `main` and `master`; invalidates the statusline cache after a successful commit.
- `finish` (after the commit): pushes the branch, opens one PR titled with the commit's subject, posts the out-of-scope `GAIA-Audit` stamp, enables auto-merge, and stays on the branch. It never waits for the merge: `/gaia-wiki` then waits and cleans up through the shared work lifecycle (`.claude/skills/gaia/references/work-lifecycle.md`), like every other GAIA command that opens a PR. Drops the branch if it is empty. Leaves an aborted dirty tree in place for review. No-op for in-place runs on a feature branch.
- `refresh-nudge` (after cleanup): writes the main checkout's wiki drift into the statusline cache, so the `/gaia-wiki` nudge clears the moment the landed state file is pulled rather than on the next background refresh.

`/gaia-wiki` takes no stage argument; the `gaia wiki chain` commands are how every run lands.

`/gaia-wiki`'s lint stage fixes what it finds. After the detection subagent writes its report, a parent-side fix loop resolves each finding (mechanically where one answer is right, by asking where the fix needs judgment), files the narrative-ref findings in instruction files as tech-debt because `chain commit` refuses non-wiki changes, then re-runs detection so the report describes the fixed wiki. The fixes and the final report land in the run's one commit, made before `finish`, so `finish` opens a PR on a wiki that is clean or whose remaining findings the user explicitly accepted. The loop's rules live in `.claude/skills/gaia/references/wiki/lint-fix.md`.

<!-- gaia:maintainer-only:start -->
## Shipped-surface boundary check

`wiki/` ships, so a page the sync stage of `/gaia-wiki` authors is a newly-shipping file the moment it's created. Before landing, sync stages its own authored pages and runs the release-staging build against them, the same check CI's advisory shipped-surface leak check runs, moved ahead of the pull request rather than discovered after it's open. It repairs what a page's own prose caused (a pointer at a release-excluded path, a wikilink to a release-excluded page), bounded at three attempts, and records what it can't repair or what a newly-created page still owes the distribution manifest in the sync summary instead of staying silent about it.
<!-- gaia:maintainer-only:end -->

## State file

`wiki/.state.json` is the single source of truth for sync state:

```json
{
  "version": 1,
  "last_evaluated_sha": "...",
  "last_evaluated_at": "2026-05-07T...",
  "last_consolidated_sha": "...",
  "last_consolidated_at": "2026-05-07T..."
}
```

Two stages own disjoint subsets:

- the sync stage of `/gaia-wiki` owns `last_evaluated_sha` and `last_evaluated_at`
- the consolidate stage owns `last_consolidated_sha` and `last_consolidated_at`

Each writer uses `state-bump` to preserve the other's fields. Hooks and other commands are read-only consumers.

## See also

[[Wiki Sync]], [[Wiki Consolidate]], `.claude/skills/gaia/references/wiki/sync.md`, `.claude/skills/gaia/references/wiki/consolidate.md`.
