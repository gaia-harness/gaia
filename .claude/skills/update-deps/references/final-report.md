Contents: Final-tree security audit; What goes in each section (Security, Security cache rewrite); Report template.

## Phase 7: Final report

**Security.** Before building the report, audit the final tree once, inline, from the project root, in every run. This audit is the authority for what is resolved, still open, and introduced; the opening advisories payload only enriches its rows (EPSS, scope, relationship, alert numbers), and the Dependabot alerts list is never the authority. It never fails the run, never reverts anything, and never edits the `overrides:` map.

The two capture files are fixed literal paths, so every command stays plain inside a worktree. Run each line as its own call:

```bash
mkdir -p .gaia/local/cache/shared
pnpm audit --json > .gaia/local/cache/shared/update-deps-final-audit.json 2> .gaia/local/cache/shared/update-deps-final-audit-err.txt || true
jq -e '.advisories | type == "object"' .gaia/local/cache/shared/update-deps-final-audit.json >/dev/null 2>&1 || { jq -r '.error.message // empty' .gaia/local/cache/shared/update-deps-final-audit.json 2>/dev/null | grep . || head -n 1 .gaia/local/cache/shared/update-deps-final-audit-err.txt | grep . || echo "pnpm audit produced no JSON"; }
jq -r '.advisories // {} | .[] | [(.github_advisory_id // ("pnpm:" + (.id | tostring))), .id, .module_name, .severity, (.findings | map(.version) | unique | join(", ")), .patched_versions, (.findings | map(.paths[]) | unique | first), (.findings | map(.paths | length) | add)] | @tsv' .gaia/local/cache/shared/update-deps-final-audit.json
```

`pnpm audit` exits non-zero whenever an advisory is open, so read the JSON, not the exit status. When the second command prints a line (no `advisories` object: `pnpm audit` reported an error or the registry did not answer), the source line reads `Source: Not run (<that line>)` and the run's applied resolutions are listed `unverified`. Otherwise each row is `key, pnpm id, package, severity, installed, patched, chain, path count`; the key is the GHSA id, or `pnpm:<id>` without one, the same key the advisories payload uses. In alerts mode you may re-run `advisories --emit` against the final tree for fresh joins. List every severity: the frontend audit's advisory oracle (`gaia update-deps advisories`) surfaces only high and critical, and on a manifest-only `chore(deps)` PR the frontend member is waived. Remove the two capture files (`update-deps-final-audit.json` and `update-deps-final-audit-err.txt` under `.gaia/local/cache/shared/`) once the report is printed.

Build the report **only** from the agent reports returned to you, the snooze and transitive-refresh decisions from Phase 1, the Phase 5c result, and the final-tree audit above. Do not add rows from your own memory of the run.

**What goes in each section:**

- **Updated packages**: every package the Wave A agent or a Wave B agent reports as `updated`. Then, on a run that created a worktree, one line per package whose declared version in the worktree differed from the version discovery read, naming both values and whether it left the apply set (`references/worktree.md`, step 5 of `## Create the worktree`).
- **Breaking changes applied**: only what Wave B agents report editing in the codebase. Empty if no Wave B group ran.
- **Transitive refresh**: the Phase 5b agent's result: one row per package it moved (from and to), or one of `Nothing moved`, `Declined in preview`, `Not run (--scope)`, `Not run (--security)`, or `Reverted (<reason>)` followed by the rows that would have moved. Always include this section; `Nothing moved` is a result, not an empty section. These rows never go in Updated packages, and a reverted refresh is reported here, not in Skipped packages.
- **Overrides audited**: only what the Phase 0 / Phase 6 audit reports. If the `overrides:` map was empty, write "None" and move on. On a refresh-only run where Phase 6 did not run, write `Not run (refresh-only, tree unchanged)`.
- **Security**: always present, printed on every exit path, and never a bare `None`: the heading is always followed by the source line and all three tables, and an empty table reads `None.`. The source line is `Source: pnpm audit, enriched by Dependabot alerts` when alerts were read, `Source: pnpm audit. Dependabot alerts: Not run (<reasonText>)` when they were unavailable, `Source: pnpm audit. Dependabot alerts: Not run (CI run)` in CI, or `Source: Not run (<reason>)` when the final-tree audit failed.
  - **Resolved**: an opening advisory absent from the final-tree audit. Package, advisory key, method (`in-range refresh`, `chain-head bump (<pkg> <from> → <to>)`, `override (<key>: <value>)`, `chain-head major (<group>)`), new installed version. Append `(on this branch, pending merge)` when its alert is still open in alerts mode.
  - **Accepted**: package, advisory key, dismissal reason (or `baseline entry proposed` on the fallback).
  - **Still open**: every final-tree audit row not accepted. Package, advisory key, severity, installed, first patched, held back by (the extracted chain below its importer, plus `(+N more paths)` when the path count exceeds 1), and the reason from the security plan or Phase 5c (`report-only run` in a report-only run). Mark `introduced by this run` on a row whose key is not in the opening advisory set Phase 1 kept (`advisories[].key`, `auditKeys`, and `dismissedGhsas`); this comparison is the whole test.
  - **Dismissed alerts.** In alerts mode, a final-tree audit record whose GHSA is in the opening `dismissedGhsas`, or that this run dismissed, is accepted, not open: it gets no Still open row and no `introduced by this run` marker. Without this, an advisory accepted in an earlier run would reappear as open and introduced on every run. On the fallback `dismissedGhsas` is `[]` and nothing changes; a final-tree row whose pnpm id `.gaia/local/dep-audit-baseline.json` acknowledges is Accepted with `baseline entry`.

  **Security cache rewrite.** After printing the report, in a run that reads alerts (never in CI: there the rewrite is skipped entirely, so a CI run never replaces a `dependabot` count with a `pnpm-audit` one), take the count from the advisories verb against the final tree, never from the report's tables:

  ```bash
  .gaia/cli/gaia update-deps advisories --emit .gaia/local/cache/shared/update-deps-advisories-count.json --count-only
  jq -r '[.source, (.count | tostring), (.reasons | join(","))] | @tsv' .gaia/local/cache/shared/update-deps-advisories-count.json
  ```

  When its source is `dependabot` or `pnpm-audit`, run `.gaia/cli/gaia update-deps write-security-cache --count <count> --source <source>`, adding `--reason <reasons>` when the reasons field is non-empty. When it is `unavailable`, do not call it: the three security fields stay as they are. The verb counts what the background refresh counts (open alerts together with the final tree's `pnpm audit` advisories, less dismissed alerts and baseline acknowledgments of advisories no open alert backs, so this run's dismissals are already gone and branch-only resolutions still count; or, without alerts, the final tree minus baseline acknowledgments), so the two agree. Never hand-edit the cache's security fields. Remove `.gaia/local/cache/shared/update-deps-advisories-count.json` afterwards.

- **Skipped packages**: _only_ packages that were attempted and reverted mid-run (peer-dep conflict, quality-gate failure, manual revert by an agent). **Never** include packages filtered out before installation by a policy rule (e.g. the ESLint 9.x cap or the release-age cooldown). Those are silent by design, surfacing them is noise the user sees every run. When you cannot tell whether a package was policy-filtered before installation or attempted and reverted mid-run, include it in Skipped, a spurious row is recoverable but a silently dropped real failure is not. If nothing was actually skipped during the run, write "None" or omit the table.
- **Snoozed (deferred this run)**: the companion groups the human chose to skip in the preview, with the version each was snoozed at. These quiet the statusline for 14 days (or until a newer version ships); they are not failures. Omit the section if the human chose "Update all".
- **Quality gate**: the gate result reported by the agents, verbatim.
- **Global tools**: the playwright-cli row from the Phase 1 global-tools step: status, installed, latest, and the action taken (`upgraded`, `declined`, `report-only`, `not installed`). Print the section only when the row's status is not `current` (a newer release, not installed, or a failed probe); a `current` tool has nothing to act on, so omit the section rather than writing `None`. When it applies, print it on every exit path, including the all-up-to-date and Skip exits. It is built inline, so it is an exception to building the report only from agent reports, like the Security section.

<!-- gaia:maintainer-only:start -->

- **Vendored skills**: built inline from the Vendored skill sync step, so it is an exception to building the report only from agent reports. Print the section only when the result is not `current`; a `current` marker is omitted, not written as `None`. One row: the skill name (`playwright-cli`), marker version, upstream latest, and `re-vendored`, `verify failed (<path>)`, or `unknown`.

<!-- gaia:maintainer-only:end -->

If a section would be empty, write "None" rather than leaving it blank or fabricating filler.

Print the report. Do not commit.

```
## Migration Report

### Updated packages
| Group | Package | From | To | Type |
| --- | --- | --- | --- | --- |

### Breaking changes applied
- [group] description

### Transitive refresh
| Package | From | To |
| --- | --- | --- |

### Overrides audited
- Removed: <key>, <reason>
- Retained: <key>, <reason>

### Security
Source: pnpm audit, enriched by Dependabot alerts

Resolved
| Package | Advisory | Method | Installed now |
| --- | --- | --- | --- |

Accepted
| Package | Advisory | Reason |
| --- | --- | --- |

Still open
| Package | Advisory | Severity | Installed | First patched | Held back by | Reason |
| --- | --- | --- | --- | --- | --- | --- |

### Skipped packages
| Package | Reason |
| --- | --- |

### Snoozed (deferred this run)
| Group | Snoozed at version | Resurfaces |
| --- | --- | --- |

### Quality gate
| Step | Result |
| --- | --- |

### Global tools
| Tool | Status | Installed | Latest | Action |
| --- | --- | --- | --- | --- |
```
