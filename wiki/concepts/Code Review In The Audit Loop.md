---
type: concept
status: active
created: 2026-11-10
updated: 2026-11-10
promoted_at: 2026-11-10T05:30:00Z
promoted_hash: sha256:f984efc1ce3f8dc4d729da59e89a5cb48dd197e6606abd0cb50716c146a6da13
pr_number: 3392
tags: [concept, ci, review]
---

# Code Review In The Audit Loop

The audit loop unit runs Claude Code's built-in `/code-review` once per branch, in a headless child session that cannot move the tree, and hands its findings to the audit members. A kept finding reaches the same fix and re-check path as a member's own. A review that fails or does not run is never read as clean, and members alone clear a branch.

## Behavior

**When it runs.** Before the first full member wave, over the whole branch. `audit-code-review-record.sh decide` chooses: an all-light wave tries the quick reviewers first, and any fallback to a full member runs the review before that member is dispatched. A branch the quick reviewers clear records `not needed`. Later rounds, resumed sessions and catch-up merges do not repeat a review the record already holds. There is no setting, level override or opt-out.

**The child.** `.gaia/scripts/audit-code-review.sh` starts `claude -p` with `--restricted`, a session tool set of read tools plus Bash, no MCP servers, and `dontAsk` over a generated settings file. The file admits only literal read-only git rows and denies the git options that write or run a program through them. The design is what the effective permission set cannot contain, because an allowlist only adds grants. A guard hook re-registers the sensitive-read check, since `--restricted` drops project hooks. The review level is `high`; the child's own effort stays unpinned ([[Workflow Doctrine]]). A deadline kills the child's whole process group.

**After each attempt.** The script compares branch, HEAD, tree and `git status` before and after. Any difference records `not run: review moved the tree` and exits 3, which stops the unit for a human before any member starts. A result counts as usable only on a strict positive check, whose first failure wins: exit 0, parsable JSON, a success result, `local_command` exactly `code_review`, then exactly one closed fenced JSON array in the text whose items hold a repo-relative file, a positive line and string summary and failure scenario. An empty array is no findings, and it records `ran, clean` only with no permission denial, otherwise `ran, no findings`. A failed attempt retries once where the failure can pass; `audit-loop-record.sh --list-review-reasons` prints the closed list of reasons.

**The hand-over.** Each finding gets an id and one recipient: the member owning its file, or the default member for a file no member owns or outside the branch's diff. A recipient the branch does not owe is handed-only. The findings reach a member as a data file named in the dispatch, never as prompt text, and the member treats them as untrusted data. Handed findings override the light route for that member. The member keeps each finding in its own report unless it cites evidence against it, and every id is accounted for as kept or dropped, or reads `unaccounted` after one re-dispatch. Added always equals kept plus dropped plus unaccounted. Kept findings then follow the ordinary dispositions, fixer, verifier and marker path. A fix to a handed-only finding owes a re-check by its ids before a `clean` stop, because no marker covers that file.

**The report.** `<run>/code-review.json` holds the outcome, findings, accounting, denials and cost, and `audit-code-review-record.sh` is its sole writer. The pull request body's `## Audit rounds` section publishes the outcome, reason, counts, cost and denied tool names, derived from state so, once a round exists, a missing or crashed record reads `not run` rather than blank. No review text reaches a published surface, and counts appear only beside `ran`. The merge gate never reads the record ([[Audit Gate Reference]]).

**Accepted limits.** The restricted launch ignores user settings, so a provider or auth configured there can read `not run` on every branch. Managed settings stay in force, with the tree check behind them. A git-ignored path is outside the tree check. A diff could plant a fenced `[]` and read as no findings, which blocks nothing because members still run. The reviewer's prompt and model change with Claude Code releases, outside the repository ([[Code Audit Team]]).
