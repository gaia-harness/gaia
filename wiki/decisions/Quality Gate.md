---
type: decision
status: active
priority: 1
date: 2026-04-20
created: 2026-04-20
updated: 2026-11-08
tags: [decision, ci, quality]
---

# Decision: Mandatory Quality Gate

Every change must pass the Quality Gate. Pre-commit hooks enforce a subset; Claude runs the full pipeline below before any `git commit` that touches source, except that an audit fix round may run [the smaller gate](#the-smaller-gate); **unless the gate has nothing to check**.

## Steps

The contract lives at the repo root. Steps 3 to 5 are root scripts that run across every workspace member that defines the script, so a library or a second app is checked with no gate edit. Steps 6 to 8 exercise the web app only; each root `pnpm <script>` there is a proxy that forwards to the `pnpm -C apps/web <script>` shown beside it, and either spelling runs the same command.

1. **Simplify**: run `simplify` skill; apply all endorsed changes. Two kinds of commit skip it, and the Simplify row says `skipped: <reason>`: a `/gaia-plan` orchestrator's commits, because the plan run makes one whole-branch pass in its closing stage (`.claude/skills/gaia/references/simplify-pass.md`), and an audit fix round's commit, because only the fixer edits inside the loop.
2. **Localization check**: no hardcoded user-facing strings or unfilled keys.
3. `pnpm typecheck`: zero errors in every member. This is the sole enforcer for type-only tests (`expectTypeOf`/`assertType`/`@ts-expect-error`).
4. `pnpm lint`: zero errors in every member, zero warnings. In the web app it runs `eslint --fix`, so it auto-fixes every fixable lint rule **and** Prettier formatting (Prettier is wired in as an `eslint` rule via `prettier/prettier`); only non-auto-fixable issues need manual attention. Hand-formatting while authoring is wasted effort; this step normalizes it. Outside the `.gaia/cli` member, `pnpm lint` ignores `.gaia/**`.
   <!-- gaia:maintainer-only:start -->
   `.gaia/cli` is a recursive workspace member here, so the root `pnpm lint`, `pnpm typecheck` and `pnpm test:ci` already cover it; `pnpm lint:cli` (`pnpm -C .gaia/cli lint`) remains the CLI's own ESLint run for focused work. The CLI's ESLint and vitest runs do not type-check, which is why its `typecheck` script matters.
   <!-- gaia:maintainer-only:end -->
5. `pnpm test:ci`: all tests pass in every member, one member at a time, with **zero console warnings** (missing keys, HydrateFallback, etc. count as failures). Then run `bash .gaia/scripts/gate-member-warnings.sh`, which prints one `WARN` for each member that has test files but no `test:ci` script, or TypeScript sources but no `typecheck` script, and exits 0; fix each warning. Stories and hook tests run in headless Chromium, so `pnpm install:browsers` must have run once; a missing browser fails the step with an install command ([[Stories as Tests]]).
6. `pnpm pw` (`pnpm -C apps/web pw`): all Playwright E2E tests pass. Playwright reads the `.env` of its working directory, so the file is `apps/web/.env`; without it the web server never starts. Entering a worktree provisions it, which symlinks the main checkout's `apps/web/.env` into the worktree's `apps/web/`, so a worktree missing one was never entered by a session: run `bash .claude/hooks/provision-worktree.sh <absolute-worktree-path>`, which also installs dependencies and moves a plain `.gaia/local` aside to `.gaia/local.bak.<timestamp>` before linking the shared one. When the main checkout itself has no `apps/web/.env`, linking skips it; run `.gaia/cli/gaia setup bootstrap-env` in the main checkout, since it seeds only the tree it runs in (never a `cp`, which the `Edit(**/.env)` deny refuses), and link again. If `apps/web/.env.example` is gone too, stop and ask the human to create `apps/web/.env` (`apps/web/app/env.server.ts` lists the required variables). Never read, print, or copy `.env` contents: the link shares the file without exposing it. The linked `.env` is the real one, so an `MSW_ENABLED` that is off sends Playwright to the real `API_URL`, exactly as in the main checkout. A web server that fails to start on an error naming a variable `apps/web/.env` lacks takes step 7's missing-variable handling.
7. **Dev smoke test**: `bash .gaia/scripts/dev-smoke.sh`: exit 0 means the route, or the page its same-origin redirects end at, answered HTTP 200 and the server it started is stopped. It starts `pnpm -C apps/web dev` on this tree's dev port, requests `/` (`--path` names another route), follows up to five redirects within the dev server's own origin (an auth-gated `/` that redirects to a login page passes when that page answers 200), and stops the server it started. A dev server this Claude session launched in this tree and left running, a subagent's included, is not a held port: its launch record names this session's Claude process (its session id or its host, which survives `/clear` and `/resume`), so the script stops it, says so, and runs the smoke test. Do not start or stop the dev server by hand for this step: a pattern kill (`pkill -f 'react-router dev'`, `kill $(lsof -ti:<port>)`) also stops other sessions' and other worktrees' servers. When the gate runs this step, it passes only on exit 0. Every other exit, each reason for exit 3 included, reports `Dev server` as not run or failed in the table below, and no later step or commit proceeds. Exit 1 and 2 report failed with the script's message. Exit 3 means the script refused to start; a held port is told from the other reasons by the script's message `is already in use`:

   - **Port held** (`is already in use`): attended, ask with `AskUserQuestion`: `Hold the commit` (Recommended), because the holder may be another session's or a human's server (`apps/web/.claude/rules/ports.md`), or `Stop it`. `Stop it` stops the holder, reruns the step, and only exit 0 passes. `Hold the commit` is reported in the `Dev server` row.
   - **No `react-router.config.*` package**: the tree has no dev server to smoke test. Next step: run the gate from a tree that has the frontend package, or report the step as not run and hold the commit.
   - **No resolvable port**: `ports.sh` prints its own reason on stderr. Next step: act on that message, then rerun the step.
   - **No process backend**: neither `lsof` nor `ss` with `/proc` can tell who holds the port. Next step: install `lsof`, or `ss` with `/proc`, then rerun the step.

   An exit 1 whose server error names a variable `apps/web/.env` lacks is a missing environment variable: never read or edit `.env`. Attended, name the line to add, its value taken from `apps/web/.env.example`, and ask with `AskUserQuestion`: `I added the line` (Recommended), which reruns the step, or `Hold the commit`. Only exit 0 passes; a second failure holds the commit with no new question.

   Unattended, the workflow halts naming the reason. The script's header documents the exit codes.
8. `pnpm build` (`pnpm -C apps/web build`): confirms production build.
9. **Fix all warnings before reporting**: never hand off with known warnings.
10. **Stop and report**: ask for approval with `AskUserQuestion` (`Commit` (Recommended) or `Hold for review`), except inside a workflow whose own instructions commit without stopping: the audit fix round ([[Audit Round Procedure#The fix round: fixer, verifier, gate]]), the worthiness step's fix commit (`.claude/skills/gaia/references/worthiness-step.md`), the overlap pass's fix commit (`.claude/skills/gaia/references/overlap-pass.md`), the simplify pass's commit (`.claude/skills/gaia/references/simplify-pass.md`), `/gaia-debt`, a `/gaia-plan` orchestrator's phase commits, and `/gaia-init`'s init commit.

| Step          | Result |
| ------------- | ------ |
| Simplify      | ...    |
| Localization  | ...    |
| Type checking | ...    |
| Linting       | ...    |
| Unit tests    | ...    |
| E2E tests     | ...    |
| Dev server    | ...    |
| Build         | ...    |

## When to skip the gate

Skip the gate entirely if no staged file is something typecheck / lint / tests / build can inspect. The gate runs only when at least one staged file matches:

- **Source**: `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.mjs`, `*.cjs`, `*.css`
- **Gate-affecting config**: `package.json`, `pnpm-lock.yaml`, `tsconfig*.json`, `vite.config.*`, `vitest.config.*`, `playwright.config.*`, `eslint.config.*`, each at the repo root or at any depth under a member folder such as `apps/web/`
- **Package registry**: `.gaia/packages.json` and any member's `gaia.package.json`

Pure markdown, `.claude/**`, `wiki/**`, image, or other non-source-affecting commits skip straight to the commit step.

Quick check:

```bash
git diff --cached --name-only -z | tr '\0' '\n' | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|css)$|^([^/]+/)*(package\.json|pnpm-lock\.yaml|tsconfig.*\.json|vite\.config\.|vitest\.config\.|playwright\.config\.|eslint\.config\.)|^(\.gaia/packages\.json|([^/]+/)*gaia\.package\.json)$'
```

<!-- gaia:maintainer-only:start -->
Steps 3 to 5 run across the workspace, so any Quick check match runs them, and a `.gaia/cli/**` match is covered there because the CLI is a recursive member. Steps 6 to 8 exercise the web app only, so a match under `.gaia/cli/`, `.gaia/tests/`, or `.gaia/scripts/` does not select them: those paths are not the web app, which is also why `.gaia/scripts/precommit-packages.sh` runs no web check for them. Pipe the Quick check's output through the frontend filter and run steps 6 to 8 only when a path survives.

Frontend filter:

```bash
grep -vE '^\.gaia/(cli|tests|scripts)/'
```
<!-- gaia:maintainer-only:end -->

## The smaller gate

Inside an audit fix round whose `bash .gaia/scripts/audit-gate-owed.sh choose` prints `smaller`, run every step of this page except step 1, which a fix round skips, and steps 6, 7 and 8 (Playwright, the dev smoke test, the production build); the skip logic above still applies. Report each deferred step as owed in the result table, not as not run. Those three steps run once on the final tree before the audit status posts, and that run of step 7 passes and stops exactly as step 7 says. A Major, Critical or security fix, and a fix entry with no sidecar row, takes the full gate. `.gaia/scripts/audit-gate-owed.sh`'s header owns the owed record and the rule that picks the gate; [[PR Merge Workflow]] owns when the owed run happens.

<!-- gaia:maintainer-only:start -->
The maintainer `bash .gaia/tests/verify-harness.sh round` step is unchanged: the smaller gate does not shorten it.
<!-- gaia:maintainer-only:end -->

## Behavior when the gate runs

- **Fix issues as you encounter them** rather than just reporting them.
- All warnings/issues (typecheck errors, lint errors/warnings, test console warnings like missing i18n keys or HydrateFallback, runtime errors) must be resolved before the commit; never commit with known warnings.
- After fixing, **STOP and report results to the user**; do not commit until the user reviews and approves. That step governs an ordinary commit. Inside a workflow step 10 names, the commit proceeds on a clean gate: that workflow's own checkpoint is where the human reviews.

Localization: all user-facing strings must be localized; no hardcoded strings in JSX, no keys without values.

## Source of truth

This page is the source of truth for quality gate steps, the full gate and the smaller gate alike; no other page defines a gate the audit unit runs. The always-loaded `.claude/rules/quality-gate.md` rule points commits at this page.

See [[Pre-commit Hooks]], [[Workflow Doctrine]] (the gate runs once per commit, on the main thread; a /gaia-debt budget batch runs it once over its combined staged diff before its per-part commits), [[PR Merge Workflow]], [[Task Orchestration]], [[Claude Hooks]] (the source-edit and Bash safeguards keep `.env`, lockfile, secrets, and destructive-git footguns out of the staged surface before the gate ever runs).

<!-- gaia:maintainer-only:start -->
The Forensics Triage Workflow runs its own CI gate (`.github/forensics/run-quality-gate.sh`, whose header lists its steps) on every auto-fix branch; gate failure abandons the branch and demotes the issue to `needs-human` instead of opening a partial PR. That gate is distinct from the developer Quality Gate above: it adds `pnpm knip` because it runs post-task against a complete tree, whereas the dev gate omits knip (see `wiki/dependencies/knip.md`).
<!-- gaia:maintainer-only:end -->
