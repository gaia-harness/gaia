# SPEC and plan lifecycle procedures

The procedures a generated `ORCHESTRATOR.md` and both pre-flights point at. `.claude/skills/gaia/references/plan/planner.md` owns the order of the orchestrator's steps and the verbatim blocks a planner copies; this page owns what each step does. Every command runs from the directory each section names, with the placeholders the orchestrator holds: `<SPEC_PATH>` (the absolute, main-anchored `SPEC.md`, stored in the main checkout: the clone's primary working directory, on any branch), `<PLAN_DIR>` (the absolute, main-anchored plan folder), `<RESOLVED_ROOT>` (the working copy the isolation reference resolved) and `<N>` (the PR number).

Contents: Pre-audit flow checks; Consolidation; Post-merge close; Pre-flight sweep.

## Pre-audit flow checks

For a spec-derived plan written with a closing flow-test phase, the orchestrator's `flow-checks` block runs after the last phase commits and before the worthiness step, from `<RESOLVED_ROOT>`:

```bash
bash .gaia/scripts/spec/flow-coverage.sh --spec <SPEC_PATH> --root <RESOLVED_ROOT> --flow-tests-out <RUN_FOLDER>/flow-tests.tsv
```

`<RUN_FOLDER>` is the branch's run folder (`.claude/doctrine/execution.md`, `## Run folder`). The script checks that each SPEC flow has its test file and that the branch changed it, and for a web flow that the spec is in the Playwright listing and its `@covers` header names every SPEC folder the branch changed; it also scans each flow test for a working-document id. It writes `<RUN_FOLDER>/flow-tests.tsv`, one row per flow whose test exists, which the worthiness step reads as its flow inputs and the merge-time presence gate reads so that a changed test in a listed flow file with no recorded worthiness verdict denies the merge.

- Exit 0: every flow passed; the block records a `## Flow checks` block and goes on.
- Exit 1: one or more findings, one stdout line each; the block's one fixer round runs, then the script runs once more.
- Exit 2: a usage error or a refused SPEC (a `uats:` key, or no `flows:`); the block halts.
- Exit 3: an operational failure, such as a Playwright listing that could not run; the block halts.

The fixer, the retry bound of one and the `## Flow checks (HALTED)` record are the `flow-checks` block's, in `.claude/skills/gaia/references/plan/planner.md`. A failure here is a HALT, never an audit finding to fix inside a fix round.

## Consolidation

The one consolidation recipe. Four callers run it:

- **The pre-audit pass.** The orchestrator, after the worthiness step and before the first member dispatch. It always attempts promotion.
- **The post-clearance refresh.** The orchestrator, after audit clearance and the merge question's `Merge it` answer. It rewrites `SUMMARY.md` against the audited code, uncommitted, and attempts promotion only when it reaches `wiki-promote.md`'s Step 2.
- **The cold sweep.** The pre-flight sweep's cold consolidation, against a folder whose PR already merged. It accepts an interrupted run's pre-audit `SUMMARY.md` as the last complete summary: a verified one is no candidate, and an unverified one is rewritten from the layers.
- **A plan generated before this order.** Its own orchestrator block consolidates after clearance and keeps that block's continuation. It may omit `Pass:` from its record, so a plan running its old block needs no new reading of this page.

**Synthesis.** The caller (the warm orchestrator, or the session running the sweep; never a task sub-agent) writes `SUMMARY.md` by layered override-resolution: read the layers in precedence `SPEC.md`, then `AUDIT.md`, then the plan's `PROGRESS.md`; the top layer wins on conflict. A spec-less plan has no `SPEC.md` or `AUDIT.md`, so its `PROGRESS.md` is the only layer; a cold consolidation reads the plan's `PROGRESS.md` when one is present. Ground the result in the merged code and passing tests, write it present-tense as final-state prose, and surface any material narrowing between the stated intent and the shipped scope under an optional `## Divergence` section. Yield blocks in `PROGRESS.md` are resumption records, not findings, so consolidation ignores them.

**Location.** A spec-colocated plan's `SUMMARY.md` sits beside `SPEC.md`, in the SPEC folder one level above the plan subfolder; a spec-less plan's sits in `<PLAN_DIR>`. Both folders are main-anchored. From a linked worktree, the write follows the tool-choice contract in `.claude/skills/gaia/references/spec.md` Operational primitives, which applies the same way to a spec-less plan folder.

**Shape.** Frontmatter with `wiki_promote_default` and `wiki_promote_targets`, a non-empty H1, a non-empty body, and an optional `## Divergence`.

- `wiki_promote_default` is exactly `yes`, `ask` or `no`. A spec-colocated plan copies the SPEC's value; a spec-less plan stamps `ask`.
- `wiki_promote_targets` for a spec-colocated plan is the SPEC's own list when its frontmatter carries a non-empty one; otherwise consolidation derives it from what shipped, picking every subdomain the merged result belongs in from `decisions` (a choice between alternatives and its rationale), `concepts` (a mechanism or behavior that spans files), `modules` (one component's architecture), `flows` (an end-to-end sequence) and `dependencies` (a third-party package's role), at least one. The SPEC template carries no list, so derivation is the normal path. A spec-less plan stamps `[decisions]`.

**Verify.**

```bash
bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
```

Consolidation removes nothing: `SPEC.md`, `AUDIT.md`, `PROGRESS.md` and the plan folder all stay until the post-merge close (or, for a cold consolidation, until the sweep's own removal below). On exit 0 the orchestrator continues to the wiki promotion step. On a non-zero exit the continuation depends on the caller: the pre-audit pass records the outcome below and goes on to the audit, with no commit and nothing removed; the refresh appends a `## Consolidation refresh` block instead and goes on to the merge. Either way the post-merge close then keeps the layers, fail-closed:

```
## Wiki promotion
Pass: pre-audit
Default: <the stamped value>   Choice: skipped-verify-failed
Pages: none   Commit: none
Reason: summary-verify.sh failed: <its first stderr line>
```

Every record a current plan's promotion step writes starts with `Pass: pre-audit` or `Pass: refresh`. The `## Wiki promotion` block is written only by a pass attempting promotion; a refresh that does not attempt it, a verify failure included, appends a `## Consolidation refresh` block, a different heading, so it can never become the last promotion block. The last `## Wiki promotion` block is the run's outcome. A block recording `promoted` is never promoted again in the run.

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
4. **Clean up.** Run `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`. Feature-branch mode runs `### Feature branch` with the plan's branch. Worktree mode runs the arm that matches how the worktree was entered (`### Worktree entered by name in this session` or `### Worktree entered by path or in an earlier session`). From an isolated sub-agent context, run its `### Sub-agent context: continuation prompt`, whose appended lines carry steps 5 and 6 for the human to run from the main checkout. A stop at the pre-removal check goes into the close's report with the check's output and the removal commands; the merge itself still counts as done.
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

   A spec-colocated plan subfolder is deleted; a spec-less plan folder is reduced to `SUMMARY.md`, with its `RUNNING` sentinel cleared. The helper leaves the folder untouched until the usage ledger holds a `gaia-plan` close for the run and a consolidated `SUMMARY.md` exists (the parent SPEC's, passing its verifier, for a spec-colocated plan). It always exits 0.

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

- **`/gaia-spec` step 2.** When `citation_query.answered` is false, say the citation check could not run and why (its `reason`), before the question. When `eligible` is non-empty, ask the human once with `AskUserQuestion`: list each slug with its verdict and lead with the option the JSON's `recommended` names, marked ` (Recommended)`, from the three options **Reap all**, **Snooze all** (for another `GAIA_RESEARCH_RETENTION_DAYS` window) and **Keep for now** (asked again next sweep); free text splits the answer per folder. Then run `bash .gaia/scripts/notebook/research-reaper.sh apply` with one `--reap <slug>` or `--snooze <slug>` per decision (none for keep). On exit 7 (non-interactive) or 8 (a slug no longer eligible), print the stderr lines and continue. Also print the `reported` lists (untagged, row-less, loose files) as one line each when non-empty. In auto mode or any unattended run, never ask: print the eligible count and continue.
- **`/gaia-plan` step 0.** Run `list` only and print exactly one line with the eligible count (for example `research: <n> folder(s) eligible to reap; the next /gaia-spec sweep asks`), never asking and never running `apply`, so a chained spec-to-plan session asks at most once.
