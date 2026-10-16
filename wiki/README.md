---
type: meta
status: active
created: 2026-04-20
updated: 2026-10-15
tags: [meta, schema]
---

# GAIA React: LLM Wiki

Purpose: Persistent knowledge base for the GAIA React workflow: architecture, conventions, decisions, Claude integration.
<!-- gaia:maintainer-only:start -->
Owner: Steven Sacks
<!-- gaia:maintainer-only:end -->
Created: 2026-04-20

## Structure

```
wiki/
├── index.md            # master catalog (/gaia-wiki maintains it)
├── log.md              # change ledger (gaia wiki log-prepend writes it, newest at TOP)
├── overview.md         # executive summary
├── modules/            # major architectural areas (routing, auth, i18n, etc.)
├── decisions/          # ADRs: why GAIA chose X over Y
├── dependencies/       # external deps with role + version
├── flows/              # data flows (auth, theme, language, form submit)
<!-- gaia:maintainer-only:start -->
├── entities/           # GAIA project, contributors, ecosystem actors
<!-- gaia:maintainer-only:end -->
├── concepts/           # ideas/patterns (Workflow Doctrine, Worktrees, Update Workflow)
<!-- gaia:maintainer-only:start -->
└── meta/               # lint and consolidate reports
<!-- gaia:maintainer-only:end -->
```

## Conventions

- All notes use YAML frontmatter: type, status, created, updated, tags (minimum)
- Wikilinks use `[[overview]]` - filenames are unique, no paths needed
- Keep pages 100-300 lines; split if longer

## Operations

- Query: ask any question - Claude reads `index.md` first → drills in
- Maintenance: `/gaia-wiki` runs sync, consolidate, and lint with fixes, and opens one PR when run from `main`
