# Orchestrator template

The one source of the text every generated `ORCHESTRATOR.md` and `KICKOFF.md` shares: the ten fixed step blocks and the generic sections around them. `.gaia/scripts/spec/orchestrator-render.sh` renders a plan's two files from this template and the plan's `orchestrator-parts.md`; `.gaia/scripts/spec/plan-verify.sh` checks the fixed blocks of a rendered `ORCHESTRATOR.md` against this file's copy. Those two scripts, and the suites that pin this file, are its only readers: a planner or a session never reads it. Everything from the first region marker on is rendered text a cold orchestrator executes, not instructions to a planner.

## Header

Every line before the first region marker is this header and is never emitted. Every marker is a line holding only an HTML comment whose text opens with the `gaia:` prefix; this header names each marker by the rest of that text, so no header line reads as a marker or counts as one.

## Marker grammar

Read line by line:

- **Regions.** The marker `template orchestrator` opens the `ORCHESTRATOR.md` region and `template kickoff` opens the `KICKOFF.md` region. Each runs to the next region marker or the end of the file, each appears exactly once, the orchestrator region first, and a region marker line is never emitted.
- **Part slots.** A marker `part <name>`, `<name>` one of `pushes`, `phase-loop`, `phase-entries`, `kickoff-goal` and `kickoff-outline`, is replaced by the body of that part of the parts file.
- **Conditionals.** The markers `render-if spec`, `render-if audit` and `render-if pushes` open a run of lines emitted only when the renderer was given `--spec`, when its `--audit` is not `unset`, or when the parts file holds `## Pushes`, respectively; the marker `render-end` closes the run. Conditionals never nest, and neither marker line is emitted.
- **Fixed blocks.** Each fixed block sits in its own three-backtick fence whose first non-blank content line is its `orchestrator-step <name>` sentinel marker, the block's lines at column 0. The renderer emits a fixed block's content lines without its fence lines; any other fence is emitted as is, fence lines included.
- **Tokens.** Substituted literally on template lines, never inside an inserted part body: the four plan tokens, the names PLAN_DIR, SPEC_PATH, AUDIT_PATH and BRANCH_ID each inside one pair of curly braces, and the renderer's own TITLE (the Title part's first line), BRANCH_TYPE, BRANCH_SLUG and PHASE_COUNT (the number of phase entry lines), written the same way. Inside a fixed block only the plan folder and SPEC path tokens occur. The SPEC path token sits only inside a spec conditional and the audit path token only inside an audit conditional. The isolation pointer's four double-brace names and every angle-bracket runtime placeholder pass through unchanged.
- **Sections after the phase entries.** Every generic section after the `phase-entries` slot opens with its own `## ` heading at column 0 outside a fence, and the first non-blank line after that slot is one, so the last phase entry ends where the slot's text ends.
- **Maintainer-only marker lines** are ordinary lines: emitted as is, balanced, and stripped by the release scrub like those of any other file under `.claude/skills/`.

## Fixed blocks

The ten fixed blocks carry a sentinel line and appear in the orchestrator region in this order: `resume-detection`, `yield-handling`, `gate-retry`, `security-writer`, `simplify-pass`, `flow-checks`, `wiki-promotion`, `code-audit`, `post-clearance` and `post-merge-close`. A spec-derived plan carries all of them; a spec-less plan omits `flow-checks` (it sits inside the spec conditional) and carries the rest. `/gaia-plan` step 4.5 checks each sentinel and their order with `plan-verify.sh`, which also compares the text of the resume-detection, yield-handling, gate-retry, security-writer, simplify-pass, flow-checks, wiki-promotion, code-audit and post-clearance blocks, line by line with indentation and blank lines ignored, against this file's copy, with the plan folder and SPEC path tokens substituted, so a paraphrase fails. A plan generated before this order keeps its own order and is never re-verified: step 4.5 runs only when the plan is generated, and the test stage halts on a plan without `orchestrator-parts.md` before its Checks step. Both `/gaia-plan` step 4.5 and the test stage's Checks step run the script.

## Maintenance notes

- The pre-flight isolation section's tool-choice contract has a parallel rule for main-anchored SPEC-folder writes in `.claude/skills/gaia/references/spec.md`'s Operational primitives; a change to the harness behavior in one needs the same change in the other.

<!-- gaia:template orchestrator -->
# Orchestrator: {TITLE}

You run this plan end to end: resume detection, pre-flight isolation, the phases, the closing stages, the Code Audit Team audit and the merge. Plan folder (main checkout, always written at this path): `{PLAN_DIR}`.

<!-- gaia:render-if spec -->
Source SPEC: `{SPEC_PATH}`.
<!-- gaia:render-end -->
<!-- gaia:render-if audit -->
Adversarial audit: `{AUDIT_PATH}`.
<!-- gaia:render-end -->

Read `{PLAN_DIR}/README.md` first: the task graph, the file ownership and the frozen interface contracts are there.

## Resume detection

```
<!-- gaia:orchestrator-step resume-detection -->
**Resume detection (cold-start, before the sentinel write).** Before writing this run's RUNNING sentinel, and before the pre-flight isolation below, check for a pre-existing `{PLAN_DIR}/RUNNING`. The detection read MUST precede the sentinel write, or every fresh run would self-detect as a resume.

- **No prior sentinel.** This is a fresh first run: skip resume entirely, run `gaia_pull_gate "/gaia-plan"` (sourcing `.gaia/scripts/main-only-lib.sh` first) before the pre-flight isolation, and on a non-zero exit follow `.claude/skills/update-gaia/references/pull-gate.md`, restarting by printing the fenced KICKOFF re-run; then proceed to the pre-flight isolation, and let it write this run's own sentinel afterward as usual. The resume arm below runs ungated.
- **Merged-PR guard.** If a sentinel exists, check whether its plan's PR is already merged before reconnecting to anything. The sentinel carries no PR number, so recover it from the sentinel's `branch:` line:

      pr_state="$(gh pr list --head "<sentinel-branch>" --state all --json number,state \
        --jq '.[0].state' 2>/dev/null)"

  If `pr_state` is `MERGED`, do not drive a resume of merged work, the post-merge close's fail-closed archive gate can leave a stale RUNNING/PROGRESS on an already-merged plan, surface it and stop. If no PR is found (empty result) or the state is `OPEN`, proceed with resume; the guard degrades to a no-op when there is nothing merged to protect against.
- **Reconnect by isolation mode.** Read `branch:` and `mode:` from the sentinel; a sentinel missing either is corrupt, so surface it and STOP, as for a failed reconnect below. Reconnect using the matching operation: `git checkout <branch>` for feature-branch isolation, or re-enter the existing worktree for worktree mode with `EnterWorktree({name: "<branch>"})`, the name originally passed (do NOT `git checkout` the worktree-held branch and do NOT create a new worktree); `.claude/skills/gaia/references/isolation.md` (`### Resume`) owns the lookup. Do NOT re-fire the on-main isolation `AskUserQuestion` and do NOT cut a new branch. **Failed reconnect:** if the sentinel branch is genuinely missing or the working tree is dirty, surface the condition and STOP, never silently start a new branch.
- **Dirty tree on resume.** When the failed reconnect is a dirty working tree, surface it with one `AskUserQuestion` (header `Dirty tree`): `Stay halted (Recommended)` first, which ends the run and leaves the edits and the sentinel as they are, then `Discuss this`, which talks the uncommitted edits through in this session and does not resume the run. It never offers to stash, discard or commit the edits. Append the pick to `{PLAN_DIR}/PROGRESS.md` as a `## Resume (HALTED)` block with `Reason: dirty working tree` and `Answered: <label>`.
- **Compute the resume point.** Run the helper from the reconnected working context:

      bash .gaia/scripts/plan-resume-point.sh --plan-dir {PLAN_DIR} --phases <M>

  where `<M>` is the plan's total phase count (from README's phase list). In worktree mode, run this with cwd inside the worktree so its ancestor check evaluates the worktree branch's HEAD; `--plan-dir` stays the main-checkout (the clone's primary working directory, on any branch) `{PLAN_DIR}` regardless, it locates the ledger only (`{PLAN_DIR}/PROGRESS.md`), never the git context. Read the resume point `K` from line 1 of stdout; read the `COMPLETE <n> <sha>` lines for the gate announcement below.
- **Confirmation gate (only when `K > 1`).** Present via `AskUserQuestion` (header `Resume`), announcing each verified-complete phase and its short-SHA taken from the helper's `COMPLETE` lines (the one source of truth, do not re-parse `PROGRESS.md`):
  - `Resume at Phase K (Recommended)`: enter the phase loop at Phase K.
  - `Restart from Phase 1`: run every phase from Phase 1.
  - `Abandon`: stop cleanly without re-running, committing, merging, or deleting anything; the sentinel, `PROGRESS.md`, branch, and prior commits stay intact.

  When `K` equals `M+1` (every phase a verified-complete ancestor), resume re-enters with no phase re-run at the simplify pass, then continues through the pre-audit flow checks in a spec-derived plan, the wiki promotion and the pre-merge Code Audit Team audit with the worthiness step that opens it; each of those steps skips what its own `PROGRESS.md` record or its route already settled.
- **A phase with a security-writer step.** A phase whose entry carries a `- Security writer:` line, whose security tests (its task docs' Test lines with a security kind other than `none`) have no line naming their file and title in the record the security writer step keeps in `{PLAN_DIR}`, and which has no HALTED block in `PROGRESS.md` re-runs the security-writer step before its quality gate.
- **Resumed-run git flow.** A resumed run reuses the already-open PR, it does NOT re-issue `gh pr create`; it updates the existing PR with subsequent commits exactly like an uninterrupted run. The branch edge recorded at the first cut still keys the run's cost to the same feature after reconnect, so no second `usage.sh link` runs; the pre-merge marker handshake and the post-merge close behave unchanged.
```

## Pre-flight isolation

> Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this plan's work", `{{WORKER}}` = "the orchestrator", `{{OWNER}}` = "this plan", `{{SIBLING}}` = "another plan".

This file carries that pointer, never an inlined copy of the reference: a copy freezes at plan time and never receives a later change. The reference owns the decision order (already inside a worktree, forced worktree off `main`, the on-`main` question), the prompt literals, and the worktree-creation call, and it exports two values: the resolved isolation mode as `RESOLVED_MODE`, one of `feature-branch` or `worktree`, and the resolved working copy's absolute path as `RESOLVED_ROOT`. Derive `RESOLVED_ROOT` once, immediately after the reference returns, and interpolate that same value into every later sub-agent dispatch: each task sub-agent below and each pre-merge Code Audit Team member. On a cold resume, re-derive `RESOLVED_ROOT` once cwd has settled back into the reconnected worktree or checkout (Resume detection above), before either dispatch site fires.

**Branch naming.** Pass the isolation reference exactly the output of this command, whichever mode it resolves, including the forced worktree on the not-on-main path:

    bash .gaia/scripts/branch-name-lib.sh name plan {BRANCH_ID} --type {BRANCH_TYPE} --slug "{BRANCH_SLUG}"

`.gaia/scripts/branch-name-lib.sh` owns GAIA's branch-naming convention. The PR title takes the same Conventional Commits type, `{BRANCH_TYPE}`. The SPEC id a spec-derived plan's branch name carries (`<type>/spec-NNN`) is what `spec-reconcile.sh` reads to flip the SPEC's ledger row to `merged` after the PR merges, and what the SPEC allocator reads to keep a number that is only on a branch from being handed out twice; a colocated plan's folder basename (`plan`) does not carry that marker, so the branch name is the only place it survives. The reference takes this name from you; it never derives one of its own.

When `RESOLVED_MODE` is `worktree`, every later step (task sub-agent edits, per-phase commits, `gh pr create`, and the pre-merge Code Audit Team audit) runs from inside the worktree.

**The plan folder stays in the main checkout.** The plan folder lives in main's `.notebook/`; a linked worktree reaches it through its `.notebook` link, and every write still uses the plan folder's main-checkout absolute path, `{PLAN_DIR}`. Read the task docs and `README.md` from `{PLAN_DIR}` and write `PROGRESS.md` and the `RUNNING` sentinel there, while each task edits the worktree's own copy of the tracked files it touches. Dispatch each task sub-agent with both: `RESOLVED_ROOT` (the worktree's absolute path) for the files to edit, and `{PLAN_DIR}` for the docs to read. The post-merge close runs its removal and archive steps only after `ExitWorktree` returns the session to the main checkout, so the archive helper's repo-root guard resolves the main checkout rather than the worktree.

**Tool-choice contract: which tool writes `{PLAN_DIR}/PROGRESS.md` and `{PLAN_DIR}/RUNNING` depends on `RESOLVED_MODE`, and is stated only here.** Under `feature-branch` isolation the plan folder sits inside the acting checkout, so the ordinary `Edit`/`Write` tools write both and nothing below applies. Under `worktree` mode they cannot reach either: the harness isolates the session to the worktree and refuses an `Edit`/`Write` whose `file_path` resolves to the shared checkout, and both spellings of the path land on that same refused target, because a linked worktree reaches the notebook through its `.notebook` symlink to the main checkout. GAIA's own guard already allows these writes (`.claude/hooks/block-worktree-path-mismatch.sh` exempts any write under main's `.notebook` outright), so editing it will not lift the harness refusal sitting above it. Write both files at their main-checkout absolute paths instead, by writing each into the session scratchpad and copying it in with one plain `cp` (a heredoc is refused there too; `.claude/doctrine/execution.md`, `## Run folder`), then read each back and confirm both its content and its location before continuing. The read-back is what makes this fallback safe rather than a dodge, since the failure the discipline exists to prevent is a write landing in the wrong tree. Keep the fallback scoped to these two main-anchored files: a `Bash` redirect is never the way to write into another checkout where the edit tools already work.

## RUNNING sentinel

Immediately after the pre-flight isolation above (the feature branch is cut, or the worktree is entered and its branch renamed to the canonical name by the isolation reference, so `branch:` records the canonical name), write a sentinel file at `{PLAN_DIR}/RUNNING`, per the tool-choice contract above. Content:

    branch: <the isolation branch's canonical name, as `git branch --show-current` prints it now that pre-flight cut the branch / entered the worktree and renamed it>
    slug: <basename of the plan folder>
    started: <current UTC time, ISO 8601, e.g. 2026-05-19T14:32:00Z>
    mode: <the RESOLVED_MODE the isolation reference exported: feature-branch or worktree>

This file is deleted automatically when the post-merge close archives the plan folder. Its purpose: it marks this plan as the branch's active run, which resume detection above reads for the run's `branch:` and `mode:`. The write follows pre-flight isolation, so `branch:` never records `main` while phase commits land on the feature branch. `mode:` is the exported `RESOLVED_MODE`, so a resume picks the reconnect operation without re-prompting. When a spec-less plan folder is KEPT (reduced, not deleted) under the retention the post-merge close describes below, the archive step clears this `RUNNING` sentinel as part of the reduction, so resume detection never mistakes a reaped-but-kept folder for a still-live run.

## Link the branch to its feature

Right after the RUNNING sentinel is written and before the first phase dispatch, record the execution branch's edge in the usage ledger, once per branch and never on a resume:

    bash .gaia/scripts/usage.sh link branch:<branch> <feature-ref>

`<branch>` is the canonical branch name the sentinel's `branch:` line holds. `<feature-ref>` is `spec:SPEC-NNN` (the id from `README.md`'s `## Source SPEC`) for a spec-derived plan, or `plan:PLAN-NNN` (the basename of the plan folder) for a spec-less one.

<!-- gaia:render-if pushes -->
## Pushes

<!-- gaia:part pushes -->
<!-- gaia:render-end -->

## Phase loop

<!-- gaia:part phase-loop -->

<!-- gaia:part phase-entries -->

## Sub-agent yield handling

The dispatcher half of the sub-agent context checkpoint (`.claude/hooks/context-checkpoint-subagent.sh`, `.claude/doctrine/context-yield.md`), applied inside the phase loop:

```
<!-- gaia:orchestrator-step yield-handling -->
**Sub-agent yield handling (every task dispatch).** Every task executor dispatch except a phase gate retry opts into the sub-agent context checkpoint, so a long task hands off to a fresh executor instead of running on into context rot.

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

## Phase gate retry

```
<!-- gaia:orchestrator-step gate-retry -->
**Phase gate retry (one static retry and one test retry per phase).** When the phase's `pnpm typecheck`, `pnpm lint` or file-length check (a lint `max-lines` rule, the fitness lint's line limit) fails, send each owning task's errors to a fresh executor for that task, and errors in a test file several tasks of this phase declare to that file's shared-file executor (the in-phase arm below), instead of halting at once. When a flow test fails in the closing phase's gate, send it to the task that owns it (the flow-test arm below). When a failing Playwright test is in an outside Playwright file and passes the three checks below, send it to the candidate tasks' implementers (the outside arm below). When a failing test of any runner is in a file a task of this phase declares and passes check 2 below, send it to that task, or to one executor for the file when several tasks declare it (the in-phase arm below). Never fix it on the main thread. One retry carries every arm the failure set needs; a failure that halts halts the whole set. Any other gate failure halts under Stop conditions with no retry.

- **Kind.** A gate failure holding only typecheck, lint and file-length errors is static; one holding any failing test is a test failure, even with static errors beside it. Its retry takes the same kind. A phase runs each kind at most once, so a static fix never spends the retry a later test failure needs, and a phase retries at most twice.
- **Attribute.** Map each error in the gate output to the file it names, and each file to the task whose `task-*.md` declares it. A failure is attributable only when every error names a file exactly one task declares or a test file several tasks declare. An error with no file path, on a file no task declares, or on a non-test file more than one task declares makes the failure unattributable. A typecheck or lint error in a test file several tasks declare goes straight to that file's **Shared-file executor** under **In-phase arm**, with no check 2.
- **Playwright test outside this phase.** An outside Playwright file is one that no task in this phase declares. Its failure goes to the outside arm only when all three checks hold; otherwise it halts under Stop conditions with no retry, `Reason: a Playwright test outside this phase fails in this phase's gate`, naming each `file › test name`:
  1. Known green: an earlier phase whose gate, as ORCHESTRATOR.md lists it, runs the file has a Commit block in `{PLAN_DIR}/PROGRESS.md` (`known-green: phase <k> gate`), or the file exists at the merge base of the run branch and the default branch (`git -C <RESOLVED_ROOT> cat-file -e "$(git -C <RESOLVED_ROOT> merge-base HEAD <default branch>)":<file>`), where the project's quality gate kept it green (`known-green: merge-base`).
  2. Not the environment: at least one test in the same run passed, and the failure is raised inside a test body (an assertion, locator or navigation error), not by the web server start, global setup, a setup file, a module import or a missing build.
  3. Candidates: at least one task in this phase declares a non-test file the phase changed (`git -C <RESOLVED_ROOT> status --porcelain --untracked-files=all`). Those tasks are the candidates.
- **Halt instead.** An unattributable failure, or a gate failure of a kind this phase already retried (a `(GATE RETRY k)` block for this phase in `{PLAN_DIR}/PROGRESS.md` with that `Kind:` line), halts under Stop conditions.
- **Record the retry.** Otherwise append this block to `{PLAN_DIR}/PROGRESS.md`, `k` being 1 for the phase's first retry and 2 for its second. One retry writes one block, however many arms fire: its Tasks line lists every task any arm of the retry re-dispatches and every declaring task of a shared test file, and no arm writes another:

      ## Phase N, <title> (GATE RETRY k)
      Retry: k
      Kind: <static or test>
      Tasks: <task-<T>.md of each owning task>
      Failures: <file:line and TypeScript error code, ESLint rule or file-length rule of each error, each `file › test name` of a failing flow test, each `file › test name` of a failing in-phase test, or each `file › test name` of an outside Playwright failure followed by its `known-green: phase <k> gate` or `known-green: merge-base`>

- **Re-dispatch the owning tasks.** Leave the working tree as it is: no commit, stash, reset, checkout or discard. Dispatch a fresh executor for each owning task, in parallel when there are several. A task with no attributed error is not re-dispatched. Each prompt carries the original task prompt first, without its `Yield handoff:` line, then the line `The phase quality gate failed on files this task owns. Fix only these errors, within this task's scope, and edit no other file; still run the typecheck and lint your task prompt requires before you return:`, then the gate output lines for its files. A task with a file-length error gets, before that line, the line `A file over its length limit is split: move whole functions or sections into a new lib file beside it, or an existing one no other task of this phase declares, which you may create or edit despite the line below, and name it under ### Deviations from plan. Never trim wording and never raise a limit or ceiling. Re-run the failed file-length check on your files before you return.` It carries no `Yield handoff:` line, so a retry executor never yields and the task's yield count and handoff paths stay as they are. Never continue an executor with SendMessage.
- **Flow-test arm.** A failing flow test in the closing phase's gate goes once to a fresh executor for the task whose `Flow test` line names it, free to edit code or test, using the phase's test retry; a second test failure halts under Stop conditions. Record the retry as above, then dispatch the executor: the original task prompt, without its `Yield handoff:` line, then the line `The flow test this task owns fails in the closing phase's gate. Fix the cause in the code or in the test, whichever is wrong, and say which under ### Deviations from plan. The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. The failing tests:`, then the failing test lines and their output.
- **In-phase arm.** For a failing test in a file a task of this phase declares, other than a flow test the flow-test arm takes, in place of **Attribute**, the test file alone decides the owner.
  - **Who owns the failure.** When check 2 under **Playwright test outside this phase** holds, the failure goes to the task that declares it when exactly one task declares it, and to a shared-file executor when several tasks of this phase declare it; otherwise it halts under Stop conditions with no retry.
  - **Single-owner executor.** For one declaring task, record the retry as above, then dispatch a fresh executor for that task: the original task prompt, without its `Yield handoff:` line, then the line `A test in a file this task declares fails in this phase's gate. Fix the code, or update the test when this phase changed the asserted behavior on purpose, and say which under ### Deviations from plan. The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in this task's files, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The failing tests:`, then the failing test lines and their output. A task that another arm or **Re-dispatch the owning tasks** also re-dispatches gets one executor whose prompt carries each one's lines, each line followed by its own failures and applying only to them; its edit limit is then the files the task declares, plus the lib file of a file-length split when the task carries a file-length error.
  - **Shared-file executor.** For several declaring tasks, record the retry as above, then dispatch one fresh executor per such test file, separate from any executor this retry sends a declaring task: the original task prompt of the declaring task with the lowest task number, without its `Yield handoff:` line, then the line `Read these task docs for context; they do not widen what you may edit:`, then each other declaring task's `task-*.md` path, then the line `A test in a file several tasks of this phase declare fails in this phase's gate. Edit only that test file, and in it only its failing tests and the shared setup they use, such as mocks and beforeEach, updating them when this phase changed the asserted behavior on purpose, and say what you changed under ### Deviations from plan. The task docs and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in the test file, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The failing tests:`, then the failing test lines and their output. A typecheck or lint error in that test file goes to the same executor: its prompt carries the `A test in a file several tasks` line and the failing tests only when a test there fails, and the line `The phase quality gate failed on this test file. Fix these errors in it when their cause is in this test file, such as a call to code this phase changed on purpose, edit no other file, and still run the typecheck and lint your task prompt requires before you return. The task docs and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide whether the test file or the code it calls is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in the test file, edit nothing and say so under ### Findings, on a line Cause file: <repo-relative path> naming the file that holds it. The errors:`, then the gate output lines for that file. Each line applies only to the failures that follow it. Every other executor this retry sends a declaring task ends its prompt with the line `Leave <test file> alone: another executor owns it in this retry.`
  - **Cause forwarding.** When the single-owner or shared-file executor edits no file and its `Cause file:` names a file exactly one task of this phase declares and, for a single-owner executor, that task is not its own task, the same retry goes on to that task: append `Cause owner: task-<T>.md (<cause file>)` to `{PLAN_DIR}/PROGRESS.md` under the retry record, then, once any executor this retry already sent that task has returned, dispatch a fresh executor for it: its original task prompt, without its `Yield handoff:` line, then the line `Another executor traced a failure in this phase's gate to a file this task declares. Fix the cause within this task's files, edit no other file, and say what you changed under ### Deviations from plan. The diagnosis and the failures:`, then that executor's ### Findings, then the failing test or gate output lines it was sent.
  - **Halt.** When the single-owner or shared-file executor edits no file and names no such file, or no executor this retry sent the cause owner edited a file, the phase halts under Stop conditions with no re-run, `Reason: a test file this phase declares fails in this phase's gate`, naming each `file › test name` and each `file:line` error.
- **Outside arm.** For an outside Playwright failure that passes all three checks, in place of **Attribute**, record the retry as above with each candidate on its Tasks line, then dispatch a fresh executor for each candidate task, in parallel: the original task prompt, without its `Yield handoff:` line, then the line `A Playwright test outside this phase passed before this phase and fails now, so this phase's code may have broken it. Fix the code, or update the test when this phase changed the asserted behavior on purpose, and say which under ### Deviations from plan. The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. If the cause is not in this task's files, edit nothing and say so under ### Findings. The failing tests:`, then the failing test lines and their output, then each other candidate's task file and changed files. A candidate that also owns a failing flow test gets one executor whose prompt carries both arms' lines. When no candidate edits a file, the phase halts under Stop conditions with no re-run, `Reason: a Playwright test outside this phase fails in this phase's gate`, naming each `file › test name`.
- **Re-run the gate.** Once every re-dispatched executor returns, including a cause owner's, run the whole phase gate again from its first step. A pass goes on to the commit as usual.

The retry is not a grant: it never widens a task's scope, except that a file-length split may write its lib file.
```

## Security writer

```
<!-- gaia:orchestrator-step security-writer -->
**Security writer (each build phase whose entry carries a `- Security writer:` line).** At the end of the phase, after its task executors return and before its quality gate, read `.claude/skills/gaia/references/security-writer.md` and run it from `RESOLVED_ROOT`: it owns the dispatch of the `security-test-writer` agent over that phase's Test lines with a security kind other than `none`, the record, the failing-test route back to the owning executor, the one retry, the HALT block and its reason, and auto mode. Never have a task executor write a security test.
```

## Sub-agent invocation

Dispatch each task sub-agent as `general-purpose` with `model: "sonnet"` explicitly pinned on the dispatch, and no `effort` parameter: it runs at the session effort. Pin Sonnet on the dispatch itself so the executors run on Sonnet whatever your own session model is: a cold orchestrator is often on Opus, and an unpinned sub-agent inherits that. The feature's complexity was resolved upstream, in the spec and its audit and the plan and its decomposition audit, precisely so execution can run on the cheaper model. **Escape hatch:** a phase or task whose entry in the phase loop above pins `model: "opus"` and says why (genuinely deep synthesis, such as a subtle parser grammar or a cross-cutting type redesign) is dispatched on Opus. Sonnet is the floor; Opus is a per-phase, justified exception, never the blanket default.

**Fail-loud tree self-check (mirrors the pre-merge Code Audit Team dispatch).** Immediately before each phase's task-dispatch wave fires, capture the expected tree fresh: `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}`, and put it in each prompt of the wave as `<EXPECTED_TREE>`. Recapture it before every wave: HEAD moves once a prior phase's commit lands, so reusing a stale value would fail a later wave's self-check against a tree it is correctly editing. The prompt's first action compares the two; it closes the gap where a wrong or stale `RESOLVED_ROOT` (a bad interpolation, or a worktree removed or relocated mid-run) let a task sub-agent silently edit the wrong tree with no signal.

Sub-agents do not commit, push, or open or update the PR: they only edit files and report. You own staging, committing, pushing, and the PR.

**The prompt template.** Every dispatch, a gate retry's or a flow-checks fixer's fresh executor included, opens with the template's role line. Fill `<plan>` (the plan's title), `<N>`, `<T>`, `<RESOLVED_ROOT>`, `<EXPECTED_TREE>`, `<WAVE_SIZE>` (the number of tasks the wave dispatches) and `<k>` (the dispatch's yield count, from the yield handling above); every other `<...>` in it is the executor's to fill.

    You are a task executor for the <plan> plan, Phase <N>, task-<T>.

    Working copy: <RESOLVED_ROOT>. Plan folder (read only): {PLAN_DIR}. Your task doc: {PLAN_DIR}/task-<T>.md. Read it in full, then every file its read-first list names, before your first edit. The plan README's frozen interface contracts bind you. Edit only files under <RESOLVED_ROOT> that your task doc declares.

    First action, before any edit: run `git -C <RESOLVED_ROOT> rev-parse HEAD^{tree}` and compare it to <EXPECTED_TREE>. On a mismatch or a command error, STOP, make no edits, and return only the mismatch or the error as your entire output. Proceed with your task only on an exact match.

    Git: you do not commit, push, or open or update the PR; you only edit files and report, and the orchestrator owns staging, committing, pushing, and the PR. Never run a git command that rewrites the working tree, the index, or HEAD, such as `git stash`, `git reset`, `git checkout`, `git switch`, `git restore`, or `git clean`: every executor in a wave edits this one working tree, so any of them silently discards a sibling's uncommitted edits or new files while the sibling still reports success and the orchestrator commits whatever is left. Before/after or mutation work (proving a guard can fail) runs on a scratch copy instead, a temporary directory or `$BATS_TEST_TMPDIR` in a bats suite. A scratch copy never symlinks `node_modules`, or any other directory of the real checkout, and no `pnpm`, `npm`, or `npx` command runs with a scratch copy as its project directory: the package manager treats the copy as a fresh project and reinstalls, and through a symlink that writes into the real checkout's `node_modules` and breaks the orchestrator's next gate with a module-not-found error that names no cause. Run the real checkout's own binaries against the scratch files instead (`node_modules/.bin/vitest --root <scratch> --config <scratch config>`), or copy only the single file under test.

    Checks: this wave dispatches <WAVE_SIZE> task(s). When it is more than one, run only file-scoped, non-mutating checks over your own paths (the linter without its fix flag on your own files, the tests in your own test files), never a repo-wide mutating or shared-state command such as the project's lint script (`eslint --fix` over the whole app), the project's typecheck script or route typegen (writes one shared generated directory), Playwright, or a dev server. Siblings run concurrently in the one tree, so a fix pass that read a file before a sibling's edit and writes it back after silently discards that edit while the sibling reports success, and typegen or a shared server turns one sibling's half-finished edit into another's reported failure. Those repo-wide checks run once, in the phase's quality gate, after every task in the wave completes.

    Typecheck your own work before you return, so a type slip you made is fixed by you instead of failing the phase gate: in a wave of one task, `pnpm -C <package dir> typecheck`; in a wave of more than one, `pnpm -C <package dir> exec tsc --noEmit`, allowed despite the confinement above because it runs no typegen. In either wave act only on errors in files your task owns. An error in an owned file that your edit did not cause, such as an import of a route types module typegen has not generated yet, goes under `### Findings`, not chased.

    Lint your own files before you return, with `pnpm -C <package dir> exec eslint <its own files>`, the paths relative to the package and no fix flag (for example `pnpm -C apps/web exec eslint app/components/x/index.tsx`). Rewrite your edit until lint reports no problem your edit caused, error or warning, but `prettier/prettier`, adding an `eslint-disable` only as the last resort the coding guidelines allow; a problem your edit did not cause, such as an unresolved import of a file a sibling task has not written yet, goes under `### Findings`, not chased. The phase gate's lint runs with the fix flag, so any other autofixable error left at return is rewritten there and can silently undo your edit; for you this overrides the coding guidelines' default of leaving autofixable lint to the gate, and formatting alone stays with it. Never lint from the repository root with `--config <package dir>/eslint.config.mjs` instead: ESLint matches the config's file globs against the root, so the package's `app/**`-scoped rules never apply, its Tailwind rules disable themselves, and a file that breaks them lints clean.

    Tests: once the test stage has written your task doc's Test lines, write the test each of them names, under that line's title verbatim, and no other new test. Read `.claude/doctrine/testing.md` before your first test write. Never write a test whose Test line has a security kind other than `none`: the security writer does. Any other test you judge worth adding goes under `### Findings` instead of into the tree. Read `.claude/rules/typescript.md` before your first TypeScript write: a path-scoped rule loads only after the Write that creates a new file lands, and a new file is often left as written.

    Never copy a working-document id from the task doc into a file you edit: a SPEC, flow, plan, or directive id, or an issue or pull request number, never lands in code, a comment, a test name, a user-facing string, or prose (`.claude/rules/working-doc-ids.md`). Write the behavior the id stood for instead.

    End your return with a `## Notes for orchestrator` section containing any of: `### Findings` (non-obvious things you noticed), `### Deviations from plan` (where the task doc was wrong or you had to work around it), `### Follow-ups` (work the user should consider after merge). Subsections may be empty or omitted; only non-trivial signal belongs there, and routine "phase done, tests green" status does not.

    How your run ends: a reply with no tool call ends it, and the orchestrator reads whatever you returned as your finished result. Do not end on a summary that announces a next step, an offer to continue, a list of questions none of which blocks the work, or a progress report because a milestone is done; take the next step instead. Stop only when the task is complete, or when something you cannot resolve blocks it, and then say which.

    Yield exemption: only when a hook-delivered sub-agent context checkpoint instruction arrived in this run, a reply whose first line is `YIELDED <band>: <handoff path>` is not the progress report the paragraph above forbids. Follow that instruction: write the handoff at the absolute path it names by copying a scratchpad file in with one plain `cp` (Edit and Write can refuse a path outside your worktree), read it back, then reply. Never yield without that instruction.

    Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-yield-<k>.md

The `Yield handoff:` line is the path the yield-handling step pre-clears for that dispatch, and it is the dispatch prompt's final line because the hook reads only an opt-in line that ends the prompt. A nested dispatch an executor makes never carries it. Neither does a phase gate retry prompt (the gate-retry step).

The prompt's `How your run ends` paragraph names the stops that are not wanted. The failure-triggered STOP under Stop conditions below stays wanted: a sub-agent blocked by something it cannot resolve says so under `### Deviations from plan` and returns.

## Orchestrator-owned git flow

After each phase that produces changes, and only once its quality gate is clean, stage, commit with a Conventional Commits subject (`wiki/decisions/Naming Conventions.md`; enforced by the `commit-msg` hook), and push. **Before staging, check each task's completion**: compare the files the task's `task-*.md` declares with the files actually changed (`git -C <RESOLVED_ROOT> status --porcelain`). A declared file left untouched, or a `### Deviations from plan` or forward-looking note in the sub-agent's return, means reading that task's diff against its acceptance criteria before committing; the quality gate passes on valid but unfinished code, so it cannot catch this. A miss the sub-agent's notes do not explain is a sub-agent failure under Stop conditions below. Open the PR after the first phase's commit lands on the remote (using `gh pr create --draft`), unless a Pushes section above says when it opens, and update it with subsequent commits. The PR body puts its issue lines where `.claude/skills/gaia/references/work-lifecycle.md` (`## 5. Commit and open the draft PR`) says. In worktree mode, tell the user "after merge, the worktree will be discarded" before opening the PR. The PR title, PR body and commit messages describe the change in words and never cite the SPEC or plan id or the plan folder's path (`.claude/rules/working-doc-ids.md`); the `commit-msg` hook refuses a message that does. Never commit a broken state.

## Phase findings ledger

`{PLAN_DIR}/PROGRESS.md` is an append-only file you maintain across the run, so sub-agent observations survive context compression, written per the tool-choice contract in the pre-flight isolation section above. After each phase, append a `## Phase N, <title>` block whose first content line is `Commit: <short-sha>`, the machine-readable anchor `.gaia/scripts/plan-resume-point.sh` reads, followed by the merged `Notes for orchestrator` content from every sub-agent in that phase. A phase with no sub-agent notes writes `_No notes._`. **This section, the Phase findings ledger section of `.claude/skills/gaia/references/plan/orchestrator-template.md`, is the single source of truth for the `PROGRESS.md` block format**; any other doc or reference page that describes the ledger points to it rather than restating the literal `Commit:` line. Example:

```
## Phase 2, Helper implementation
Commit: a1b2c3d

### Findings
…
```

A HALTED block carries no `Commit:` anchor: `## Phase N, <title> (HALTED)` (see Stop conditions below), and a later Commit block for the phase records a halt that a passing rerun cleared. Sub-agents do not write to this file directly; you own it.

A block that records how a halt or question was resolved names the question and the answer as `Answered: <selected label>`, or `Answered: typed: <text>` for a free-text answer. It never credits "the human" for an option pick: a pick reads the same whether a person or an unattended driver made it.

A yield block is headed exactly `## Phase N, <title> (YIELD k)`, its first content line is `Yield: k`, it names the task, the band and the handoff path, and it carries no `Commit:` line. The yield-handling step writes it. Example:

```
## Phase 2, Helper implementation (YIELD 1)
Yield: 1
Task: task-helpers.md
Band: red
Handoff: /abs/plan/handoffs/phase-2-task-helpers-yield-1.md
```

A gate retry block is headed exactly `## Phase N, <title> (GATE RETRY k)`, its first content line is `Retry: k`, its second is `Kind: static` or `Kind: test`, it names the owning tasks and the failures, then a `Cause owner:` line when the in-phase arm sent the failure on, and it has no `Commit:` line. The gate-retry step writes it.

`plan-resume-point.sh` reads a yield or gate retry block as a `## Phase N` block whose first content line is not a `Commit:` anchor, so a phase whose last block is one of them resumes at that phase, and a later Commit block for the phase still marks it complete.

## Stop conditions

On any sub-agent failure, or a quality-gate failure the phase gate retry does not settle: STOP and surface to the user. Do not "fix and continue", do not commit, do not push. Before stopping, append the failure context (which phase, which sub-agent, error) to `PROGRESS.md` under a `## Phase N, <title> (HALTED)` block with a `Gate retries: <0, 1 or 2>` line, written per the tool-choice contract in the pre-flight isolation section above, so the user and any follow-up session see the same record, then ask one `AskUserQuestion` (header `Halted`): `Stay halted (Recommended)` first, which ends the run with the phase's edits uncommitted, then `Discuss this`, which talks the failure through in this session and still makes no inline fix, commit or push. It never offers fixing inline or a standing fix grant (`.claude/rules/user-questions.md`). Append the pick to the HALTED block as `Answered: <label>`. A failure only the human can clear, a known cause whose fix is a step the agent may not take (a missing line in `.env`), asks instead (header `Human step`) `I did it (Recommended)` first, which reruns the whole phase gate from its first step (for a sub-agent failure, it re-dispatches that sub-agent first) and continues only on a pass, then `Stay halted`. A passing rerun appends `Rerun: passed` under the `Answered:` line and the phase commits. A failed rerun appends `Rerun: failed` and its error under the `Answered:` line, then ends the run and asks no new question. When the gate's own dev smoke or Playwright missing-variable question (`wiki/decisions/Quality Gate.md`, step 7) already ran and its rerun failed, this halt asks only `Stay halted (Recommended)` then `Discuss this`, never a second `I did it`. A reply whose first line is `YIELDED` is not a sub-agent failure: the yield-handling step handles it, and that step's own HALTED blocks are the stops.

## Simplify pass

```
<!-- gaia:orchestrator-step simplify-pass -->
**Simplify pass (every start and every resume, after the last phase commits and before the flow checks and the code audit's worthiness step).** Read `.claude/skills/gaia/references/simplify-pass.md` and run it from `RESOLVED_ROOT`. It records its outcome as a `## Simplify pass` block in `{PLAN_DIR}/PROGRESS.md`.
```

<!-- gaia:render-if spec -->
## Pre-audit flow checks

```
<!-- gaia:orchestrator-step flow-checks -->
**Pre-audit flow checks.** After the last phase commits, and before the wiki promotion, the pre-merge Code Audit Team audit with its worthiness step, and the final summary, run from `RESOLVED_ROOT`:

    bash .gaia/scripts/spec/flow-coverage.sh --spec {SPEC_PATH} --root <RESOLVED_ROOT> --plan-dir {PLAN_DIR} --flow-tests-out <RUN_FOLDER>/flow-tests.tsv

`<RUN_FOLDER>` is this branch's run folder (`.claude/doctrine/execution.md`, `## Run folder`); the merge-time presence gate reads the file it writes. What each exit means: `.claude/skills/gaia/references/spec/lifecycle.md` `## Pre-audit flow checks`.

- **Exit 0.** Append this block to `{PLAN_DIR}/PROGRESS.md` and go on to the wiki promotion. Exit 0 also covers a test stage that was skipped or never ran (`{PLAN_DIR}/TEST-STAGE` reading `status: skipped`, or absent): each flow with no test is then one `flow-coverage: gap:` stdout line, a visible gap and not a failure. Copy each such line under `Gaps:`, or write `Gaps: none`:

      ## Flow checks
      Result: <every flow has a test changed on the branch | test stage skipped: each flow with no test is listed under Gaps>
      Flow tests: <the path column of each flow-tests.tsv row, or none>
      Gaps: <each flow-coverage: gap: line, or none>

- **Exit 1, the named fixer.** Map each stdout failure line to the closing-phase task whose `Flow test` line names its flow or its test path. Dispatch one fresh `general-purpose` executor on `model: "sonnet"` per closing-phase task whose `Flow test` line names a failing flow, in parallel, each free to fix code or test: the original task prompt, without its `Yield handoff:` line, then the line `The pre-audit flow checks failed on the flow this task owns. Fix the cause in the code or in the test, whichever is wrong, and say which under ### Deviations from plan. The task doc and, when {PLAN_DIR}/README.md names a Source SPEC, that SPEC and the documents its Required reading names decide which is wrong: never change an asserted label, role, message or URL they state to match the code. The failures:`, then its failure lines. Once every fixer returns, run the closing phase's quality gate, commit, push, and re-run the script once.
- **Halt.** A second exit 1, an exit 2 or 3, a failure line no closing-phase task's `Flow test` line names, or a fixer round that edits nothing: append this block to `{PLAN_DIR}/PROGRESS.md`, then ask one `AskUserQuestion` (header `Flow checks`), `Stay halted (Recommended)` first, then `Discuss this`, and append the pick as `Answered: <label>`:

      ## Flow checks (HALTED)
      Reason: <flow checks failed after one fixer round | flow-coverage.sh exit <2 | 3> | a failure no closing-phase task owns | the fixer edited nothing>
      Failures: <each stdout failure line, or the stderr line>

The retry bound is one. A flow test's honesty or worth judgment is not this block's: the worthiness step bounds it. A failure here is a HALT, never an audit finding to fix in a fix round.
```
<!-- gaia:render-end -->

## Consolidation and wiki promotion

Run this step warm, on your own session: consolidation is synthesis, not a task sub-agent's job. It runs before the Code Audit Team audit below, so the promotion commit lands before any member's marker exists and rotates none.

```
<!-- gaia:orchestrator-step wiki-promotion -->
**Consolidation and wiki promotion.** Runs after the flow checks (a spec-less plan: after the simplify pass) and before the code audit's worthiness step and the first member dispatch.

1. On a resume, when `{PLAN_DIR}/PROGRESS.md` already holds a `## Wiki promotion` block with `Pass: pre-audit`, skip this whole step: no re-consolidation and no re-promotion.
2. Consolidate per `.claude/skills/gaia/references/spec/lifecycle.md` `## Consolidation`. It writes `SUMMARY.md` and runs `summary-verify.sh`, and removes nothing. When its verify fails it records `skipped-verify-failed`; make no commit, remove nothing, skip step 3 and go on to the audit.
3. Promote per `.claude/skills/gaia/references/spec/wiki-promote.md`. Its Step 2 reads `SUMMARY.md`'s `wiki_promote_default` and `wiki_promote_targets` and decides whether pages are written and which Choice token results; this block does not decide it. A Step 2 `ask` fires its question here, and an unattended run records `skipped-unattended` and goes on to the audit. Nothing writes a defer cache.
4. The promotion commit holds the paths that file's Step 6 names, lands on this PR branch, and is pushed before the first member dispatch and before the pre-dispatch verification. Write the committed page paths, one per line, to `promoted-pages.txt` in this branch's run folder (`.claude/doctrine/execution.md`, `## Run folder`).
<!-- gaia:maintainer-only:start -->
On the maintainer repo, that commit also carries the manifest answer `wiki-promote.md`'s maintainer note describes, before any `bash .gaia/tests/verify-harness.sh branch` pass.
<!-- gaia:maintainer-only:end -->
5. Append the record to `{PLAN_DIR}/PROGRESS.md`, `Pass: pre-audit` first, then the Choice token and `Reason:` line exactly as that Step 2 returned them:

       ## Wiki promotion
       Pass: pre-audit
       Default: <yes | ask | no>   Choice: <promoted | declined | skipped-unattended | skipped-verify-failed | no>
       Pages: <paths or none>   Commit: <short-sha or none>
       Reason: <one line; required whenever Choice is not promoted>
```

## Code Audit Team audit

The pre-merge audit is roster-first and non-skippable. It opens with the worthiness step, names the resolver and the dispatch, and closes with the late pass:

```
<!-- gaia:orchestrator-step code-audit -->
**Code Audit Team audit.** First read `.claude/skills/gaia/references/worthiness-step.md` and run it from `RESOLVED_ROOT`. It records a `## Worthiness step` block in `{PLAN_DIR}/PROGRESS.md`, and on a resume that block makes it skip-safe, so it settles only what is still open. Then resolve the dispatched members with `bash .gaia/scripts/resolve-audit-members.sh`, then dispatch the audit loop unit per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`, only after the wiki promotion commit is pushed and the pre-dispatch verification has passed.

On a `clean` unit, run `bash .gaia/scripts/audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>`, then the PR review per `wiki/concepts/PR Merge Workflow.md` `#### PR review` (once per PR, passing `--spec` the SPEC path this plan's `README.md` names under `## Source SPEC` when it names one), then the late pass from `.claude/skills/gaia/references/worthiness-step.md` `## The late pass`, before the final summary, so a residual it decides is surfaced before the merge confirmation. The `GAIA-Audit` status posts later, in the post-clearance block.
```

Before any `gh pr merge` call, resolve which Code Audit Team members this branch's diff dispatches:

    bash .gaia/scripts/resolve-audit-members.sh

It prints one member (agent) name per line, deduped and sorted. Dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`: the unit runs the named members, and `code-audit-frontend` fail-closed when the output is empty or an in-scope file no member owns. The status posts in the post-clearance block below, per `#### Posting the status last`.

Skip a spawn for a member already cleared for HEAD: its marker exists, or (for the default member) one of the bypass signals in the marker-handshake table already applies to this PR. The spawn set names who *can* be required, not who is still outstanding.

On a clean pass each member writes its own marker; it does not post the `GAIA-Audit` success status itself, you do, per `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last`. The merge deny-hook requires **every** dispatched member's marker, so one member withholding holds the gate shut for all. If a member declines to write its marker, its report names what remains unaddressed; resolve those, commit, push (HEAD moves), then re-spawn the pending members on the new HEAD. A member's marker is keyed to its own branch-own digest (the branch's own patch on the files it owns plus the shared gate machinery), not to HEAD's sha, so a re-spawn is owed only when the fix changed the branch's own patch on a path that member's digest covers; an unrelated fix, or a catch-up merge of the base, leaves an already-cleared member's marker valid and it is skipped per the rule above (`wiki/concepts/PR Merge Workflow.md` `#### Skipping already-cleared members`). Never hand-write a marker to bypass the gate. Once the `#### Posting the status last` conditions all hold, post the status yourself, `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`, immediately before calling `gh pr merge` (the post-clearance block below).

A member spawned with nothing in its remit self-skips and writes no marker, so an over-broad spawn is harmless, but an under-broad one deadlocks the merge, which is why the spawn set comes from the resolver and not from a guess.

<!-- gaia:maintainer-only:start -->
The maintainer-scope members are read-only: they report findings and gate their marker; their findings are the orchestrator's to fix.
<!-- gaia:maintainer-only:end -->

The default member's LOCAL Task return is terse (pointer + counts + marker line); the full per-finding detail lives in the re-run carry-forward ledger (`.gaia/local/audit/<audit-key>.rerun.json`, keyed per `wiki/concepts/Code Review Audit Agent.md` `## Re-run carry-forward ledger`), the round's shared ledger, whose entries each name their `member`. To surface its open findings, read the ledger's `remaining[]` (enumerating Critical, Major, and escalated Minor findings for the user) instead of expecting a full inline report. Every member's open entries live in that ledger, and each clearance write must account for the writing member's entries by `entry_id` or the writer refuses it. If the ledger is absent, corrupt, or stale, the default member's return carries the full report (it emits the full report whenever it could not write the ledger), so surface the open findings from that report; a specialized member's report carries its own findings directly.

## Final summary

After all implementation phases pass and the final commit is pushed, before the merge question below, **read `{PLAN_DIR}/PROGRESS.md`** and print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, a yields line, a gate retries line, the `## Simplify pass` block from `PROGRESS.md`, the `## Worthiness step` block from `PROGRESS.md` plus any residual its late pass settled (residuals, refused deletes and filings, stated before the `AskUserQuestion`), and the highest-signal findings/deviations/follow-ups drawn from `PROGRESS.md` so nothing is lost to context compression; a finding or deviation saying the shipped app differs from the SPEC or its Required reading is listed as a decision to make, never as a follow-up, unless the human accepted it at the audit checkpoint. The yields line gives, per phase that yielded, the number of its `(YIELD k)` blocks in `PROGRESS.md` and the peak band among them (red below fire below skull), printed as `Yields: Phase <N> <count> (peak <band>)` with entries joined by `; `, and as `Yields: none` when no phase yielded. The gate retries line names each phase with a `(GATE RETRY k)` block in `PROGRESS.md`, printed as `Gate retries: Phase <N>, Phase <M>`, and as `Gate retries: none` when no phase retried. Keep it tight, a few lines plus the surfaced notes, not a recap of every change.

After every dispatched member's clean-pass marker is written and before the merge, print the whole implementation's cost with `bash .gaia/scripts/usage.sh initiative <root> --box`, where `<root>` is `spec:SPEC-NNN` (from the `## Source SPEC` section of `README.md`) for a spec-derived plan or `plan:PLAN-NNN` (the basename of the plan folder) for a spec-less one. The output lists the spec (when there is one), the plan and the execution, with a total, and is relayed verbatim inside a bare fenced block (an unfenced box is reflowed by the Markdown renderer and loses its alignment). Never compute or restate a figure; on a non-zero exit, relay the command's one stderr line in its place.

**The merge question.** After the cost line, wait on the required checks with `bash .gaia/scripts/pr-wait-merge.sh --pr <N> --until-green --attempts 20`; exit 2 is a refusal, not a verdict, so stop and say so. Then ask one `AskUserQuestion` with `Merge it` and `Hold the merge`, the recommended option first. Recommend `Merge it` when the merge is ready; it needs no stated reason. Recommend `Hold the merge` only when one of these holds, and its description then says in plain words what is blocking the merge and what the user can do about it (`The required check "lint" failed. Fix it, push, then resume the plan run to merge.`), never quoting this list's wording, a verdict token such as `CHECK_FAILED`, or a `PROGRESS.md` label:

- the wait's verdict is `CHECK_FAILED`, `CONFLICTING` or `CLOSED`, or `TIMEOUT` (required checks still pending after the wait), except a `TIMEOUT` whose `GREEN was not proved` line names `no required check is declared`, which has none to hold on;
- a deviation the summary surfaced needs a decision the human has not given; a finding or deviation saying the shipped app differs from the SPEC or its Required reading needs that decision unless the human already accepted it at the audit checkpoint;
- the residual count read's `.ask` is non-zero and no human answered the residual question;
- the worthiness step's late pass settled a `fix` or `delete` verdict as a residual with no human answer.

Residuals the human accepted at the audit checkpoint are no hold reason, nor is a phase halt, however it was answered: a halted phase commits only after its gate passes. `Merge it` runs the post-clearance block; `Hold the merge` leaves the PR open and stops.

## Post-clearance

Run this step warm, after audit clearance and the merge question's `Merge it` answer, before the merge:

```
<!-- gaia:orchestrator-step post-clearance -->
**Post-clearance.** Runs after every dispatched Code Audit Team member has cleared and the merge question was answered `Merge it`, and before the merge.

1. Consolidate again into `SUMMARY.md` per `.claude/skills/gaia/references/spec/lifecycle.md` `## Consolidation`; it is untracked, so it stays uncommitted.
2. Read each page in `promoted-pages.txt` against the audited code. A falsified page gets a wiki-only commit and push, which keeps every member's marker and restarts CI.
3. When the last attempted pass recorded `skipped-verify-failed` and the verify now passes, retry promotion per `.claude/skills/gaia/references/spec/wiki-promote.md`.
<!-- gaia:maintainer-only:start -->
On the maintainer repo, a retry that writes a new page commits its manifest answer per `wiki-promote.md`'s maintainer note, which rotates the shell member's marker and owes a fresh `bash .gaia/tests/verify-harness.sh branch` pass and a shell re-audit before the status posts.
<!-- gaia:maintainer-only:end -->
4. A verify failure here, or a refresh with nothing to retry, appends a `## Consolidation refresh` block to `{PLAN_DIR}/PROGRESS.md`, and the run continues to the merge, the close keeping the layers.
5. A pass that reached `wiki-promote.md`'s Step 2 appends a `## Wiki promotion` block with `Pass: refresh` first, in the same shape as the pre-audit record. The last `## Wiki promotion` block is the outcome, so a refresh verify failure never overwrites a promoted record. A block recording `promoted` is never promoted again.
6. Confirm every dispatched member's marker is current, per `wiki/concepts/PR Merge Workflow.md` `#### Skipping already-cleared members`, and re-spawn any member whose marker rotated; never hand-write one.
7. Post the `GAIA-Audit` status with `bash .claude/hooks/post-audit-status.sh <path to a current member marker>` per `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last`, which writes the residual sections first, immediately before `gh pr merge`, on the head the audit cleared, including after a catch-up merge. Then print the merge report per `wiki/concepts/PR Merge Workflow.md` `**The merge report.**`, and merge.
```

## Post-merge close

```
<!-- gaia:orchestrator-step post-merge-close -->
**Post-merge close.** After `gh pr merge`, follow `.claude/skills/gaia/references/spec/lifecycle.md` `## Post-merge close` in its order: wait on `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` and continue only on exit 0 (`MERGED`); reconcile the ledger (passing `<N>` to `plan-reconcile.sh` for a spec-less plan); exit the worktree (worktree mode); verify `SUMMARY.md`, and only on a pass remove `SPEC.md` and `AUDIT.md`; then run `bash .gaia/scripts/plan-archive.sh {PLAN_DIR}`. `plan-archive.sh` runs only after `MERGED` is confirmed, never before the merge. Nothing deletes `{PLAN_DIR}` before this step.
```

The archive argument is the cached plan folder path, `{PLAN_DIR}` (absolute); the helper normalizes an absolute-under-repo path to repo-relative, and the allow entry `Bash(bash .gaia/scripts/plan-archive.sh:*)` matches any argument shape. A spec-colocated plan subfolder is deleted and its SPEC folder keeps `SUMMARY.md`; a spec-less plan folder is reduced to `SUMMARY.md`. Both stay for the retention `lifecycle.md` `## Post-merge close` states, and the pre-flight sweep reaps them once past it. The notebook is gitignored under the GAIA default (`git check-ignore` confirms it), so the archive needs no commit; if a path is tracked, commit and push the change. If the user explicitly asks to keep the plan folder, skip the archive and report.

If the run stops before this step finishes (an interruption, a merge made outside the orchestrator), the pre-flight sweep that `/gaia-spec` and `/gaia-plan` both run (`lifecycle.md` `## Pre-flight sweep`) reconciles the ledger, consolidates the folder and reaps it later.

## Post-merge cleanup

Follow `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, run only after the post-merge close has confirmed `MERGED` through `pr-wait-merge.sh` and reconciled the ledger; if the merge is not confirmed, surface it to the user and stop. Take the arm for this run's isolation mode; this file carries no snapshot of the reference:

- **Feature-branch run:** `### Feature branch`, with `<branch-name>` = the plan's branch. Without it, a feature-branch run ends on the merged branch with no checkout, pull, branch delete or prune.
- **Worktree run:** `### Worktree entered by name in this session` when you entered the worktree in this session, and `### Worktree entered by path or in an earlier session` for a resumed run. The `Merge it` answer is the consent to discard the worktree, so discard it without prompting (the git flow above told the user "after merge, the worktree will be discarded" before the PR opened).
- **Isolated sub-agent context** (you were dispatched with `isolation: "worktree"` or a `cwd` override and cannot call `ExitWorktree`): that reference's `### Sub-agent context: continuation prompt`, with these two lines appended to its command list (the first for a spec-colocated plan only):

  ```text
      bash .gaia/scripts/summary-verify.sh <ABSOLUTE-PATH-TO-SUMMARY.md> && rm <ABSOLUTE-PATH-TO-SPEC-FOLDER>/SPEC.md <ABSOLUTE-PATH-TO-SPEC-FOLDER>/AUDIT.md   # spec-colocated plan only
      bash .gaia/scripts/plan-archive.sh <ABSOLUTE-PATH-TO-PLAN_DIR>
  ```

  These two commands are the post-merge close's remaining steps (`lifecycle.md` `## Post-merge close`), which an isolated orchestrator cannot run because they need the main checkout. Fill each `<ABSOLUTE-PATH-TO-...>` with its absolute path; this plan's folder is `{PLAN_DIR}`.
<!-- gaia:template kickoff -->
You are the orchestrator for the {TITLE} plan. You run it end to end from a fresh session: you dispatch sub-agents to edit files, and you own every commit, push, the PR, the Code Audit Team audit and the merge.

<!-- gaia:part kickoff-goal -->

Read these two files in full before acting:

- {PLAN_DIR}/README.md (task graph, file ownership, frozen interface contracts)
- {PLAN_DIR}/ORCHESTRATOR.md (the playbook you follow step by step)

<!-- gaia:render-if spec -->
Source SPEC: {SPEC_PATH}.
<!-- gaia:render-end -->
<!-- gaia:render-if audit -->
Adversarial audit: {AUDIT_PATH}.
<!-- gaia:render-end -->

On cold start, before pre-flight, check {PLAN_DIR}/RUNNING for a prior run and follow ORCHESTRATOR.md's Resume detection section (reconnect and resume gate) before writing the sentinel.

Pre-flight isolation, the one step this prompt points to rather than states:

> Read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this plan's work", `{{WORKER}}` = "the orchestrator", `{{OWNER}}` = "this plan", `{{SIBLING}}` = "another plan".

Pass it the branch name `bash .gaia/scripts/branch-name-lib.sh name plan {BRANCH_ID} --type {BRANCH_TYPE} --slug "{BRANCH_SLUG}"` prints.

The plan has {PHASE_COUNT} phases; ORCHESTRATOR.md lists them.

Execution outline:

<!-- gaia:part kickoff-outline -->

Hard rules:

- Dispatch each task sub-agent as `general-purpose` with `model: "sonnet"` unless ORCHESTRATOR.md's phase list escalates that phase to Opus, and with no `effort` parameter.
- Sub-agents only edit files; they never commit, push, touch the PR, or run a git command that rewrites the working tree, the index or HEAD.
- Never fix a failure inline on the main thread: a gate failure goes through ORCHESTRATOR.md's phase gate retry or halts under its Stop conditions.
- No commit message, PR title or PR body cites the SPEC or plan id or the plan folder's path.
- Never hand-write an audit marker.
- Before any `gh pr merge`, resolve the dispatched Code Audit Team members with `bash .gaia/scripts/resolve-audit-members.sh` and spawn each one through the audit loop unit; see ORCHESTRATOR.md's Code Audit Team audit section.
