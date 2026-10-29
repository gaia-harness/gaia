# Coding Guidelines

## File Naming

- **Files and folders**: kebab-case, ASCII English, except names a tool or convention fixes: React Router route modules (`_public._index.tsx`, `$id`) and the language files that mirror them, wiki pages (Title Case with spaces), the uppercase convention files (`CLAUDE.md`, `README.md`, `SKILL.md`, `Dockerfile`, `VERSION`), and tool-generated files (`mockServiceWorker.js`)
- **React components and hooks** (file and folder layout, naming): `frontend/.claude/rules/coding-guidelines-react.md`, loaded on frontend files

## 1. Simplicity First

Write no error handling for a state that cannot occur, but handle and bound real failure modes (a command exits non-zero, a loop does not converge, a network call fails).

Before writing new code, walk this order and use the first step that fully solves the need:

1. Reuse what the codebase already has, the way surrounding code uses it.
2. Use the standard library or a platform feature when the project has no equivalent.
3. Use an installed dependency.
4. Add a new dependency only when the earlier steps fall short and it earns its weight, never to save writing a few lines.
5. Only then write the minimum new code.

On a bug fix whose defect lives in shared code, fix it there once rather than at each call site, then check that every caller still holds. Change only callers your fix breaks; a problem found in any other caller is out of scope, so file it as tech debt.

Smaller code never justifies cutting trust-boundary validation, error handling that prevents data loss, security, or accessibility.

## 2. Surgical Changes

Touch only what's needed: don't improve adjacent code, don't refactor unbroken things, match existing style. Remove only the imports/variables YOUR changes made unused; mention (don't delete) pre-existing dead code.

## 3. Always Use Test Driven Development

When building new features or fixing bugs, follow the TDD workflow described in `.claude/skills/tdd/SKILL.md` (read it on demand, do not preload).

- Test individual functions in isolation and user flows end to end; the frontend stack (Vitest, Storybook, Playwright) is in `frontend/CLAUDE.md` (`## Tests and prerequisites`) and the `tdd-react` skill

## 4. Always Verify Your Work

Leave formatting and auto-fixable lint to the gate's `pnpm lint` (`eslint --fix`, with Prettier wired in as an `eslint` rule), which normalizes it in one terminal pass; spend tokens only on non-auto-fixable lint.
