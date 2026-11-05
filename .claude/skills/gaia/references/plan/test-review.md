# Test review

Contents: When it runs; Round 1; A defect; Round 2; A no-op review; The prompt template.

This page owns the test review of a plan run: a check, after a wave's test authors have recorded their REDs and before any implementer runs, that each new test asserts the behavior its task doc and SPEC specify. A recorded RED proves a test can fail, not that it asserts the right thing; a wrong assertion still fails against a stub. Once the implementation exists, fixing that assertion voids its RED and no honest run can record a new one, so the phase halts. While only stubs exist, a fix is still honest.

## When it runs

Step 2 or 3 of the test-first split block (`planner.md`, `<!-- gaia:orchestrator-step red-split -->`) passes its RED check for a wave that has at least one splitting task. A wave with none skips the review. `<RESOLVED_ROOT>` is the working root; scratch files live in the session's scratchpad directory, or a `mktemp -d` directory when the session lists none, never under `{PLAN_DIR}` (`.claude/rules/subagent-dispatch.md`).

## Round 1

1. Take `<VERDICT_FILE>` as `test-review-phase-<N>-wave-<W>-r1.json` in the scratch directory and pre-clear it: `rm -f <VERDICT_FILE>`.
2. Dispatch one reviewer for the wave: `Agent(subagent_type: "general-purpose", model: "sonnet")` with no `effort` parameter, its prompt the template below with one `Task doc:` line per splitting task and one `Test file:` line per file its `New tests:` line names. A spec-less plan sends no `SPEC path:` line.
3. Once it returns, classify the file:

       bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <VERDICT_FILE> --min-count <number of Test file: lines>

   Exit 1, or an array that names no entry for some `Test file:` path, is a no-op (`## A no-op review`). Exit 2 halts under Stop conditions.
4. Every entry `ok`: go to step 4 of the test-first split block, the implementers.

## A defect

Map each `defect` entry's `file` to the task whose `New tests:` line names it.

- **Halt.** When an owning task already appears on the `Tasks:` line of a `(TEST REVIEW 1)` block for this phase in `{PLAN_DIR}/PROGRESS.md`, append this block and stop:

      ## Phase N, <title> (HALTED)
      Reason: test review defect after one fix
      Defects: <file:line › test: expected, for each defect entry>

- **Record the fix round.** Otherwise append:

      ## Phase N, <title> (TEST REVIEW 1)
      Tasks: <task-<T>.md of each owning task>
      Defects: <file:line › test: expected, for each defect entry>

- **Re-dispatch the owning test authors only**, in parallel, each a test-author dispatch of yield unit `phase-<N>-task-<T>-tests` with its handoff pre-cleared as in step 1 of the test-first split block: the task prompt with the test-author clause, then the line `A review found that these assertions do not state the specified behavior. Fix only these test bodies, against the stubs. Run the RED command for each file you changed:`, then that task's defect lines, then the line `Yield handoff: {PLAN_DIR}/handoffs/phase-<N>-task-<T>-tests-yield-<k>.md`, k being that unit's yield count plus one.
- **Re-check the REDs.** Run `bash .gaia/scripts/red-ledger/red-pending.sh --root <RESOLVED_ROOT>`. An edited test body voids its old RED, so this proves the new one. Exit 2 halts under Stop conditions. Exit 1 appends `## Phase N, <title> (HALTED)` with `Reason: no recorded RED after test review` and each `file › test name`, and stops.

## Round 2

When the RED re-check exits 0, run round 1 again as round 2: `<VERDICT_FILE>` ends `-r2.json`, and the dispatch names only the owning tasks' task docs and test files. Every entry `ok` goes to the implementers; any `defect` takes the halt above.

## A no-op review

Re-dispatch the round once against the re-cleared path. A second no-op appends `## Phase N, <title> (HALTED)` with `Reason: test review produced no verdict file` and stops. This departs from the general inline ending (`wiki/concepts/Code Review Audit Agent.md`, `### The terminal action, stated once`) deliberately: the orchestrator dispatched the wave under review, so it cannot legitimately do the work itself.

## The prompt template

Send these lines, then the paragraphs below them, verbatim:

```
SPEC path: <absolute path to SPEC.md>
Task doc: <absolute path to task-<T>.md>
Test file: <absolute path to a New tests file>
Verdict file: <VERDICT_FILE>
```

You review new tests before any implementation exists; each runs against a stub. Your one judgment: does each assertion state the behavior the task doc and the SPEC specify?

Read the SPEC, each task doc and each test file named above, plus any file a test imports from the same test folder. Edit nothing and run no command that writes a file; the verdict file is the one file you write.

A test is a `defect` only when you can cite the line it breaks: a SPEC Then-clause or listed case, or a task doc line. No citation, no defect. With no `SPEC path:` line, cite the task doc only. The three defects:

- **Over-constraint**: it asserts something the cited line does not fix: values carried over from earlier state (spreading a previous row or response into the expectation), generated ids, timestamps, exact wording, or an order the line leaves open.
- **Under-constraint**: it never asserts a Then-clause or listed case the cited line gives it, or asserts something weaker (a status where the line names a saved record).
- **Contradiction**: the expectation contradicts the cited line.

Out of scope: whether the test is worth keeping, which layer it belongs on, naming, style, and how the stub behaves.

Write the verdict file with the Write tool, once, as a JSON array with one object per test in each test file, in file order:

```json
[
  {
    "file": "<test file path>",
    "line": 0,
    "test": "<test name as written>",
    "verdict": "ok",
    "cite": "<for a defect: the SPEC or task doc line, quoted>",
    "expected": "<for a defect: what the assertion should state, in words>"
  }
]
```

For a defect, `line` is the line of the wrong assertion; for `ok`, the line of the test's title. Reply with one line: the count of `ok` and `defect` verdicts.
