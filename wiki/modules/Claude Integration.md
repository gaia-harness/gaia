---
type: module
path: .claude/
status: active
purpose: Claude Code integration, commands, rules, hooks, agents, skills
created: 2026-04-20
updated: 2026-10-18
tags: [module, claude, hooks]
---

# Claude Integration

GAIA ships with [Claude Code](https://claude.ai/) support out of the box. Everything in `.claude/` is checked in and shared with the team, except the `.local` / gitignored exceptions noted below.

## Layout convention

`.claude/` is split by lifecycle, not by feature:

- `settings.json`: committed; hooks, permissions, plugins
- `settings.local.json`: gitignored; personal overrides
- `agent-memory/`: gitignored scratch path created on demand by named agents; **not** a source of truth; durable knowledge belongs in the wiki
- `agents/`: sub-agent definitions
- `commands/`: slash commands
- `hooks/`: bash hooks invoked by `settings.json`
- `frontend/.claude/instructions/`: parameterized one-shot runbooks dispatched by commands like `/gaia-init`; self-deleting after use
- `rules/`: auto-attached guidance, file-path scoped
- `skills/`: user-invokable workflows, scaffolders, context-triggered guidance

## Commands vs. skills

GAIA workflows are split between slash commands under `.claude/commands/` (`/gaia-plan`, `/gaia-spec`, `/gaia-cleanse`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-codify`, `/gaia-init`, and more) and standalone skills under `.claude/skills/` (`gaia-wiki`, with its own `SKILL.md`). There is no `/gaia` router; each command and skill reads a shared reference file in `.claude/skills/gaia/references/`. For the current inventory, query Serena or list the folder directly.

## Rules: auto-attached

Rules activate automatically based on file paths; no need to invoke them. Each rule scopes itself to a glob in its frontmatter (root rules in `.claude/rules/`, frontend rules in `frontend/.claude/rules/`). The set covers code conventions ([[Coding Guidelines]], [[State]], [[Routing]], [[i18n]], [[Tailwind]], [[API Service Pattern]], [[Storybook Stories]], [[Playwright]]), workflow ([[Git Workflow]], [[Quality Gate]], [[PR Merge Workflow]], [[Task Orchestration]]), and harness discipline (`shell-cwd.md`, `code-search.md`).

For the current full rule list, query Serena or list `.claude/rules/` and `frontend/.claude/rules/`.

## Hooks: wired through `settings.json`

Hooks are bash scripts wired through `.claude/settings.json`. See its `hooks` keys for the covered event types.

### Blocking hooks (deny risky actions)

[[Claude Hooks]] is the bundled-hook inventory: each blocking hook's index row says what it denies, and its subsection says why.

### Wiki coherence (a layered system)

> [!key-insight] Why GAIA owns the wiki hooks
> No hook commits wiki edits on its own.

The sync design is convergent: hooks never spawn `claude -p` sub-processes. No hook surfaces drift: the `🧠 /gaia-wiki` statusline nudge is the only signal, and the user's session reconciles the wiki via `/gaia-wiki`. See [[Wiki Sync]].

### Statusline (no hook)

`update-deps` and `update-gaia` are surfaced via the statusline, not a hook. The wrapper at `.gaia/statusline/gaia-statusline.sh` reads `.gaia/local/cache/shared/update-check.json` and right-aligns yellow `📦 /update-deps (X outdated, Y security)` and/or cyan `🚀 /update-gaia (X.Y.Z)` segments. Left-side rendering is delegated to the user's existing global `statusLine.command`; when there is none, `.gaia/statusline/left-side.sh` renders a default left side of project, branch, model with effort, and a context bar whose colors come from the shared threshold lib. A developer who has a global statusline chooses between the two in `/setup-gaia`, which records `statusline.left` (`gaia` or `user`) in `.gaia/local/settings.json`, GAIA's writable per-machine opt-ins file. `gaia` skips the global command and draws GAIA's bar; `user`, a missing key, or a file without version 1 or that does not parse keeps the global command. The choice is read from the main checkout, so every worktree shows the same left side. `/setup-gaia` warns (Phase 4.6) when the project's effective `statusLine` (a `.claude/settings.local.json` override, for example) bypasses `gaia-statusline.sh`, since that loses the nudges and the context readings. The hot path is cache-only; a background refresher (`.gaia/scripts/check-updates.sh`, TTL 6h) keeps the cache fresh. The statusline fires it on every render, so it holds a single-flight lock under `cache/shared/`: a run that finds another in flight exits without work, and a lock left by a killed run is reclaimed once stale. The `X outdated` count derives from `gaia update-deps run`, so it counts only the plan the skill will apply and inherits the `minimumReleaseAge` cooldown (see [[pnpm]]) rather than every raw `pnpm outdated` hit, and the `Y security` count is the open advisory count the same background refresh takes from `gaia update-deps advisories`; either term is omitted when it is zero. The count reads the payload's `actionable_count`, which subtracts groups the operator snoozed in the `/update-deps` preview: each run groups the outstanding updates by patch / minor / major / non-semver and lets the operator skip specific companion groups. A skipped group lands in a gitignored local ledger (`.gaia/local/declined-updates.json`) and drops out of the count until a newer version ships or 14 days pass; the preview still offers it every run. The ledger is local-statusline only.

The statusline is also the context-reading writer. Only it receives the main session's context window on stdin, so `.gaia/statusline/context-reading.sh` writes each session's reading to a per-session file under `.gaia/local/cache/shared/context/` on every render, whatever the left side is, and the audit loop's bound hook reads it to decide when a unit of audit rounds needs a human checkpoint. The checkpoint line and the bar colors both come from `.gaia/scripts/context-checkpoint-lib.sh`, so the bar and the checkpoint cannot disagree. The statusline also writes each session's effort reading to that directory, and `usage.sh record` reads it for the close rows ([[Usage Ledger]]); a human can lower the line for one machine by hand in `.gaia/local/protected/checkpoint-override.json` (see [[Project Config]]). Claude never writes that file: tool writes that name the context directory or anything under `.gaia/local/protected/` are denied by `block-audit-loop-write.sh`; a reading minted from Bash by running the statusline or `gaia_context_write` names neither and is outside that guard. See [[PR Merge Workflow#The branch checkpoint]].

The right side fits itself to the terminal width: each nudge sizes independently, shrinking through its own Large, Medium, and Small forms before collapsing to an icon (with a count, where the nudge has one), and falls back to a trailing `+N` for whatever still does not fit; the lowest-priority nudge still at its current size shrinks first. The icon legend lives in [[Claude Skills]] § Statusline update indicators.

Inside a linked worktree the right side renders only the one blocking per-clone nudge, `⚙️ /setup-gaia (Required)`, and only while setup is incomplete on main; every other indicator, `update-deps` and `update-gaia` included, is a main-checkout task queue and stays dark from a worktree, rendering only from the main checkout. The post-completion `/setup-gaia` nudge for a pending setup choice is one of that queue: it stays dark from a worktree, since `/setup-gaia` refuses to run there.

<!-- gaia:maintainer-only:start -->
On the maintainer's own machine, a gitignored `.claude/settings.local.json` (higher precedence than the committed `settings.json`) points the `statusLine` command at a gitignored `.gaia/local/maintainer-statusline.sh` wrapper. That wrapper un-suppresses the gaia-init right-side gate, then execs the shipped `.gaia/statusline/gaia-statusline.sh`, which resolves the left segment like any adopter's: the global statusline unless `.gaia/local/settings.json` chooses GAIA's bar. When debugging the statusline in this repo, read `settings.local.json` first, not `settings.json`.

A linked worktree's `.gaia/local` is one symlink to the main checkout's (see [[Worktrees]]), so `maintainer-statusline.sh` is reachable from every tree, and the wrapper finds the shipped script from its own file path, which the symlink resolves onto the main checkout. The shipped script anchors its own state reads on the one shared main-checkout resolver instead: it takes the session cwd from the status payload, resolves the main checkout from it, and reads the shared caches there, because the wrapper execs it from the main checkout even while the session runs in a worktree, so its install path answers for the wrong checkout. GAIA's left side names the main repo folder, not the worktree folder, because it reads the resolved main checkout. `EnterWorktree` does not survive `claude --resume`: a resumed session returns to main, and a statusline command loaded at session start is not hot-reloaded on `EnterWorktree`.
<!-- gaia:maintainer-only:end -->

## Agents

[[Code Review Audit Agent]] runs automatically before every PR merge (per [[PR Merge Workflow]]). The pre-merge gate is a multi-member Code Audit Team, not one agent: resolve the dispatched members with `bash .gaia/scripts/resolve-audit-members.sh` and dispatch the audit loop unit to run each one it names. See [[PR Merge Workflow]] for the dispatch and clearance mechanics.

Pre-seeded with GAIA's architecture knowledge. Durable findings belong in the wiki (`wiki/concepts/Code Review Audit Agent.md` and adjacent pages). The `.claude/agent-memory/` path is a gitignored scratch path (created on demand under a per-agent subdir such as `code-audit-frontend/`), not a source of truth.

`worthiness-evaluator` is an opus advisory agent that judges each emergent-surface test (the package descriptor's `emergentTests` globs: components, pages, and Playwright) on honesty and worthiness, returning a keep / fix / delete verdict per test. It proposes only and edits no files; every delete is human-gated. Its verdicts feed the worthiness ledger that `worthiness-presence-check.sh` enforces at merge.

## Skills

`.claude/skills/` holds workflow, scaffolder, context-triggered, and maintainer-only skills; see [[Claude Skills]] for the full grouped table, or list the folder directly for the current inventory.

Workflow and scaffolder skills are user-invoked. Context-triggered skills activate automatically when their `description:` matches the user's intent (`a11y-fixes` resolves axe-core accessibility violations from Vitest / Playwright / the `code-audit-frontend` agent's a11y bucket).

## settings.json

Registers its hooks (see the `hooks` key of `.claude/settings.json` for the current set). GAIA's shipped settings register no `WorktreeCreate` and no `WorktreeRemove` hook: the harness owns worktree creation and removal natively, under the same `.claude/worktrees/<name>/` layout, and the branch it cuts is named `worktree-<name>` with every `/` in `<name>` written as `+`. Worktree *provisioning* is a separate concern from creation, and it is GAIA's: `provision-worktree.sh` runs on session start and on worktree entry, re-links the shared state the registry declares and regenerates the worktree's typed routes, and is idempotent, so a worktree with broken links, or one made by a plain `git worktree add`, repairs itself on the next entry. Provisioning on entry rather than at creation is what lets it reach a worktree GAIA had no hand in making. Sets a `statusLine` command; the `enabledPlugins` key lists the enabled plugins. Serena MCP is registered user-globally with the `claude-code` context and `--project-from-cwd` auto-activation (`claude mcp add serena -s user`), not in this file (see [[Serena Integration]]).

The `permissions` key of `.claude/settings.json` holds the allow and deny lists. GAIA ships no `Read()` rule there: any such rule arms a bypass-immune approval breaker on every search and copy command, so read-side denial lives in the hook layer and, for sandboxed subprocesses, in `sandbox.filesystem.denyRead`. `Edit(<glob>)` is the write-side rule form: the file permission checks match only `Read(path)` and `Edit(path)` rules, and an `Edit` rule covers every file-editing tool (Write, Edit, MultiEdit, NotebookEdit), so a `Write(<glob>)` rule is accepted, never matched, and draws a startup warning naming the settings file it sits in. `block-sensitive-read.sh` delivers the whole tool tier, as heuristic defense-in-depth, not a sandbox. The OS-level sandbox is the tier that reaches an arbitrary subprocess, and GAIA declares its read boundary in `sandbox.filesystem.denyRead` rather than leaning on a permission rule to merge into it; those entries stay inert until a machine enables the sandbox, which GAIA does not do by default. Both permission lists are alphabetized; path globs are repo-relative (no leading `/`).

For the current verbatim contents of `settings.json`, read it directly via Serena.
