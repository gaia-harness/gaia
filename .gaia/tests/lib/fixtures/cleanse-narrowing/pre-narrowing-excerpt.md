# Excerpt of the playbook text that predates the narrowing

Every line below is verbatim from the earlier playbook. Each narrowing check must fail against it.

## Step 2, CONFLICT

- **CONFLICT**: a store asserts a policy that *contradicts* another canonical source on the same subject; opposed, not merely duplicated. Two scopes:
  - **Cross-store**: a memory entry or a `.claude/rules/*.md` file contradicts the wiki's canonical statement on the same subject. **Resolution favors the wiki.** Emit a `replace` swapping the contradicting line for a wikilink to the canonical page, or a `delete` if the contradicting entry has no residual value. Cite the canonical wiki page + line range in `reason` and note the superseded value inline (e.g. `reason: contradicts wiki/decisions/Foo.md L12-15 (canonical); local store asserted the opposite`).
  - **Project-internal**: two committed project files assert opposing facts on the same subject (e.g. a command file vs a skill playbook vs a wiki page on which model a stage uses). **Resolution favors the authoritative source for that fact**, which you determine and justify in `reason`; it is NOT always the wiki (the command can be wrong and the wiki right; the wiki can be stale and the playbook right). Emit a `replace` on the non-authoritative file when the Ownership step below allows it, else report it there.

## Step 3, Auto-load budget

| File                                                                               | Budget     | Rationale                                  |
| ---------------------------------------------------------------------------------- | ---------- | ------------------------------------------ |
| `CLAUDE.md` (root)                                                                 | ≤500 words | Routing, principles, standing conduct      |
| `wiki/README.md`                                                                   | n/a        | On demand, no auto-load budget needed      |
| Any nested `CLAUDE.md` discovered in Step 1 (monorepo package, subapp, docs, etc.) | ≤400 words | Scoped routing                             |
| Any single `.claude/rules/*.md`                                                    | ≤200 lines | Focused rule                               |

## Summary template

- Conflicts: {count}

## Verification round

- **Recommend Run** when the report contains any memory `delete` / `delete-entry`, or any CONFLICT-driven `replace`: those actions are irreversible or carry contradiction risk.
- **Skip is eligible** (a legitimate recommendation) only when every action is a git-reversible, non-CONFLICT-driven `shrink` on an in-repo (non-memory) file; the decision gate plus git undo already cover that case. Recommend Run in every other case. Establish "non-CONFLICT-driven" from the Summary's `Conflicts:` count, not by reading each `reason`: **only `Conflicts: 0` establishes it**, since a CONFLICT-driven action is emitted as the same `shrink` block as any other and a project-internal one need not name a contradiction in its `reason`.
- **CF, conflict adjudication (id prefix `CF`).** For each CONFLICT-driven action, INDEPENDENTLY re-pick the authoritative source and confirm a GENUINE contradiction exists, rather than: (a) sanctioned path-scoped-rule duplication (a live `paths:`-scoped `.claude/rules/*.md` rule, including a `gaia-harden:` provenance-marked rule, is allowed to duplicate wiki content and is never a CONFLICT); (b) a maintainer-only block; or (c) an out-of-scope wiki-page-vs-wiki-page case (those route to `/gaia-wiki`, not here). A CONFLICT that is actually one of these, or that picks the wrong authoritative source, is a finding.

Collect the CF findings ONLY. CL and ES findings are checkable and binary, so they route to disposition directly with no refuter. For each CF finding, dispatch ONE additional `general-purpose` Agent that independently re-adjudicates the conflict: re-pick the authoritative source from ground truth and decide whether a genuine contradiction exists.

- A CONFLICT-driven `replace` / `delete` action **survives** only if the CF lens AND its re-adjudicator agree the conflict is genuine AND agree on the same authoritative source.
