# Frontend

The React app: routes, pages, components, services, tests, Storybook, Playwright. Its rules and skills live in `apps/web/.claude/` and load when Claude works inside this directory; a root session loads them by Reading this file first.

## Conventions

- Before hand-writing a component, check the shadcn registry (`pnpm shadcn view <name>` or `pnpm shadcn search`) and run `pnpm shadcn add <name>` if it has one.
- The visual styling is a deliberate neutral baseline, not a chosen design system; before designing or restyling read `apps/web/.claude/rules/design-baseline.md` and `wiki/concepts/Design System.md`.
- Rules in `apps/web/.claude/rules/` load by their `paths:` frontmatter and skills in `apps/web/.claude/skills/` by their descriptions; list the directories to see them.
- Paths in prose inside these rules and skills (`app/`, `test/`, `.playwright/`, `.storybook/`, `public/`, config files) are relative to `apps/web/`. Shell commands are written to run from the repo root, so they carry the `apps/web/` prefix or use the root `pnpm` proxies.
- `.claude/`, `.gaia/`, and `wiki/` paths are repo-root paths; the frontend's own units appear as `apps/web/.claude/...`.

## Tests and prerequisites

Components and pages are tested by their Storybook stories (a `.test()` per behavior, run by `@storybook/addon-vitest`; see `wiki/decisions/Stories as Tests.md`), hooks with `vitest-browser-react`, and route modules (by route tests in `app/route-tests/`, the default layer) and pure and server code in the `node` Vitest project. Stories and hook tests run in headless Chromium, which `pnpm install` does not install: `/gaia-init` and `/setup-gaia` install it, and outside them run `pnpm install:browsers` once; without it Vitest fails with a missing-browser error. The rules are in `apps/web/.claude/rules/storybook.md` and the `tdd-react` skill.

## Running the gate

`pnpm <script>` from `apps/web/` equals `pnpm -C apps/web <script>` from the repo root, and the root `package.json` proxies every web script except `msw:init` (run it as `pnpm -C apps/web msw:init`), so `pnpm test`, `pnpm pw`, and `pnpm shadcn` work from either directory. At the root, `pnpm typecheck`, `pnpm lint` and `pnpm test:ci` run across every workspace member, this package included. The Quality Gate steps live in `wiki/decisions/Quality Gate.md`.

The harness CLI lives at the repo root: run `./.gaia/cli/gaia ...` from the root, or `../../.gaia/cli/gaia ...` from `apps/web/`. Scaffolders find the package through `.gaia/packages.json`, not the working directory.
