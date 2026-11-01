---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
  - 'app/route-tests/**/*'
---

# Route & Page Conventions

When editing routes or pages, fetch `wiki/decisions/Thin Routes.md` and `wiki/modules/Pages.md` for the canonical conventions (route thinness, page dir layout, loader meta pattern, i18n keys, Conform+Zod actions); group prefixes (flat `<group>.<name>` files): `wiki/modules/Routing.md`.

Which data-loading variant a route exports is the rule in `frontend/.claude/skills/react-code/SKILL.md`.

## Route tests

A file under `app/route-tests/` whose line 1 carries the contract marker is a rendered contract: its Given, When and Then comment is the contract. Selectors, fixtures and request details are yours to edit. A change to its flow, success criteria, error-handling branch, asserted side effect, precondition or post-state is a logical divergence, reported and never edited in (`.claude/skills/gaia/references/spec/uat-divergence.md`). Keep every `expect(` of the Then clause in the test body. The owning phase turns the `test.fails` body into a plain `test`.

Authorization conventions, with the layer limits in `wiki/decisions/Test Layering.md`:

- A route module with a write action behind authentication has a test that an anonymous request is refused with no side effect. State which way the side effect is observed: at the route layer, or by a follow-up read on a live stack.
- A loader returning protected data has a test that an anonymous request receives none of it.
