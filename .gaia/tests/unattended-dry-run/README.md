# Unattended dry run

Maintainer-only (all of `.gaia/tests` is release-excluded). One `/gaia-next` iteration runs with the [autonomy switch](../../../wiki/concepts/Autonomy%20Switch.md) on, as a headless `claude -p` session in an adopter fixture. The check proves that the iteration ends without stalling, that the question gate wrote its decision-log entry, and that a forced audit checkpoint parked the run.

It spends model usage and needs Claude auth, so it is a manual check: run it by hand after a change to the gate, the park procedure, the audit budget, the merge policy, `/gaia-next` or `.claude/loop.md`.
## Files

- `run-dry-run.sh`: builds the fixture, runs the session, asserts, and writes the evidence.
- `build-fixture.sh`: builds the fixture alone. Its header lists the layout and what the fixture forces.
- `gh-stub.sh`: the `gh` on the session's `PATH`, standing in for GitHub.

## Running it

```
bash .gaia/tests/unattended-dry-run/run-dry-run.sh --out "$(mktemp -d)" --max-usd 3
```

`--out` must be an empty directory outside this checkout and outside any git repository. Inside one, the session would load that repository's harness instead of the fixture's. The fixture is the release bundle from `.gaia/tests/distribution/lib/build-staging.sh`, committed with a local bare remote, so it runs the adopter harness, with the maintainer marker stripped.

Flags: `--model` (default `sonnet`), `--permission-mode` (default `bypassPermissions`), `--max-minutes` (default 30, a wall-clock kill), `--mutate none|gate|park`. `CLAUDE_BIN` overrides the `claude` binary.

Sonnet is the cheapest model that reaches the checkpoint. On Haiku the gate half passes, but Haiku ends the `pr` job before dispatching the audit unit, once citing the spend cap and once parking with reason `question` because `may_merge` is false. So the `parked` and `comment` assertions fail on a model choice, not on the harness.

A plain `claude -p` session has no `AskUserQuestion` tool: ToolSearch cannot load it, so the gate's question arm never fires there. The tool exists only when a host answers prompts, so the session runs with `--input-format stream-json --permission-prompt-tool stdio`, the protocol the Agent SDK speaks, and the prompt arrives on stdin.

The default permission mode is not the `auto` mode [GAIA Next](../../../wiki/concepts/GAIA%20Next.md) recommends for a real unattended run: auto mode's classifier can block a call and end the run for reasons this check is not testing. Under `bypassPermissions`, deny rules and the fixture's hooks still apply, the question gate among them. `gh` is the stub, its config directory is empty, and the remote is local. Only project and local settings load (`--setting-sources project,local`), so your own hooks never run in the fixture.

## What it asserts

The iteration reaches no question before it parks, so `--append-system-prompt` tells the session to ask one with a single `(Recommended)` option before its first step. The gate must deny that call, log the option and tell Claude to take it.

- `ended`: the session ended with a `result` event, not at the wall-clock kill.
- `answered`: the session called `AskUserQuestion`, and every call got a tool result.
- `decision-log`: the decision log holds the gate's entry for that question, carrying this session's id.
- `parked`: the parked marker names `audit-checkpoint`, the fixture's pull request and the branch head origin holds.
- `comment`: the stub recorded the park comment with its `audit-grant <n>` line.

The checkpoint is forced: the pull request branch's audit loop state holds six rounds at `checkpoint_round: 6`, and the switch sets an audit budget of zero units. The first unit dispatch is denied at the round-count checkpoint, the budget declines to answer it, and the denial tells an unattended run to park.

Evidence lands in `--out`: `stream.jsonl` (with hook events), `stderr.log`, `summary.json` (cost, wall seconds, each assertion) and the fixture. Exit 0 means every assertion passed, 1 that one failed, 2 a usage error or a refused `--out`, and 3 that the fixture or the session could not start.

## Negative proofs

- `--mutate gate` drops the `autonomy-gate.sh` registration from the fixture's `.claude/settings.json`. The run must fail `decision-log`.
- `--mutate park` replaces `autonomy-park.sh` with a script that prints a park line and does nothing else. The run must fail `parked`.

## Cost

On Claude Code 2.1.332 with Sonnet, a passing run cost $0.32 and took 48 seconds, and the `--mutate park` run cost $0.35. The `--mutate gate` run ends at the unanswered question, for $0.12 in 8 seconds. A `--max-usd 3` cap leaves room for a session that wanders. `summary.json` records each run's real figure.

No CI job runs it: the run needs Claude auth on the runner and spends usage on every trigger, and the check guards changes that land a few times a release.