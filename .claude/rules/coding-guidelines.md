# Coding Guidelines

## File Naming

- **Files and folders**: kebab-case, ASCII English, except names a tool or convention fixes: React Router route modules (`_public._index.tsx`, `$id`) and the language files that mirror them, wiki pages (Title Case with spaces), the uppercase convention files (`CLAUDE.md`, `README.md`, `SKILL.md`, `Dockerfile`, `VERSION`), and tool-generated files (`mockServiceWorker.js`)
- **Where code lives**: apps go in `apps/<name>`, libraries in `packages/<name>` once two consumers share them, never a new top-level folder. An adopter's existing extras such as `infra` stay where they are. The procedure is `## Adding an app or package` in `wiki/concepts/Package Descriptor.md`.
- **React components and hooks** (file and folder layout, naming): `apps/web/.claude/rules/coding-guidelines-react.md`, loaded on frontend files

## 1. Simplicity First

Write no error handling for a state that cannot occur, but handle and bound real failure modes (a command exits non-zero, a loop does not converge, a network call fails).

Before writing new code, walk this order and use the first step that fully solves the need:

1. Reuse what the codebase already has, the way surrounding code uses it.
2. Use the standard library or a platform feature when the project has no equivalent.
3. Use an installed dependency.
4. Add a new dependency only when the earlier steps fall short and it earns its weight, never to save writing a few lines.
5. Only then write the minimum new code.

Design new code as deep modules (small interface, deep implementation), take collaborators as parameters, and prefer pure functions.

On a bug fix whose defect lives in shared code, fix it there once rather than at each call site, then check that every caller still holds. Change only callers your fix breaks; a problem found in any other caller is out of scope, so file it as tech debt.

Smaller code never justifies cutting trust-boundary validation, error handling that prevents data loss, security, or accessibility.

## 2. Surgical Changes

Touch only what's needed: don't improve adjacent code, don't refactor unbroken things, match existing style. Remove only the imports/variables YOUR changes made unused; mention (don't delete) pre-existing dead code.

## 3. Test What Matters

Test critical flows at the seams, after the code exists: one test per critical user flow at its real entry point, covering its happy path and the error paths the build has. A seam worth pinning gets a route test; tricky pure logic gets a unit test; a bug fix gets a test that reproduces the bug. Test-first with `/tdd` is a tool for logic where it helps, not a rule.

- Write tests, not too many, mostly integration (the testing trophy); one test per user-observable behavior. Full rule: `wiki/decisions/Test Layering.md`
- The frontend stack (Vitest, Storybook, Playwright) is in `apps/web/CLAUDE.md` (`## Tests and prerequisites`) and the `tdd-react` skill

## 4. Always Verify Your Work

Leave formatting and auto-fixable lint to the gate's `pnpm lint` (`eslint --fix`, with Prettier wired in as an `eslint` rule), which normalizes it in one terminal pass; spend tokens only on non-auto-fixable lint.

When lint flags something, fix the code first. An `eslint-disable` is a last resort, acceptable only when fixing the code would be worse than disabling the rule (a false positive, a gap in a library's typings, a rule that does not fit the case), and its `--` reason names which.
