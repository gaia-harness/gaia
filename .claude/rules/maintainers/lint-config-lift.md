---
paths:
  - 'apps/web/eslint.config.mjs'
---

# Lint Config Lift (maintainer-only)

Maintainer repo only; never ships. The shipped `apps/web/eslint.config.mjs` carries no customization: it only spreads `@gaia-harness/lint`'s configs and passes their options. An edit that adds rules, files or overrides beyond that is a local trial only:

1. Confirm the change in `apps/web/eslint.config.mjs`.
2. Lift it into the `gaia-harness/lint` repo with a test and a changeset (patch preferred, minor if needed, never major without the maintainer's say-so), and open its PR; the maintainer cuts the release (that repo's `.github/workflows/release.yml`).
3. Bump the `@gaia-harness/lint` pin in `apps/web/package.json` and delete the local block before the gaia PR merges.
