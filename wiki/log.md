---
type: meta
title: Log
status: active
created: 2026-10-24
updated: 2026-10-25
tags: [meta, log]
---

# Log

## [promote] 2026-10-26 | Single-session onboarding promoted

- 2026-10-26 b8f8300 WORTHY - renamed-dependency removal in package merge → wiki/concepts/Update Workflow.md
- 2026-10-26 10bdf13 WORTHY - jq as-binding lint folded into shell-lint; maintainer-only guard, no page change
- 2026-10-26 2b6ae16 WORTHY - all lock directories taken through one exclusive helper → wiki/concepts/GAIA Scripts.md
- 2026-10-26 1cce8f8 WORTHY - RED-capture re-run no longer installs dependencies → wiki/concepts/Claude Hooks.md, wiki/decisions/TDD RED Verification.md
- 2026-10-26 6506b27 WORTHY - repo and lint package references moved to gaia-harness; wiki updated in-commit → wiki/dependencies/gaia-lint.md
- 2026-10-26 b8ba858 WORTHY - dead-path scan exempts shared tooling paths; already covered by the scanner-owns-its-exemptions line → wiki/decisions/Wiki Management.md
- 2026-10-26 cfc7bd7 WORTHY - single-session onboarding; wiki updated in-commit → wiki/concepts/Single-session First-time Onboarding.md
- 2026-10-26 c50e91e WORTHY - verify-main-green gate on release preflight, merge and tag → wiki/concepts/Release Workflow.md
- 2026-10-26 512eb69 WORTHY - links, contacts and ping point at gaiaharness.com; wiki updated in-commit → wiki/concepts/GAIA CLI.md
- 2026-10-26 462c44c WORTHY - bats legs scoped to the change, full suite on push to main; wiki updated in-commit → wiki/decisions/Sharded CI Test Matrix.md
- 2026-10-26 80bee4c WORTHY - license holder named, .gaia/LICENSE ships in new projects; wiki updated in-commit → wiki/concepts/Release Workflow.md
- 2026-10-26 d2d9a3c WORTHY - strip-branding anchors on storybookBrandOptions, fails loudly when absent → wiki/concepts/GAIA Init Workflow.md
- 2026-10-26 PROMOTED: wiki/concepts/Single-session First-time Onboarding.md (PR #3071)

## [docs] 2026-10-25 | Change-scoped audit CI documented

Sharded CI Test Matrix, Audit Round Procedure, PR Merge Workflow, the bats assertions rule, CONTRIBUTING and the verify-harness round-mode comment now describe change-scoped bats legs on pull requests, the full run on every push to main, per-step run caps, and the red-main issue reporter. The whole-tree mark guard's delegated-script limit is restated as what it still cannot see.

## [v2.1.1] 2026-10-24 | Released

See CHANGELOG.md for details.
