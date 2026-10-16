# SPEC and plan lifecycle procedures

The procedures a generated `ORCHESTRATOR.md` and both pre-flights point at. `.claude/skills/gaia/references/plan/planner.md` owns the order of the orchestrator's steps and the verbatim blocks a planner copies; this page owns what each step does. Every command runs from the directory each section names, with the placeholders the orchestrator holds: `<SPEC_PATH>` (the absolute, main-anchored `SPEC.md`), `<PLAN_DIR>` (the absolute, main-anchored plan folder), `<RESOLVED_ROOT>` (the working copy the isolation reference resolved) and `<N>` (the PR number).

Contents: Owning-phase UAT gate; Phase N, <title> (HALTED); Pre-audit UAT checks; Consolidation; Wiki promotion; Post-merge close; Pre-flight sweep.

## Owning-phase UAT gate

**When it runs.** For a spec-derived plan, after `pnpm typecheck && pnpm lint` pass for a phase whose number appears in an `e2e` row of the UAT routing table in `<PLAN_DIR>/README.md`, and before that phase commits. A phase that owns no `e2e` row skips it.

**Command**, from `<RESOLVED_ROOT>`:

```bash
bash .gaia/scripts/spec/uat-gate.sh <SPEC_PATH> --routing <PLAN_DIR>/README.md --phase <N>
```

Here `<N>` is the phase number.

**Prerequisites and cost.** Playwright's Chromium is installed and `pnpm storybook` is stopped (the run boots its own servers). Each run boots two webServers, so budget roughly a minute per owning phase.

**What it checks.** Per owned spec: the file exists and starts with its contract marker; no `test.fail`, `test.fixme`, `test.skip`, `.only` or skipped or fixme `describe` annotation remains; the deterministic floor holds (a `page.` call and an `expect(` on a real value); the contract comment still matches the SPEC UAT; no working-doc id appears in the e2e tree; and Playwright's JSON reporter records every test in the file as passed. Whether the test body still asserts the contract is not decided here: the `uat-fidelity-judge` agent judges it once, in `## Pre-audit UAT checks`.

**Outcome.**

| Exit | Meaning | Action |
|---|---|---|
| 0 | every owned spec passed, or the phase owns none | continue to the phase commit |
| 1 | gate failure; stderr names each failing file and its comma-joined reasons | do not commit; append the block below to `<PLAN_DIR>/PROGRESS.md` and stop |
| 2 | invalid input (SPEC, routing table, arguments) | do not commit; append a `## Phase N, <title> (HALTED)` block with `Reason: UAT gate input invalid` and the stderr line, and stop |
| 4 | Playwright could not run (no browser, port held, server failed to boot) | do not commit; append a `## Phase N, <title> (HALTED)` block with `Reason: UAT gate prerequisite missing` naming the prerequisite from stderr, and stop |

```
## Phase N, <title> (HALTED)
Reason: UAT gate failed
Spec files: <each failing path and its reasons, from uat-gate.sh's stderr>
```

A HALTED phase block carries no `Commit:` line, so a resume re-runs the phase. A yield block (`## Phase N, <title> (YIELD k)`, format owned by `plan/planner.md`) carries no `Commit:` line either.

## Pre-audit UAT checks

For a spec-derived plan, after the last phase commits and before the final summary and the pre-merge Code Audit Team audit, from `<RESOLVED_ROOT>`:

```bash
bash .gaia/scripts/spec/uat-gate.sh <SPEC_PATH> --routing <PLAN_DIR>/README.md --all
```

`--all` runs the same checks over every `e2e` row, which includes the divergence check and the working-doc id scan across every rendered spec. A non-zero exit is a HALT: stop and surface stderr. It is never an audit finding to fix inside a fix round.

Then confirm the render landed before the first phase. When `<PLAN_DIR>/PROGRESS.md`'s first `## UAT render` block carries a `Commit: <short-sha>` (not `none`, not `Skipped:`), take the Phase 1 SHA from the last `## Phase 1` block carrying a `Commit:` line and run:

```bash
git -C <RESOLVED_ROOT> merge-base --is-ancestor <render sha> <Phase 1 sha>
```

A non-zero exit is a HALT naming both SHAs: Phase 1 was committed without the rendered red specs under it.

Then judge the test bodies. The gate proves each spec still carries its contract and passes, but never reads the body, so a body can keep its contract comment and stop asserting it. That judgment goes to one fresh `uat-fidelity-judge` agent per run, never to the orchestrator, which would be grading its own phases' work. Skip this step when the gate printed `no owned e2e specs`.

1. Pre-clear the verdict file: `rm -f <PLAN_DIR>/uat-fidelity.json`.
2. Dispatch `Agent(subagent_type: "uat-fidelity-judge")` with a prompt of these lines, one `Spec:` line per `e2e` row of the routing table in `<PLAN_DIR>/README.md`, the path joined from `<RESOLVED_ROOT>`, the frontend package, `.playwright/e2e/`, the row's `feature_folder` and its `file_name`:

   ```
   SPEC path: <SPEC_PATH>
   Verdict file: <PLAN_DIR>/uat-fidelity.json
   Spec: <uat_id> <absolute path of the rendered spec>
   ```

3. Wait for the agent's completion notification, never classifying when the dispatch call returns, then classify the file, which is a JSON array with one entry per `Spec:` line:

   ```bash
   bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <PLAN_DIR>/uat-fidelity.json --expect-count <number of Spec lines>
   ```

   Exit 1 is a no-op: re-dispatch exactly once against the re-cleared path. A second consecutive no-op is a HALT, never a judgment the orchestrator makes itself. Its message names the verdict file and the specs from the `Spec:` lines, and gives the next step: resume the plan to run this step again, or have a human read each listed spec against its contract, then tell the orchestrator to continue to the final summary when every body still asserts it, or fix a diverging one as step 4 states.
4. Halt on any divergence:

   ```bash
   jq -e 'all(.[]; .verdict == "asserts")' <PLAN_DIR>/uat-fidelity.json
   ```

   A non-zero exit is a HALT: surface each `diverges` entry's file and reason. The fix is implementing the behavior or reopening the SPEC (`.claude/skills/gaia/references/spec/uat-divergence.md` `## Reopen`), never an edit to the contract comment and never re-adding `test.fail()`. Like the gate, it is never an audit finding to fix inside a fix round.

## Consolidation

The one consolidation recipe. Two callers run it: the orchestrator, after audit clearance and the human's ready-to-merge confirmation, and the pre-flight sweep's cold consolidation, against a folder whose PR already merged.

**Synthesis.** The caller (the warm orchestrator, or the session running the sweep; never a task sub-agent) writes `SUMMARY.md` by layered override-resolution: read the layers in precedence `SPEC.md`, then `AUDIT.md`, then the plan's `PROGRESS.md`; the top layer wins on conflict. A spec-less plan has no `SPEC.md` or `AUDIT.md`, so its `PROGRESS.md` is the only layer; a cold consolidation reads the plan's `PROGRESS.md` when one is present. Ground the result in the merged code and passing tests, write it present-tense as final-state prose, and surface any material narrowing between the stated intent and the shipped scope under an optional `## Divergence` section. This step is agent synthesis, not a template: a mechanical concatenation cannot resolve conflicts between the layers or judge what "materially narrower" means. Yield blocks in `PROGRESS.md` are resumption records, not findings, so consolidation ignores them.

**Location.** A spec-colocated plan's `SUMMARY.md` sits beside `SPEC.md`, in the SPEC folder one level above the plan subfolder; a spec-less plan's sits in `<PLAN_DIR>`. Both folders are main-anchored. From a linked worktree, the write follows the tool-choice contract in `.claude/skills/gaia/references/spec.md` Operational primitives, which applies the same way to a spec-less plan folder.

**Shape.** Frontmatter with `wiki_promote_default` and `wiki_promote_targets`, a non-empty H1, a non-empty body, and an optional `## Divergence`.

- `wiki_promote_default` is exactly `yes`, `ask` or `no`. A spec-colocated plan copies the SPEC's value, normalizing a legacy `true` to `yes` and `false` to `no`; a spec-less plan stamps `ask`. Consolidation never writes `true` or `false` (`summary-verify.sh` accepts them only so an older `SUMMARY.md` still verifies).
- `wiki_promote_targets` is the SPEC's list, or `[decisions]` for a spec-less plan.

**Verify.**

```bash
bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
```

Consolidation removes nothing: `SPEC.md`, `AUDIT.md`, `PROGRESS.md` and the plan folder all stay until the post-merge close (or, for a cold consolidation, until the sweep's own removal below). On exit 0 the orchestrator continues to the wiki promotion step. On a non-zero exit the orchestrator records the outcome in the wiki promotion record and continues to the merge without promoting; the post-merge close then keeps the layers, fail-closed:

```
## Wiki promotion
Default: <the stamped value>   Choice: skipped-verify-failed
Pages: none   Commit: none
Reason: summary-verify.sh failed: <its first stderr line>
```

## Post-merge close

Runs after `gh pr merge`, in this order. Each step runs only after the one before it.

1. **Confirm the merge.** Run `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`. Only exit 0 with stdout `MERGED` proceeds. On any other exit (`CONFLICTING`, `CHECK_FAILED`, `TIMEOUT`, `CLOSED`, or exit 2, a refusal and never a verdict) stop and surface the verdict: nothing below runs before `MERGED` is confirmed.
2. **Resolve the main checkout.** In worktree mode the cwd is the worktree, whose catalog view is not the main checkout's, so never pass `$PWD`:

   ```bash
   main_root="$(bash .gaia/scripts/main-root-lib.sh)"
   ```

3. **Reconcile the catalog.** Best-effort, never blocking:

   ```bash
   # spec-colocated plan (branch carries the SPEC marker)
   bash .gaia/scripts/spec/spec-reconcile.sh "$main_root" || true
   # spec-less plan: the third argument is the PR number step 1 confirmed MERGED
   bash .gaia/scripts/spec/plan-reconcile.sh "$main_root" "$PLAN_ID" "<N>" || true
   ```

   Passing the confirmed PR number stamps `pr_number` on the plan's catalog row, which the pre-flight sweep's reap reads.
4. **Clean up.** Run `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`. Feature-branch mode runs `### Feature branch` with the plan's branch. Worktree mode runs the arm that matches how the worktree was entered (`### Worktree entered by name in this session` or `### Worktree entered by path or in an earlier session`). From an isolated sub-agent context, run its `### Sub-agent context: continuation prompt`, whose appended lines carry steps 5 and 6 for the human to run from the main checkout.
5. **Verify, then remove the layers.** From the main checkout:

   ```bash
   bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
   ```

   On exit 0, for a spec-colocated plan, `rm <SPEC folder>/SPEC.md <SPEC folder>/AUDIT.md`; a spec-less plan has neither. On a non-zero exit keep both. Either way append to `<PLAN_DIR>/PROGRESS.md`:

   ```
   ## Post-merge close
   SUMMARY verify: <pass | fail: SPEC.md and AUDIT.md kept>
   ```

6. **Archive the plan folder.**

   ```bash
   bash .gaia/scripts/plan-archive.sh <PLAN_DIR>
   ```

   A spec-colocated plan subfolder is deleted; a spec-less plan folder is reduced to `SUMMARY.md`, with its `RUNNING` sentinel cleared. Without a verified `SUMMARY.md` the helper leaves the folder untouched. It always exits 0.

**Retention.** The SPEC folder's `SUMMARY.md` and a reduced spec-less plan folder, stay for `GAIA_SPEC_RETENTION_DAYS` (default 30). Nothing reaps them early; the pre-flight sweep reaps them once past the window.

## Pre-flight sweep

The shared backstop for merges that happened outside an orchestrator, or a close that never finished. `/gaia-spec` step 2 and `/gaia-plan` step 0 both run it, each naming its caller (`/gaia-spec` or `/gaia-plan`) so pass 6 knows whether it may ask. Pass 0 is the one blocking pass; passes 1-6 are best-effort and never block the command that runs the sweep. The order is load-bearing: pass 1's scan stamps the `pr_number` that pass 3's plan candidates and pass 4's confirmed reap read.

**0. Notebook readiness (blocking).**

```bash
bash .gaia/scripts/notebook/notebook-lib.sh require-ready
```

A non-zero exit stops the command that runs the sweep: surface its one stderr line (it names `bash .gaia/scripts/notebook/move.sh run`) and run nothing else. Every later pass would refuse anyway, and a session must not allocate on a machine whose one-time move is still pending.

**1. Reconcile.** Flip finalized rows whose PR merged:

```bash
bash .gaia/scripts/spec/spec-reconcile.sh "$PWD" 2>/dev/null || true
bash .gaia/scripts/spec/plan-reconcile.sh "$PWD" 2>/dev/null || true
```

The plan call is the scan form (no id): it matches `ready` rows, and `merged` rows without a `pr_number`, to their merged PR and stamps `merged_at` and `pr_number`.

**2. Generalized reconcile.**

```bash
bash .gaia/scripts/notebook/reconcile.sh 2>/dev/null || true
```

Show its output lines to the human when non-empty. It registers row-less research folders as `untagged` and changes nothing else.

**3. Cold consolidation.** Find merged folders whose layers were never consolidated: merged spec rows whose folder holds `SPEC.md` or `AUDIT.md` without a verified `SUMMARY.md`, and merged plan rows carrying `pr_number` whose folder holds `PROGRESS.md` without a verified `SUMMARY.md`. The candidates come from the notebook library, and each folder from its `path` verb, which resolves the main checkout itself:

```bash
spec_rows="$(bash .gaia/scripts/notebook/notebook-lib.sh list spec --status merged 2>/dev/null)" || spec_rows="[]"
plan_rows="$(bash .gaia/scripts/notebook/notebook-lib.sh list plan --status merged 2>/dev/null)" || plan_rows="[]"
spec_ids="$(printf '%s' "$spec_rows" | jq -r '.[].id')"
plan_ids="$(printf '%s' "$plan_rows" | jq -r '.[] | select((.pr_number // null) != null) | .id')"
for id in $spec_ids; do
  folder="$(bash .gaia/scripts/notebook/notebook-lib.sh path spec "$id")" || continue
  { [ -f "${folder}/SPEC.md" ] || [ -f "${folder}/AUDIT.md" ]; } || continue
  bash .gaia/scripts/summary-verify.sh "${folder}/SUMMARY.md" >/dev/null 2>&1 && continue
  echo "$folder"
done
for id in $plan_ids; do
  folder="$(bash .gaia/scripts/notebook/notebook-lib.sh path plan "$id")" || continue
  [ -f "${folder}/PROGRESS.md" ] || continue
  bash .gaia/scripts/summary-verify.sh "${folder}/SUMMARY.md" >/dev/null 2>&1 && continue
  echo "$folder"
done
```

The library fails closed when the main checkout is unresolvable: its `list` and `path` calls exit non-zero, the candidate lists stay empty and the pass finds nothing, and a `path` call that exits non-zero skips its folder; never fall back to a relative path, which would read a forked notebook inside a linked worktree.

For each printed folder, run `## Consolidation` above against it as a cold consolidation (for a SPEC folder, the layers include its `plan*/PROGRESS.md` when one is present). On a verify pass, a SPEC folder's PR is already merged, so remove its `SPEC.md` and `AUDIT.md`; a plan folder has no layers to remove. On a failed synthesis or verify, leave everything in place for a later pass. This pass never destroys a layer it failed to replace.

**4. Reap merged past retention.**

```bash
bash .gaia/scripts/spec/spec-archive-merged.sh "$PWD" 2>/dev/null || true
bash .gaia/scripts/spec/plan-archive-merged.sh "$PWD" 2>/dev/null || true
```

Both delete a merged folder once its `merged_at` is past `GAIA_SPEC_RETENTION_DAYS` (default 30), its layers are consolidated, and its cost is represented in the usage ledger; a folder still holding unconsolidated layers or an unrepresented cost is kept. The plan reap takes two kinds of row: rows confirmed against a merged PR (`pr_number`, stamped at the post-merge close or by pass 1's scan) and older merged rows without one, which age out on `merged_at` alone.

**5. Reap abandoned past retention.**

```bash
bash .gaia/scripts/spec/spec-archive-abandoned.sh "$PWD" 2>/dev/null || true
```

Deletes an abandoned SPEC folder once its `abandoned_at` is past the same `GAIA_SPEC_RETENTION_DAYS` window. There is no consolidation or usage-ledger gate: nothing promotes an abandoned SPEC's content, so the age rule alone decides.

**6. Research.**

```bash
bash .gaia/scripts/notebook/research-reaper.sh list
```

Its header owns the output shape, the keep reasons and the exit codes; read it rather than restating them here. What happens next depends on the caller.

- **`/gaia-spec` step 2.** When `citation_query.answered` is false, say the citation check could not run and why (its `reason`), before the question. When `eligible` is non-empty, ask the human once with `AskUserQuestion`: list each slug with its verdict and lead with the option the JSON's `recommended` names, from the three options **Reap all**, **Snooze all** (for another `GAIA_RESEARCH_RETENTION_DAYS` window) and **Keep for now** (asked again next sweep); free text splits the answer per folder. Then run `bash .gaia/scripts/notebook/research-reaper.sh apply` with one `--reap <slug>` or `--snooze <slug>` per decision (none for keep). On exit 7 (non-interactive) or 8 (a slug no longer eligible), print the stderr lines and continue. Also print the `reported` lists (untagged, row-less, loose files) as one line each when non-empty. In auto mode or any unattended run, never ask: print the eligible count and continue.
- **`/gaia-plan` step 0.** Run `list` only and print exactly one line with the eligible count (for example `research: <n> folder(s) eligible to reap; the next /gaia-spec sweep asks`), never asking and never running `apply`, so a chained spec-to-plan session asks at most once.
