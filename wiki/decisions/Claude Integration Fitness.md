---
type: decision
status: active
created: 2026-05-12
updated: 2026-10-14
tags: [decision, claude, fitness]
---

# Claude Integration Fitness

`/gaia-fitness` answers one question, "how well-configured and coherent is this project's Claude integration?", and heals what it can. A single invocation checks, reports an F-to-A+ grade, heals the findings the project owns (asking per file first), re-runs the check once to verify, and offers a publish gate. The step-by-step flow is the playbook `.claude/skills/gaia/references/fitness.md`; this page records why it is shaped that way.

## Why a deterministic linter

The check is `gaia fitness check`, a fixed rule catalog run by the CLI, not a set of model auditors. A model reading the same files twice returns different findings, so a model-run grade moves between runs and a fix cannot be verified by re-running the check. A script over a fixed catalog gives the same findings for the same files, so the grade is reproducible, the catalog is covered by tests, and the same run can gate GAIA's own CI. Judgment the catalog cannot encode (description substance, trigger overlap between skills, rule scope against its `paths:` globs, terminology consistency) runs as one read-only advisory pass whose findings never move a grade.

The rules themselves live in the catalog, not on this page: `gaia fitness rules --json` prints every rule id, category, severity, the file kinds it applies to and a one-line detection description. A project adds its own checks as a rule (`.claude/rules/`) or a skill, not as a section here.

## Why grade only what the project owns

GAIA is a foundation: a project's `.claude/` mixes files GAIA ships, files the project wrote, and files a third party installed. A grade that counted all of them would charge the project for defects it cannot fix without drift. The grade covers files the project owns; a GAIA-shipped finding is listed under an upstream section, fixed by `/update-gaia`, and does not move the grade.

## Grading

The grade is a pure function of the finding set. The CLI owns the bands and the overall rule, and the report's `categories`, `overall` and `findings` keys carry the result. Optional `.claude/gaia-fitness.json` suppresses a finding by rule id and path with a stated reason. This page restates neither the bands nor the rules.

## Heal protocol

### Heal phase

Only a finding the CLI marks `fixable: true` is healed, and `gaia fitness apply` is the only writer. The fixable set is a property of the finding the CLI computes (a graded, unsuppressed error or warning on a file the project owns, in the hooks, settings, `CLAUDE.md` or rules categories), never a judgment the playbook makes.

1. A proposer drafts the complete new content of each fixable file without touching it.
2. The main thread shows each file's diff and asks, one file per question. A run with no one to answer reports the proposals and edits nothing.
3. Each accepted proposal goes through `gaia fitness apply`, which re-checks ownership, refuses a symlink escape and refuses a file that changed since the diff was shown. A refusal is reported, never retried, and the file is never written by hand.
4. After all applies, `gaia fitness check` runs once more. A finding that survives a fix stays reported as unresolved; there is no second heal cycle, so no fix is proposed twice in a run.

A fix too invasive to apply without product context (restructuring a rule file, splitting an oversized `CLAUDE.md`, changing the structure of hook logic) gets a recommended approach in the report and no edit.

#### Ownership

The heal edits only the project's own files, and only on a yes for each one. Ownership comes from the project's records (`.gaia/manifest.json`, the `.gaia/vendor/*.json` pins, `.gitignore`), never from a reading of the file; `.gaia/scripts/fitness-ownership.sh` decides it and its header defines the classes and their precedence. Each class gets one treatment:

| Class          | Treatment                                                                                                                                                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `third-party`  | Inventoried, never linted or edited. Upstream-owned.                                                                                                                                                                          |
| `ignored`      | Inventoried, never linted or edited. Whoever manages the file (the tool that installed it, or a machine's owner for a per-machine file) fixes it.                                                                            |
| `gaia-shipped` | Never edited locally: a local edit is drift the next `/update-gaia` has to reconcile. Findings are listed under the upstream section with the remediation `/update-gaia`.                                                    |
| `unknown`      | Graded like an owned file but never healed: the classifier could not decide, so the heal does not guess.                                                                                                                     |
| `adopter`      | Edited only on a yes for that file, through `gaia fitness apply`.                                                                                                                                                             |

A classifier that cannot read its inputs leaves every path `unknown`; that run heals nothing.

### Publish

After a heal that applied at least one fix, a single gate chooses between publishing (commit, push, open a PR and drive it through the merge gate), opening the PR only, or keeping the changes in the working tree. The heal lands on the run's own branch, isolated through `.claude/skills/gaia/references/isolation.md` before the first fix is applied, so a run from any branch publishes through its own PR and never commits onto the branch the checkout holds. The mechanics live in `.gaia/scripts/fitness-publish.sh` and the playbook.

## See also

[[Wiki Management]]: `gaia wiki dead-paths`, `gaia wiki orphans`, and the other primitives the wiki rules of the catalog run.
