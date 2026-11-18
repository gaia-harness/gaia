# /gaia-cleanse cross-file duplication

The `--cross-file` procedure: find a procedure, list, threshold or convention stated in two or more instruction files, and replace each restating copy with its case-specific detail plus a pointer to the one file that owns it. Read by the main conversation on `--cross-file` (candidates, shards, judges) and by the `Stage 1 (cross-file)` assembler (`## Assemble`). The dispatch blocks and their model pins are in the entry file, `.claude/skills/gaia/references/cleanse.md`.

Contents: File set; Run the candidates; Shard and dispatch (judge brief); Exceptions; Assemble (report, coverage, cost).

## File set

`.gaia/scripts/cleanse/cross-file-candidates.mjs` decides which instruction files are compared, how each splits into blocks, and which shared literals pair two blocks; its header comment is the authority for all three. A model never reads the whole set: the script clusters blocks from different files that share enough distinctive literals, and a judge reads only each cluster's member excerpts.

## Run the candidates

The main conversation runs the script from the main checkout, into a fresh folder in the session's scratchpad directory (`CROSS_FILE_DIR`), adding `--focus <path>` once per repo path the scope hint names:

```bash
rm -rf "$CROSS_FILE_DIR" && mkdir -p "$CROSS_FILE_DIR"
node .gaia/scripts/cleanse/cross-file-candidates.mjs --root "$(git rev-parse --show-toplevel)" \
  >"$CROSS_FILE_DIR/candidates.json"
```

- **Exit 0**: the candidates file holds one JSON object; read its `clusters` length as the cluster count. Zero clusters is a result, not a stop: dispatch no judge, and dispatch the assembler with no verdict files, which writes a 0-action report.
- **Exit 2 or 3**: a could-not-run stop. Relay the script's one `cross-file-candidates:` stderr line, dispatch nothing, and write no report. The run ends there, with the entry file's cost record.

A hint that names no repo path adds no `--focus`; it still reaches the report's `scope:` line.

## Shard and dispatch

Split the clusters, in the order the script printed them, into shards of at most 20 clusters, and give each shard its own pre-cleared verdict path:

```bash
CLUSTER_COUNT="$(jq '.clusters | length' "$CROSS_FILE_DIR/candidates.json")"
SHARD_COUNT=$(( (CLUSTER_COUNT + 19) / 20 ))
for (( shard = 1; shard <= SHARD_COUNT; shard++ )); do
  number="$(printf '%03d' "$shard")"
  jq --argjson start $(( (shard - 1) * 20 )) '.clusters[$start:$start + 20]' \
    "$CROSS_FILE_DIR/candidates.json" >"$CROSS_FILE_DIR/shard-$number.json"
  rm -f "$CROSS_FILE_DIR/verdict-$number.json"
done
```

Dispatch one `Cross-file judge` per shard (its dispatch block is in the entry file), in waves of at most 8 parallel judges, one message per wave. Before starting the next wave, poll each verdict file of the current one and classify it with its shard's cluster count:

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file \
  --path "$CROSS_FILE_DIR/verdict-$number.json" \
  --expect-count "$(jq length "$CROSS_FILE_DIR/shard-$number.json")"
```

Every verdict file that ends REAL goes to the assembler, with the candidates file and the shard count.

### Judge brief

You are one cross-file duplication judge. Your dispatch names a shard file (a JSON array of clusters), an output path, and the shard's cluster count. Each cluster has an `id`, the `literals` its members share, and `members`, each with `path`, `start_line`, `end_line`, `ownership`, `maintainer_only` and its block's verbatim `text`. The members come from different instruction files and were paired by shared literals alone, so sharing literals is a reason to look, never a verdict.

For each cluster, decide one verdict:

- `duplicate`: two or more members state the same fact (a procedure, list, threshold or convention) and agree on its substance. One of them is the owner; the others are copies.
- `distinct`: no two members restate one fact. They share literals but say different things about them (one defines a command, another only runs it).
- `disagree`: a member restates another member's fact and differs on substance (a different value, step, order, or the opposite rule). When any restating member disagrees, the whole cluster is `disagree`.
- `exempt`: the restatement is one that `## Exceptions` below keeps; name the exception in `reason`.

Decide it this way:

- **Pick the owner by subject.** The owner is the member whose file the fact belongs to: the file a reader would open for that procedure, list, threshold or convention. Never pick by which copy is longer or more detailed. The owner is always one of the cluster's members; record its block in `owner_block` and the owner file's section heading in `owner.heading` (null when the file has one section).
- **List only real copies.** `copies` holds only the members that restate the owner's fact. Every other member goes in `distinct_members`: clusters chain members together, so a cluster can hold a block unrelated to the owner's fact. A copy that an exception keeps goes in `distinct_members` too, with the exception named in `reason`; when every restating member is kept that way, the verdict is `exempt`.
- **Keep the case-specific detail.** Each copy's `keep` is the text of that copy, verbatim, that is specific to its own file's case and that the owner does not state (a trigger, a departure, a local consequence). Empty when the copy carries none. Never paraphrase into `keep`.
- **Set `pointer`.** `pointer: false` when the copy's reader already has the owner loaded: the owner is a rule under `.claude/rules/` with no `paths:` frontmatter, or one whose `paths:` match the copy's file. Otherwise `pointer: true`.
- **Read more when the excerpt is not enough.** You may Read the full files around a block to see its section, its `paths:` frontmatter, or whether two blocks really say the same thing.

Write the array below to the output path with the Write tool, one entry per cluster, in shard order, the file holding JSON only. `owner`, `owner_block` and `copies` are set only on `duplicate` (null or empty otherwise); `disagree` has `owner: null` and a `reason` naming the contradiction. Reply with one line of verdict counts and nothing else.

```
[{"cluster": "C001",
  "verdict": "duplicate" | "distinct" | "disagree" | "exempt",
  "reason": "<one line>",
  "owner": {"path": "<repo-relative>", "heading": "<the owner's section heading, or null when it has one section>"} | null,
  "owner_block": {"start_line": <n>, "end_line": <n>} | null,
  "distinct_members": [{"path": "<repo-relative>", "start_line": <n>}],
  "copies": [{"path": "<repo-relative>", "start_line": <n>, "end_line": <n>,
              "keep": "<the copy's case-specific detail to keep, verbatim, or empty>",
              "pointer": <true | false>}]}]
```

## Exceptions

These are the cross-file pass's own exceptions to replacing a copy; the single-source rule's general exceptions apply too and are not repeated here. Each names the verdict it yields.

- **A copy that disagrees with its owner**: `disagree`. Choosing which side is right would edit a committed instruction file on conflict grounds, which no cleanse action does; a human reconciles it from the out-of-scope finding.
- **A pointer from `apps/web/.claude/` to a root `.claude/rules/` file**, or a block there restating one: `exempt`. Whether a session launched inside `apps/web/` loads the root rules is unverified, so that block may be the only copy its reader sees.
- **A copy whose reader cannot see the owner**: `exempt`. A shipped copy (not `maintainer_only`) whose only owner sits inside a maintainer-only block, or in a file that never ships, stays: replacing it would leave a shipped reader a pointer to nothing.
- **A copy whose text a script or hook matches**: `exempt`. When one of the copy's distinctive lines appears under `.gaia/scripts/`, `.claude/hooks/` or `.githooks/` (`git grep -F -- '<line>' -- .gaia/scripts .claude/hooks .githooks`), replacing the copy breaks the match. When the copy also restates its owner, end `reason` with `redundant`, so the assembler records it as an out-of-scope finding.
- **A verbatim block a script compares byte for byte against its source**: `exempt`. The orchestrator-step blocks in `.claude/skills/gaia/references/plan/planner.md`, which `.gaia/scripts/spec/plan-verify.sh` compares, are the case; the copy is the contract the script checks.
<!-- gaia:maintainer-only:start -->

In the GAIA source repo, a file that never ships is one `.gaia/release-exclude` lists. A pin in a maintainer test suite under `.gaia/tests/` is not the script-or-hook exception: a doc-contract suite that pins a replaced passage is reworked at publish (`.claude/skills/gaia/references/cleanse/publish.md`), so a copy only a test suite matches is judged as any other.
<!-- gaia:maintainer-only:end -->

## Assemble

The `Stage 1 (cross-file)` assembler turns the verdict files into a report. It judges nothing: a cluster with no verdict entry gets only its coverage line. Read `.claude/skills/gaia/references/cleanse/research.md` for its `## Step 0, Prune old reports`, `### Ownership (every action)`, and `## Step 4, Report` sections; run Step 0 first. From the candidates file take `files_scanned`, `words_scanned` and the clusters (the member texts and lines); from each verdict file, its entries.

Per verdict:

- **Duplicate**: one `replace` action per entry in `copies`, never one for a `distinct_members` entry. Read the copy's lines `start_line` to `end_line` from the file under `$PROJECT_ROOT` for `before`; when they no longer equal the member's `text` in the candidates file, the file changed since the scan, so write no action and mark the coverage line `drifted`. Build `after` from `keep`, then, when `pointer: true`, append one space and the pointer sentence `` See `<owner path>` (<owner heading>). ``, or `` See `<owner path>`. `` when the heading is null; with an empty `keep`, `after` is the pointer sentence alone, prefixed with the list marker and indentation `before` opened with. With `pointer: false` and an empty `keep`, `after` is empty: the copy goes. The action is a `### Shrink / Convert` block from the report template, id `shrink-{nnn}`, whose `owner:` is followed by `grounds: cross-file-duplicate` and `owner_path: <absolute path of the owner file>`, and whose `reason` names the cluster id and the owner's path and lines from `owner_block`.
- **Disagree**: record one entry in `## Out-of-scope findings` per `disagree` cluster and emit no action for any of its members; the copies stay as they are until a human reconciles them.
  The entry carries `severity: major`, the cluster's first member as `path` and `line`, every member path and the judge's `reason` in `failure_mode`, `footprint: wide`, and the suggested fix: reconcile the owner against the machinery it describes, then delete the copy.
- **Exempt**: its coverage line only, naming the exception. When `reason` ends `redundant` (the script-or-hook exception), also one `## Out-of-scope findings` entry, `severity: minor`, whose suggested fix is to move the script's match onto the owner so the copy can become a pointer.
- **Distinct**: its coverage line only.

Then run `bash .gaia/scripts/knowledge-inventory.sh classify --root "$PROJECT_ROOT"` once over every file an action writes and set each action's `owner:` per research.md's Ownership step, its maintainer-only cross-file arm included. An action the Ownership step allows on no file becomes a `Report-only` line, as there.

Write the report with research.md's report template and these differences:

- Frontmatter: `status: draft`, `audit_hardened: false`, `scope: cross-file` (or `scope: cross-file: <hint>` with the hint verbatim), `store_counts: instruction_files=<files_scanned> clusters=<cluster count>`.
- `## Summary`: `Stores scanned` is `<files_scanned> instruction files, <words_scanned> words`; add `Cross-file clusters: <cluster count> in <shard count> shards (<n> duplicate, <n> distinct, <n> disagree, <n> exempt)` so a run's cost reads against its size; the cross-store, auto-load, over-budget, stale and conflict lines read `not audited in a cross-file run`.
- `## Cross-file coverage`, right after `## Summary`: one line per cluster in the candidates file, in its order, `` - `C001`: <duplicate | distinct | disagree | exempt> ``, or `no verdict` when no verdict file carries the cluster. A `duplicate` line appends `; distinct members: <path>:<start_line>, ...` (or `none`), and `drifted` when it wrote no action for a copy.
- `## Step 2 coverage`: `None: a cross-file run compares instruction files with one another only.`

End the run by printing the report path and the action and out-of-scope counts.
