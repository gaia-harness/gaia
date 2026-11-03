---
description: 'Render step of the generated plan orchestrator: render the `real-server`-routed UATs into red request-fixture stubs, the `browser`-routed (and legacy `e2e`-routed) UATs into red browser stubs, and the route-routed UATs into red Vitest route tests in the web member before Phase 1.'
---

# UAT render step

The orchestrator runs this step before Phase 1 on every start and every resume. It renders each `real-server`-routed UAT of the plan's SPEC into one red request-fixture stub (`test.fail()`, no page) and each `browser`-routed or legacy `e2e`-routed UAT into one red browser stub, all under `apps/web/.playwright/e2e/` (the e2e directory of the web member registered in `.gaia/packages.json`; the row's surface, not the path, tells them apart), and each route-routed UAT into one red Vitest test (`test.fails(`) under `apps/web/app/route-tests/` (the route-tests directory of the same package), so a failing harness exists before source is edited. The render is idempotent.

## Inputs

- `SPEC_PATH`: the absolute, main-anchored (stored in the main checkout: the clone's primary working directory, on any branch) path of the plan's `SPEC.md`.
- The plan `README.md` holding the UAT routing table, absolute and main-anchored. Its table sits between the `gaia:uat-routing` start and end marker lines, one row per UAT with columns `uat_id`, `surface`, `phase`, `feature_folder`, `file_name`.
- cwd: `RESOLVED_ROOT`, the isolation root the plan runs in.

## Run

```bash
bash .gaia/scripts/spec/uat-write.sh "$SPEC_PATH" --routing "$PLAN_README"
bash .gaia/scripts/spec/working-doc-id-scan.sh
```

Capture the renderer's stdout JSON as is: `{"ok":true,"e2e_directory":"...","summary":{"written":0,"rewritten":0,"unchanged":0,"preserved":0,"deleted":0,"conflict":0},"details":[{"uat_id":"...","path":"...","action":"written"}]}`. A conflict detail also carries `reason`. The renderer validates the routing table and the SPEC before it writes anything, and keeps a render ledger (`uat-render.json`) beside the plan README so a later run finds the spec of a removed or re-routed UAT. The ledger lives in the plan folder and is never committed.

The id scan checks every path and every text file under `apps/web/.playwright/` (the web member's Playwright directory), except the `output/` run-artifacts folder, and under `apps/web/app/route-tests/`, for a working-document id. Run it even when the renderer reported nothing changed.

## Exit codes

Renderer:

| Exit | Meaning | Orchestrator action |
|---|---|---|
| 0 | Success, no conflict | Run the id scan, then `## Record` |
| 1 | Operational failure (stdout `{"ok":false,"error":"..."}`), nothing written | HALT |
| 2 | Invalid input: usage, malformed SPEC, invalid routing table, or a working-document id in a `real-server`, `browser`, `e2e` or `route` UAT (stderr only), nothing written | HALT |
| 3 | Conflict: every non-conflict action still applied, the summary printed with `"ok":true`, every conflict file left byte-identical | `## Conflicts` |

The id scan exits 0 when clean, 1 printing `<path>:<line>: <match>` per hit, 2 on a usage error. A non-zero id scan HALTs, naming each file and line.

Every render-step HALT appends this block to `PROGRESS.md` and stops before Phase 1. The block does not start with `## Phase`, so the resume helper ignores it and the render re-runs on resume.

```
## UAT render (HALTED)
Reason: UAT render conflict   (or)   Reason: UAT render failed (exit <1 | 2>)   (or)   Reason: working-doc id in rendered specs
Spec files: <each conflict path and its reason from the JSON details; or each path:line from the id scan; or none>
Detail: <the renderer's error message or stderr, one line; omit for a conflict>
Next step: <conflict: answer the keep/replace question per uat-write.md "Conflicts", or reconcile the edited file manually, then resume with KICKOFF.md; exit 1 or 2 or an id hit: fix the named input (a SPEC reopen when the UAT text itself carries the id), then resume with KICKOFF.md>
```

Keep exactly one of the three `Reason:` alternatives. When a UAT's own text carries the id (renderer exit 2 naming the UAT and field), the fix is a SPEC reopen that describes the behavior without the id: see `uat-divergence.md` `## Reopen`.

## Record

After exit 0 (or exit 3 once `## Conflicts` is settled and the renderer re-run exits 0) and a clean id scan:

- Stage only the paths the JSON summary names (every `path` whose action is `written`, `rewritten` or `deleted`) and commit them as their own commit, before the Phase 1 commit, with a Conventional Commits subject of type `test(e2e)`, or `test(route)` for a route-only plan, for example `test(e2e): render red specs for the planned user acceptance tests`.
- Append this block to `PROGRESS.md` with the commit's short SHA:

```
## UAT render
Commit: <short-sha>
Summary: written <n>, rewritten <n>, unchanged <n>, preserved <n>, deleted <n>, conflict <n>
```

- Nothing changed (no `written`, `rewritten` or `deleted`): no commit; the block carries `Commit: none (nothing changed)`.
- No `real-server`, `browser`, legacy `e2e` or `route` row in the routing table: the renderer writes nothing, so record `Skipped: no e2e-routed or route-routed UATs` in place of the `Commit:` line. A table with only `route` rows renders and commits, and never records `Skipped`.

## Conflicts

Each `conflict` detail names a file the renderer left byte-identical, with a `reason`:

- `changed-and-edited`: the UAT text changed and the rendered file was edited since it was rendered.
- `unmarked-file-at-target`: a file with no contract marker already sits at the path a `real-server`, `browser`, `e2e` or `route` row resolves to.
- `removed-or-rerouted-and-edited`: no row claims the file any more and it was edited.

For each conflict, ask the human once with `AskUserQuestion`:

- Keep the edited file (first, marked ` (Recommended)`, because it never loses the edit): HALT for a manual reconcile.
- Replace it with the new render (or delete it when no row claims it): re-run the renderer with `--overwrite <repo-relative-path>` for exactly that path. Unnamed conflicts stay conflicts.

With no human present (unattended or auto), or when the human keeps the edited file, HALT with the `## UAT render (HALTED)` block above, `Reason: UAT render conflict`, naming each file and reason on `Spec files:`. Never overwrite or delete without that answer.

## The rendered file

Each rendered test starts with a contract marker (line 1, `// gaia-uat-contract sha256:<digest>`), then the UAT's canonical `Given`, `When` and `Then` lines and the divergence rule pointer. A `browser` or legacy `e2e` spec's body is a `const outcome = {text: '<then-clause>'}` followed by `test(outcome.text, () => { test.fail(); expect(false, outcome.text).toBe(true); })`. A `real-server` stub uses the same `outcome` const, but its test callback destructures only `{request}`, opens no page, and its placeholder is `expect(request, outcome.text).toBeUndefined()`; the owning phase writes a request-fixture body, and the gate refuses one that opens a page. No path, title or comment carries a working-document id.

- The digest covers everything after line 1. A file counts as edited when the digest differs from the file's current content.
- The renderer rewrites or deletes only a file whose first line is a contract marker. A hand-written file in the same folders, with no marker, is never read for writing and never listed in the summary.
- The owning phase removes the `test.fail();` call, so the test is a plain `test(`, and writes a real body that drives the app with Playwright in place of the placeholder `expect(false, ...)`. It keeps the contract lines as they are. Cosmetic edits are allowed and logical ones are not: `uat-divergence.md`.
- A route test is shaped differently: after the contract lines it imports `expect` and `test` from `vitest` and holds one `test.fails('the owning phase replaces this body', ...)` with a placeholder `expect(false).toBe(true)`. The owning phase removes the `.fails`, so `test.fails(` becomes `test(`, and writes a real body that calls the route module's loader or action directly and asserts the Then-clause on the response. The gate refuses a route test that keeps an inverting or skipping annotation; the comment on `gate_route_annotated` in `.gaia/scripts/spec/uat-gate-route.sh` names them.
