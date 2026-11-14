# Security writer

Contents: When it runs; The step; The audit-loop arm; What it never does.

This page owns the security-writer step of a plan run: the separate agent that writes the tests of security and permission rows (access, forgery, secrets), so a test cannot mirror the code's mistake. The orchestrator's `security-writer` block points here. The judgment is `.claude/agents/security-test-writer.md`; the rule for what a security row is lives in `.claude/doctrine/testing.md` (`## Guards and security rows`).

## When it runs

At the end of each build phase whose entry carries a `- Security writer:` line, after the phase's task executors return and before the phase's quality gate. `<RESOLVED_ROOT>` is the working root, `{PLAN_DIR}` the plan folder at its main-checkout absolute path. Scratch files live in the session's scratchpad directory.

## The step

1. **Dispatch.** The phase's security rows are the rows of `{PLAN_DIR}/tests.json` whose `security` is not `none` and whose `task` is a task of this phase. Pre-clear the report path in the scratchpad with `rm -f`, then dispatch one `Agent(subagent_type: "security-test-writer")`. The prompt names the report path and says the file is JSON, carries `RESOLVED_ROOT`, the frozen interfaces from `{PLAN_DIR}/README.md`, and one line per row: `Row: <id> › <file> › <title> › <layer> › <security kind> › <case>`. Wait for the agent to finish, then classify the report:

   ```bash
   bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <report> --expect-count <rows>
   ```

   On a no-op, re-dispatch exactly once against the re-cleared path. A second no-op goes to step 5.

2. **Record.** For each `written` row, run from the main checkout (the plan folder is main-anchored and the record step writes through Node):

   ```bash
   node .gaia/scripts/test-design/test-table.mjs record-security --plan-dir {PLAN_DIR} --root <RESOLVED_ROOT> --row <id>
   ```

   A non-zero exit (the test is absent) counts as a `cannot_write` row.

3. **Run the tests.** Run the phase's security tests with their runner: a `.bats` file through `pnpm test:shell <file> < /dev/null`, a Vitest file through `pnpm -C <package> test --run <path>`, a Playwright file through `pnpm -C <package> exec playwright test <path>`.

4. **Fix the code, never the test.** A failing security test goes once to a fresh executor for the row's owning task. Its prompt is the original task prompt without its `Yield handoff:` line, then `A security test written for this task's code fails. Fix the code, never the test; the test is not yours to edit. The failing tests:` and the output. Re-run the tests.

5. **Halt.** A second failure, a `cannot_write` row, or a second no-op: append `## Phase N, <title> (HALTED)` to `{PLAN_DIR}/PROGRESS.md` with `Reason: security writer: <test fails after one code fix | cannot write row <id> | no report>` and `Gate retries: <n>`, then ask `Stay halted (Recommended)` then `Discuss this`. Auto mode and an unattended run take the same halt; the recommended option keeps it halted.

6. **Pass.** On a pass the phase goes on to its quality gate; the security tests ride the phase commit.

## The audit-loop arm

When an audit fixer adds or replaces a security row, the loop unit runs the same dispatch for those rows only, before the round's gate. The round's fixer is the code owner for step 4. A second failure stops the unit `needs-human`.

## What it never does

- The writer never edits code, `tests.json` or `tests.approved.json`.
- Nobody weakens a security test, and a task executor never writes a security row's test: an executor-written test under a security row's title does not satisfy the merge gate.
