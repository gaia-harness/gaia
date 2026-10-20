# Audit cost toolkit

Maintainer-only (all of `.gaia/tests` is release-excluded). It measures what a Code Audit Team dispatch costs before and after a change to the team's definitions: first-call context, per-dispatch cost and wall time, round 1 only. It mines Claude Code transcripts, prepares isolated scratch trees, and drives the replays and first-call probes. The probe and replay drivers spend tokens and need Claude auth, so a maintainer runs them by hand under a spend cap; nothing runs them in CI. The bats suite (`.gaia/tests/lib/audit-cost-measure.bats`) exercises everything else against committed fixtures and stubs.

Savings were probed on Claude Code 2.1.304. A client at 2.1.292 or later still runs every definition correctly without the saving.

## Files

| File | Role |
|---|---|
| `lib/transcripts.mjs` | Transcript library: `listAgents`, `readCalls`, `finalReplyText`, `firstCallAttachments`, `classifyChild`. The recall harness imports it; `classifyChild` is the one role classifier both the measurement and the recall scorer use. |
| `lib/session-checks.mjs` | Two checks the drivers share: whether the round-1 frontend member wave has returned, and whether a listed tool was called without ToolSearch and without an error result. |
| `measure-dispatch.mjs` | One main session transcript in, schema-1 measure JSON out. |
| `summarize-runs.mjs` | Round-1 medians over a fixed number of measure files. |
| `prepare-scratch-clone.sh` | The one way a run gets a maintainer tree. |
| `probe-first-call.sh` | One fresh `claude -p` session per agent type, then `measure-dispatch.mjs` over each; optional callability probes. |
| `run-replay.sh` | One round-1 audit replay in a throwaway adopter checkout. |
| `replays/*.patch` | The two replay changes, authored against the tracked `frontend/app` files a scaffold ships as-is. |
| `fixtures/` | A trimmed real session (`rc3-trimmed/`, with the rates file it is priced from and `expected.json`) and small synthetic sessions for the cases the real slice lacks. |

## Cost method

The transcript method, and the only one before and after compare on:

1. Assistant API calls are deduped by message id. Claude Code writes a record per content block of a streamed message, each carrying the usage so far, so the last usage block per id is the call's usage.
2. Every call is priced from one committed `token-rates.json` revision with the rules of `.gaia/scripts/token-pricing-lib.sh`: the rate row is selected by model and by the call's date against each row's `effective_through`; fresh input at the input rate; 5-minute cache writes at input x `cache_multipliers.write_5m`; 1-hour cache writes at input x `cache_multipliers.write_1h`; cache reads at input x the row's `cache_read_multiplier`, else `cache_multipliers.read`; output at the output rate. A main session that writes cache only in the 1-hour bucket is mispriced by a 5-minute-only rule, so both buckets are read.
3. The script exits 3 naming any model id the rates file cannot price.

This method totals less than the figure a session reports about itself. Compare numbers only against numbers from this method.

`measure-dispatch.mjs --session <main session jsonl> --rates <token-rates.json> [--out <file>]` prints the schema-1 JSON. `--measure-types a,b` also measures those agent types wherever they sit in the tree (the probe dispatches one type straight from the main thread). A dispatch is measured when it is a Code Audit Team member, a descendant of one, or a direct child of the audit loop unit dispatched before the unit's first fixer; the unit itself is reported in `unit`, and every other agent type present is listed in `excluded_agent_types`. `round` is 1 before the unit's first fixer dispatch and 2 or more after. `children_by_role` counts a member's specialists by role and its refuters under `refuter`. `noop_retries` counts a second dispatch of the same specialist role by the same parent.

## Scratch-clone rule

Every probe, replay and recall run happens in a scratch tree, never the live checkout or a linked worktree. `prepare-scratch-clone.sh --source <repo> --ref <sha|branch> --out <dir>` clones with `--no-hardlinks`, checks the ref out as the clone's local `main`, removes `.claude/rules/maintainers/harness-triage-threshold.md` and commits the removal, cuts `scratch-<epoch>` and writes the sentinel `<dir>/.gaia/local/measurement-scratch`. The probe, replay and recall drivers refuse (exit 2) a root without the sentinel, before any `claude` call.

Why the marker is stripped: in a tree carrying it, `audit-loop-bound.sh` refuses the first member or unit dispatch until `verify-harness.sh branch` has passed for that HEAD, a multi-minute run per replay HEAD that historical trees are likely to fail. That gate guards the maintainer's own merges, not a measurement. Removing the marker also turns off the maintainer-only branches of `audit-light-telemetry.sh` and `audit-loop-eval.sh` and removes one rule file from a member's project instructions, none of which changes what a member reviews. Before and after clones get the identical treatment, so the comparison stays like for like.

## Building a bundle

A before or after bundle is a scaffolded adopter checkout built from a committed tree:

1. Make a committed clone of the before or after tree (a scratch clone from `prepare-scratch-clone.sh` works, or `git worktree add` on the commit).
2. Copy the maintainer's local create-gaia script to a temporary location and set its `REPO` to that clone. Never edit the original.
3. Run the copy with `--no-claude --no-install` and a throwaway project name. It builds the release bundle from the clone and scaffolds it.
4. Give the scaffold a GitHub remote, write the sentinel into it, and pass it to `run-replay.sh` as `--scaffold`.

## Replays

`run-replay.sh --scaffold <throwaway> --replay language-file|tsx-variant --run <k> --out <dir> --max-usd <n>` cuts `replay-<replay>-<k>-<epoch>` from the throwaway's `main`, applies `replays/<replay>.patch`, commits, pushes, opens a draft pull request, runs the audit gate in one headless session, and stops the session once the round-1 frontend member wave has returned. It writes `run.json` (Claude Code version, start and end UTC, the router's route and reason) and `measure.json`. A trap closes the draft pull request and deletes the remote branch on exit.

The router must send the frontend member down its full route; a light or quick route leaves no specialist wave, so the driver treats it as an input error (exit 2, no `measure.json`). The language-file patch carries more than the router's 40-line quick cap across the two `en` files, and adds language keys, so it routes full by line cap or by the added keys. The tsx-variant patch adds a `useTranslation` import and hook call, which route full on their own.

**Spacing rule.** Start consecutive runs at least 6 minutes apart, so the 5-minute cache lifetime cannot carry a prefix from one run into the next. Record the actual spacing: it is the gap between one run's `end_utc` and the next run's `start_utc` in `run.json`.

## Probes

`probe-first-call.sh --root <scratch tree> --types <comma list> --out <dir> --max-usd <n> [--callability]` runs one session per type. `--callability` adds, for `audit-loop-unit`, a trivial child dispatch continued once with `SendMessage` plus one `Monitor` on `echo ok`, and for `code-audit-maintainer-shell` one `Monitor` and one `WebFetch` of `https://example.com`; `<out>/callability.json` lists `{type, tool, called, toolsearch_used, error}`. A tool passes when it was called, ToolSearch was not used, and no result was an error. Both drivers stop and record `summary.json` when the accumulated cost reaches `--max-usd`.

## Fixtures

`fixtures/rc3-trimmed/` is a real audit session cut to what the measurement reads: the main session and a dozen of its sub-agent transcripts, with thinking blocks, tool output, request shapes and most attachments dropped, attachment text replaced by same-length filler, and every home path, email address, token-shaped string and session URL replaced by a placeholder. `expected.json` is the measure JSON it must produce, priced from the `token-rates.json` copied beside it so a later price change cannot move it. `fixtures/synthetic/` holds hand-built sessions for a duplicated specialist dispatch, a member that reads the refuter reference, an after-bundle specialist with an `Extension rule files:` block, and a repeated message id with a 1-hour cache write.
