---
type: dependency
status: active
package: knip
role: dead-code-detection
created: 2026-05-04
updated: 2026-11-16
tags: [dependency, quality]
---

# knip

Reports unused files, exports, types, and dependencies across the codebase. Devtime-only.

## Conventions

- Config: `apps/web/knip.config.ts`
- Run: `pnpm knip` (manual) or `pnpm knip --reporter json` (machine-readable, used by the audit agent)
- Blocks merge: the Tests workflow runs `pnpm knip` after lint on every pull request that changes app code, and any finding fails the check. A pull request is the finished state, so the in-progress noise concern below doesn't apply.
- Runs automatically pre-merge inside the [[Code Review Audit Agent]] (alongside `react-doctor`) too, where its findings are sorted into the buckets below.
- Not part of the [[Quality Gate]] (pre-commit): in-progress work routinely flags exports that haven't been wired up yet, which drowns the signal.
<!-- gaia:maintainer-only:start -->
- The CLI has its own config, `.gaia/cli/knip.config.ts`, run by `pnpm -C .gaia/cli knip` and as a blocking step in the CLI Tests workflow.
<!-- gaia:maintainer-only:end -->

## Template-aware config

GAIA ships as a template, so `apps/web/app/` carries components, hooks, utilities, services, and types that the template itself does not consume yet. `apps/web/knip.config.ts` lists those folders as `entry` globs, alongside the test and tooling roots, so a fresh project does not open with a wall of unused-export findings for scaffolding it has not reached. The cost is a blind spot: knip never reports an unused export from an entry file, including one your app used and then dropped. Once your app consumes a folder, remove its glob from `entry` so knip reports that folder's dead exports again. Bundled deps used via Tailwind, Storybook, MSW, or runtime resolution are listed in `ignoreDependencies`.

## When to run

- After a refactor that removes or restructures modules
- After deleting a feature, route, page, or component
- After removing or replacing a dependency
- Before opening a release-candidate PR

## Acting on output

Output falls into three buckets:

1. **Real dead code**: unused file/export/type with no callers. Delete.
2. **Unconsumed template surface**: exported on purpose though nothing in this repo imports it yet. Cover it with an `entry` glob in `apps/web/knip.config.ts`, as narrow as the case allows, and remove the glob once the app consumes it.
3. **Implicit dependency**: package used via config plugin, CSS, or runtime resolution that knip can't trace. Add to `ignoreDependencies` in `apps/web/knip.config.ts`.

See [[Quality Gate]].
