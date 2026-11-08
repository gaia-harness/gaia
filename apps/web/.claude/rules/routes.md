---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
  - 'app/route-tests/**/*'
---

# Route & Page Conventions

When editing routes or pages, fetch `wiki/decisions/Thin Routes.md` and `wiki/modules/Pages.md` for the canonical conventions (route thinness, page dir layout, loader meta pattern, i18n keys, Conform+Zod actions); group prefixes (flat `<group>.<name>` files): `wiki/modules/Routing.md`.

Which data-loading variant a route exports is the rule in `apps/web/.claude/skills/react-code/SKILL.md`.

## Route tests

Authorization conventions, with the layer limits in `wiki/decisions/Test Layering.md`:

- A route module with a write action behind authentication has a test that an anonymous request is refused with no side effect. State which way the side effect is observed: at the route layer, or by a follow-up read on a live stack.
- A loader returning protected data has a test that an anonymous request receives none of it.
