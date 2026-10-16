---
type: decision
status: active
priority: 2
date: 2026-04-20
created: 2026-04-20
updated: 2026-04-20
tags: [decision, i18n]
---

# Decision: TypeScript Language Files Over JSON

GAIA uses `.ts` files for translations instead of the JSON convention.

## Rationale

- ESLint + Prettier keep them tidy
- TypeScript catches typos and renamed keys at compile time
- Auto-completion in editors
- The pre-commit typecheck blocks commits referencing missing keys
- Strings can be `import`ed into tests (Playwright assertions)
- Composition: `pages.account.profile.fullName` via dot-chain imports

## Tradeoff

All strings for a language load up front. In practice, gzip + caching makes this a non-issue. Switch to JSON later if on-demand loading becomes a real bottleneck.

## Caveat

Breaks third-party tooling that expects JSON (translation management systems, etc.). If you're integrating with one, evaluate before adopting.

See [[i18n]].
