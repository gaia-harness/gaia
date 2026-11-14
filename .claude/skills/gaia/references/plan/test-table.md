# Test-design table

The planner's table procedure and the one owner of the table's shape. Which test to write and at which layer is `.claude/doctrine/testing.md`; this file owns the files, the row fields, the key grammar, the task-doc lines and how the planner fills the table.

Contents: `## Files`, `## Row`, `## Requirement-source keys`, `## Task-doc lines`, `## Procedure`, `## README rendering`.

## Files

All four live in the plan directory.

- `TEST-DESIGN`: the marker, one line `schema: 1`. `/gaia-plan` writes it right after it creates the plan folder; the planner never writes it. The approve step appends an `approved_sha256:` line.
- `tests.json`: the table, `{"schema": 1, "rows": [<row>, ...]}`. The planner writes it.
- `tests.approved.json`: the byte copy of `tests.json` taken at approval. Nobody edits it afterwards.
- `security-tests.jsonl`: the append-only ledger of the security-row tests the security writer wrote. Only `node .gaia/scripts/test-design/test-table.mjs record-security` writes it.

A write to any of these from a worktree session goes through the scratchpad-plus-`cp` route (`.claude/skills/gaia/references/plan/planner.md` tool-choice contract; `.claude/doctrine/execution.md`, `## Run folder`).

## Row

Every field is required unless marked.

- `id`: `T` plus a number, unique in the table (`T1`, `T2`). Never written into a test file.
- `source`: one requirement-source key.
- `case`: the case in words.
- `file`: the repo-relative test path.
- `title`: the exact full title the extractor emits: the describe titles plus the test title, single-space joined; for a story test `<Story Name>   <test name>` with three spaces. String literals only.
- `layer`: one of `unit`, `story`, `route`, `real-server`, `browser`, `flow`, `shell`.
- `task`: the owning task stem, `task-<name>`. A security row's owning task is the latest task whose code its test needs.
- `action`: one of `new`, `reuse`, `extend`, `change`, `retire`.
- `security`: one of `none`, `access`, `forgery`, `secret`.
- `caseKey`: required when two or more rows name one `file` plus `title`, and on every `extend` row. A string literal that appears in that test's `.each` or `.for` case table for this row's case. Rows sharing one test carry distinct `caseKey`s; a security row never shares a test without one.
- `reason`: optional; required on a row the drift step adds for a kept unplanned test.
- `held`: optional, written only by `approve --auto`: `"auto-mode"` on a `retire` row whose `security` is not `none`. Such a row is not executed.

## Requirement-source keys

`bash .gaia/scripts/spec/requirement-keys.sh --spec <SPEC.md> [--audit <AUDIT.md>]` prints one key per line, sorted; for a spec-less plan `requirement-keys.sh --description` prints `description`.

- `flow:<slug>`: each SPEC flow.
- `success_criteria:<i>`: 0-based.
- `scope_boundaries:<always|ask_first|never>:<i>`: 0-based.
- `clarifications:<i>`: 0-based index into `answered`.
- `directive:<n>`: the number of an item under the audit heading that starts with `## Plan-time directives`, matched by that prefix: a real audit writes `## Plan-time directives (no SPEC change)`.
- `description`: a spec-less plan's one key.

## Task-doc lines

A task doc names a test only on a line `- Test: <repo-relative file> › <exact title>`, one line per distinct file plus title the task owns, plus the closing phase's `- Flow test (<flow_id>): <path>` line. The `›` is U+203A with one space each side.

An existing test file whose pinned wording the task's edit falsifies is named on a line `- Pin update: <repo-relative path>`, one line per file. It needs no table row, since a pin repair is not a requirement-sourced test.

No other test path appears in a task doc: a path ending `.test.ts`, `.test.tsx`, `.spec.ts`, `.stories.tsx`, `.stories.ts` or `.bats` outside a `- Test:`, `- Flow test` or `- Pin update:` line fails `node .gaia/scripts/test-design/test-table.mjs verify`. Each `- Test:` line matches a row whose `task` is that doc's stem, and every row's task doc carries a `- Test:` line for it.

## Procedure

1. Read `.claude/doctrine/testing.md`.
2. Enumerate the requirement keys with `requirement-keys.sh`.
3. List the source paths the plan touches and run `node .gaia/scripts/test-design/existing-tests.mjs --root <tree> --touched <file>` over them: the existing tests that drive what the plan changes.
4. Map every key, and every case and stated literal (SPEC rows, success criteria, scope boundaries, clarifications, directives, and the documents the SPEC's Required reading names), to rows. Every key is some row's `source`, and every row's `source` is a key.
5. Pick each row's layer by the doctrine's `## Layers`, and confirm a path's layer with `node .gaia/scripts/test-design/layer-map.mjs --root <tree>` (NUL-separated repo-relative paths on stdin).
6. Give each row its action against the existing tests: `reuse`, `extend`, `change` or `retire`, else `new`. A case an existing test asserts is never `new`.
7. Flag access, forgery and secret rows per the doctrine's `## Guards and security rows`; a `retire` or `change` row on an existing test meeting that definition carries the flag. Set each security row's `task` to the latest task whose code its test needs.
8. Give rows that share one test distinct `caseKey`s, and a security row that shares a test a `caseKey` too.
9. Write titles as string literals, story titles in the three-space form.
10. Never write a row for a corner case no stated requirement names, or a self-test of a test double.
11. Write `tests.json`, then each task doc's `- Test:` lines from the rows whose `task` is that doc.

## README rendering

`README.md` carries a `## Test design` section with one table row per `tests.json` row, columns: id, source, case, file, title, layer, task, action, security. The README is the human's view; `tests.json` is the source.
