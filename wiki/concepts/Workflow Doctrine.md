---
type: concept
status: active
created: 2026-10-01
updated: 2026-10-18
tags: [concept, claude, workflow, doctrine]
---

# Workflow Doctrine

The workflow doctrine is one set of working rules for GAIA sessions, split into two halves by the moment each applies. [`.claude/rules/context-discipline.md`](../../.claude/rules/context-discipline.md) is the always-loaded half: a short, mode-neutral rule about keeping the main thread lean, fanning reads out, choosing models by fit, and keeping research output small. [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md) is the execution half: it is never auto-loaded, and a hook injects it verbatim the moment a session is on a working branch or in a linked worktree. This page holds the reasoning and the depth behind both.

The halves are split because guidance about executing biases a session toward action. In a discussion that bias is the reactivity failure the project CLAUDE.md names under "Before responding": a stimulus becomes a response before the stimulus is characterized. So a discussion session carries only context discipline, and execution doctrine arrives only when a branch exists, which is the signal that the work has moved from deciding to doing.

## Roles

The doctrine names four roles because each failure it guards against has a different owner. Read-only advisors investigate and write plan JSON, so wide reading never lands in the thread that has to decide. The main thread decides, because decisions need the whole picture and the user. Executors edit files and nothing else: a sub-agent that stages or commits works from a partial view, and several executors share one working tree, so one stray state-changing git command silently discards a sibling's edits. A verifier checks executor output against the plan JSON before the gate, so the gate runs once on work already known to match intent, not as a repair loop.

The main thread alone owns git that changes state, and runs the Quality Gate once per commit. Running it per executor multiplies a slow gate by the number of dispatches and checks half-built states nobody will commit. The operative wording lives in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md). When a running command defines its own contract, such as a plan orchestrator's per-phase commits or a debt fix's inline flow, that contract governs where it differs from the doctrine.

One agent is exempt from the executor and advisor limits. `audit-loop-unit`, dispatched by the main thread during the pre-merge audit, is the sanctioned depth-2 orchestrator: it runs state-changing git (commit and push of the fix rounds) and the Quality Gate for the rounds of its unit, because a fix round is a whole cycle of dispatch, fix, verify, gate and commit, and running it on the main thread charges every round's reading to the context that has to survive to the merge. The exemption is bounded from outside the agent: the deterministic verifier and the dispositions check stand behind every round, and a unit window recorded by the bound hook caps how many rounds it may open. The main thread still decides the checkpoint, the markers and the merge.

## Inline floor

Delegation has a fixed cost: a brief to write, a result to read back, and a context the sub-agent does not share. Small work, tightly iterative edit-run-fix work, and anything that needs the user stay on the main thread because the cost exceeds the gain. A platform limit makes this a floor, not a preference: a sub-agent cannot prompt the user, so a task that needs a question answered cannot be pushed down. Nesting is not such a limit: Claude Code lets a sub-agent spawn its own, three levels below the main conversation by default, set by `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`. GAIA still keeps delegation depth-1 by choice, so the main thread dispatches every sub-agent and sees every artifact it decides on. The audit loop is the one place depth-2 earns its cost, and `audit-loop-unit` is the sole exception: its rounds are numerous, mechanical to hand back as a thin report, and bounded by the hook-recorded unit window, so the main thread keeps the decisions while the per-round context stays below it. Nesting needs a Claude Code version that allows it; when a nested dispatch is unavailable the unit stops `needs-human` naming the Claude Code version it needs, and the main thread never runs the rounds inline (see [[PR Merge Workflow]]).

## Model table

Models are ranked by fit to the task class. Fit has two halves: the reasoning depth the task needs, and how tightly the work must keep to the brief. Model and effort set both together: a top model, or any model at its highest effort, reads wider and reaches past the brief, which a review wants and a written plan does not. Narrow focus helps only when the brief carries the judgment; with a loose brief it turns into literal-minded shortcuts. Cost decides only between models that fit equally.

| Task class | Model | Why it fits | Cost note |
| --- | --- | --- | --- |
| extraction, classification, inventory | Haiku | Each item is decided by a written rule and the result is checkable: a JSON array verified with a count, or a fixed template. Narrow focus keeps it on the brief. At a `low` session effort it can stop early in a long agent prompt. Not for code changes. | A twentieth of Sonnet's input and output rates and a tenth of its cache-read rate, for prompts up to 100k tokens. A prompt over 100k tokens pays five times those rates. |
| judgment sweep | Sonnet | Wide reads where each item needs a call, such as research, refutation, or verification reads, returning a small result. The brief carries the judgment, and narrow focus keeps each call inside it. | Half of Opus's rate on every tier, cache reads included. |
| scoped implementation | Sonnet | A bounded change with a written plan and a verifier behind it. The plan carries the judgment, and Sonnet stays inside the brief. At a `max` session effort it reaches for extra review, extra sub-agents, and out-of-scope edits. | Half of Opus's rate on every tier, cache reads included. |
| review and adversarial check | Opus | Finding what a change got wrong needs sustained judgment and the wider view. The Code Audit Team members are this class. | Top-model rates. A missed defect costs more than the rate difference. |
| synthesis | Opus (Fable when the session is on it or the user picks it) | Wording, positioning, architecture, and design decisions where one weak choice propagates into everything after it. | Top-model rates; Fable's input and output rates are two and a half times Opus's. Fit selects it. |
| lookup, scaffold, mechanical | Haiku | The answer is fixed by a template, a rule id, or a written convention: scaffolding from a pattern, a fix keyed to a lint or accessibility rule id, a rule-based check. Reasoning depth adds nothing the template does not already carry. | Fit selects it and the lower price follows. A pin is a ceiling: an inline skill's pin holds for the rest of the turn it loads in, so a skill that triggers in the middle of general implementation work is not this class. |

GAIA never pins effort. Every subagent, named, general-purpose or fork, runs at the session's effort level, the same as work the main thread does inline: no agent frontmatter carries `effort:`, and no dispatch passes the `Agent` tool's `effort` parameter. Effort is the user's lever. A low session is low by choice and a high one is high by choice, and a level GAIA chose would raise or lower spend behind the user's back. `CLAUDE_CODE_EFFORT_LEVEL`, when set, overrides the session level machine-wide. The cost of this rule is accepted: the Code Audit Team members and the `/gaia-spec` and `/gaia-plan` audit pipelines grade at the session's level, not a constant one.

The cost ratios come from the published price card, not from measurement. `.gaia/scripts/token-rates.json` carries the same rates for GAIA's cost readouts, with Haiku at its short-prompt rate, so a Haiku cost readout is a lower bound.

Among the doctrine sources (the rule, `.claude/doctrine/execution.md`, and this page), the table is the only text edited when a model ships. A pin site is any other place that names a model for a skill, an agent, or one dispatch. Each follows the table and is re-checked against it in the same change.
<!-- gaia:maintainer-only:start -->
`.gaia/tests/hooks/workflow-doctrine-sources.bats` fails when a file that pins a model matches no entry below.
<!-- gaia:maintainer-only:end -->

### Pin sites

- Frontmatter `model:` in skills and agents: `.claude/skills/*/SKILL.md`, `frontend/.claude/skills/*/SKILL.md`, `.claude/agents/*.md`. A skill pins only for the lookup, scaffold, mechanical row; [[Deliberate Configuration Asymmetries]] records which skills pin and why.
- Dispatch pins in playbooks: `.claude/skills/gaia/references/plan.md` (the planner picker), `.claude/skills/gaia/references/plan/planner.md` (the executor pin), `.claude/skills/gaia/references/spec.md` (the model gate), `.claude/skills/gaia/references/cleanse.md`, `.claude/skills/gaia/references/fitness.md`, `.claude/skills/gaia/references/wiki.md` and its stage files `.claude/skills/gaia/references/wiki/*.md`, the update-deps wave and override-audit agents in `.claude/skills/update-deps/SKILL.md`, and the bump agents in `.claude/skills/update-gaia/references/conflict-flow.md`.
- Executed wiki pages: `wiki/concepts/Audit Round Procedure.md` (the fixer dispatch).
- Descriptive wiki pages that restate a pin: `wiki/concepts/GAIA Plan.md`, `wiki/concepts/GAIA Spec.md`, `wiki/concepts/Task Orchestration.md`, `wiki/concepts/Wiki Sync.md`, `wiki/concepts/Wiki Consolidate.md`, `wiki/decisions/Deliberate Configuration Asymmetries.md`.

## Run folder and checkpoint

Each branch gets one folder under `.gaia/local/runs/<key>/`, with the `branch:` prefix of the usage key dropped. One folder per key keeps two branches from clobbering each other's state, and the key is derived from the branch, so a returning session finds its own folder without being told where it is.

`STATE.md` is small and rewritten in place because append-only state files grew past any context window: a checkpoint that has to be read to be trusted must stay cheap to read. It records what is known, what each dispatch was expected to return, and one next step. Each dispatch writes one JSON artifact with its expected count recorded in `STATE.md`, so a missing or truncated artifact is detectable by counting rather than by guessing. `log.md` is append-only and never read on resume: it is a trace for a human, and loading it would reintroduce the growth the checkpoint exists to avoid. The operative layout is in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md), and the registry entry for the folder is in `.gaia/state-registry.json`.

## Resume

A resumed session reads `STATE.md` and the artifact listing and nothing else. The checkpoint says where the run stands, and the listing says which dispatches finished, so the two together answer "what next" without replaying the history that produced them. Reading more than that spends the context the run folder was built to protect. The steps are in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md).

## Context checkpoint

Claude cannot see its own context reading, so a long session has no way to notice it is running heavy. A PostToolUse hook reads the per-session reading the statusline writes and, once per band from red upward, injects [`.claude/doctrine/context-checkpoint.md`](../../.claude/doctrine/context-checkpoint.md) with the session id and the resolved save path above it. That file owns the rule: what each band means, where to save, what to ask, and what to recommend. This page does not restate it.

The main-session hook stays silent for sub-agents, when there is no fresh reading, and for a session the audit loop's state file for its branch records (a unit or checkpoint entry carrying its session id), because the audit loop owns that checkpoint. The bands come from `.gaia/scripts/context-checkpoint-lib.sh`, the same source the statusline reads, so the two never disagree. Marks live per session: a session resumed after `/clear` starts unmarked and is checked afresh, while compaction keeps its marks.

A sub-agent gets its own checkpoint from a separate PostToolUse hook, `.claude/hooks/context-checkpoint-subagent.sh`. It reads the sub-agent's context from the sub-agent's own transcript and injects [`.claude/doctrine/context-yield.md`](../../.claude/doctrine/context-yield.md), but only for a sub-agent that opted in by naming a handoff path in its dispatch prompt. A heavy sub-agent writes the handoff and returns instead of running on; the dispatcher re-dispatches a fresh agent from that handoff and halts for the human once the yield limit `gaia_context_yield_limit` returns is passed. The bands and the limit come from `.gaia/scripts/context-checkpoint-lib.sh`; the doctrine file and `.claude/skills/gaia/references/plan/planner.md` own the rules.

## Concurrency limits

Every worktree shares one `.gaia/local`, which resolves into the main checkout. That is why run folders are keyed by branch and never shared between keys, and why research binding works through a Write made to the main checkout's absolute path and not through a path relative to the worktree.

The injection hook decides from the session's own tree. Two spellings therefore do not inject the doctrine: `git -C <path>` aimed at another tree, and `git worktree add` followed by `cd`. Entering a worktree through EnterWorktree does inject it, because that tool reports the tree the session now works in. A `git worktree add` that creates a tree under `.claude/worktrees/` is caught on the add itself and steered into `EnterWorktree`, a separate injection described in `.claude/skills/gaia/references/work-lifecycle.md` under `## The git worktree add backstop`.

## Initiative linking

A branch's spend is tied to the initiative it serves with `bash .gaia/scripts/usage.sh link branch:<normalized> research:<date>-<topic>`, or with `issue:<n>` when an issue is the anchor. The link is made once per branch. Issue edges the branch name already derives need no link: `debt/<n>` and the `(fix|feat|chore|docs|refactor)/<n>-` forms. The key line the hook injects carries the concrete command for the current key. See [[Usage Ledger]].

## Research attribution

A research Write binds to its initiative only when it is made with the Write tool to the main checkout's absolute `.notebook/research/<date>-<topic>/...` path (see [[Notebook]]). A worktree-relative path or a symlinked path does not bind. Research done with Edit or Bash binds with `bash .gaia/scripts/usage.sh declare research:<date>-<topic>`. A binding re-keys only `session:` spend, so spend already attributed to a branch or an issue stays where it is. The research ref is the full folder name, date included.

## Injection hook

`.claude/hooks/workflow-doctrine-inject.sh` injects the execution doctrine through `hookSpecificOutput.additionalContext`. It fires at SessionStart for all four sources (`startup`, `resume`, `clear`, `compact`), after EnterWorktree, and after a Bash call that runs `git checkout`, `git switch`, or `gh pr checkout`. For Bash the command only decides whether to look; the decision is the branch checked out afterwards, in the session's own tree. The hook registrations are described in [[Claude Hooks]].

A per-session marker holds the last injected key. `startup` and PostToolUse skip when the key is unchanged, `compact` and `clear` re-inject because the context they follow is gone, and a new key injects. A resumed session always re-injects, because the platform replays injected text but does not guarantee a resumed session still holds it. The hook fails open: any error, a missing or oversized doctrine file, or a CI environment produces no output and exit 0. The key line is omitted, never rewritten, when a branch name falls outside the ledger's ref grammar. Without jq only SessionStart injects and no marker is kept.

What the platform documents, as current behavior: `startup`, `resume`, `clear`, and `compact` are all SessionStart sources, and compaction fires SessionStart. PostToolUse `additionalContext` is documented generally, but the documentation does not state it for Bash or EnterWorktree specifically, so the mid-session triggers are best-effort and the SessionStart triggers are the guaranteed path. Injected text is saved in the transcript and replayed on resume; whether a resumed session keeps its `session_id` is not documented, which is why resume always re-injects.

<!-- gaia:maintainer-only:start -->

## Measurements

Re-measured with `bash .gaia/tests/hooks/workflow-doctrine-timing.sh`.

| Metric | Value | Budget |
| --- | --- | --- |
| p50 SessionStart, default branch | 31.6 ms | 50 ms |
| p50 SessionStart, working branch | 40.2 ms | 50 ms |
| p50 PostToolUse Bash, non-arming | 25.1 ms | 50 ms |
| p50 PostToolUse Bash, arming | 46.9 ms | 50 ms |
| Per-session hook cost estimate | 843.4 ms | none |

The per-session estimate uses the median session's 32 Bash calls and 0 compactions. The timing rows and the estimate keep their earlier quieter-machine values, because a re-run at a 1-minute load above 13 inflated every path and would have recorded a load artifact as a budget miss.

The context checkpoint hook runs after every tool call of every main session, so each exit path of its ladder carries the 50 ms budget. Re-measured with `bash .gaia/tests/hooks/context-checkpoint-timing.sh`, through the registered command string with its rooting step included. The paths are interleaved in blocks next to a no-op baseline so they share the machine's load; read each row beside the baseline.

| Path | p50 | Budget |
| --- | --- | --- |
| Sub-agent payload | 17.2 ms | 50 ms |
| Below red, no marker | 34.2 ms | 50 ms |
| Skull already marked | 18.0 ms | 50 ms |
| Red marked, below fire | 33.7 ms | 50 ms |
| Firing | 52.3 ms (50.0 ms paired, below) | 50 ms |
| In an audit loop | 48.2 ms | 50 ms |
| 200 KB tool result, below red | 39.8 ms | 50 ms |
| No-op baseline (`/bin/sh -c true`) | 4.3 ms | none |

The figures come from the quietest of several runs on a shared machine, whose 1-minute load stayed above 10 throughout.

Because the firing path's absolute figure tracks machine load, its budget was judged by a paired relative measurement instead. The firing path and the doctrine hook's arming path were each run through their registered commands under bash 3.2 from one fixture, alternating run by run with the order flipped every pair, 200 runs each, at a 1-minute load of 14.6 to 14.8. Doctrine arming read a p50 of 55.3 ms and checkpoint firing 59.0 ms, a ratio of 1.0669. Scaled against the doctrine arming row above (46.9 ms), the firing path reads 50.0 ms (50.04 before rounding). To re-check it, repeat the pairing on any machine and scale the ratio by that row; an idle-machine run of the checkpoint timing tool supersedes it.

The sub-agent checkpoint hook is registered with no matcher, so it also runs after every tool call of every main session, where it must end at its first raw pattern check. The per-call paths every session and every sub-agent pays carry the 50 ms budget. The two per-call paths only an opted-in sub-agent pays (opted in below red, band already marked) carry 75 ms: each runs the payload confirm and the transcript tail read on every call, and an opted-in executor's tool calls each take seconds, so the difference over a whole executor run is a second or two. The once-per-agent first-sight path and the firing path carry 100 ms. Re-measured with `bash .gaia/tests/hooks/context-checkpoint-subagent-timing.sh`, through the registered command string, against generated sub-agent transcripts of more than 7 MB (including one whose final line is past the tail read bound and one whose first record is near the head read bound), 50 runs per path, interleaved next to the same no-op baseline.

| Path | p50 | Budget |
| --- | --- | --- |
| Main-session payload (no `agent_id`) | 22.3 ms | 50 ms |
| Not opted in, marked | 23.3 ms | 50 ms |
| Opted in, below red | 59.4 ms | 75 ms |
| Band already marked | 62.0 ms | 75 ms |
| Widened tail read | 104.3 ms | none |
| First sight (head read of a large first record) | 95.2 ms | 100 ms |
| Firing | 68.8 ms | 100 ms |
| No-op baseline (`/bin/sh -c true`) | 5.6 ms | none |
| Injected bytes on the firing path | 1,740 | none |
| Per-session chain over the no-matcher PostToolUse hooks | 3,955 ms | none |

The figures come from one run on a machine whose other sessions were idle, at a 1-minute load of 7.3 at the start and 13.7 at the end; runs under a load of 30 to 63 read the same or lower on every per-call row, so these rows do not track load. Profiling the opted-in path under bash 3.2 splits it into the cost every call pays (about 22 ms, the main-session row), the payload confirm's one `jq` (about 13 ms), the transcript tail read and scan (about 23 ms: `wc`, `tail` of the tail read bound, and the bash scan over it), and the window, line and band (about 6 ms). The per-session row is the main-session hook's below-red, no-marker p50 (34.2 ms, above) plus this hook's main-session payload p50, times 70 tool calls, the median over the 596 main-session transcripts of this repository's maintainer that held at least one tool call (a one-off count of `tool_use` blocks per transcript file). To re-check it, repeat the count on any machine and pass the two inputs to the tool as `--main-hook-ms` and `--median-tool-calls`.
<!-- gaia:maintainer-only:end -->

## See also

- [[Task Orchestration]]: the plan-specific case of this doctrine.
- [[Usage Ledger]]: the keys, links, and attribution the run folder and research rules rely on.
- [[Claude Hooks]]: how the injection hook is registered.
- [[Quality Gate]]: the gate the main thread runs once per commit.
- [[GAIA Plan]]: the command that applies the doctrine to a planned run.
