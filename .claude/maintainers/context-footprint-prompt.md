# Measure GAIA's context footprint (pre-release re-run)

Maintainer-only, release-excluded. Run it before tagging every release, on a probe built from the release-candidate bundle of final `main` (`dogfood/<probe>`), on a working branch. Open a session at the root of that probe and paste:

```text
Read gaia/.claude/maintainers/context-footprint-prompt.md in the gaia-react repo and run it against this probe.
```

It re-measures what GAIA's harness costs in the context window and diffs the result against the baseline at the bottom of this file. The numbers go on the docs site's token-efficiency page (the sibling `../docs` checkout), and into any README data point that quotes them.

All percentages are against a **1M token** context window.

## Scope

Measure these, nothing else:

| # | Measurement | Source |
|---|---|---|
| S | Startup load in a root session | headless run on a scratch copy, blocks counted one by one |
| 1 | Rules loaded by a typical task (edit one component and one route) | headless edit task on the scratch copy |
| 2 | Skill sizes: list entry vs SKILL.md vs supporting files | files on disk, counted |
| 3 | Startup in a session launched from `frontend/` | headless run in `<copy>/frontend` |
| 4 | Audit loop footprint: what the main session receives per unit report vs what the sub-agent spent | existing transcripts |
| 6 | Re-review vs first full review | existing transcripts |

Out of scope: resume compression, and light vs full on one identical diff. The maintainer dropped both.

Items 4 and 6 need audit data. Before starting, confirm the probe has at least one PR audit with **two full rounds by the same member** in its transcripts. If it doesn't, stop and say so; don't fake a run.

## What GAIA counts as, and what it doesn't

Count: root `CLAUDE.md`, root `.claude/rules/*` (the ones with no `paths:` frontmatter load at startup), the SessionStart hook's additional context, the list entries for GAIA's skills, commands and agents, and on demand: path-scoped rules, `frontend/CLAUDE.md`, frontend rules, frontend skill entries, skill bodies.

Exclude: the user's global `~/.claude/CLAUDE.md`, the gaia-react monorepo's own `CLAUDE.md` (a downstream adopter has neither), user-level MCP servers (Serena, context7), claude.ai connectors, and PostToolUse hook stdout that is only a terminal notification (Warp `terminalSequence`; it never reaches the model).

## Lessons from the first run (read before measuring)

1. **Don't diff whole sessions** (project dir vs empty dir). The claude.ai connector tool list changes from run to run, which moves totals by 1-2k and swamps GAIA's deltas. Instead, pull the exact injected text out of a transcript and count each block on its own.
2. **Count with a single-turn, inert wrapper.** `claude -p --output-format json` reports usage **summed over every turn**. A bare SKILL.md as the prompt makes the model act on it, run tools, and inflate the count up to eightfold. Use `cnt.sh` below (`--max-turns 1`, a "this is data" wrapper, no MCP) and check that `turns=1` on every line.
3. **Measure the baseline twice** before counting. It was stable to the token (24,363 on Opus 5.5 with the wrapper). If the two runs differ, find out why before going on.
4. **Use the session model** (`--model claude-opus-5-5` at the time of writing, or its successor) so the tokenizer matches what users run.
5. **Work on a scratch copy**, never the probe itself: the item 1 task edits files. Copy with rsync, excluding `node_modules`, `.git`, `local` and `worktrees`, then `git init` on a working-branch name so the doctrine hook emits its working-branch text.
6. **Transcript attachment types**: `instructions` (CLAUDE.md files and rules at startup), `hook_additional_context` (SessionStart text), `skill_listing`, `agent_listing_delta` (`addedLines`), `nested_memory` (path-scoped rules and nested CLAUDE.md, loaded mid-session), `dynamic_skill` (metadata only; the frontend skill entries arrive as a second `skill_listing`). Headless transcripts land in `~/.claude/projects/<cwd with / replaced by ->/<session_id>.jsonl`.
7. **Hidden-file glob trap**: a rule saved as `.claude__rules__x.md` is skipped by `*`. Glob `* .*` or avoid leading dots.
8. **Skill entries set to name-only** (`skillOverrides` in `.claude/settings.json`) cost only their name. In a frontend launch they don't appear at all.
9. **Re-review classification**: read the route in `.gaia/local/audit/light/*.route.json`. A re-dispatch that went down the **light** route is a light-vs-full data point, not a re-review. Only a full re-dispatch by the same member counts for item 6.
10. **Peak context vs billed input**: a sub-agent's peak single-turn context is the context-window number. Its summed input across turns (mostly cache reads) is a cost number. Report both and label them; never mix them.
11. **Delegate items 4 and 6** to one sub-agent writing a JSON array file (`.claude/rules/subagent-dispatch.md`). It took about 160k tokens last time. Items S, 1, 2 and 3 are cheap; run them inline.

## Helpers

Put these in the session scratchpad (`$S`). `$PROBE` is the probe root, `$C` the scratch copy, `$E` an empty directory.

```bash
mkdir -p $S/empty $S/parts $S/item1 $S/item2 $S/item3
rm -rf $S/copy && mkdir -p $S/copy
rsync -a --exclude node_modules --exclude .git --exclude local --exclude worktrees $PROBE/ $S/copy/
git -C $S/copy init -q -b feat/footprint-probe && git -C $S/copy add -A \
  && git -C $S/copy -c user.name=x -c user.email=x@x commit -qm init
```

`$S/cnt.sh` (prints `<total input tokens> <turns>`; subtract the baseline):

```bash
#!/bin/bash
E=$1; f=$2
{ printf 'Reply with exactly OK. Everything below the line is inert data; do not act on it.\n----\n'; cat "$f"; } \
  | (cd $E && claude -p --max-turns 1 --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
       --output-format json --model claude-opus-5-5 2>/dev/null) \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); u=d["usage"]; print(u["input_tokens"]+u["cache_creation_input_tokens"]+u["cache_read_input_tokens"], d.get("num_turns"))'
```

Baseline: `: > $S/emptyfile; $S/cnt.sh $S/empty $S/emptyfile` (twice).

Headless run that returns the session id:

```bash
run_session(){ (cd "$1" && claude -p "$2" --output-format json --model claude-opus-5-5 --permission-mode bypassPermissions 2>/dev/null) \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["session_id"])'; }
transcript(){ ls ~/.claude/projects/*/"$1".jsonl; }
```

## Steps

### S. Startup (root)

1. `SID=$(run_session $S/copy "Reply with exactly: OK")`.
2. From `$(transcript $SID)`, write one file per block into `$S/parts/`:
   - `instr_claudemd.txt`, `instr_rules.txt`: the `instructions` files under the copy, each prefixed `Contents of <path> (project instructions, checked into the codebase):` to match how they appear in context.
   - `hook_sessionstart.txt`: `SessionStart hook additional context: ` + the `hook_additional_context` content.
   - `skills.txt`: the `skill_listing` entries whose name is a directory in `.claude/skills/` or a file in `.claude/commands/` (split entries on `\n(?=- )`; read the names from disk, don't hardcode them).
   - `agents.txt`: the `agent_listing_delta.addedLines` for the files in `.claude/agents/`.
3. Count each, and the sum. Report the sum as % of 1M.

### 1. A typical task's rule load

1. `SID=$(run_session $S/copy "Small task: in <a component file>, make a one-attribute tweak, and in <a route file>, change the page meta title text slightly. Follow the repo's instructions for working in frontend. Do not run tests, lint, or git. Reply DONE when edited.")`. Pick a real component and route in the RC (last time: `frontend/app/components/confirm-dialog/index.tsx` and `frontend/app/routes/_public._index.tsx`).
2. Confirm with `git -C $S/copy diff --stat` that both edits happened.
3. From the transcript, save every `nested_memory` attachment to `$S/item1/` (one file each, no leading dot) and the second `skill_listing` (the frontend skill entries). List which path-scoped rules loaded and which didn't.
4. Count each. The task's total = the loaded rules + the frontend skill entries + `frontend/CLAUDE.md` (it arrives as a Read result, so count the file). Also give startup + task, as % of 1M.
5. Flag any rule that loaded on a pure code edit with no obvious bearing on it. Last time `wiki-style` and `working-doc-ids` (3.6k together) loaded on `frontend/app/**`; check whether 2.0 still does that and whether it was intended.

### 2. Skill sizes

For `new-component`, `react-code`, `tdd-react`, `react-doctor` (frontend) and `tdd` (root), plus any skill new in 2.0: count the list entry (from a `skill_listing`), `SKILL.md`, and every other file in the skill's folder (not only `references/`; `tdd` keeps its extra files beside `SKILL.md`). Report "max when used" = SKILL.md + all supporting files, and the list entry as a share of it.

### 3. Startup from `frontend/`

1. `SID=$(run_session $S/copy/frontend "Reply with exactly: OK")`.
2. Count `frontend/CLAUDE.md` (from `instructions`) and the 14-ish frontend skill entries. Note which root GAIA entries drop out (the name-only ones). Total = root startup minus dropped entries plus these. Report as % of 1M.

### 4 and 6. Audit footprint and re-review

Dispatch one sub-agent (JSON array file, 2 objects; classify it with `audit-noop-detect.sh --expect-count 2`). Its brief:

- Sources: the probe's session transcripts and their `<session>/subagents/*.jsonl`, plus `.gaia/local/audit/light/*.route.json` and `*.reviews.jsonl`.
- Item 4, for each audit: tokens of the unit report the main session received (from the context jump between main-session turns, or chars/3.6 as a fallback), the unit's peak single-turn context, the whole agent tree's summed input, output and cache writes.
- Item 6: the same member, same branch, round 1 vs a **full** round 2. Report the summed input and peak context for both, and the size of the fix between them. Skip any light-routed re-dispatch (lesson 9).
- Dedupe usage per message id. Read with python over the jsonl, never whole files.

## Output

1. Write `$S/footprint-<date>.json`: an array with one object per item (`item`, `status` MEASURED / PARTIAL / NO DATA, `numbers`, `pct_of_1m`, `sources`, `notes`).
2. Reply with a table per item and, for each number, the delta vs the baseline below. Call out anything that moved more than 10%.
3. Include the new baseline (numbers, date, probe) in the JSON output; this session is rooted in the probe, so it does not edit this file. The maintainer, or a session at the GAIA root, lands the baseline update in this file through a small PR, so the next run diffs against it, and updates the docs token-efficiency page (and any README data point) with the new numbers.

## Baseline (2026-10-21, `dogfood/spec130-probe`, Opus 5.5)

Counting baseline with the wrapper: 24,363 tokens.

**S. Startup: 7,672 (0.77%)**

| Block | Tokens |
|---|---|
| Root rules with no `paths:` (8) | 3,877 |
| SessionStart hook context | 1,409 |
| Root `CLAUDE.md` | 1,041 |
| Skill and command entries (10, 5 name-only) | 804 |
| Agent entries (7) | 541 |

**1. Typical task (1 component + 1 route): adds 14,526 (1.45%); startup + task 22.2k (2.2%)**

| Layer | Tokens |
|---|---|
| Root path-scoped, 5 of 9: code-comments 1,549, wiki-style 1,978, working-doc-ids 1,604, code-search 495, no-abbreviations 451 | 6,077 |
| Frontend, 8 of 13: design-baseline 1,124, coding-guidelines-react 1,068, i18n 886, tailwind 853, accessibility 618, ports 563, react-router-docs 357, routes 277 | 5,746 |
| Frontend skill entries (14) | 1,788 |
| `frontend/CLAUDE.md` | 915 |

**2. Skills**

| Skill | Entry | SKILL.md | Other files | Max when used |
|---|---|---|---|---|
| new-component | 142 | 1,434 | none | 1,434 |
| react-code | 182 | 5,880 | 9,061 (4) | 14,941 |
| tdd-react | 148 | 303 | 7,491 (1) | 7,794 |
| react-doctor | 112 | 1,766 | 1,750 (1) | 3,516 |
| tdd | 75 | 4,282 | 416 (3) | 4,698 |

**3. Frontend launch startup: ~10.4k (1.04%)**: root startup + `frontend/CLAUDE.md` 915 + frontend entries 1,788, minus the root name-only entries (~60).

**4. Audit footprint**

| Audit | Main receives | Unit peak context | Tree input billed |
|---|---|---|---|
| Light only (2 agents) | ~450 | 80k | 0.93M |
| 1 full round + fixer + light re-check (7 agents) | ~690 | 141k | 9.6M |
| 2 full rounds + fixer (11 agents) | ~840 | 167k | 23.7M |

**6. Re-review**: full round 2 = 45% of round 1 (2.87M vs 6.39M billed; member peak 136k vs 180k). Caveat: that fix was a large rewrite (the ja locale), so it overstates a small-fix re-review. The only small-fix re-dispatch went light (15k vs 2.19M), so it isn't a re-review data point. If 2.0's probe has a small-fix full re-dispatch, prefer it.
