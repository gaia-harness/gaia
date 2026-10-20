---
paths:
  - 'frontend/app/**/*.{ts,tsx,js,jsx,css}'
  - 'frontend/test/**/*.{ts,tsx}'
  - 'frontend/.playwright/**/*.ts'
  - 'frontend/.storybook/**/*.{ts,tsx}'
  - 'frontend/.claude/**/*.md'
  - '.gaia/**/*.{ts,sh}'
  - '.claude/**/*.{md,sh}'
  - '.github/**'
  - 'wiki/**/*.md'
  - '**/*.bats'
---

# Working-Document IDs

Code, comments, test names, user-facing strings, and prose never cite the project's working-document ids. Describe the behavior and why it exists instead; for provenance, a reader has `git log -L` and `git blame`.

## What is banned

- **SPEC, UAT, and plan ids**: `SPEC-` and `UAT-` plus a number, `PLAN-` plus a number.
- **Plan and audit directive ids**: the lens- or contract-prefixed ids a plan, a SPEC audit, or a decomposition audit assigns its findings and constraints (a letter prefix plus a number, with or without a dash).
- **This project's own issue and pull request references**: a bare `#` plus a number, its `owner/repo#` qualified form, and an issue or pull request URL.
- **Paths to machine-local artifacts**: a path under `.gaia/local/` or `.notebook/` naming something one machine generated, such as a SPEC or plan folder, a research folder or its snapshot, or a run's evidence. Content that only works against such an artifact (a baseline query, a verdict procedure) moves into `.gaia/local/` or `.notebook/` beside it; files there may reference each other.

## Why

These ids and paths point at documents no other reader can open: a SPEC or plan lives under the gitignored `.gaia/local/` or `.notebook/` on one machine and is deleted when archived, and an adopter's SPEC of the same number is a different document. A reference to a closed or historical issue adds nothing the change's history does not already record.

The usual way one gets written is copying: a plan task doc cites the directive it honors, and the executor copies the citation into the file it edits. A directive id belongs in the plan, never in the files the plan changes.

## Enforced

`.gaia/scripts/machine-local-ref-lib.sh` is the detector; its header owns the exact patterns. The `commit-msg` hook runs it on every commit message, the `pre-commit` hook on the lines a commit adds (prose whole, code in full-line comments only), and the UAT gate on the Playwright tree. It refuses SPEC, UAT and plan ids and machine-local paths in history ledgers and commit messages too: a ledger records history, and a document only one machine has is not part of it.

Advisory only, never enforced: directive ids and issue or pull request references (too close to ordinary prose for a pattern), and test files and fixtures (data).

## Not covered

- **Placeholders**: `SPEC-NNN`, `#<N>`, `Closes #<N>`, `.notebook/research/<date>-<topic>/`. An example in a usage doc uses a placeholder, never a concrete number.
- **GAIA's own state locations**: a `.gaia/local/` path GAIA's tooling creates and owns on every machine (`.gaia/local/runs/<branch>/STATE.md`, `.gaia/local/debt/count.json`) and the generic notebook layout (`.notebook/specs/<SPEC-ID>/`, `.notebook/catalog.json`), in the code that reads or writes it and in the docs describing it.
- **Data, not references**: template format examples showing a SPEC's shape, fixture values (CLI args, JSON/YAML literals, URLs in test fixtures), regex targets that match SPEC structure, filename literals, and identifier fragments inside variable names (`uat_id`).
- **An upstream third-party tracker** cited beside the platform quirk it documents (a dependency's own issue). It names a public, stable record outside this project.
- **A pointer to an open tracking issue** in an operator-facing message (a refusal or error) that would otherwise leave the reader with no next step. Open work is not in git history, so the pointer carries information the history cannot; a test that pins the message keeps it.
- **Issue and pull request references in history ledgers**: `wiki/log.md`, `wiki/meta/`, `CHANGELOG.md`, commit messages, and pull request bodies.
<!-- gaia:maintainer-only:start -->
- **`.gaia/tests/`**: release-excluded test infrastructure whose `UAT-`, `SEC-`, and `TST-` prefixes are deliberate SPEC-conformance traceability.
<!-- gaia:maintainer-only:end -->
A section heading or inline parenthetical naming a working-doc id (`#### 5b. Discuss-this escape (UAT-…)`) is narrative and is covered.

## Editing a file that already carries one

When an edit touches a line citing a working-doc id, rewrite it to the behavior it stood for, or delete it if the surrounding text already says that. Never truncate it to a bare id. Leave untouched lines alone.
