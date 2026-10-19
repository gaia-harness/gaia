# Subagent Dispatch

When a dispatched agent's output is something you will act on, do not ask for it in the reply: an absent report reads as "it found nothing", the conclusion you must not draw.

**Give it a file, and say in the dispatch prompt that the file is JSON.** Put the file in the session's scratchpad directory, or a `mktemp -d` directory when the session lists none, never under `.gaia/local` or `.notebook` when the agent writes it with the Write tool: in a worktree both are symlinks into the main checkout, so worktree isolation refuses the agent's Write there. A procedure whose own steps put the artifact in a run folder or plan folder keeps that location, and the agent writes it there by copying a scratchpad file in with one plain `cp` (`.claude/doctrine/execution.md`, `## Run folder`). Pre-clear the output path (`rm -f`), have the agent write its result there and return only a short summary, then classify the file. The artifact must be a JSON **array**, either the top-level value or the value at the one top-level key `--report-key` names; a Markdown or plain-text report classifies NO-OP however complete it is.

```bash
bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <path> \
  [--report-key <key>] [--expect-count <n> | --min-count <n>]
```

Exit 0 REAL (usable artifact; says nothing about its findings), 1 NO-OP (unusable: treat as if the agent never ran, never as "found nothing"), 2 usage error. **Pass a count when you know one**: a truncated write parses fine and reads as real otherwise. On a no-op, re-dispatch **exactly once** against the re-cleared path; a second consecutive no-op means doing the work inline yourself and applying the result as if the agent had returned it.

**Poll the file, not the notification**, and **never classify at the moment the dispatch call returns**: the `Agent` call returns dispatch metadata immediately, before the agent has done anything, so classifying there reads a no-op on a dispatch still running correctly and spends the one hardened re-dispatch on it.

Full contract for this shape, including what the terminal action is: the `No-op guard against silent subagents` section of `wiki/concepts/Code Review Audit Agent.md`. An artifact whose path moves between rounds (`--findings-root`): `wiki/concepts/Audit Round Procedure.md` ("No-op detection and retry for each dispatched member").
