---
type: concept
status: active
created: 2026-07-18
updated: 2026-10-23
tags: [concept, ci, audit, claude]
---

# Registering a Code Audit Team Member

The [[Code Audit Team]] gate dispatches specialized auditor members by file glob rather than running one generic reviewer over every diff. Adding a member is config plus an agent file: the dispatch resolver is generic over the roster, so registering a member never touches `.gaia/scripts/resolve-audit-members.sh` itself.

## Registration steps

### 1. Author the agent definition

Copy `.claude/agents/code-audit-github-workflows.md`, the smallest adopter member, to `.claude/agents/code-audit-<name>.md` and rewrite its subject matter. The `code-audit-` prefix is required: the branch checkpoint's bound hook (`.claude/hooks/audit-loop-bound.sh`) reads it to tell a member from any other agent, and the machinery list registers every `.claude/agents/code-audit-*.md` file by that one pattern, so a member named this way needs no edit to `.claude/hooks/lib/audit-machinery.sh`. That registration is what makes a rewrite of the member's own instructions rotate its clearance.

Keep the copied shape: `name` / `description` / `model` / `color` frontmatter, a **Remit and self-skip** section with the heading, the root fence and the scope resolver call, **Review dimensions**, a **Finding Proof Gate**, **Findings grading** (which severities the member may use), a read-only stance (the member reports and gates its marker; it edits no tracked file), **Cross-remit findings** handling, a protocol section pointing at `.claude/hooks/lib/audit-member-protocol.md` (which owns the scope resolution, output format, gate handshake and findings sidecar), and a **Methodology** summary. Leave the glob list and the filter instruction to the generated remit region, which step 3 produces. The `description` states the member's subject matter and read-only stance in one line, since that's what a dispatching agent reads first, and restates no glob.

The **Remit and self-skip** section runs the root fence, sends the member to the `## Scope resolution` section of `.claude/hooks/lib/audit-member-protocol.md` before the scope resolver runs, and then runs the resolver under the member's own name. It keeps only what is the member's own: the resolver's flags and what a narrower increment obliges the member to check in its domain. The protocol section holds everything else about the scope once for every member, including the scope-resolution obligation: Capture your own branch-own digest at scope resolution with `.gaia/scripts/audit-scope-digest.sh --capture`, and at marker-write time read that captured value back with `--read` and pass it as `--scope-digest`; never re-derive it in the writing call, and a rotation between the two means the review was superseded and you must be re-dispatched on the new HEAD.

### 2. Register in the roster

Add an entry to the `auditors:` list in `.gaia/audit-ci.yml`: `name`, `globs`, and `audience: adopter`. That list is the only roster: the ownership classifier has no fallback, and a config without an `auditors:` block fails closed. Claimant globs match first-match-wins in roster order, so place the entry where its globs neither shadow nor are shadowed by an earlier member's (see `## Choices to make per member`).

### 3. Generate the remit region

Run `bash .gaia/scripts/write-audit-remits.sh`. It reads `.gaia/audit-ci.yml` and writes each member's marker-delimited remit region into its agent definition, inserting the markers on a definition that has none. Everything outside the markers is left alone. Re-run it after any roster change: the roster check fails whenever a region disagrees with the roster entry that dispatches that member, and every one of its findings prints this command.

### 4. Register finding classes, if the member needs new ones

A member reporting an **oracle** finding from a deterministic tool GAIA already knows (`react-doctor/`, `axe/`, `knip/`, `cve/`) needs no registration: the tool owns the id space after its prefix, and any well-formed id is valid. Everything else goes in `.gaia/finding-classes.json`:

- a project tool whose ids the tally should accept verbatim adds its kebab-case prefix to `oracle_prefixes`;
- a genuinely new root-cause category adds `<prefix>/<slug>` kebab-case classes to `classes`, and the member's definition names them as its own vocabulary.

Keep new classes genuine root-cause categories the member can assign reliably and repeatably, never a subsystem tag standing in for "somewhere in this member's remit." When in doubt, leave a class out: a finding with no fitting class is stamped `holistic/unclassified` and counted as the unclassified recurrence signal rather than a draftable candidate. A class missing from the file counts the same way, so register a class before the member assigns it. `codify-tally` reports a malformed file on stderr as `malformed_finding_classes` and reads it as empty.

<!-- gaia:maintainer-only:start -->
In the GAIA repo, a class every adopter should get belongs in the built-in vocabulary instead: `.gaia/cli/src/schemas/finding-class.ts`, maintainer-only CLI source, as a new prefix with a seeded `as const` union folded into the closed-vocabulary set, or as members added to an existing union with its parity list. It reaches the shipped `codify-tally` command only once the bundled binary is rebuilt (see step 7). `.gaia/finding-classes.json` ships empty and stays empty here.
<!-- gaia:maintainer-only:end -->

### 5. Integrate the recurrence tally

The finding-recurrence tally reads each member's findings sidecar to feed `/gaia-codify`'s judge-the-form logic. A new class routes by the default rule: a mechanizable pattern routes to a deterministic check, a judgment call routes to a prose rule.

<!-- gaia:maintainer-only:start -->
If a new built-in bucket needs routing guidance beyond the default, add a short paragraph to `.claude/skills/gaia/references/codify.md` describing how it routes, alongside the existing oracle / holistic / rule / workflow / prose paragraphs.
<!-- gaia:maintainer-only:end -->

### 6. Verify the roster

Run `bash .gaia/scripts/verify-audit-roster.sh` and repair every finding it prints; each one names its repair. It checks remit region parity, ownerless-path coverage, the `code-audit-` name prefix, and that the machinery list reaches every member definition. The pre-commit hook also runs it whenever a commit stages `.gaia/audit-ci.yml`, a `.claude/agents/code-audit-*.md` file, or `.claude/hooks/lib/audit-machinery.sh`, so a broken registration cannot be committed.

<!-- gaia:maintainer-only:start -->
### 7. Regenerate the CLI binary

A finding-class schema change only reaches the shipped `codify-tally` command once the bundled adopter binary (`.gaia/cli/gaia`) is rebuilt from `.gaia/cli/src` and committed alongside the schema edit. Skipping this leaves the schema and the binary disagreeing about the valid vocabulary.

A change to how the tally counts, the window, the recurrence threshold, which PRs count as audited, how one PR's findings from several auditors merge, or which findings blocks and findings the parser accepts, bumps `TALLY_SCHEMA_VERSION` in `.gaia/cli/src/codify/material-rise.ts` in the same change. The counting code sits inside the `tally-semantics` regions of `.gaia/cli/src/codify/tally.ts`, `.gaia/cli/src/codify/compute-tally.ts`, and `.gaia/cli/src/codify/parse-findings-block.ts`; nothing checks the bump, so a change inside those regions is the cue to make it. A comment-only edit there needs no bump, and neither does a new finding_class bucket alone. A bump fires exactly one "tally changed" nudge and voids every share baseline recorded under the old counting.

### 8. Release-exclude any test fixtures

A maintainer member takes `audience: maintainer` in step 2, inside the roster's `# gaia:maintainer-only` markers. Its agent file, and any fixtures or bats suites written to exercise it, belong in `.gaia/release-exclude` so the release scrub strips them from the adopter bundle. An `audience: adopter` member ships as-is and needs no exclusion entry.
<!-- gaia:maintainer-only:end -->

## Choices to make per member

- **Read-only and gating.** Every member only reports: it edits no tracked file, and after a full review it clears or withholds its own marker. Repair belongs to the one verifier-checked fixer the audit loop unit drives, so no roster key grants a member write access. A roster an older release wrote may still carry a retired per-member repair key; the roster readers ignore it and `/update-gaia` drops it when it applies the member's mapping.
- **`audience`.** `adopter` ships to every clone. `maintainer` entries sit inside `# gaia:maintainer-only` marker comments in the roster, and the release scrub strips them, so an adopter's roster only ever carries adopter-audience members.
- **Globs and roster order.** Every claimant member's globs are matched first-match-wins over roster order; the default member's globs are a catch-all tier reached only once every claimant has failed to match. Two claimants claiming overlapping territory silently hands a path to whichever member the roster happens to list first, so check for that by eye when adding a member; `.gaia/scripts/verify-audit-roster.sh` asserts remit region parity (each member's agent definition carries exactly its roster globs, in roster order, inside a balanced marker pair), ownerless-path coverage, the `code-audit-` name prefix, and machinery registration. It ships to every clone and the pre-commit hook runs it on a roster commit (step 6); it does not catch overlapping claimant globs.

<!-- gaia:maintainer-only:start -->
## Local-gate checklist

Registering a member touches shared classifier and merge-gate machinery, not just the new agent file, so the bats suites guarding that machinery are the local gate for the change. Run all of these before merge:

- `bash .gaia/scripts/verify-audit-roster.sh`, the roster's own deterministic check, plus its own bats suite.
- `.gaia/tests/hooks/audit-scope-lib.bats`, structural and invariant tests over the shared ownership classifier (`.claude/hooks/lib/audit-scope.sh`): golden ownership-resolution cases, the machinery-is-roster-claimed invariant, and the fail-closed roster-less init.
- `.gaia/tests/hooks/audit-scope-routing-parity.bats`, the before/after routing-parity proof: it classifies every tracked file against a committed fixture snapshot and asserts each resolves to its prior owner, except the named set of paths a deliberate roster change is moving. A new member's globs belong in that named-exception set.
- `.gaia/tests/hooks/pr-merge-audit-check.bats`, tests over the local merge-gate deny-hook itself: the dispatched-member set it resolves, and the AND-aggregation across every dispatched member's own marker.

All four read live roster and machinery state, so a registration that only edits `.gaia/audit-ci.yml` and the agent file, without updating the machinery lists in lockstep, is exactly the drift these checks exist to catch before CI does.
<!-- gaia:maintainer-only:end -->

## Pairs with

- [[Code Audit Team]]: the roster mechanism, ownership classifier, branch-own digest keying, and AND-aggregation this page's steps plug into.
- [[Policy-Memory Loop]]: what happens to a member's findings once they start recurring.
