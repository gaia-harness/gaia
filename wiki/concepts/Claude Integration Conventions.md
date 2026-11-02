---
type: concept
title: Claude Integration Conventions
status: active
created: 2026-04-21
updated: 2026-10-23
tags: [claude, meta, configuration]
---

# Claude Integration Conventions

> Not auto-loaded. Consult on demand when a Claude-integration retrofit is in scope.

Conventions for GAIA's Claude Code config surface: extension points, monorepo retrofit, service swaps, domain isolation. For the inventory of what currently exists in this project, see [[Claude Integration|the modules page]].

## 1. Directory overview

| Directory / File        | Purpose                                                                                                                       | Loaded                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| `.claude/agents/`       | Named subagents (`.md` per agent); extension dirs for review-type agents                                                      | Manual (Task tool)           |
| `.claude/commands/`     | Slash commands (e.g. `/gaia-init`, `/gaia-plan`)                                                                              | Manual (slash invocation)    |
| `.claude/hooks/`        | Bash scripts wired in `settings.json`                                                                                         | Auto on matched tool events  |
| `.claude/rules/`        | Coding rules; optionally path-scoped via `paths:` frontmatter                                                                 | Auto (global) or path-scoped |
| `.claude/skills/`       | Skills: both context-triggered (`naming-conventions`, `tdd`) and user-invoked (`gaia-wiki`, `update-deps`) | Auto on context/intent match |
| `.claude/agent-memory/` | Ephemeral per-agent scratch (gitignored by GAIA's shipped `.gitignore`, not source of truth)                                   | Auto per named agent         |
| `wiki/`                 | Knowledge base: architecture, decisions, patterns (source of truth)                                                           | Manual (on-demand fetch)     |

See [[Claude Integration|the modules page]] for the inventory of current commands, rules, hooks, and skills.

### Wiki vendor relationship

`wiki/` is an Obsidian vault: a reader can open it in the Obsidian app, and Claude writes its syntax from the Obsidian section of `.claude/rules/wiki-style.md`. Wiki maintenance (sync, consolidate, lint) runs through GAIA's native CLI (`.gaia/cli/gaia wiki ...`), and the wiki hooks are GAIA-owned (`.claude/hooks/wiki-*.sh`); no hook commits wiki edits on its own.

## 2. Rules vs. skills vs. hooks: decision criteria

Three layers, three triggers. Pick the layer that loads guidance only when it's actually needed.

| Layer | Loads when…                                        | Use for                                                                            |
| ----- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Hook  | Tool call matches a registered event               | Mechanical block / advice on a specific tool shape, no judgment required           |
| Rule  | `paths:` glob matches an in-scope file (or always) | File-path-bound conventions: project-wide style, route layout, accessibility, i18n |
| Skill | `description:` matches user intent / context       | Cross-file reasoning patterns: refactor playbooks, error-fix recipes, TDD loop     |

Layer-selection heuristics:

- **Hook** when the guidance is a deterministic block on a specific tool call (e.g. `block-secrets-write.sh` denies writes to `.env`).
- **Skill** when the guidance is intent-triggered, not file-path-triggered, and benefits from references that load on demand (e.g. `eslint-fixes` only matters when fixing lint, not on every edit).
- **Rule** when the guidance must auto-apply whenever an in-scope file is touched, regardless of intent (`i18n.md`, `accessibility.md`, `coding-guidelines.md`, `quality-gate.md`).

After adding a rule, skill, agent or command, Claude runs `.gaia/cli/gaia fitness check --json` and fixes any finding it reports against the new file before calling the work done.

Cross-link: [[Claude Skills]] § Rules vs. Skills: decision criteria.

## 3. Agent extensions (review-type agents only)

Review-type agents, agents that spawn multiple specialist subagents, support a directory-based extension mechanism. Single-subagent agents do not need it.

**Contract:** `.claude/agents/{agent-name}/*.md` files with `subagents:` and `library:` YAML frontmatter.

```yaml
---
subagents: [react-patterns, typescript]
library: package-name
---
```

At dispatch the agent Globs `*.md` in its extension directory (skipping `README.md`), reads each file's `subagents:` line, and hands the file's path to the matching specialist subagent, which reads it itself. To swap a library: delete its extension file, add one for the replacement. The main agent definition stays unchanged.

Convention applies to **review-type agents only**, currently just `code-audit-frontend`. Cross-link: [[Code Review Audit Agent]].

## 4. Skill references convention

`SKILL.md` is stack-agnostic lazy philosophy; it auto-loads into context, so it must stay concise. Vendored third-party skills are the exception: they ship as the upstream wrote them, and [[Vendored Third-Party Skills]] owns that rule.

Cross-link: [[Claude Skills]].

## 5. Rule `paths:` frontmatter

Rules in `.claude/rules/*.md` with a `paths:` YAML list auto-load **only** when a matching file is in scope. Rules without `paths:` auto-load every session. Keep the always-load list tight. A rule under `apps/web/.claude/rules/` anchors its globs at `apps/web/`, so it writes package-relative globs (`app/**`); a root rule anchors at the repo root and writes `apps/web/app/**`. See [[Package Descriptor]].

```yaml
---
paths:
  - 'app/pages/**/*'
  - 'app/components/**/*'
---
```

Examples of path-scoped rules: `i18n.md` (pages + components + languages), `routes.md` (routes + pages), `state-pattern.md` (state directory). Always-load rules: `quality-gate.md`, `coding-guidelines.md`.

A new or re-scoped rule closes with `.gaia/cli/gaia fitness check --json`, which reports a `paths:` entry that does not compile and a path the rule names that does not exist.

## 6. Monorepo retrofit playbook

Adding an app or a library to the pnpm workspace is one procedure, owned by [[Package Descriptor#Adding an app or package]]: it names the workspace entry, registry entry and descriptor, and the settings that follow from a member's stack. This section holds only what that page does not.

- **Its own `CLAUDE.md` and `.claude/`.** A member with stack-specific rules or skills puts them in `{PKG}/.claude/rules/` and `{PKG}/.claude/skills/`, with `paths:` globs relative to `{PKG}`, beside a `{PKG}/CLAUDE.md`. `apps/web/` is the worked example.
- **A quality gate of its own**, as §8 describes: the shared gate's skip check matches JavaScript, TypeScript and CSS sources, so a member in another language gets no gate until its own names its checks.
- **CI.** `.github/workflows/tests.yml` arms its incremental skip on the web app and root config, so a change under `{PKG}` alone runs no tests there. Add a workflow of its own named per [[Workflow Naming Convention]], copying `tests.yml`'s shape, and gate its steps inside the job rather than with a workflow `paths:` filter ([[Incremental CI Skipping]]).
- **An auditor**, when no existing member's lens fits: [[Registering a Code Audit Team Member]], then `bash .gaia/scripts/verify-audit-roster.sh`.
- **Verify.** Run `pnpm -C {PKG} typecheck`, `./.gaia/cli/gaia packages sync-settings --check`, `bash .gaia/scripts/verify-audit-roster.sh` and `.gaia/cli/gaia fitness check --json` before reporting the member added.

### A backend and worktrees

GAIA provisions per-worktree isolation for the `apps/web/` app only: the port slot, the port file, and the refusals that keep one tree's servers off another's ports ([[Worktrees#Ports per worktree]]). A backend added beside it gets none of that automatically: it has no port slot, and its database, migrations, seed data and queues are shared by every tree. It takes one of two shapes:

- **One shared backend** that every worktree points at. It is simple, but branches that change the schema or the data collide.
- **A backend per worktree**, with its own port, database and seed. It isolates each branch, but every tree pays the setup and running cost.

Before running backend work in a worktree, Claude raises this trade-off with the user and lets the user choose. Claude does not pick a shape on its own.

## 7. External-service rule pattern

When adding an external service (Supabase, Firebase, Stripe, Auth0, etc.):

- Add `.claude/rules/{service}.md` with `paths:` scoped to directories touching the service.
- Optionally add `.claude/agents/code-audit-frontend/{service}.md` with `subagents:` frontmatter for specialist review hooks.
- Document the service in `wiki/dependencies/{Service}.md`.

## 8. Per-stack quality gate

Multiple gates coexist via path scoping:

- `.claude/rules/quality-gate.md`: shared/default gate (always loaded; not stack-neutral, since its gate's package steps check only `apps/web/`)
- `.claude/rules/quality-gate-{stack}.md`: stack-specific gate with `paths:` frontmatter

**How the two coexist.** The stack gate adds to the shared gate and replaces none of it. It loads when a `{PKG}` file is in scope and owns that package's checks; the shared gate stays loaded and keeps its own skip check, which reads file extensions rather than packages, so a commit staging TypeScript under `{PKG}` selects both and runs both. The stack gate never restates the shared steps (simplify, localization, the stop-and-report step); it points at them. A stack gate is new and adopter-owned, so `/update-gaia` never touches it, while the shared gate is `owned`: change it only by adding a stack gate.

**The contract.** A stack gate names its trigger (the staged paths that select it), its checks in order with the exact commands, the pass condition (zero errors and zero warnings), and where it hands back to the shared gate. Skeleton, with `{PKG}` and `{stack}` filled in:

```
---
paths:
  - '{PKG}/**'
---

# Quality Gate ({stack})

Before any `git commit` that stages a file under `{PKG}/`, run these in order. Fix every error and warning before reporting.

1. `pnpm -C {PKG} typecheck`
2. `pnpm -C {PKG} lint`
3. `pnpm -C {PKG} test`
4. The package's build or smoke command.

This gate adds to `.claude/rules/quality-gate.md`. Run its simplify and stop-and-report steps (`wiki/decisions/Quality Gate.md`) once for the whole commit, not once per gate.
```

Steps 1 and 3 are scripts the pre-commit floor already requires of `{PKG}/package.json` (§6 step 5), so the gate and the hook run the same checks. Cross-link: [[Quality Gate]].

## 9. API service layer swap

When replacing the default API layer (Ky + Zod) with Supabase, Firebase, GraphQL, or another REST client:

1. Delete or archive `apps/web/.claude/rules/api-service.md` (GAIA's default Ky pattern).
2. Delete `apps/web/.claude/skills/new-service/` if it scaffolds the outgoing pattern.
3. Add `.claude/rules/{new-service}.md` with `paths:` scoped to affected directories.
4. Add `.claude/agents/code-audit-frontend/{new-service}.md` with `subagents: [react-patterns, typescript]`.
5. Update `{CONTAINER}/{APP}/CLAUDE.md` (or root) with dev-server commands for the new service.
6. Update `apps/web/test/mocks/`: remove MSW handlers that shimmed the old layer if the new layer has its own test fakes.

## 10. Per-app CLAUDE.md hierarchy (monorepo)

Per-package `CLAUDE.md` hierarchy (see section 6 step 3):

- **Root `CLAUDE.md`**: monorepo overview, cross-cutting rules (wiki, memory discipline).
- **`{CONTAINER}/{APP}/CLAUDE.md`**: per-app stack specifics, dev commands, local env notes.

Loading is cwd-based: the closest-up `CLAUDE.md` wins per Claude Code's convention.

## 11. Domain isolation (MANDATORY)

The governing rule from root `CLAUDE.md`: **don't cross-load domains.**

- Technical work → the technical wiki folders named in CLAUDE.md (Wiki and memory) only.
- Only cross-load when the task genuinely spans domains.

When adding new wiki top-level folders, keep them single-domain. Claude must refuse to auto-include cross-domain content during normal operation. When in doubt, ask rather than load.

See root `CLAUDE.md` § Wiki for the authoritative directive.

## 12. React Doctor (per-machine install)

Do **not** vendor `react-doctor` into the repo. Do not symlink it. Install per-machine with `.gaia/scripts/install-react-doctor.sh`, which `/gaia-init` runs at the end of its dependency step, before anything reads `apps/web/`, and `/setup-gaia` runs through `.claude/skills/gaia/references/setup/per-machine.md` when the skill is absent. The skill lands in `apps/web/.claude/skills/react-doctor/`.

The `code-audit-frontend` agent dispatches react-doctor **in parallel** with its specialist subagents. `.claude/agents/code-audit-frontend.md` owns the command and its scope flag.

## 13. Proceed vs. AskUserQuestion

When a recommendation already contains the concrete decisions (file paths, specific subsections to add, exact replacements), proceed directly instead of issuing `AskUserQuestion` to confirm sub-details.

**Why:** The user reads the recommendation, decides at the recommendation level, and treats internal sub-decisions as Claude's responsibility. Confirming sub-decisions that were already in the recommendation slows work without changing the outcome.

**How to apply:**

- After laying out a clear, specific plan, default to executing it. Do not issue `AskUserQuestion` to confirm "should we do X" when X was already in the plan.
- Reserve `AskUserQuestion` for genuinely branching decisions where the user's preference cannot be inferred (e.g., scope bundling vs. splitting, two valid approaches with different trade-offs).
- A brief verification pass (path audit, wiki-style check) before commit is not a question; it is verifying the work.
- When a question is warranted and its answer is a choice, `.claude/rules/user-questions.md` sets its form: an `AskUserQuestion`, recommended option first.

---

## Cross-links

[[Code Review Audit Agent]] · [[Claude Skills]] · [[Claude Hooks]] · [[Quality Gate]] · [[Pre-commit Hooks]]
