---
name: gaia-serena-sync
description: Detects the languages Serena is not indexing and, on explicit consent, additively appends them to the `language_servers:` list (`languages:` before Serena 1.7) in `.serena/project.yml`, then prompts a Serena restart. Never mutates without a yes; inert without Serena.
disable-model-invocation: true
---

Run the GAIA **serena-sync** workflow.

## Pre-flight: Worktree check

This command rewrites the clone's `.serena/project.yml` language list, so it runs only from the main checkout (the clone's primary working directory, on any branch). Run this first, before anything else; a non-zero exit is the refusal: relay it and stop.

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-serena-sync" || exit 1
```

Read `.claude/skills/gaia/references/serena-sync.md` from the project root and follow it exactly. No arguments are needed.
