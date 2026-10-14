---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-13
tags: [concept, claude, skills]
---

# Claude Skills

`.claude/skills/` holds project-local skills. Each has a `SKILL.md` with YAML frontmatter (`name`, `description`, optional `allowed-tools`) defining when it activates. Skills apply by context/intent (description match); rules apply by file path. Skills that serve only the React app live in `frontend/.claude/skills/` and surface when work touches files under `frontend/`; the harness and stack-neutral skills stay in `.claude/skills/`.

See [[modules/Claude Integration|the modules page]] for the full skills inventory inside `.claude/`.

## Project-local skills

GAIA's skills split into two groups: shared `gaia/references/` playbooks consumed by user-invoked workflows, and the skills under `.claude/skills/` and `frontend/.claude/skills/`, which [[modules/Claude Integration|the modules page]] inventories.

### `gaia/references/` workflow playbooks

`.claude/skills/gaia/` holds no `SKILL.md`; it is a `references/` folder of deep-dive playbooks, each consumed by its matching `gaia-*` command or skill (the command/skill is the activation surface; the reference is the runbook it reads). A few references (`isolation.md`, `cost-record.md`, `work-lifecycle.md`) are shared recipes several commands read.

### Statusline update indicators

Every GAIA nudge (the post-completion `setup-gaia` choice nudge, `update-gaia`, `gaia-serena-sync`, `update-deps`, `gaia-cleanse`, `gaia-codify`, `gaia-debt`, `gaia-residue`, `gaia-wiki`, in that priority order) is surfaced by the **statusline**, not by a hook. `.gaia/statusline/gaia-statusline.sh` reads `.gaia/local/cache/shared/update-check.json` (plus the debt count's own cache) and right-aligns a colored `Run /<command> (<reason>)` segment for each nudge that is armed. The left side is the adopter's own global `statusLine.command` from `~/.claude/settings.json` when one exists, so an existing statusline appears unchanged, unless the machine chose GAIA's bar in `/setup-gaia`; otherwise GAIA's own bar, falling back to a bare `Claude Code` label. [[Claude Integration]] owns the left-side resolution. The hot path is cache-only (no network, no `pnpm` calls) and a background refresher (`.gaia/scripts/check-updates.sh`, TTL 6h) keeps the cache fresh. The outdated count derives from `gaia update-deps run` rather than raw `pnpm outdated`, so it counts only the plan the skill will apply and inherits the `minimumReleaseAge` cooldown and major-version cap (see [[pnpm]]); the nudge never advertises an update the skill would skip. It reads the payload's `actionable_count`, which also subtracts groups the operator snoozed in the `/update-deps` preview (a gitignored `.gaia/local/declined-updates.json` ledger, resurfacing after a newer version or 14 days). Silent on missing cache or missing `jq`.

The right side fits itself to the statusline row, which is the terminal width less the spacing Claude Code draws around it, rather than letting Claude Code cut the line at the edge. Each nudge sizes independently through its own Large, Medium, and Small forms, then an icon, then a trailing `+N`: Large carries the full reason, Medium a short form with just its number (`Run /update-deps (28)`; the version for `/update-gaia`; `/gaia-cleanse` has none, since its reasons share no unit), and Small the bare command. The lowest-priority nudge still at its current size shrinks first, so a higher-priority nudge is never at a later size step than a lower-priority one (a nudge with no Medium form, such as `/gaia-cleanse`, shows its Small text at that step), and past the icon stage `+N` names how many more are hidden. `/setup-gaia` is the one exception: while setup is incomplete it renders alone, as text, at every width. Once setup is complete, `/setup-gaia` comes back as the first nudge, `Run /setup-gaia (<N> setup choices pending)`, when `.gaia/setup-features.json` lists a machine-scope setup choice that `decisions` in `.gaia/local/setup-state.json` does not yet record; it renders only from the main checkout, never shrinks before a lower-priority nudge does, and clears as `/setup-gaia` records each choice. Claude Code does not re-render the statusline on a bare terminal resize, so the line refits on the next message rather than immediately. The icon legend:

| Icon | Command             | Count shown                      |
| ---- | ------------------- | -------------------------------- |
| 🔧   | `/setup-gaia`       | pending setup choice count       |
| 🌍   | `/update-gaia`      | none                             |
| 🔭   | `/gaia-serena-sync` | missing language count           |
| 📦   | `/update-deps`      | outdated count                   |
| 🔎   | `/gaia-cleanse`       | none                             |
| 🔨   | `/gaia-codify`      | candidate count (none when zero) |
| 💸   | `/gaia-debt`        | open issue count                 |
| 🧹   | `/gaia-residue`     | aged residual count              |
| 🧠   | `/gaia-wiki`        | commits behind the wiki          |

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
- A `model:` pin follows the model table in [[Workflow Doctrine]].

Vendored and installer-managed skills keep their upstream frontmatter.
`gaia fitness check` (the `frontmatter` rules) checks the `name` and `description` limits over every skill and command the project owns.

## Skill references convention

`SKILL.md` is stack-agnostic lazy philosophy. It auto-loads into context, so it must stay short and general.

Stack-specific or deep-dive content lives in `references/{topic}.md` inside the skill directory, loaded on demand. `SKILL.md` hints at available references via markdown links. Adding support for a new stack means adding a new reference file; `SKILL.md` itself is never touched. Vendored third-party skills are the exception: they ship as the upstream wrote them, and [[Vendored Third-Party Skills]] owns that rule.

**Example:** `frontend/.claude/skills/tdd-react/SKILL.md` links to `frontend/.claude/skills/tdd-react/references/tests-react.md`, while the stack-neutral `.claude/skills/tdd/` stays at the root. A Svelte package would carry its own `tdd-svelte` skill beside it.

See [[Claude Integration Conventions]] for the broader convention covering extension points, monorepo retrofit, and service swaps.

## Plugin skills (claude-obsidian)

Core wiki maintenance (sync, consolidate, lint) runs through GAIA's native CLI (`.gaia/cli/gaia wiki ...`), not the plugin. Wiki-lint in particular is a GAIA-native check with its own rules and report, independent of the plugin's `wiki-lint` skill. The `claude-obsidian` plugin is installed at project scope for this repository through the Claude Code marketplace (not vendored into this repo; the marketplace stays user-level) and supplies **auxiliary** skills only. Its skills load in sessions of this project, not of every project on the machine, and auto-load on context match alongside GAIA's project-local skills.

GAIA leans on two of them:

- `claude-obsidian:wiki-query`: read-only. Answers questions using the vault (hot cache, index, then drill in), with citations; quick / standard / deep modes.
- `claude-obsidian:obsidian-markdown`: write correct Obsidian Flavored Markdown (wikilinks, embeds, callouts, properties, math, canvas syntax).

GAIA owns `log.md` and `index.md`: `gaia wiki log-prepend` writes `log.md` and `/gaia-wiki` maintains `index.md`. The plugin's mutation skills (`claude-obsidian:save`, `claude-obsidian:wiki-ingest`, `claude-obsidian:autoresearch`) are not leaned on: they would write into GAIA's sha-keyed `log.md` ledger, and their vault resolution fails closed on GAIA's layout, which is the intended default.

The plugin ships further skills; the upstream [skills directory](https://github.com/AgriciDaniel/claude-obsidian/tree/main/skills) is the catalog. The skill source also lives in the upstream plugin cache (`~/.claude/plugins/cache/agricidaniel-claude-obsidian/claude-obsidian/<version>/skills/`), informational reference only: adopters should not edit these files. See [[Claude Integration Conventions]] § Wiki vendor relationship and [[DragonScale Opt-Out]] for the baseline policy and why DragonScale's `wiki-fold` skill is dormant under GAIA's default configuration.

## Playwright CLI vs. MCP

GAIA uses the `playwright-cli` skill (Bash-invoked CLI) rather than the Playwright MCP server. The MCP server was evaluated and rejected.

**Why:** MCP servers load tools into the system prompt every conversation, paying a token tax even when unused. For Playwright specifically, the per-test workflow is independent enough that CLI invocation works fine; there is no warm-state benefit that justifies the tax.

**How to apply:** Do not recommend the Playwright MCP server for GAIA. When browser automation is needed, point at the existing `playwright-cli` skill.

**Scope:** This is a Playwright-specific decision, not a blanket "CLI over MCP" policy. Other MCPs (Serena, claude-obsidian, context7) are evaluated on their own merits. Each MCP candidate is assessed individually.
