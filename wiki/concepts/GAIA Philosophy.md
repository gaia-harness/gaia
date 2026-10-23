---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-24
tags: [concept, philosophy]
---

# GAIA Philosophy

GAIA ships a component layer you own: shadcn components vendored into your project, not an installed library ([[shadcn Component Layer]]). Everything else is pre-configured but removable.

## Core tenets

1. **Pre-configured but removable: ask Claude to swap.** Don't need i18n? Tell Claude to rip it out. Prefer a different icon set? Ask Claude to swap it in. Because Claude understands how the pieces are wired, removals and substitutions stay coherent. Nothing is locked in.
2. **Quality enforced by tooling, not vigilance.** 20+ ESLint plugins + pre-commit hooks + the [[Quality Gate]] catch issues before they compound.
3. **Working examples, not just installs.** Every tool ships with a real, working example: i18n wired up with a working English locale and the full namespace structure ready for more (the init flow lets you add locales), MSW handlers for tests and Storybook, Conform-validated forms.
4. **Co-location with discipline.** Tests, stories, assets, hooks, state live next to the component, but in their own subfolders so the component folder stays scannable.
5. **Thin routes, fat pages.** Routes do data; pages do UI. See [[Thin Routes]].
6. **Best practices baked in.** Patterns over docs.

## What GAIA explicitly avoids

- A specific deployment target; uses default React Router deploy, you pick the host
- Heavy state management (no Redux, Zustand); Context+Provider is enough
- Backend assumptions (no Prisma, Drizzle, etc.); your services layer talks to your API

## Positioning & Naming

GAIA is **a harness for Claude Code, not a template**: the harness governs the whole monorepo, and React is the frontend it ships with. Calling it a "template" undersells the scope. Lead with "harness"; "workflow", "system" and "Claude-first" stay fine as secondary framing.

The frontend GAIA ships is React, built on [[React Router]], with React-specific tooling for that frontend. There is no multi-framework roadmap: React is the only frontend GAIA ships and supports.
