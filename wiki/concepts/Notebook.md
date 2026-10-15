---
type: concept
status: active
created: 2026-10-15
updated: 2026-10-15
tags: [concept, notebook, working-state]
---

# Notebook

The notebook is the one place GAIA keeps the working material a human reads: specs, plans and research. This page owns its layout, lifecycle and keep rules; every other page points here instead of restating them.

## What it is

The root `.notebook/` holds the three kinds of working material a human reads. It is gitignored and main-anchored: every tree reads and writes the main checkout's copy. A linked worktree reaches it through one `.notebook` symlink that `link-worktree.sh` creates (see [[Worktrees]]), so nothing written there vanishes with the worktree. It fails closed when the main checkout cannot be resolved, never falling back to a relative path.

`.gaia/local/` keeps GAIA's internal state and its generated reports; see [[Local Working State]].

## Layout

`.notebook/` holds `catalog.json`, `specs/SPEC-NNN/` (a plan derived from a spec nests inside it as `plan[-N]/`), `plans/PLAN-NNN/` and `research/<slug>/`. Nothing else lives there.

## The catalog

One file describes every item. Only the notebook library (`.gaia/scripts/notebook/notebook-lib.sh`) opens it, under its catalog write lock; the row schema and the status enums are stated in that library's header. A spec-derived plan has no row of its own; the parent spec's row covers it.

A catalog that is present but unreadable makes every writer and reaper refuse and change nothing. Treat the file as do-not-delete: it carries the draft-resume state and the local half of spec-number allocation that no other copy holds.

## Lifecycle

- **Specs and plans.** Each is allocated, reconciled from git ground truth, consolidated once its work lands, and reaped once past `GAIA_SPEC_RETENTION_DAYS`. [[GAIA Spec]] and [[Task Orchestration]] describe the steps around them.
- **Research.** A writer registers a folder and closes it once its outcome lands in tracked output. A migrated or unregistered folder stays `untagged` and is only reported. The research reaper deletes only a closed, aged (`GAIA_RESEARCH_RETENTION_DAYS`), uncited, unsnoozed folder, and only after a human confirms in that run, with an advisory landed verdict.

`.claude/skills/gaia/references/spec/lifecycle.md` (`## Pre-flight sweep`) owns the pass order and the confirmation question. The reaper script's header owns its keep rules and exit codes.

## Readiness and the one-time move

On a machine still holding the 1.x-era folders under `.gaia/local/specs/`, `.gaia/local/plans/` or `.gaia/local/research/`, every notebook consumer refuses with a message naming `bash .gaia/scripts/notebook/move.sh run` until the move runs. The move relocates by rename, folds both old ledgers into the catalog, keeps the old ledgers as frozen backups, deletes nothing, and reports auto-memory files that name the old paths (it repoints them only on a yes). `.gaia/migrations/2.0.0.md` says when an adopter runs it.

## Permissions and guards

`rm -rf` is allowed only on children of the specs and plans folders; the state registry's `rm_whitelist` is the list. The worktree path-mismatch hook exempts writes under the main checkout's `.notebook/` (see [[Claude Hooks]]). A bats guard holds every script and hook outside the library to never naming the catalog file or a kind folder.

Usage binding for research follows the Write path rule in [[Usage Ledger]].
