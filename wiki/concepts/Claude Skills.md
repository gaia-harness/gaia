---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-15
tags: [concept, claude, skills]
---

# Claude Skills

`.claude/skills/` holds project-local skills. Each has a `SKILL.md` with YAML frontmatter (`name`, `description`, optional `allowed-tools`) defining when it activates. Skills apply by context/intent (description match); rules apply by file path. Skills that serve only the React app live in `frontend/.claude/skills/` and surface when work touches files under `frontend/`; the harness and stack-neutral skills stay in `.claude/skills/`.

See [[Claude Integration|the modules page]] for the full skills inventory inside `.claude/`.

## Project-local skills

GAIA's skills split into two groups: shared `gaia/references/` playbooks consumed by user-invoked workflows, and the skills under `.claude/skills/` and `frontend/.claude/skills/`, which [[Claude Integration|the modules page]] inventories.

### `gaia/references/` workflow playbooks

`.claude/skills/gaia/` holds no `SKILL.md`; it is a `references/` folder of deep-dive playbooks, each consumed by its matching `gaia-*` command or skill (the command/skill is the activation surface; the reference is the runbook it reads). A few references (`isolation.md`, `cost-record.md`, `work-lifecycle.md`) are shared recipes several commands read.

### Statusline update indicators

Every GAIA nudge is surfaced by the **statusline**, not by a hook, and the slot indices in `.gaia/statusline/gaia-statusline-right.sh` set their priority order. Its right side, `.gaia/statusline/gaia-statusline-right.sh`, reads `.gaia/local/cache/shared/update-check.json` (plus the debt count's own cache) and right-aligns a colored `<emoji> /<command> (<reason>)` segment for each nudge that is armed, with ` │ ` between segments. The left side is the adopter's own global `statusLine.command` from `~/.claude/settings.json` when one exists, so an existing statusline appears unchanged, unless the machine chose GAIA's bar in `/setup-gaia`; otherwise GAIA's own bar, falling back to a bare `Claude Code` label. [[Claude Integration]] owns the left-side resolution. The hot path is cache-only (no network, no `pnpm` calls) and a background refresher (`.gaia/scripts/check-updates.sh`, TTL 6h) keeps the cache fresh. The outdated count derives from `gaia update-deps run` rather than raw `pnpm outdated`, so it counts only the plan the skill will apply and inherits the `minimumReleaseAge` cooldown and major-version cap (see [[pnpm]]); the nudge never advertises an update the skill would skip. It reads the payload's `actionable_count`, which also subtracts groups the operator snoozed in the `/update-deps` preview (a gitignored `.gaia/local/declined-updates.json` ledger, resurfacing after a newer version or 14 days). Silent on missing cache or missing `jq`.

The right side fits itself to the statusline row, which is the terminal width less the spacing Claude Code draws around it, rather than letting Claude Code cut the line at the edge. Each nudge sizes independently through its own Large, Medium, and Small forms, then an icon, then a trailing `+N`: Large carries the full reason, Medium a short form with just its number (`📦 /update-deps (28)`; `/gaia-cleanse` has none, since its reasons share no unit, and the `/update-gaia` update state has none, since its Large reason is already just the version; the pull and resume states' Medium forms are `pull <version>` and `resume <version>`), and Small the bare command (a teammate's in-progress nudge is the exception, below). Every form leads with the nudge's emoji, so the icon a nudge shrinks to is one its text forms already showed. The lowest-priority nudge still at its current size shrinks first, so a higher-priority nudge is never at a later size step than a lower-priority one (a nudge with no Medium form, such as `/gaia-cleanse`, shows its Small text at that step), and past the icon stage `+N` names how many more are hidden. The `/update-gaia` slot holds exactly one of four states, first match winning: `🚀 /update-gaia (pull <version>)` when origin's default branch carries a higher version than this checkout's own `.gaia/VERSION`, `⌛️ GAIA <version> in progress (@<login>)` when a named teammate's update is open, `🚀 /update-gaia (resume <version>)` when the user's own claim is open, and `🚀 /update-gaia (<version>)` when a release is available. The in-progress nudge has a floor: it shrinks to a Medium form (`GAIA <version> (@<login>)`) and never past it, so it never shows `/update-gaia` or the rocket; while the line shrinks and hides every other nudge, it renders past the available width with the `+N` when nothing else is left to give up. [[Update Workflow]] owns the claim. `/setup-gaia` is the one exception: while setup is incomplete it renders alone, as text, at every width. Once setup is complete, `/setup-gaia` comes back as the first nudge, `⚙️ /setup-gaia (<N> choices pending)`, when `.gaia/setup-features.json` lists a machine-scope setup choice that `decisions` in `.gaia/local/setup-state.json` does not yet record; it renders only from the main checkout, never shrinks before a lower-priority nudge does, and clears as `/setup-gaia` records each choice. Claude Code does not re-run the statusline on a terminal resize, so the shipped `statusLine` block sets `refreshInterval: 15` and the line refits within 15 seconds of a resize with no message sent. The icon legend:

| Icon | Command             | Count shown                      | Color (SGR)              |
| ---- | ------------------- | -------------------------------- | ------------------------ |
| ⚙️   | `/setup-gaia`       | pending setup choice count       | `01;95` bright magenta   |
| 🚀   | `/update-gaia`      | none                             | `01;36` cyan             |
| ⌛️   | none (a teammate's update in progress) | none          | `01;93` bright yellow    |
| 📦   | `/update-deps`      | outdated plus security advisory count | `01;33` yellow      |
| 🔎   | `/gaia-cleanse`     | none                             | `01;32` green            |
| 💪   | `/gaia-fitness`     | a grade, blended file count, or harness commit count | `01;94` bright blue |
| 🔨   | `/gaia-codify`      | candidate count (none when zero) | `01;35` magenta          |
| 🐛   | `/gaia-debt`        | open issue count                 | `01;91` bright red       |
| 🧹   | `/gaia-residue`     | aged residual count              | `01` default foreground  |
| 🧠   | `/gaia-wiki`        | commits behind the wiki          | `01;96` bright cyan      |

Colors follow one rule, so a new nudge picks its color from it rather than by eye. Every code is bold (`01`), plus one of the 16 named ANSI colors, which the terminal theme recolors so they stay readable on light and dark backgrounds; 256-color and 24-bit codes are out. Black (`30`, `90`) vanishes on dark themes, white (`37`, `97`) on light ones, and plain blue (`34`) is too dim on dark ones, so none of them is used; a nudge that should read as plain white uses bold alone (`01`), which draws in the theme's own foreground. Each nudge gets a color no other nudge uses, and adjacent slot numbers never share a hue family, because a normal and a bright shade of one hue read alike side by side (the renderer packs only the present nudges, so two nudges whose slots are separated by empty ones can still render side by side). The `/setup-gaia (Required)` segment that renders alone uses the setup nudge's color. Bright green (`92`) and red (`31`) are the safe colors left; past them, a new nudge shares a color with a nudge in a slot that is not adjacent to its own. Only a nudge's text forms are colored: its icon form and the trailing `+N` render uncolored, so the icon alone identifies a nudge at narrow widths.

The statusline surface is chosen over a `SessionStart` `<system-reminder>` hook because system-reminders are visible only to the model; the user never sees them, so prompts fire and snooze without the user being shown a choice. The statusline is always visible, has no snooze state, and clears itself the moment the underlying cache reports clean.

## Rules vs. Skills: decision criteria

GAIA's `.claude/` surface places each kind of guidance in the layer that loads it most efficiently. Use this matrix when adding new guidance:

| Layer                                 | Loads when…                                            | Use for                                                                            |
| ------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Hook (`.claude/hooks/`)               | Tool call matches a registered event                   | Mechanical enforcement (block / advise) on a specific tool shape, no judgment      |
| Rule (`.claude/rules/`)               | Matching `paths:` glob in scope (or always when empty) | File-path-bound conventions: project-wide style, route layout, accessibility, i18n |
| Skill (`.claude/skills/`)             | `description:` matches user intent / context           | Cross-file reasoning patterns: refactor playbooks, error-fix recipes, TDD loop     |
| Instruction (`frontend/.claude/instructions/`) | Dispatched by a command/skill at runtime               | Parameterized one-shot runbooks (add a locale, strip i18n, etc.); self-deleting    |

Heuristic when migrating:

- **Rule → hook** when the guidance can be phrased as a deterministic block on a specific tool call (e.g. "no writes to `.env`" → `block-secrets-write.sh`).
- **Rule → skill** when the guidance is a body of patterns triggered by intent rather than file path (e.g. ESLint fix recipes only matter when fixing lint, not on every edit) and benefits from references that load on demand.
- **Keep as rule** when it must auto-apply whenever a file in scope is touched, regardless of user intent (e.g. `i18n.md` for `frontend/app/pages/**`, `accessibility.md`, `coding-guidelines.md`, `quality-gate.md`).

## Skill listing

Every session carries a listing of the skills and commands Claude may start on its own: each one's `name` and `description`, truncated per entry. The listing is always-loaded context, so every description pays its bytes in every session, and it is also the only text Claude matches a request against. The frontmatter that feeds it follows Anthropic's Agent Skills rules:

- `name`: at most 64 characters of lowercase letters, digits, and hyphens, never containing `claude` or `anthropic`.
- `description`: non-empty, at most 1,024 characters, no XML tags, written in the third person ("Files a tech-debt issue...", never "File a..." or "You can..."). A model-invocable skill states what it does and when to use it, with the phrases a user would say.
- A command only a person starts sets `disable-model-invocation: true`. Its description leaves the listing and Claude cannot start it on its own; it runs when typed as `/name`, and its description needs only the third-person what. `grep -l 'disable-model-invocation: true' .claude/commands/*.md` lists them.
- A workflow skill a person reaches by typing `/name` or from a statusline `<emoji> /<name>` nudge, and whose name says what it does, is `name-only` under `skillOverrides` in `.claude/settings.json` (that key holds the list): its description leaves the listing, and Claude can still start it from a request that names the job. Some stay out because their descriptions carry the routing, for example `file-tech-debt`, whose Do-NOT-trigger clause keeps a filing request away from `/gaia-debt`, and `gaia-cleanse`, whose name alone does not draw a request to clean up drifted memory and wiki files.
- A `model:` pin follows the model table in [[Workflow Doctrine]].

Vendored and installer-managed skills keep their upstream frontmatter.
`gaia fitness check` (the `frontmatter` rules) checks the `name` and `description` limits over every skill and command the project owns.

## Skill references convention

`SKILL.md` is stack-agnostic lazy philosophy. It auto-loads into context, so it must stay short and general.

Stack-specific or deep-dive content lives in `references/{topic}.md` inside the skill directory, loaded on demand. `SKILL.md` hints at available references via markdown links. Adding support for a new stack means adding a new reference file; `SKILL.md` itself is never touched. Vendored third-party skills are the exception: they ship as the upstream wrote them, and [[Vendored Third-Party Skills]] owns that rule.

**Example:** `frontend/.claude/skills/tdd-react/SKILL.md` links to `frontend/.claude/skills/tdd-react/references/tests-react.md`, while the stack-neutral `.claude/skills/tdd/` stays at the root. A Svelte package would carry its own `tdd-svelte` skill beside it.

See [[Claude Integration Conventions]] for the broader convention covering extension points, monorepo retrofit, and service swaps.

## Wiki skills

Wiki maintenance (sync, consolidate, lint) runs through GAIA's native CLI (`.gaia/cli/gaia wiki ...`) and `/gaia-wiki`; GAIA owns `log.md` (`gaia wiki log-prepend`) and `index.md`. Obsidian syntax for wiki pages lives in `.claude/rules/wiki-style.md`, which loads on the paths its own `paths:` frontmatter names. See [[Claude Integration Conventions]] § Wiki vendor relationship.

## Playwright CLI vs. MCP

GAIA uses the `playwright-cli` skill (Bash-invoked CLI) rather than the Playwright MCP server. The MCP server was evaluated and rejected.

**Why:** MCP servers load tools into the system prompt every conversation, paying a token tax even when unused. For Playwright specifically, the per-test workflow is independent enough that CLI invocation works fine; there is no warm-state benefit that justifies the tax.

**How to apply:** Do not recommend the Playwright MCP server for GAIA. When browser automation is needed, point at the existing `playwright-cli` skill.

**Scope:** This is a Playwright-specific decision, not a blanket "CLI over MCP" policy. Other MCPs (context7) are evaluated on their own merits. Each MCP candidate is assessed individually.
