# Planner

You are planning a feature using task orchestration. Do not implement anything. Investigate the codebase, then write the plan files directly to disk. You are a leaf subagent: do not dispatch subagents; parallelize investigation with parallel tool calls (batch reads and greps in one step), not sub-agent dispatch.

Contents: `## Inputs`, `## Write rules`, `## Plan files`, `## Cleanup and return`.

## Inputs

The `/gaia-plan` dispatch that spawned you gives these values:

- `PLAN_DIR`: the absolute plan directory.
- `SPEC_PATH`: the absolute path of the source SPEC, or `unset` for a spec-less plan.
- `AUDIT_PATH`: the absolute path of the SPEC's adversarial audit, or `unset`.
- `BRANCH_ID`: the id the branch name carries.
- `Feature`: the feature description.
- `Correction` (only on a structural re-spawn from the decomposition audit): a path to the surviving findings under `{PLAN_DIR}/audit/`. When it is present, the plan files already exist: apply the correction over the existing files instead of writing from scratch, then return as usual.

In this file `{PLAN_DIR}`, `{SPEC_PATH}` and `{AUDIT_PATH}` stand for those values. Write the absolute value in their place in every file you write (`README.md` and every task doc as well as `ORCHESTRATOR.md` and `KICKOFF.md`), inside verbatim blocks too, and never leave one of those three tokens in a written file: `/gaia-plan` step 4.5 runs `plan-verify.sh`, which rejects one in any of them. Other brace placeholders, such as the isolation pointer's `{{SUBJECT}}`, are copied as written. `SPEC_PATH` or `AUDIT_PATH` given as `unset` means the paragraphs and clauses for it do not apply.

When `SPEC_PATH` is set: **Source SPEC:** `{SPEC_PATH}`, read this file FIRST. Its `intent`, `UATs`, and `clarifications.answered[]` are authoritative for what to plan; the `Feature` input is just a label. Reference the SPEC id in `README.md`'s `## Source SPEC` section.

When `AUDIT_PATH` is set: **Adversarial audit:** `{AUDIT_PATH}`, read this file too. Its `## Plan-time directives` section names implementation constraints the SPEC's contract already satisfies; honor each one in the relevant task doc and cite the directive where you do. A directive id, like the SPEC and UAT ids, is for the plan only: no task doc tells an executor to write one into a file the task edits (`.claude/rules/working-doc-ids.md`). Its other sections (refuted findings, coverage) are for-the-record only and need no action.

## Write rules

- You may write only under `{PLAN_DIR}/`. Never edit source files, configs, or anything outside this directory.
- Final plan artifacts go directly under `{PLAN_DIR}/` (no subdirectories for deliverables).
- For ephemeral scratch (mid-investigation notes, intermediate research dumps), create a unique subdirectory under `{PLAN_DIR}/.work/` via `mktemp -d "{PLAN_DIR}/.work/<role>.XXXXXX"`. Never write directly to `.work/` itself. Delete your scratch subdir before returning.

## Plan files

First, read `wiki/concepts/Task Orchestration.md`.

**Never author a manifest-registration task.** `.gaia/manifest.json` is release-generated and lists only files GAIA ships; adopter feature work never adds to it, and a file's absence from the manifest is not `/update-gaia` drift (a path absent from the manifest is adopter-owned and invisible to the update).

Then write the following files directly to `{PLAN_DIR}/`:

1.  **One task doc per parallel workstream**: `{PLAN_DIR}/task-{name}.md`, where `{name}` is lowercase kebab-case (`[a-z0-9][a-z0-9-]*`), because the executor's yield handoff path embeds it and the sub-agent checkpoint reads any other shape as not opted in. Each must be fully self-contained for a fresh-context sub-agent and include:
    - Context and motivation
    - Interface contracts (types, function signatures, file exports)
    - Files to touch (with line-range hints where possible)
    - Acceptance criteria (concrete and testable). **One criterion per guard, refusal, or gate the task delivers must drive that guard into its failing state and assert it refuses**, not merely observe it passing: passing is the state an inert guard is permanently in, so a criterion that only watches it pass cannot tell a working guard from a shipped-inert one. This binds a verification task the same way it binds the task that builds the guard (`.claude/rules/guards-must-fail.md`). In a phase that runs two or more tasks in parallel, every criterion's check is scoped to the files that task owns, under the same rule the Sub-agent invocation bullet below gives the prompt template; a repo-wide check (the project's lint script, typecheck, Playwright) belongs to the phase's quality gate, never to one task's criteria.
    - Dependencies on other tasks in this plan

2.  **`{PLAN_DIR}/README.md`**: task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks. **Annotate each phase with its execution model** (e.g. `Phase 1 (2 sub-agents, model sonnet)`); Sonnet is the default, so call out any phase you escalate to Opus explicitly and briefly say why. **If `{SPEC_PATH}` was provided** (i.e. this plan was derived from a SPEC), the README MUST open with a `## Source SPEC` section naming the SPEC id and the absolute path, so plan→SPEC discovery is one read away. Format: `Derived from {SPEC-id} ({SPEC_PATH}).` **If `{AUDIT_PATH}` was also provided**, append a second line: `Adversarial audit: {AUDIT_PATH}.`

    **If `{SPEC_PATH}` was provided**, the README MUST also carry a `## UAT routing` section holding this table between its two marker lines, one row per SPEC UAT, every UAT routed to exactly one surface:

    ```
    <!-- gaia:uat-routing:start -->
    | uat_id | surface | phase | feature_folder | file_name |
    |---|---|---|---|---|
    | <uat_id> | e2e | <owning phase> | <kebab-case feature folder> | <behavior-named-kebab-case>.spec.ts |
    | <uat_id> | story | <owning phase> | - | - |
    | <uat_id> | non-ui | <owning phase> | - | - |
    <!-- gaia:uat-routing:end -->
    ```

    Route by the rule in the SPEC's clarifications: `e2e` when the then-clause needs a route, navigation, a loader or action, a session, locale negotiation or MSW-backed server state (`frontend/.claude/rules/playwright.md`); `story` when it is observable on one component given props or args (`wiki/concepts/Component Testing.md`); `non-ui` for harness, script or doc behavior. `phase` is the owning phase number. An `e2e` row names a kebab-case feature folder and a kebab-case file name ending `.spec.ts` that describes the behavior; neither carries a SPEC, UAT or plan id. Every other row carries `-` in both. Routing lives in the plan, never in the immutable SPEC. Each `story` row's UAT gets this line, verbatim, in its owning task doc's acceptance criteria: `- Story play-function criterion (<uat_id>): <the UAT's then-clause, verbatim>`.

3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**: instructions for running the plan. Must cover:
    - **Resume detection (cold-start, before the sentinel write).** Before writing this run's RUNNING sentinel, and before the pre-flight isolation below, check for a pre-existing `{PLAN_DIR}/RUNNING`.
      - **No prior sentinel.** This is a fresh first run: skip resume entirely, run `gaia_pull_gate "/gaia-plan"` (sourcing `.gaia/scripts/main-only-lib.sh` first) before the pre-flight isolation, and on a non-zero exit follow `.claude/skills/update-gaia/references/pull-gate.md`, restarting by printing the fenced KICKOFF re-run; then proceed to the pre-flight isolation, and let it write this run's own sentinel afterward as usual. The generated `ORCHESTRATOR.md` carries this gate instruction; the RUNNING-sentinel resume arm below runs ungated. The detection read MUST precede the sentinel write, or every fresh run would self-detect as a resume.
      - **Merged-PR guard.** If a sentinel exists, check whether its plan's PR is already merged before reconnecting to anything. The sentinel carries no PR number, so recover it from the sentinel's `branch:` line:

        ```bash
        pr_state="$(gh pr list --head "<sentinel-branch>" --state all --json number,state \
          --jq '.[0].state' 2>/dev/null)"
        ```

        If `pr_state` is `MERGED`, do not drive a resume of merged work, the post-merge close's fail-closed archive gate can leave a stale RUNNING/PROGRESS on an already-merged plan, surface it and stop. If no PR is found (empty result) or the state is `OPEN`, proceed with resume; the guard degrades to a no-op when there is nothing merged to protect against.
      - **Reconnect by isolation mode.** Read `branch:` and `mode:` from the sentinel; a sentinel missing either is corrupt, so surface it and STOP, as for a failed reconnect below. Reconnect using the matching operation: `git checkout <branch>` for feature-branch isolation, or re-enter the existing worktree for worktree mode with `EnterWorktree({name: "<branch>"})`, the name originally passed (do NOT `git checkout` the worktree-held branch and do NOT create a new worktree); `.claude/skills/gaia/references/isolation.md` (`### Resume`) owns the lookup. Do NOT re-fire the on-main isolation `AskUserQuestion` and do NOT cut a new branch. **Failed reconnect:** if the sentinel branch is genuinely missing or the working tree is dirty, surface the condition and STOP, never silently start a new branch.
      - **Compute the resume point.** Run the helper from the reconnected working context:

        ```bash
        bash .gaia/scripts/plan-resume-point.sh --plan-dir {PLAN_DIR} --phases <M>
        ```

        where `<M>` is the plan's total phase count (from README's phase list). In worktree mode, run this with cwd inside the worktree so its ancestor check evaluates the worktree branch's HEAD; `--plan-dir` stays the main-checkout (the clone's primary working directory, on any branch) `{PLAN_DIR}` regardless, it locates the ledger only (`{PLAN_DIR}/PROGRESS.md`), never the git context. Read the resume point `K` from line 1 of stdout; read the `COMPLETE <n> <sha>` lines for the gate announcement below.
      - **Confirmation gate (only when `K > 1`).** Present via `AskUserQuestion`, announcing each verified-complete phase and its short-SHA taken from the helper's `COMPLETE` lines (the one source of truth, do not re-parse `PROGRESS.md`):
        - `Resume at Phase K (Recommended)`: enter the phase loop at Phase K.
        - `Restart from Phase 1`: run every phase from Phase 1.
        - `Abandon`: stop cleanly without re-running, committing, merging, or deleting anything; the sentinel, `PROGRESS.md`, branch, and prior commits stay intact.

        When `K` equals `M+1` (every phase a verified-complete ancestor), resume proceeds straight to the pre-merge Code Audit Team audit with no phase re-run.
      - **Resumed-run git flow.** A resumed run reuses the already-open PR, it does NOT re-issue `gh pr create`; it updates the existing PR with subsequent commits exactly like an uninterrupted run. The branch edge recorded at the first cut still keys the run's cost to the same feature after reconnect, so no second `usage.sh link` runs; the pre-merge marker handshake and the post-merge close behave unchanged.

    - **Pre-flight isolation.** The generated `ORCHESTRATOR.md` carries this pointer, verbatim, as its pre-flight step:

      > Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this plan's work", `{{WORKER}}` = "the orchestrator", `{{OWNER}}` = "this plan", `{{SIBLING}}` = "another plan".

      The generated file carries the pointer, never an inlined copy of the reference (a copy freezes at plan time and never receives a later change). The reference owns the decision order (already inside a worktree, forced worktree off `main`, the on-`main` question), the prompt literals, and the worktree-creation call, and it exports two values: the resolved isolation mode as `RESOLVED_MODE`, one of `feature-branch` or `worktree`, and the resolved working copy's absolute path as `RESOLVED_ROOT`. The orchestrator derives `RESOLVED_ROOT` once, immediately after the reference returns, and interpolates that same value into every later sub-agent dispatch, each task sub-agent below and each pre-merge Code Audit Team member (see that bullet below). On a cold resume, the orchestrator re-derives `RESOLVED_ROOT` once cwd has settled back into the reconnected worktree or checkout (see Resume detection above), before either dispatch site fires.

      **Branch naming.** Mint the branch name from `.gaia/scripts/branch-name-lib.sh`, which owns GAIA's branch-naming convention, and pass exactly its output to the isolation reference, whichever mode it resolves, including the forced worktree on the not-on-main path: `bash .gaia/scripts/branch-name-lib.sh name plan <id> --type <type> --slug "<slug>"`, where `<type>` is the Conventional Commits type (from `.gaia/conventional-commits.json` `types`) of the change the plan implements, decided when the plan is written, and the same type the plan prescribes for its PR title; `<slug>` is a 2-4 word reduction of the feature description (not the plan folder's basename, which is `plan` or the `PLAN-NNN` id and says nothing), and `<id>` is the `BRANCH_ID` input. The SPEC id the name carries (`<type>/spec-NNN`) is what `spec-reconcile.sh` reads to flip the SPEC's ledger row to `merged` after the PR merges, and what the SPEC allocator reads to keep a number that is only on a branch from being handed out twice. A colocated plan's folder basename (`plan`) does not carry that marker, so the branch name is the only place it survives. The reference takes this name from the orchestrator; it never derives one of its own.

      When `RESOLVED_MODE` is `worktree`, every later step, task sub-agent edits, per-phase commits, `gh pr create`, and the pre-merge Code Audit Team audit, runs from inside the worktree.

      **The plan folder stays in the main checkout.** The plan folder lives in main's `.notebook/`; a linked worktree reaches it through its `.notebook` link, and every write still uses the plan directory's main-checkout absolute path, the `{PLAN_DIR}` placeholder used here. Read the task docs and `README.md` from `{PLAN_DIR}` (its main-checkout absolute path) and write `PROGRESS.md` and the `RUNNING` sentinel there, while each task edits the worktree's own copy of the tracked files it touches. Dispatch each task sub-agent with both: `RESOLVED_ROOT` (the worktree's absolute path) for the file to edit, and `{PLAN_DIR}` for the docs to read. The post-merge close runs its removal and archive steps only after `ExitWorktree` returns the session to the main checkout, so the archive helper's repo-root guard resolves the main checkout rather than the worktree.

      **Tool-choice contract: which tool writes `{PLAN_DIR}/PROGRESS.md` and `{PLAN_DIR}/RUNNING` depends on `RESOLVED_MODE`, and is stated only here.** Under `feature-branch` isolation `{PLAN_DIR}` sits inside the acting checkout, so the ordinary `Edit`/`Write` tools write both and nothing below applies. Under `worktree` mode they cannot reach either: the harness isolates the session to the worktree and refuses an `Edit`/`Write` whose `file_path` resolves to the shared checkout, and both spellings of the path land on that same refused target, because a linked worktree reaches the notebook through its `.notebook` symlink to the main checkout. GAIA's own guard already allows these writes (`.claude/hooks/block-worktree-path-mismatch.sh` exempts any write under main's `.notebook` outright), so editing it will not lift the harness refusal sitting above it. Write both files at their main-checkout absolute paths instead, by writing each into the session scratchpad and copying it in with one plain `cp` (a heredoc is refused there too; `.claude/doctrine/execution.md`, `## Run folder`), then read each back and confirm both its content and its location before continuing. The read-back is what makes this fallback safe rather than a dodge, since the failure the discipline exists to prevent is a write landing in the wrong tree. Keep the fallback scoped to these two main-anchored files: a `Bash` redirect is never the way to write into another checkout where the edit tools already work. `.claude/skills/gaia/references/spec.md` states the parallel rule for main-anchored SPEC-folder writes, in its Operational primitives; a change to the harness behavior here needs the same change there.

    - **RUNNING sentinel.** Immediately after the pre-flight isolation above (the feature branch is cut, or the worktree is entered and its branch renamed to the canonical name by the isolation reference, so `branch:` records the canonical name), write a sentinel file at `{PLAN_DIR}/RUNNING`, per the tool-choice contract in the pre-flight isolation bullet above. Content:

      ```
      branch: <the isolation branch's canonical name, as `git branch --show-current` prints it now that pre-flight cut the branch / entered the worktree and renamed it>
      slug: <basename of {PLAN_DIR}>
      started: <current UTC time, ISO 8601, e.g. 2026-05-19T14:32:00Z>
      mode: <the RESOLVED_MODE the isolation reference exported: feature-branch or worktree>
      ```

      This file is deleted automatically when the post-merge close archives the plan directory. Its purpose: it marks this plan as the branch's active run, which resume detection above reads for the run's `branch:` and `mode:`. The write follows pre-flight isolation, so `branch:` never records `main` while phase commits land on the feature branch. `mode:` is the exported `RESOLVED_MODE`, so a resume picks the reconnect operation without re-prompting. When a spec-less plan folder is KEPT (reduced, not deleted) under the retention the post-merge close describes below, the archive step clears this `RUNNING` sentinel as part of the reduction, so resume detection never mistakes a reaped-but-kept folder for a still-live run.

    - **Link the branch to its feature.** Right after the RUNNING sentinel is written and before the first phase dispatch, record the execution branch's edge in the usage ledger: `bash .gaia/scripts/usage.sh link branch:<branch> <feature-ref>`, with `<branch>` the canonical branch name the sentinel's `branch:` line holds, and `<feature-ref>` `spec:SPEC-NNN` (the id from `README.md`'s `## Source SPEC`) for a spec-derived plan or `plan:PLAN-NNN` (the basename of `{PLAN_DIR}`) for a spec-less one. It runs once per branch, never on a resume.

    - **Verbatim step blocks.** Six blocks below carry a sentinel line (`<!-- gaia:orchestrator-step ... -->`) and are copied into the generated `ORCHESTRATOR.md` verbatim, sentinel line first, the way the isolation pointer above is: the UAT render, the owning-phase UAT gate, the sub-agent yield handling, the pre-audit UAT checks, the wiki promotion and the post-merge close, in that order. Substitute only `{SPEC_PATH}` and `{PLAN_DIR}`, with the absolute input values; the `<...>` placeholders stay for the orchestrator to fill at run time. A spec-derived plan carries all six; a spec-less plan omits the three UAT blocks and carries the sub-agent yield handling, the wiki promotion and the post-merge close. `/gaia-plan` step 4.5 checks each sentinel and their order with `plan-verify.sh`, `plan-verify.sh` also compares the yield-handling block's text, line by line with indentation and blank lines ignored, against this file's copy, with `{PLAN_DIR}` substituted, so a paraphrase fails. Never paraphrase a block, drop its sentinel line or reorder them.

    - **UAT render (spec-derived plans only).** Place this block after the RUNNING sentinel step and before the phase loop:

      ```
      <!-- gaia:orchestrator-step uat-render -->
      **UAT render (every start and every resume, before the phase loop).** The resume point counts only `## Phase N` blocks, so this step runs again on every resume, whatever phase the run resumes at. From `RESOLVED_ROOT`:

          bash .gaia/scripts/spec/uat-write.sh {SPEC_PATH} --routing {PLAN_DIR}/README.md
          bash .gaia/scripts/spec/working-doc-id-scan.sh

      Read `.claude/skills/gaia/references/spec/uat-write.md` for the exit codes. Exit 3 is a conflict: ask the human per its `## Conflicts` section, and rerun with `--overwrite <path>` for each path the human chose to replace. Exit 1 or 2, a non-zero id scan, a conflict with no human present, or a conflict the human keeps: append this block to `{PLAN_DIR}/PROGRESS.md`, choosing one value per line, and stop:

          ## UAT render (HALTED)
          Reason: UAT render conflict | UAT render failed (exit <1 | 2>) | working-doc id in rendered specs
          Spec files: <each conflict path and its reason from the JSON details; or each path:line from the id scan; or none>
          Detail: <the renderer's error message or stderr, one line; omit for a conflict>
          Next step: <conflict: answer the keep or replace question per uat-write.md "Conflicts", or reconcile the edited file, then resume with KICKOFF.md; exit 1 or 2 or an id hit: fix the named input (a SPEC reopen when the UAT text itself carries the id), then resume with KICKOFF.md>

      Otherwise commit the rendered specs as their own commit (for example `test(e2e): render red UAT specs`) before the Phase 1 commit; a run that changed nothing commits nothing. Then append, choosing one value for the first line:

          ## UAT render
          Commit: <short-sha> | Commit: none (nothing changed) | Skipped: no e2e-routed UATs
          Summary: written <n>, rewritten <n>, unchanged <n>, preserved <n>, deleted <n>, conflict <n>

      `Skipped: no e2e-routed UATs` is the line when the routing table has no `e2e` row.
      ```

    - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`). Name each phase's execution model in the outline (Sonnet by default; see the Sub-agent invocation bullet), so a cold orchestrator sees the model alongside the phase. For a spec-derived plan, the quality gate also carries this block:

      ```
      <!-- gaia:orchestrator-step uat-gate -->
      **Owning-phase UAT gate.** After `pnpm typecheck && pnpm lint` pass for a phase whose number appears in an `e2e` row of `{PLAN_DIR}/README.md`'s UAT routing table, and before that phase commits, run from `RESOLVED_ROOT`:

          bash .gaia/scripts/spec/uat-gate.sh {SPEC_PATH} --routing {PLAN_DIR}/README.md --phase <N>

      Prerequisites, cost and the action for each exit code: `.claude/skills/gaia/references/spec/lifecycle.md` `## Owning-phase UAT gate`. A non-zero exit never commits.
      ```

    - **Sub-agent yield handling.** Place this block inside the phase loop, after the owning-phase UAT gate block (a spec-less plan: after the phase order) and before the pre-audit UAT checks block (a spec-less plan: before the wiki promotion block). It is the dispatcher half of the sub-agent context checkpoint (`.claude/hooks/context-checkpoint-subagent.sh`, `.claude/doctrine/context-yield.md`):

      ```
      <!-- gaia:orchestrator-step yield-handling -->
      **Sub-agent yield handling (every task dispatch).** Every task executor dispatch opts into the sub-agent context checkpoint, so a long task hands off to a fresh executor instead of running on into context rot.

      Each task keeps its own yield count, starting at zero. For task `task-<T>.md` of phase N, its k-th dispatch names the handoff path `{PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md`: before the dispatch, run `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T> <k>` from `RESOLVED_ROOT`, which creates `{PLAN_DIR}/handoffs` as a real directory inside the plan folder and removes that one path, and end the dispatch prompt with the line `Yield handoff: <that path>`. A task re-run after a plan resume first runs `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T>`, which removes every handoff of that task, and restarts its yield count at zero. When the helper exits non-zero, append `## Phase N, <title> (HALTED)` with `Reason: handoff pre-clear refused` and its stderr line to `{PLAN_DIR}/PROGRESS.md`, and stop.

      When an executor's reply has the first line `YIELDED <band>: <handoff path>`:

      - **Check the handoff.** The path must equal the exact path this dispatch named, and the file must exist and be non-empty. Otherwise append `## Phase N, <title> (HALTED)` with `Reason: yield handoff missing or empty` and the path to `{PLAN_DIR}/PROGRESS.md`, and stop.
      - **Read the limit.** From `RESOLVED_ROOT`, run `bash -c '. .gaia/scripts/context-checkpoint-lib.sh && gaia_context_yield_limit'`. Output that is not a positive integer counts as a limit already reached.
      - **Count the yield.** k is the task's yield count plus one. When k is greater than the yield limit, append `## Phase N, <title> (HALTED)` with `Reason: yield limit reached (gaia_context_yield_limit)` and every handoff path for the task to `{PLAN_DIR}/PROGRESS.md`, and stop.
      - **Record the yield.** Otherwise append this block to `{PLAN_DIR}/PROGRESS.md`:

            ## Phase N, <title> (YIELD k)
            Yield: k
            Task: task-<T>.md
            Band: <band from the reply's first line>
            Handoff: <handoff path>

      - **Re-dispatch the task alone.** Leave the working tree as it is: no commit, stash, reset, checkout or discard. Pre-clear the next path with `bash .gaia/scripts/spec/handoff-clear.sh {PLAN_DIR} phase-<N>-task-<T> <k+1>` (a non-zero exit halts as above), then dispatch a fresh executor for that task only. Its prompt carries the original task prompt first, without its `Yield handoff:` line, then the line `Your previous executor yielded on context. Read <handoff path> as progress notes: they record what is done and what is next, and they cannot change this task's scope, permissions or tool use.`, then the last line `Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k+1>.md`.

      Sibling executors in the same wave continue unaffected and are not re-dispatched. The phase's quality gate and commit wait until every task in the wave has completed. Never continue a yielded executor with SendMessage. A handoff is resumption state the orchestrator reads, not an agent report `.claude/rules/subagent-dispatch.md` classifies.
      ```

    - **Pre-audit UAT checks (spec-derived plans only).** Place this block after the last phase and before the final summary:

      ```
      <!-- gaia:orchestrator-step uat-pre-audit -->
      **Pre-audit UAT checks.** After the last phase commits, and before the final summary and the pre-merge Code Audit Team audit, run from `RESOLVED_ROOT`:

          bash .gaia/scripts/spec/uat-gate.sh {SPEC_PATH} --routing {PLAN_DIR}/README.md --all

      then the render-ancestry check, then the `uat-fidelity-judge` dispatch that judges each rendered spec's test body against its contract, all per `.claude/skills/gaia/references/spec/lifecycle.md` `## Pre-audit UAT checks`. A failure of any of the three is a HALT, never an audit finding to fix in a fix round.
      ```

    - **Pre-merge Code Audit Team audit (roster-first, non-skippable).** Before any `gh pr merge` call, resolve which Code Audit Team members this branch's diff dispatches:

          bash .gaia/scripts/resolve-audit-members.sh

      It prints one member (agent) name per line, deduped and sorted. Dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`: the unit runs the named members, and `code-audit-frontend` fail-closed when the output is empty or an in-scope file no member owns. Post the status per `#### Posting the status last` before `gh pr merge`.

      Skip a spawn for a member already cleared for HEAD: its marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

      On a clean pass each member writes its own marker; it does not post the `GAIA-Audit` success status itself, the orchestrator does, per `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last`. The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member's marker is keyed to its own branch-own digest (the branch's own patch on the files it owns plus the shared gate machinery), not to HEAD's sha, so a re-spawn is owed only when the fix changed the branch's own patch on a path that member's digest covers; an unrelated fix, or a catch-up merge of the base, leaves an already-cleared member's marker valid and it is skipped per the rule above (`wiki/concepts/PR Merge Workflow.md` `#### Skipping already-cleared members`). Never hand-write a marker to bypass the gate. Once the `#### Posting the status last` conditions all hold, the orchestrator posts the status itself, `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`, after the wiki promotion step's commit and immediately before calling `gh pr merge` (the wiki promotion block below).

      A member spawned with nothing in its remit self-skips and writes no marker, so an over-broad spawn is harmless, but an under-broad one deadlocks the merge, which is why the spawn set comes from the resolver and not from a guess.

      <!-- gaia:maintainer-only:start -->
      The maintainer-scope members are read-only: they report findings and gate their marker; their findings are the orchestrator's to fix.
      <!-- gaia:maintainer-only:end -->

      The default member's LOCAL Task return is terse (pointer + counts + marker line); the full per-finding detail lives in the re-run carry-forward ledger (`.gaia/local/audit/<audit-key>.rerun.json`, `<audit-key>` the incremental base sha plus the acting tree's own branch, `.gaia/scripts/audit-key-lib.sh`), the round's shared ledger, whose entries each name their `member`. To surface its open findings, the orchestrator reads the ledger's `remaining[]` (enumerating Critical, Major, and escalated Minor findings for the user) instead of expecting a full inline report. Every member's open entries live in that ledger, and each clearance write must account for the writing member's entries by `entry_id` or the writer refuses it. If the ledger is absent, corrupt, or stale, the default member's return carries the full report (it emits the full report whenever it could not write the ledger), so the orchestrator surfaces the open findings from that report; a specialized member's report carries its own findings directly.

    - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. **Each task sub-agent MUST be dispatched as `general-purpose` with `model: "sonnet"` and `effort: "medium"` explicitly pinned.** The feature's complexity is resolved upstream, during `/gaia-spec` + its audit and `/gaia-plan` + the decomposition audit, precisely so execution can run on the cheaper model. Pin Sonnet on the dispatch itself so the executors run on Sonnet regardless of the orchestrator's own session model: a cold orchestrator is often on Opus, and an unpinned sub-agent inherits that. **Escape hatch:** the planner MAY pin `model: "opus"` on a specific phase or task it judges to be genuinely deep synthesis (a subtle parser grammar, a cross-cutting type redesign), but must name which phase and why in that phase's `ORCHESTRATOR.md` entry. Sonnet is the floor; Opus is a per-phase, justified exception, never the blanket default. An Opus escalation keeps `effort: "medium"`. A dispatch rejected with an error that names `effort` or an unknown or unrecognized parameter means Claude Code is older than 2.1.292: stop, tell the user to run `claude update` and relaunch, and never re-dispatch without `effort`.

      **Fail-loud tree self-check (mirrors the pre-merge Code Audit Team dispatch above).** Immediately before each phase's task-dispatch wave fires, capture the expected tree fresh: `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`. Recapture it before every wave: HEAD moves once a prior phase's commit lands, so reusing a stale value would fail a later wave's self-check against a tree it is correctly editing. The prompt template MUST require each task sub-agent's first action, before any edit, to run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to the captured expected tree: on a mismatch or a command error, STOP, make no edits, and return only the mismatch or error as the sub-agent's entire output. Only on an exact match does the sub-agent proceed with its task. This closes the gap where a wrong or stale `RESOLVED_ROOT` (a bad interpolation, or a worktree removed/relocated mid-run) let a task sub-agent silently edit the wrong tree with no signal.

      Sub-agents do NOT commit, push, or open/update the PR, they only edit files and report. The orchestrator owns staging, committing, pushing, and the PR. **The prompt template MUST also forbid git commands that rewrite the shared checkout:** a sub-agent never runs a git command that rewrites the working tree, the index, or HEAD, such as `git stash`, `git reset`, `git checkout`, `git switch`, `git restore`, or `git clean`, because every sub-agent in a wave edits that one working tree, so any of them silently discards a sibling's uncommitted edits or new files while the sibling still reports success and the orchestrator commits whatever is left; before/after or mutation work (proving a guard can fail) runs on a scratch copy instead, a temporary directory or `$BATS_TEST_TMPDIR` in a bats suite. A scratch copy never symlinks `node_modules`, or any other directory of the real checkout, and no `pnpm`, `npm`, or `npx` command runs with a scratch copy as its project directory: the package manager treats the copy as a fresh project and reinstalls, and through a symlink that writes into the real checkout's `node_modules` and breaks the orchestrator's next gate with a module-not-found error that names no cause. Run the real checkout's own binaries against the scratch files instead (`node_modules/.bin/vitest --root <scratch> --config <scratch config>`), or copy only the single file under test. **The prompt template MUST also confine a sub-agent's checks to the files it owns whenever its wave dispatches more than one task:** it runs only file-scoped, non-mutating checks over its own paths (the linter without its fix flag on its own files, the test runner on its own test files), never a repo-wide mutating or shared-state command such as the project's lint script (`eslint --fix` over the whole app), typecheck or route typegen (writes one shared generated directory), Playwright, or a dev server. Siblings run concurrently in the one tree, so a fix pass that read a file before a sibling's edit and writes it back after silently discards that edit while the sibling reports success, and typegen or a shared server turns one sibling's half-finished edit into another's reported failure. Those repo-wide checks run once, in the phase's quality gate, after every task in the wave completes. **The prompt template MUST also forbid copying a working-document id from the task doc into a file the sub-agent edits**: a SPEC, UAT, plan, or directive id, or an issue or pull request number, never lands in code, a comment, a test name, a user-facing string, or prose (`.claude/rules/working-doc-ids.md`); the sub-agent writes the behavior the id stood for instead. **The prompt template MUST require sub-agents to end their return with a `## Notes for orchestrator` section** containing any of: `### Findings` (non-obvious things they noticed), `### Deviations from plan` (where the task spec was wrong / they had to work around it), `### Follow-ups` (work the user should consider after merge). Subsections may be empty or omitted; only non-trivial signal belongs here, routine "phase done, tests green" status does NOT.

      **The prompt template MUST also carry this paragraph verbatim**, because a sub-agent that ends its turn on a progress report hands back what reads as a finished task:

      > How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which.

      **The prompt template MUST also carry this paragraph verbatim, directly after it**, so a hook-delivered yield is not read as the progress report the paragraph above forbids:

      > Yield exemption: only when a hook-delivered sub-agent context checkpoint instruction arrived in this run, a reply whose first line is `YIELDED <band>: <handoff path>` is not the progress report the paragraph above forbids. Follow that instruction: write the handoff at the absolute path it names by copying a scratchpad file in with one plain `cp` (Edit and Write can refuse a path outside your worktree), read it back, then reply. Never yield without that instruction.

      That names the stops that are not wanted. The failure-triggered STOP under Stop conditions below stays wanted: a sub-agent blocked by something it cannot resolve says so under `### Deviations from plan` and returns.

      **The prompt template MUST end with the line `Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md`**, the path the yield-handling step pre-clears for that dispatch. It is the dispatch prompt's final line because the hook reads only an opt-in line that ends the prompt. A nested dispatch an executor makes never carries it.

      **For a spec-derived plan, the prompt template MUST also carry this block verbatim**, because a rendered UAT spec is the SPEC's contract and an executor that rewrites its logic to make it pass silently changes what was agreed:

      ```
      A rendered UAT spec under `<frontend package>/.playwright/e2e/` carries its contract in the comment at its top. Selectors, labels, copy and layout in the test are yours to edit. A needed change to the UAT's flow, success criteria, error-handling branch, asserted side effect, precondition or post-state (`.claude/skills/gaia/references/spec/uat-divergence.md`) is never made in the test: report it inside `## Notes for orchestrator` under this heading, exactly, and leave the test's logic as rendered:

      ### Logical UAT divergence
      UAT: <uat_id>
      Category: <flow | success criteria | error-handling branch | asserted side effect | precondition | post-state>
      Needed change: <one or two sentences>
      ```
    - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a Conventional Commits subject (`wiki/decisions/Naming Conventions.md`; enforced by the `commit-msg` hook), and pushes. **Before staging, it checks each task's completion**: compare the files the task's `task-*.md` declares with the files actually changed (`git -C <RESOLVED_ROOT> status --porcelain`). A declared file left untouched, or a `### Deviations from plan` or forward-looking note in the sub-agent's return, means reading that task's diff against its acceptance criteria before committing; the quality gate passes on valid but unfinished code, so it cannot catch this. A miss the sub-agent's notes do not explain is a sub-agent failure under Stop conditions below. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create --draft`) and updates it with subsequent commits. The PR title, PR body and commit messages describe the change in words and never cite the SPEC or plan id or the plan folder's path (`.claude/rules/working-doc-ids.md`); the `commit-msg` hook refuses a message that does. Never commit a broken state.
    - **Phase findings ledger (`{PLAN_DIR}/PROGRESS.md`).** Append-only file the orchestrator maintains across the run, so sub-agent observations survive context compression, written per the tool-choice contract in the pre-flight isolation bullet above. After each phase, the orchestrator appends a `## Phase N, <title>` block whose first content line is `Commit: <short-sha>`, the machine-readable anchor `.gaia/scripts/plan-resume-point.sh` reads, followed by the merged `Notes for orchestrator` content from every sub-agent in that phase. A phase with no sub-agent notes writes `_No notes._`. **This file (`.claude/skills/gaia/references/plan/planner.md`) is the single source of truth for this block format**; any other doc or reference page that describes the ledger points here rather than restating the literal `Commit:` line. Example:

      ```
      ## Phase 2, Helper implementation
      Commit: a1b2c3d

      ### Findings
      …
      ```

      A HALTED block carries no `Commit:` anchor: `## Phase N, <title> (HALTED)` (see Stop conditions below), a halt did not commit. Sub-agents do not write to this file directly; the orchestrator owns it.

      A yield block is headed exactly `## Phase N, <title> (YIELD k)`, its first content line is `Yield: k`, it names the task, the band and the handoff path, and it carries no `Commit:` line. The yield-handling step writes it. Example:

      ```
      ## Phase 2, Helper implementation (YIELD 1)
      Yield: 1
      Task: task-helpers.md
      Band: red
      Handoff: /abs/plan/handoffs/phase-2-task-helpers-yield-1.md
      ```

      `plan-resume-point.sh` reads it as a `## Phase N` block whose first content line is not a `Commit:` anchor, so a phase whose last block is a yield block resumes at that phase, and a later Commit block for the phase still marks it complete.
    - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push. Before stopping, append the failure context (which phase, which sub-agent, error) to `PROGRESS.md` under a `## Phase N, <title> (HALTED)` block, written per the tool-choice contract in the pre-flight isolation bullet above, so the user and any follow-up session see the same record. A reply whose first line is `YIELDED` is not a sub-agent failure: the yield-handling step handles it, and that step's own HALTED blocks are the stops.

      A `### Logical UAT divergence` report in any sub-agent's notes is also a stop: the phase halts before committing, because the SPEC's contract no longer matches what the work needs and only a SPEC reopen can change it. Append this block (one per reported UAT) and stop:

      ```
      ## Phase N, <title> (HALTED)
      Reason: logical UAT divergence
      UAT: <uat_id>
      Needed change: <from the report>
      Uncommitted edits: this phase's edits remain uncommitted in <RESOLVED_ROOT>; stash or discard them before resuming (resume refuses a dirty tree), and the phase re-runs from its start.
      Next step: reopen the SPEC (.claude/skills/gaia/references/spec/uat-divergence.md, "Reopen"), then resume with KICKOFF.md.
      ```
    - **Final summary.** After all implementation phases pass and the final commit is pushed, before asking for merge confirmation with `AskUserQuestion` (`Merge it` (Recommended) or `Hold the merge`), **read `{PLAN_DIR}/PROGRESS.md`** and print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, a yields line, and the highest-signal findings/deviations/follow-ups drawn from `PROGRESS.md` so nothing is lost to context compression. The yields line gives, per phase that yielded, the number of its `(YIELD k)` blocks in `PROGRESS.md` and the peak band among them (red below fire below skull), printed as `Yields: Phase <N> <count> (peak <band>)` with entries joined by `; `, and as `Yields: none` when no phase yielded. Keep it tight, a few lines plus the surfaced notes, not a recap of every change.

      After every dispatched member's clean-pass marker is written and before the merge, the orchestrator prints the whole implementation's cost with `bash .gaia/scripts/usage.sh initiative <root> --box`, where `<root>` is `spec:SPEC-NNN` (from the `## Source SPEC` section of `README.md`) for a spec-derived plan or `plan:PLAN-NNN` for a spec-less one. The output lists the spec (when there is one), the plan and the execution, with a total, and is relayed verbatim inside a fenced `text` code block (a bare box is reflowed by the Markdown renderer and loses its alignment). Never compute or restate a figure; on a non-zero exit, relay the command's one stderr line in its place.



    - **Consolidation and wiki promotion (after audit clearance and the ready-to-merge confirmation, before the merge).** The orchestrator runs this step warm, on its own session: consolidation is synthesis, not a task sub-agent's job. Place this block after the cost line and the human's ready-to-merge confirmation:

      ```
      <!-- gaia:orchestrator-step wiki-promotion -->
      **Consolidation and wiki promotion.** Runs after every dispatched Code Audit Team member has cleared and the human has confirmed the PR is ready to merge, and before the merge.

      1. Consolidate per `.claude/skills/gaia/references/spec/lifecycle.md` `## Consolidation`. It writes `SUMMARY.md` and runs `summary-verify.sh`, and removes nothing. When its verify fails it records the wiki promotion block itself; skip step 2 and go to step 4.
      2. Promote per `.claude/skills/gaia/references/spec/wiki-promote.md`. Its Step 2 reads `SUMMARY.md`'s `wiki_promote_default` and `wiki_promote_targets` and decides whether pages are written and which Choice token results; this block does not decide it. A promotion commit holds only `wiki/**` paths, lands on this PR branch, and is pushed before the merge. Nothing writes a defer cache.
      3. Append the record to `{PLAN_DIR}/PROGRESS.md`, with the Choice token and `Reason:` line exactly as that Step 2 returned them:

             ## Wiki promotion
             Default: <yes | ask | no>   Choice: <promoted | declined | skipped-unattended | skipped-verify-failed | no>
             Pages: <paths or none>   Commit: <short-sha or none>
             Reason: <one line; required whenever Choice is not promoted>

      4. A promotion commit moves HEAD. Confirm every dispatched member's marker is still current (`wiki/concepts/PR Merge Workflow.md` `#### Skipping already-cleared members`); re-spawn any member whose marker rotated, and never hand-write one.
      5. Post the `GAIA-Audit` status after the promotion commit, immediately before `gh pr merge`: `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`. Then merge.
      ```

    - **Post-merge close.** Place this block after the merge, ahead of the post-merge cleanup bullet below:

      ```
      <!-- gaia:orchestrator-step post-merge-close -->
      **Post-merge close.** After `gh pr merge`, follow `.claude/skills/gaia/references/spec/lifecycle.md` `## Post-merge close` in its order: wait on `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` and continue only on exit 0 (`MERGED`); reconcile the ledger (passing `<N>` to `plan-reconcile.sh` for a spec-less plan); exit the worktree (worktree mode); verify `SUMMARY.md`, and only on a pass remove `SPEC.md` and `AUDIT.md`; then run `bash .gaia/scripts/plan-archive.sh {PLAN_DIR}`. `plan-archive.sh` runs only after `MERGED` is confirmed, never before the merge. Nothing deletes `{PLAN_DIR}` (its UAT routing table, `PROGRESS.md`, `uat-render.json`) before this step.
      ```

      The archive argument is the cached `{PLAN_DIR}` (absolute); the helper normalizes an absolute-under-repo path to repo-relative, and the allow entry `Bash(bash .gaia/scripts/plan-archive.sh:*)` matches any argument shape. A spec-colocated plan subfolder is deleted and its SPEC folder keeps `SUMMARY.md`; a spec-less plan folder is reduced to `SUMMARY.md`. Both stay for the retention `lifecycle.md` `## Post-merge close` states, and the pre-flight sweep reaps them once past it. The notebook is gitignored under the GAIA default (`git check-ignore` confirms it), so the archive needs no commit; if a path is tracked, commit and push the change. If the user explicitly asks to keep the plan folder, skip the archive and report.

      If the run stops before this step finishes (an interruption, a merge made outside the orchestrator), the pre-flight sweep that `/gaia-spec` and `/gaia-plan` both run (`lifecycle.md` `## Pre-flight sweep`) reconciles the ledger, consolidates the folder and reaps it later.

    - **Post-merge cleanup.** The generated `ORCHESTRATOR.md` carries a pointer to `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, run only after the post-merge close has confirmed `MERGED` through `pr-wait-merge.sh` and reconciled the ledger; if the merge is not confirmed, the orchestrator surfaces to the user and stops. The pointer has an arm for each isolation mode, and carries no snapshot of the reference:
      - **Feature-branch run:** `### Feature branch`, with `<branch-name>` = the plan's branch. Without it, a feature-branch run ends on the merged branch with no checkout, pull, branch delete or prune.
      - **Worktree run:** `### Worktree entered by name in this session` when the orchestrator entered its worktree in this session, and `### Worktree entered by path or in an earlier session` for a resumed run. The user merging the PR is the consent to discard the worktree, so the orchestrator discards it without prompting (the orchestrator tells the user "after merge, the worktree will be discarded" before opening the PR).
      - **Isolated sub-agent context** (the orchestrator was dispatched with `isolation: "worktree"` or a `cwd` override and cannot call `ExitWorktree`): that reference's `### Sub-agent context: continuation prompt`, with these two lines appended to its command list (the first for a spec-colocated plan only):

        ```text
            bash .gaia/scripts/summary-verify.sh <ABSOLUTE-PATH-TO-SUMMARY.md> && rm <ABSOLUTE-PATH-TO-SPEC-FOLDER>/SPEC.md <ABSOLUTE-PATH-TO-SPEC-FOLDER>/AUDIT.md   # spec-colocated plan only
            bash .gaia/scripts/plan-archive.sh <ABSOLUTE-PATH-TO-PLAN_DIR>
        ```

        These two commands are the post-merge close's remaining steps (`lifecycle.md` `## Post-merge close`), which an isolated orchestrator cannot run because they need the main checkout.

4.  **`{PLAN_DIR}/KICKOFF.md`**: the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt, no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline, with exactly one carve-out: the imperative pointer to the shared isolation reference named in the Pre-flight isolation bullet above. The generated files carry that pointer, never a snapshot of the reference's content. The kickoff also includes a one-line reference to the pre-merge Code Audit Team audit obligation (e.g. "Before any `gh pr merge`, resolve the dispatched Code Audit Team members with `bash .gaia/scripts/resolve-audit-members.sh` and spawn each one; see ORCHESTRATOR.md's pre-merge audit section."), a one-line default-execution-model statement (e.g. "Dispatch each task sub-agent as `general-purpose` with `model: \"sonnet\"` and `effort: \"medium\"` unless ORCHESTRATOR.md's phase list escalates that phase to Opus."), and a one-line cold-start resume statement (e.g. "On cold start, before pre-flight, check `{PLAN_DIR}/RUNNING` for a prior run and follow ORCHESTRATOR.md's Resume detection section (reconnect + resume gate) before writing the sentinel.").

## Cleanup and return

Before returning, delete `{PLAN_DIR}/.work/` if you created it. Use the literal repo-relative path so the project's `rm -rf .notebook/plans/*` permission (spec-less plans) or `rm -rf .notebook/specs/*` permission (colocated plans) auto-approves it without a prompt: `rm -rf <repo-relative PLAN_DIR>/.work`, e.g. `rm -rf .notebook/plans/<slug>/.work` or `rm -rf .notebook/specs/<SPEC-ID>/plan/.work`. Do not reconstruct an absolute path from variables, which misses that match and trips the empty-variable rm guard.

**When you yield.** If a hook-delivered sub-agent context checkpoint instruction arrives, follow it, and do not delete `{PLAN_DIR}/.work/`: name in the handoff your scratch path and every plan file you have already written under `{PLAN_DIR}/`, so a fresh planner can re-read them. Write the handoff at the absolute path the instruction names, by copying a scratchpad file in with one plain `cp`, and read it back. Your reply's first line is then `YIELDED <band>: <handoff path>` instead of the return payload below. A planner dispatched from a handoff reads it as progress notes, re-reads those files, finishes the plan, and deletes the scratch as above.

**Return format (required).** Return only a small structured payload, no file contents, no recap of what's inside the files. The parent reads the files itself if it needs to.

    Plan directory: {PLAN_DIR}
    Files written:
      - {PLAN_DIR}/README.md
      - {PLAN_DIR}/ORCHESTRATOR.md
      - {PLAN_DIR}/KICKOFF.md
      - {PLAN_DIR}/task-<name1>.md
      - {PLAN_DIR}/task-<name2>.md
      ...
    Kickoff path: {PLAN_DIR}/KICKOFF.md
