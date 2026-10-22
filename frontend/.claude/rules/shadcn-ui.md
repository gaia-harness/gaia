---
paths:
  - 'app/components/ui/**'
---

# Vendored shadcn ui

- `ui/*.tsx` is vendored shadcn output, byte-identical to `pnpm shadcn add <name>`. Refresh a file with that command.
- Take the style for components outside `ui/` from GAIA's own code, not from `ui/*.tsx`: it uses `function` declarations, `import * as React` and arbitrary values that GAIA's own code does not.
- Never edit a vendored file: GAIA carries no local patches, and `shadcn add --overwrite` would drop one. Fix a mismatch on the consuming side or in `@gaia-react/lint`.
- Prettier, the house-style lint rules and the correctness rules the registry source itself trips skip `ui/*.tsx` and the few helpers `shadcn add` writes outside `ui/`; the vendored-ui block in `@gaia-react/lint` owns that list and covers the full registry. `react-hooks/rules-of-hooks`, `react-hooks/exhaustive-deps`, the shadcn token rules and every other correctness rule still apply.
- A rule firing on an unedited added file means extending the vendored-ui block in `@gaia-react/lint`, not editing the file; a correctness rule goes there only with the maintainer's sanction.
- `ui/tests/` is GAIA-authored and follows house style, fully linted and formatted.
