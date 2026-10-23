---
paths:
  - 'frontend/.claude/settings.json'
  - 'pnpm-lock.yaml'
---

# Generated Files

These files are generated. A permission deny refuses an Edit of either one with no reason, and an edit made another way (`sed -i`, `jq > file`, a Write) is overwritten or refused later, so change their source instead.

- **`frontend/.claude/settings.json`**: generated from the root `.claude/settings.json` plus `frontend/.claude/settings.overlay.json`. Put a shared setting in the root file and a frontend-only one in the overlay, then run `./.gaia/cli/gaia packages sync-settings`. The pre-commit hook refuses a commit that leaves it stale.
- **`pnpm-lock.yaml`**: written by pnpm. Change dependencies through pnpm (`pnpm add`, `pnpm remove`, `pnpm update`, `pnpm install`), never by hand.
