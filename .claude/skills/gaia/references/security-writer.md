# Security writer

Contents: When it runs; The step; The audit-loop arm; What it never does.

This page owns the security-writer step of a plan run: the separate agent that writes the tests of security and permission behaviors (access, forgery, secrets), so a test cannot mirror the code's mistake. The orchestrator's `security-writer` block points here. The judgment is `.claude/agents/security-test-writer.md`; what a security test proves lives in `.claude/skills/gaia/references/test-stage.md` (`## Security section`).

## When it runs

At the end of each build phase whose entry carries a `- Security writer:` line, after the phase's task executors return and before the phase's quality gate. `<RESOLVED_ROOT>` is the working root, `{PLAN_DIR}` the plan folder at its main-checkout absolute path. Scratch files live in the session's scratchpad directory.

## The step

1. **Dispatch.** The phase's security tests are the Test lines of its task docs whose security kind is not `none`. Pre-clear the report path in the scratchpad with `rm -f`, then dispatch one `Agent(subagent_type: "security-test-writer")`. The prompt names the report path and says the file is JSON, carries `RESOLVED_ROOT`, the frozen interfaces from `{PLAN_DIR}/README.md`, and one line per test: `Test: <behavior id> › <file> › <title> › <layer> › <security kind> › <task stem>`, then the SPEC behavior and its cases (a spec-less plan: the task's acceptance criterion). After the line of a forgery test whose `layer` is `story`, add `Sibling: <behavior id> › <file> › <title>` when the plan lists a `route` or `real-server` forgery Test line for the same behavior id, in any phase. Wait for the agent to finish, then classify the report:

   ```bash
   bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <report> --expect-count <dispatched tests>
   ```

   A second consecutive no-op goes to step 5.

2. **Record.** For each `written` entry of the report, append one JSON line to `{PLAN_DIR}/security-tests.jsonl`: `{"file":"<path>","title":"<title>","kind":"<kind>","task":"<task stem>","recorded":"<ISO 8601 UTC>"}`. Write the line the way the test stage writes its files (`test-stage.md` and the tool-choice contract: in worktree mode through the scratchpad plus one `cp`). A written test whose file is absent counts as a `cannot_write` entry.

3. **Run the tests.** Run the phase's security tests with their runner: a `.bats` file through `pnpm test:shell <file> < /dev/null`, a Vitest file through `pnpm -C <package> test --run <path>`, a Playwright file through `pnpm -C <package> exec playwright test <path>`.

4. **Fix the code, never the test.** A failing security test goes once to a fresh executor for the test's owning task. Its prompt is the original task prompt without its `Yield handoff:` line, then `A security test written for this task's code fails. Fix the code, never the test; the test is not yours to edit. The failing tests:` and the output. Re-run the tests.

5. **Halt.** A second failure, a `cannot_write` entry, or a second no-op: append `## Phase N, <title> (HALTED)` to `{PLAN_DIR}/PROGRESS.md` with `Reason: security writer: <test fails after one code fix | cannot write test <behavior id> | no report>` and `Gate retries: <n>`, then ask `Stay halted (Recommended)` then `Discuss this`. Auto mode and an unattended run take the same halt; the recommended option keeps it halted.

6. **Pass.** On a pass the phase goes on to its quality gate; the security tests ride the phase commit.

## The audit-loop arm

When an audit fix adds or changes a security behavior, the fixer names it in its result's `security_behaviors` field. The loop unit dispatches the writer once for each entry, before the round's gate, handing it that entry's stated rule, its kind and the frozen interface (the plan's `README.md`, or the entry's own sentence when the plan has no SPEC). A forgery entry on a story test takes the `Sibling:` line when a route or real-server forgery test of the same behavior exists. The round's fixer is the code owner for step 4. A second failure stops the unit `needs-human`.

## What it never does

- The writer never edits code.
- Nobody weakens a security test, and a task executor never writes a security test: an executor-written test under a security Test line's title has no line in `security-tests.jsonl`, so a resume re-runs the phase's security-writer step over it.
