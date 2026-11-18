---
type: decision
status: active
created: 2026-11-18
updated: 2026-11-18
promoted_at: 2026-11-18T05:37:50Z
promoted_hash: sha256:d69e70cb2d52911b765cebd086bef36447a443c1c3c1b05f01b7ac38b50eb55e
pr_number: 3654
tags: [promoted, decisions]
---

# Cross-file instruction duplication in /gaia-cleanse

`/gaia-cleanse --cross-file [scope-hint]` is an opt-in mode that finds a procedure, list, threshold or convention restated across instruction files and proposes replacing each restated copy with a pointer to one owner. The default `/gaia-cleanse` run is unchanged.

## Decisions

- **Deterministic candidates, model judgment only on excerpts.** `.gaia/scripts/cleanse/cross-file-candidates.mjs` splits every tracked instruction file (CLAUDE.md files, `.claude/**` Markdown, `wiki/**` minus `wiki/log.md` and `wiki/meta/`, nothing under `.gaia/`, nothing the ownership classifier calls third-party or ignored) into blocks. It extracts distinctive literals (code spans, fenced lines, repo paths, numbers with units), ignores literals too many files carry, and clusters blocks from different files that share enough of them. Each cluster carries its members' text, so a judge reads short excerpts and never the whole instruction set. Matching is by literals, never by titles.
- **Judges, then one assembler.** The main conversation shards clusters (at most 20 per shard) to Sonnet judges in waves of at most 8. Each judge writes one verdict per cluster (`duplicate`, `distinct`, `disagree` or `exempt`), each verdict is classified by the no-op detector, and a Sonnet `Stage 1 (cross-file)` assembler turns the verdicts into a scoped report (`scope: cross-file`). That report always gates on Apply / Discuss / Decline and never moves the statusline's last-cleanse anchor.
- **Duplicate versus disagree.** A copy that agrees with its owner becomes a `replace` action: its case-specific detail is kept, plus a pointer to the owner unless the reader already has the owner loaded. A copy that disagrees with its owner is an out-of-scope finding with no action, so the cleanse never picks a winner between two instruction files by rewording.
- **GAIA-specific exceptions live in `cleanse/cross-file.md`.** These cover a pointer from `apps/web/.claude/**` to a root rule (whether root rules load in an `apps/web` session is still unverified), a shipped copy whose only owner is maintainer-only or release-excluded, a copy a script or hook matches by text, and a block a script compares byte for byte.
- **GAIA-shipped files stay report-only.** A cross-file action on a GAIA-shipped file is reported with its remediation and never applied in an adopter repo.
  <!-- gaia:maintainer-only:start -->
  On the GAIA source repo, a cross-file action on a GAIA-shipped file carries `owner: maintainer` and is applied through the Apply answer.
  <!-- gaia:maintainer-only:end -->
- **Verification.** The classification-verification round adds a cross-file lens and recommends running whenever a cross-file action is present. A structural finding re-spawns the cross-file assembler.
- **Shell audit members.** Both shell audit members carry a duplicate-definition bullet in their shared correctness core: a new array, pattern list, path list, `jq` filter or function is checked against the repo by value for an existing definition.
