# PR review

Contents: Placeholders; 1. Skip a review that already ran; 2. Read the required checks once; 3. Build the bundle and open the record; 4. Dispatch the reviewer; 5. Dispose every finding; 6. Route each fix; 7. Publish and confirm; Unattended runs.

This page owns the PR review's procedure: one read-only, unanchored `pr-reviewer` dispatch per pull request, the record of its outcome, the main thread's disposition of each finding and the route each fix takes. When it runs and where it sits in the merge order is `wiki/concepts/PR Merge Workflow.md` `#### PR review`. The reviewer's judgment is `.claude/agents/pr-reviewer.md`. Each script's header owns its arguments, output lines and exit codes; this page names the calls and their order.

## Placeholders

`<RESOLVED_ROOT>` is the checkout that holds the PR branch. `<RUN_FOLDER>` is the branch's run folder at its main-checkout absolute path (`.claude/doctrine/execution.md`, `## Run folder`). `<N>` is the PR number. Scratch files (the reviewer's output, the guard's snapshots) live in the session's scratchpad directory, never under `.gaia/local/`: a file there reads as a change to the audit state the guard watches.

## 1. Skip a review that already ran

The review runs once per pull request and never re-runs on its own fixes or on a later HEAD. Read the record first:

```bash
bash .gaia/scripts/pr-review-record.sh read --run-folder <RUN_FOLDER>
```

A record whose `pr` is `<N>` and whose `outcome` is `ran` means no dispatch: go to step 5 and continue from the first finding with no disposition, or the first `fix` finding not yet `fixed`. A record whose `outcome` is `not-run` is a stop a human decides (step 4's question). Exit 5 (unreadable, or findings changed after the outcome) stops `needs-human` with the printed line. No record, a record keyed to another PR, or one with no outcome yet (a session that ended mid-dispatch) continues at step 2. The PR body's section is never read as the record: the merge gates deny a pull request with no local record, so a merge from a clone that lacks it runs the review there (`wiki/decisions/PR Review Step.md`).

## 2. Read the required checks once

```bash
gh pr checks <N> --required
```

Read it once, before the dispatch. A failing required check is handled first, the way `wiki/concepts/PR Merge Workflow.md` `#### Before the first dispatch: verify your own work` handles a red row (read the failing job's log: a flake wants a re-run, a defect a repair). A pending check does not hold the review: dispatch without waiting for it.

## 3. Build the bundle and open the record

Build the bundle into a new, empty directory from `mktemp -d`, never under `.gaia/local/`:

```bash
bash .gaia/scripts/pr-review-bundle.sh --root <RESOLVED_ROOT> --pr <N> --out <bundle dir> [--spec <path>]
```

Only a plan build passes `--spec`, with the SPEC path its plan README's `## Source SPEC` names. Exit 1 is the fork refusal: stop, run nothing else, and follow `wiki/concepts/PR Merge Workflow.md` `## First step: refuse a fork PR`. Exit 2 stops `needs-human` with the printed line.

Then open the record, with `<head>` the full sha of `git -C <RESOLVED_ROOT> rev-parse HEAD`:

```bash
bash .gaia/scripts/pr-review-record.sh open --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --pr <N> --head <head> --bundle <bundle dir>
```

`opened` continues at step 4. `exists` means a review for this PR already has an outcome: no dispatch, go to step 5.

<!-- gaia:maintainer-only:start -->
In this repo, on a PR wholly out of audit scope, the CHANGELOG gate's merge-time check and the advisory-check read (`wiki/concepts/PR Merge Workflow.md` `### 4. Merge`, the two maintainer steps) run before this step, so any commit they make precedes the reviewed head and the out-of-scope commit check never counts it.
<!-- gaia:maintainer-only:end -->

## 4. Dispatch the reviewer

Each attempt runs in this order, and no `pr-review-record.sh` call runs between `snapshot` and `compare`, so the record's own writes never read as a change:

1. Pre-clear the output path: `rm -f <scratchpad>/pr-review-<N>.json`.
2. `bash .gaia/scripts/pr-review-record.sh attempt-open --run-folder <RUN_FOLDER>` prints the attempt number `<n>`.
3. `bash .gaia/scripts/pr-review-guard.sh snapshot --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --pr <N> --out <scratchpad>/pr-review-before.json`. Exit 1 (a dirty tree) stops `needs-human` with the printed line, before any dispatch.
4. Dispatch, with exactly two lines in the prompt:

   ```text
   Agent(
     subagent_type: "pr-reviewer",
     prompt: "Bundle: <bundle dir>
     Output: <scratchpad>/pr-review-<N>.json"
   )
   ```

5. Wait on the output file and never classify when the `Agent` call returns (`.claude/rules/subagent-dispatch.md`).
6. `bash .gaia/scripts/pr-review-guard.sh compare --before <scratchpad>/pr-review-before.json --after <scratchpad>/pr-review-after.json --output-file <scratchpad>/pr-review-<N>.json`. Exit 1 stops `needs-human` with the printed line: no `attempt-close`, no disposition and no commit is made, and the human decides what the reviewer's change means.
7. Classify the file: `bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <scratchpad>/pr-review-<N>.json`, with no count, since the finding count is unknown.
8. `bash .gaia/scripts/pr-review-record.sh attempt-close --run-folder <RUN_FOLDER> --n <n> --classifier-exit <the classifier's exit>`.
9. On classifier exit 0, `bash .gaia/scripts/pr-review-record.sh outcome --run-folder <RUN_FOLDER> --findings <scratchpad>/pr-review-<N>.json`. Exit 0 records the findings: go to step 5. Exit 3 is a schema refusal, recorded on the attempt as a no-op.

A no-op (classifier exit 1) or a schema refusal on attempt 1 re-dispatches once, from item 1. The same on attempt 2 records the review not run, publishes the section (step 7) and stops `needs-human`:

```bash
bash .gaia/scripts/pr-review-record.sh not-run --run-folder <RUN_FOLDER> --reason "reviewer silent twice"
```

This departs from `.claude/rules/subagent-dispatch.md`'s inline ending on purpose: a review written by the main thread would be anchored on the audit ledger, so a human decides instead. An interactive run asks one `AskUserQuestion` with header `PR review`, naming the not-run line, with options `Hold (Recommended)` (leave the PR open and stop) and `Retry review` (rebuild the bundle, reopen the record with `open --retry`, and dispatch again from item 1). The merge stays refused while the record says not run.

An `Agent` call refused because `pr-reviewer` is not a loaded agent dispatched nothing and is not a no-op. Record it and stop `needs-human` with the relaunch line `wiki/concepts/PR Merge Workflow.md` `#### The branch checkpoint` prints for a changed agent definition (Ctrl+C, relaunch, then the continuation prompt):

```bash
bash .gaia/scripts/pr-review-record.sh attempt-close --run-folder <RUN_FOLDER> --n <n> --dispatch-failed
bash .gaia/scripts/pr-review-record.sh not-run --run-folder <RUN_FOLDER> --reason "reviewer agent not loaded"
```

The relaunched session reopens the record with `open --retry` and dispatches from item 1.

## 5. Dispose every finding

The main thread, which may read the audit ledger, decides each finding, recording it with:

```bash
bash .gaia/scripts/pr-review-record.sh dispose --run-folder <RUN_FOLDER> --id pr-<n> --disposition <d> [--reason <text>] [--issue <n>] [--basis <b>]
```

- The test is the audit's: fix by default (`wiki/concepts/PR Merge Workflow.md`, `**Two layers decide a finding.**`). The set and its rules are the audit's (`.gaia/scripts/audit-dispositions-check.sh` header: the reason, basis and Critical or security-class rules), plus `dismiss`, whose reason cites the evidence that makes the finding not a defect. The record script refuses a disposition its rule forbids, prints the line, and leaves the finding undecided.
- Every review finding counts as branch-authored, so `divert` and the audit's outside-branch exceptions never apply. Never pass `--severity` or `--security` to change a finding's class: the class is the reviewer's.
- A finding that repeats one the audit already disposed is new only when it carries evidence that disposition did not weigh, such as a failing input the audit's reason did not consider; then it is disposed like any new finding, `fix` by default. Without such evidence it takes `dismiss` with the reason `audit already disposed this: <the audit's reason>`.
- `file` goes through `.gaia/scripts/file-tech-debt.sh` (the `file-tech-debt` skill says how to call it), and its `--issue` is the issue number that prints. With no issue number (a refusal, a failure, no issue backend) the finding is not filed: dispose it another way.
- `accept-residual` is the human's alone. The main thread may offer it on a finding that is neither Critical nor security-class: it prints the line for the human to type as the whole prompt, then records the disposition once the hook reports the accept recorded. For finding `pr-2`, the human types:

```
pr-review-accept pr-2
```

Fixes go ahead without a question. Once every finding has a disposition, print the report:

```bash
bash .gaia/scripts/pr-review-gate.sh report --run-folder <RUN_FOLDER>
```

It prints the tally line, then one line per finding left unfixed with its reason. A security-class finding's file, line, summary and failure scenario stay in the local record: what the main thread prints, publishes, files or puts in a park detail about one is only the redacted line the report and the section carry.

## 6. Route each fix

For each finding disposed `fix`:

```bash
bash .gaia/scripts/pr-review-record.sh route-fix --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --id pr-<n> [--repair-path <path>]...
```

When the repair belongs in a file other than the finding's, pass `--repair-path <path>` once per such file. The key keeps the finding's file and line, so the finding's owner must still stop re-reporting it, and the veto also needs a change to each repair path reviewed clean by that path's owner. A path no member owns, an empty one, or one on `ENFORCEMENT_PATHS` is refused, and so is any repair path on a finding whose route is not `veto`. Passed on a finding already routed, `--repair-path` rewrites the key, so only a change from the next round on counts.

It prints the route:

- `veto <owner>`: the script has written the veto key, so the audit loop's fixer repairs the finding and the owner's review satisfies the key. Dispatch the next unit from step 1 of `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`. Once a clean unit satisfies the veto, record `bash .gaia/scripts/pr-review-record.sh fixed --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --id pr-<n> --commit <sha>` with the audit fixer's commit; it refuses while the veto is unsatisfied. Any further fixer commit for the finding is recorded with `fix-commit --run-folder <RUN_FOLDER> --sha <sha>`. Either keeps the commit out of the out-of-scope commit check. When the fixer disputes the repair or the owner re-reports the finding, record `bash .gaia/scripts/pr-review-record.sh dropped --run-folder <RUN_FOLDER> --id pr-<n> --by <member> --evidence <text>` with that evidence, which withdraws the key, then dispose the finding afresh, not `fix`, with a reason citing it (a Critical or security-class finding takes `dismiss` here, which the record script accepts only once its fix is dropped). The review is not dispatched again.
- `body`: correct the claim in the body-truth rewrite (`wiki/concepts/PR Merge Workflow.md` `#### Posting the status last`, the PR body bullet), then record `fixed` with no `--commit`.
<!-- gaia:maintainer-only:start -->
- `changelog`: fix the entry with the CHANGELOG gate's correction commit (`wiki/concepts/PR Merge Workflow.md` `## CHANGELOG gate (maintainer-only)`), then record `fixed --commit <sha>`, which lists the commit as a review fix so the out-of-scope commit check never counts it.
<!-- gaia:maintainer-only:end -->
- Exit 4, printing `PR review: fix needs a human on an unowned path: <path>`: no member owns the path, so no veto can be satisfied. Stop `needs-human` with that line. A human repairs it and the main thread records `fixed --commit <sha>` with the repair commit; a further repair commit with no finding of its own is recorded with `fix-commit --run-folder <RUN_FOLDER> --sha <sha>`. Either keeps the commit out of the out-of-scope commit check.

A fix that moves HEAD on a code PR runs the `clean` row of `wiki/concepts/PR Merge Workflow.md` again from the late worthiness pass, so the status is posted on the new head.

## 7. Publish and confirm

After every disposition change, and always before the status post and before `gh pr merge`, rewrite the PR body's section from the record:

```bash
bash .gaia/scripts/pr-review-gate.sh publish --root <RESOLVED_ROOT> --pr <N>
```

Then confirm, with `--out-of-scope` on a PR the merge hook's out-of-scope bypass or `chore(deps)` waiver clears (`wiki/concepts/Audit Gate Reference.md`, `#### Signals`):

```bash
bash .gaia/scripts/pr-review-gate.sh check --root <RESOLVED_ROOT> --pr <N> [--out-of-scope]
```

Exit 0 ends the step. Exit 1 prints the one thing still owed; resolve it from the step that owns it. Exit 2 (root, `gh` or the PR unreadable) stops `needs-human` with the printed line. The merge hook, the status poster and `gaia wiki chain finish` read the same verdict and refuse until it passes.

## Unattended runs

An unattended run follows every step above, minus printing to a human, and the review spends none of the audit budget:

- It records every disposition and never `accept-residual`: a finding it does not fix it files or dismisses. The report's lines go into the run's final report.
- A veto's unit is admitted or parked by the existing checkpoint rules (`wiki/concepts/PR Merge Workflow.md` `#### The branch checkpoint`).
- Every `needs-human` stop on this page (a dirty tree, a guard change, an unreadable record, a not-run review, an unowned-path fix) parks instead of asking, before any question, with the printed line as the detail; for a security-class finding the detail is the report's redacted line:

```bash
bash <RESOLVED_ROOT>/.gaia/scripts/autonomy-park.sh --reason question --pr <N> --detail "<the printed line>"
```

- It merges only once `pr-review-gate.sh check` passes, and never past a stop.
