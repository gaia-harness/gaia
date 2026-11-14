---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
  - 'app/route-tests/**/*'
---

# Route & Page Conventions

When writing or editing a form, read `apps/web/.claude/skills/react-code/references/conform-forms.md` first.

When editing routes or pages, fetch `wiki/decisions/Thin Routes.md` and `wiki/modules/Pages.md` for the canonical conventions (route thinness, page dir layout, loader meta pattern, i18n keys, Conform+Zod actions); group prefixes (flat `<group>.<name>` files): `wiki/modules/Routing.md`.

Which data-loading variant a route exports is the rule in `apps/web/.claude/skills/react-code/SKILL.md`.

## Route tests

Which tests a route needs, at which layer, and how guards and security rows are proven: `.claude/doctrine/testing.md` (`## Guards and security rows`). How to write a route test: `apps/web/.claude/skills/tdd-react/references/tests-react.md`.
