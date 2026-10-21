---
type: dependency
status: active
package: '@conform-to/react, @conform-to/zod'
role: form-validation
created: 2026-04-20
updated: 2026-10-21
tags: [dependency, forms]
---

# Conform

Form validation library used by [[Form Components]]. Pairs with [[Zod]] for the schema layer.

- `@conform-to/react`: `useForm`, `useInputControl`, `getFormProps`
- `@conform-to/zod`: `parseWithZod` for client + server validation

> [!warning] Use the `/v4` subpath
> Import from `@conform-to/zod/v4` (Zod v4 compatibility), not the root. Enforced by `frontend/.claude/skills/react-code/` (auto-loaded) and the Conform extension (`frontend/.claude/agents/code-audit-frontend/conform.md`) whose path [[Code Review Audit Agent]] hands to its React Patterns and TypeScript specialists, which read it themselves.

## Alternatives

[remix-forms](https://remix-forms.seasoned.cc/), [RVF](https://www.rvf-js.io/)

See [[Form Submit Flow]].
