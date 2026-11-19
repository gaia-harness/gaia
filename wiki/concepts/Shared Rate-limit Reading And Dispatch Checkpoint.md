---
type: concept
status: active
created: 2026-11-19
updated: 2026-11-19
promoted_at: 2026-11-19T06:51:37Z
promoted_hash: sha256:c4b5a650bc8d8e954d04ac29eb9207d3b9a8b5627d1803893d2627f55620af56
pr_number: 3673
tags: [promoted, concepts]
---

# Shared rate-limit reading and dispatch checkpoint

Every GAIA session of one checkout shows the freshest 5-hour and 7-day rate-limit reading any of its sessions has seen, and a main session dispatching an Agent, Task or Workflow at or above the warning band is handed that reading and a pointer to the policy for acting on it. Nothing ever blocks a dispatch.

## Behavior

### The shared reading

- **One file per checkout.** `<main checkout>/.gaia/local/cache/shared/rate-limits.json`, reached from every linked worktree through its `.gaia/local` symlink. It holds `version` 1 and, per window name, `used_percentage`, `resets_at` (epoch seconds), `observed_at`, `producer` and a capped `history`. Unknown keys are kept on rewrite; a file of another version is left untouched and read as no reading.
- **One writer.** `gaia_rate_limits_write` in `.gaia/scripts/rate-limits-lib.sh` validates the input, merges, records history and replaces the file atomically (`<file>.tmp.<pid>`, then `mv -f`), in one jq process per call, and prints the merged display records whatever its exit code, so a failed or refused write still renders the higher of file and payload. `producer` (`statusline` or `mod`) is provenance only.
- **Merge rule per window.** Reset times within 600 seconds are the same window: the higher percentage wins and the later reset is kept. A reset more than 600 seconds later replaces the window, history included; one more than 600 seconds earlier is ignored. A lower same-window reading advances neither the figure nor `observed_at`. An unchanged write less than 60 seconds after the last observation skips the rewrite.
- **Bounds.** Percentages from 0 to 999, integer `resets_at` within the window's maximum length plus 600 seconds of now, at most 8 windows, names of lowercase letters, digits and underscores. A refused reading exits 2 with `rate-limits: invalid reading` and leaves the file untouched.
- **Bands.** The warning and critical bands are defined once, as constants in `.gaia/scripts/rate-limits-lib.sh`; the statusline render and the hook read them there.
- **Producer and display.** Every statusline render, whatever draws the left side, passes its payload's windows to the writer. When GAIA draws the left side it displays each window from the merged records; an expired window renders `reset`. A payload window with no `resets_at` is shown from the payload and never written.
- **Reader.** `bash .gaia/scripts/rate-limits.sh read` prints one line per valid window from the file alone (percentage, reset time, countdown, burn-rate projection to 100%, age, and `stale` past 900 seconds), or `no reading`, and always exits 0. `GAIA_RATE_LIMITS_NOW` and `TZ` pin the clock for tests.
- **State.** Registry rows for the shared file (owned by its writer) and its orphan temporaries (7-day age retention), ordered before `cache-shared`.

### The write guard

`.claude/hooks/block-audit-loop-write.sh` refuses a session's own Write, Edit or MultiEdit of the shared file, a Bash or Monitor command that writes, moves, links or deletes it, and a Bash or Monitor run of `rate-limits.sh write` in its `bash`, `sh`, `./`, `exec` and `source` spellings. The rate-limit arm lives in the sourced library `.claude/hooks/lib/rate-limits-guard.sh` and reuses the guard's shell-word walker through a matcher. Reads (`rate-limits.sh read`, `cat`, `jq .`) stay allowed, and a read never arms the guard's jq requirement. Crafted statusline stdin, sourcing the library's writer, and indirect spellings (`eval`, `bash -c`, `env`, `xargs`, a path in a variable, `cd` then a relative name) are the guard's stated residual.

### The dispatch checkpoint

- **Hook.** `.claude/hooks/rate-limit-checkpoint-inject.sh`, PreToolUse, registered in its own `.claude/settings.json` entry with matcher `Agent|Task|Workflow`; the `Agent|Task` entry for `audit-loop-bound.sh` is unchanged. It is silent in a sub-agent (the payload carries `agent_id`, confirmed against a captured Workflow payload), with no reading, below the warning band, for an expired window, or when the session already heard that band of that window. Otherwise it emits one `additionalContext` (capped at 2048 bytes): one `Rate-limit checkpoint: <name> <band> band (<P>%), resets <when>.` line per qualifying window, the reader's lines, and `Policy: .claude/doctrine/rate-limit-checkpoint.md`. It always exits 0 and never emits a permission decision, so the triggering dispatch proceeds and the reading governs the next ones.
- **Marker.** `<main checkout>/.gaia/local/cache/rate-limit-checkpoint/<session_id>.json` records, per window, the `resets_at` and the highest band spoken; a window matches by the 600-second rule. The session id must be UUID-shaped. The folder is deliberately unguarded (a forged marker only silences advice) and has a main-only registry row with 7-day age retention.
- **Doctrine.** `.claude/doctrine/rate-limit-checkpoint.md` owns the policy by band name: with a human present, one question built from the option matrix (Chunk it, Wait until, Push through; never a smaller model; no question when only Push through qualifies); with no human, chunk at the warning band and save state and stop at the critical band; on a coordinated lane, report to the coordinator and fall back to the no-human policy; the 7-day window only defers optional heavy work.
- **Pointers.** The planner's `**Phase order**` bullet and the PR merge workflow's audit-loop dispatch step run the reader before they fan out and open the doctrine only at or above the warning band. `wiki/concepts/Workflow Doctrine.md` `## Rate-limit checkpoint` points at the doctrine.

## Divergence

- **Hook timing.** The below-the-warning-band and band-already-marked paths gain nothing from the absent pre-check and exceed their assumed 50 ms p50 budget: they pay the libraries, the full `gaia_resolve_main_root` git calls and the one `jq`. The pre-check cuts the no-shared-reading path to about a third. Figures, load-inflated: `wiki/concepts/Workflow Doctrine.md` `## Measurements`.
- **Last-observed time on a lower reading.** The SPEC says `observed_at` advances on every accepted write; the shipped writer reads a lower same-window reading as not accepted for that window, so a stale idle session cannot make the stored figure look freshly confirmed.
