---
type: concept
title: Claude Integration Conventions
status: active
created: 2026-04-21
updated: 2026-10-15
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

At dispatch the agent Globs `*.md` in its extension directory (skipping `README.md`), reads each file, and injects its content into the matching specialist subagent's prompt. To swap a library: delete its extension file, add one for the replacement. The main agent definition stays unchanged.

Convention applies to **review-type agents only**, currently just `code-audit-frontend`. Cross-link: [[Code Review Audit Agent]].

## 4. Skill references convention

`SKILL.md` is stack-agnostic lazy philosophy; it auto-loads into context, so it must stay concise. Vendored third-party skills are the exception: they ship as the upstream wrote them, and [[Vendored Third-Party Skills]] owns that rule.

Cross-link: [[Claude Skills]].

## 5. Rule `paths:` frontmatter

Rules in `.claude/rules/*.md` with a `paths:` YAML list auto-load **only** when a matching file is in scope. Rules without `paths:` auto-load every session. Keep the always-load list tight. A rule under `frontend/.claude/rules/` anchors its globs at `frontend/`, so it writes package-relative globs (`app/**`); a root rule anchors at the repo root and writes `frontend/app/**`. See [[Package Descriptor]].

```yaml
---
paths:
  - 'app/pages/**/*'
  - 'app/components/**/*'
---
```

Examples of path-scoped rules: `i18n.md` (pages + components + languages), `routes.md` (routes + pages), `state-pattern.md` (state directory). Always-load rules: `quality-gate.md`, `coding-guidelines.md`.

## 6. Monorepo retrofit playbook

GAIA ships its React app as the `frontend/` package of a pnpm workspace whose root holds the shared harness. This playbook adds a further package beside it, such as a backend. The package's folder is a project decision; `{PKG}` stands for its path below. `frontend/` is the worked example for every step: copy its shape, not its contents.

1. **Join the workspace.** List `{PKG}` under `packages:` in `pnpm-workspace.yaml` and give it a `package.json`. The pre-commit hook drives each package through `pnpm -C {PKG}`, so the manifest is needed even for a stack outside Node.
2. **Register it.** Add its entry to `.gaia/packages.json`, keeping the `frontend` entry, and write `{PKG}/gaia.package.json`, as [[Package Descriptor]] describes. Its globs are package-relative and decide which of the package's files each guard sees, the pre-commit gate included. A registered package with no descriptor fails closed, so land both files in one commit.
3. **Give it its own `CLAUDE.md` and `.claude/`.** `{PKG}/CLAUDE.md` carries the stack, its commands and its test setup, the way `frontend/CLAUDE.md` does. Stack-specific rules and skills go in `{PKG}/.claude/rules/` and `{PKG}/.claude/skills/`, with `paths:` globs relative to `{PKG}`. Add a section to the root `CLAUDE.md` telling a root session to Read `{PKG}/CLAUDE.md` before touching `{PKG}/`, mirroring its frontend section: in a root session that Read is what loads the package's rules and skills.
4. **Generate its settings.** `{PKG}/.claude/settings.json` is generated from the root `.claude/settings.json`, never hand-edited: package-only settings go in `{PKG}/.claude/settings.overlay.json`, then run `./.gaia/cli/gaia packages sync-settings`. The pre-commit hook refuses a commit that leaves any generated settings file missing or stale.
5. **Meet the pre-commit floor.** For each package with a staged path matching its pre-commit globs, the hook runs the package's typecheck, lint-staged and test scripts; `.githooks/pre-commit` names the scripts `{PKG}/package.json` must define. See [[Pre-commit Hooks]].
6. **Add a stack-specific quality gate**, as §8 describes. The shared gate's executable steps check only `frontend/`, and its skip check matches JavaScript, TypeScript and CSS sources, so a package in another language gets no gate until its own names its checks.
7. **Give it an auditor.** The Code Audit Team assigns each changed file to the member whose globs in `.gaia/audit-ci.yml` match it. A file no member claims still owes `code-audit-frontend`, the default member, so the merge gate holds the branch to an audit, but by a React lens with no remit for the package's stack. Register a member for the package, as [[Registering a Code Audit Team Member]] describes, or grant its globs to an existing member whose lens fits. `bash .gaia/scripts/verify-audit-roster.sh` reports every tracked path no member owns and no `unowned:` entry declares; no hook or shipped workflow runs it, so run it after the roster change. An `unowned:` entry only quiets that report and suppresses no review.
8. **Leave the wiki hooks alone.** `wiki-session-start.sh` is git-level and names no package path.

### A backend and worktrees

GAIA provisions per-worktree isolation for the `frontend/` package only: the port slot, the port file, and the refusals that keep one tree's servers off another's ports ([[Worktrees#Ports per worktree]]). A backend added beside it gets none of that automatically: it has no port slot, and its database, migrations, seed data and queues are shared by every tree. It takes one of two shapes:

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

- `.claude/rules/quality-gate.md`: shared/default gate (always loaded; not stack-neutral, since its gate's package steps check only `frontend/`)
- `.claude/rules/quality-gate-{stack}.md`: stack-specific gate with `paths:` frontmatter

Each gate defines its own runner commands. Cross-link: [[Quality Gate]].

## 9. API service layer swap

When replacing the default API layer (Ky + Zod) with Supabase, Firebase, GraphQL, or another REST client:

1. Delete or archive `frontend/.claude/rules/api-service.md` (GAIA's default Ky pattern).
2. Delete `frontend/.claude/skills/new-service/` if it scaffolds the outgoing pattern.
3. Add `.claude/rules/{new-service}.md` with `paths:` scoped to affected directories.
4. Add `.claude/agents/code-audit-frontend/{new-service}.md` with `subagents: [react-patterns, typescript]`.
5. Update `{CONTAINER}/{APP}/CLAUDE.md` (or root) with dev-server commands for the new service.
6. Update `frontend/test/mocks/`: remove MSW handlers that shimmed the old layer if the new layer has its own test fakes.

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

Do **not** vendor `react-doctor` into the repo. Do not symlink it. Install per-machine with `.gaia/scripts/install-react-doctor.sh`, which `/gaia-init` and `/setup-gaia` run through `.claude/skills/gaia/references/setup/per-machine.md`. The skill lands in `frontend/.claude/skills/react-doctor/`.

The `code-audit-frontend` agent dispatches react-doctor **in parallel** with its specialist subagents. `.claude/agents/code-audit-frontend.md` owns the command and its scope flag.

## 13. Proceed vs. AskUserQuestion

When a recommendation already contains the concrete decisions (file paths, specific subsections to add, exact replacements), proceed directly instead of issuing `AskUserQuestion` to confirm sub-details.

**Why:** The user reads the recommendation, decides at the recommendation level, and treats internal sub-decisions as Claude's responsibility. Confirming sub-decisions that were already in the recommendation slows work without changing the outcome.

**How to apply:**

- After laying out a clear, specific plan, default to executing it. Do not issue `AskUserQuestion` to confirm "should we do X" when X was already in the plan.
- Reserve `AskUserQuestion` for genuinely branching decisions where the user's preference cannot be inferred (e.g., scope bundling vs. splitting, two valid approaches with different trade-offs).
- A brief verification pass (path audit, wiki-style check) before commit is not a question; it is verifying the work.

---

## Cross-links

[[Code Review Audit Agent]] · [[Claude Skills]] · [[Claude Hooks]] · [[Quality Gate]] · [[Pre-commit Hooks]]
