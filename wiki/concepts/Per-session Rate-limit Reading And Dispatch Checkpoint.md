---
type: concept
status: active
created: 2026-11-24
updated: 2026-11-24
promoted_at: 2026-11-24T12:58:43Z
promoted_hash: sha256:6ade935c98be277e7cbc94e6f11fb3809f8ce10209c0d95a88bd36f9968c8bb6
pr_number: 3805
tags: [promoted, concepts]
---

# Per-session rate-limit reading and dispatch checkpoint

Each GAIA session writes its 5-hour and 7-day rate-limit windows to its own reading file, and a main session dispatching an Agent, Task or Workflow at or above its own warning band is handed its own reading and a pointer to the policy for acting on it. A limit reset or an account switch shows at once, an idle session's old figure never moves a reading, and nothing ever blocks a dispatch.

## Behavior

### The per-session reading

- **One file per session.** `<main checkout>/.gaia/local/cache/shared/rate-limits/<session_id>.json`, reached from every linked worktree through its `.gaia/local` symlink, and only for a UUID-shaped session id (`gaia_context_is_session_id` is the one UUID rule). It holds `version` 2 and, for `five_hour` and `seven_day` only, `used_percentage`, `resets_at`, `changed_at`, `confirmed` and a `history` of changes capped at 48 entries.
- **One writer.** `gaia_rate_limits_write` in `.gaia/scripts/rate-limits-lib.sh` writes only the calling session's file, atomically (`<file>.tmp.<pid>`, then `mv -f`), in one jq process, and prints the display records. The jq program text lives in `.gaia/scripts/rate-limits-programs-lib.sh`.
- **Writer rules per window.** A session's first reading of a window is stored unconfirmed. A reset time more than 600 seconds from the stored one replaces the window and its history. In the same window a different figure replaces the stored one in either direction, appends one history entry and is confirmed. An equal figure rewrites nothing, so a file changes only when its figure does, and an idle session repeating an old figure never moves its file. A refused reading exits 2 with `rate-limits: invalid reading` and leaves the file untouched.
- **Latest-change choice.** Per window, over the 32 most recently modified UUID-named files, each parsed on its own. A valid entry is version 2, a figure in 0..999, an integer `changed_at` no more than 60 seconds ahead of now and a boolean `confirmed`. Unexpired beats expired, confirmed beats unconfirmed, the newest `changed_at` wins among confirmed and the oldest among unconfirmed, then the lower session id.
- **Display.** The statusline passes its payload's windows and its session id to the writer and shows the latest-change choice per window; an expired window renders `reset`.
- **Reader.** `bash .gaia/scripts/rate-limits.sh read` prints one line per window with its band word, reset time, countdown, burn-rate projection, how long ago the figure changed and ` unconfirmed` when it is, or `no reading`, and always exits 0. When `CLAUDE_CODE_SESSION_ID` names a session with an entry for a window it prints that entry; otherwise it prints the latest-change choice. `GAIA_RATE_LIMITS_NOW` and `TZ` pin the clock for tests.
- **Bands.** `.gaia/scripts/rate-limits-lib.sh` owns every band value and the tier map. The 5-hour window bands on the standard set on every plan. The 7-day window bands on the set of the account's plan tier, and a missing, unreadable or unmapped tier gets the standard set.
- **Tier.** The tier is one string key of Claude Code's profile, read lazily: only when the chosen whole 7-day figure reaches the lowest 7-day warning of any set, so the statusline path never opens the profile. Nothing else from the profile, and neither the tier string nor a band-set name, reaches output, a file or a log.
- **State.** The state registry has a live row for the readings folder with 7-day age retention. The earlier single shared file and its temporaries are registry residue, which the residue sweep removes once the folder exists.

### The write guard

`.claude/hooks/block-audit-loop-write.sh` refuses a session's own Write, Edit, MultiEdit, Bash or Monitor call that writes, moves or deletes a session reading or a checkpoint marker, runs `rate-limits.sh write`, or changes the account tier the bands read. Reads stay allowed. The rate-limit arm lives in the sourced library `.claude/hooks/lib/rate-limits-guard.sh`, and the hook header lists the spellings it covers and its limits.

### The dispatch checkpoint

- **Hook.** `.claude/hooks/rate-limit-checkpoint-inject.sh`, PreToolUse on `Agent|Task|Workflow`. It reads only the dispatching session's own reading, never another session's. It is silent in a sub-agent (the payload carries `agent_id`), with no reading, for a window below its band or expired, and when the session already heard that band of that window. Otherwise it emits one `additionalContext` with a `Rate-limit checkpoint: <name> <band> band (<P>%), resets <when>.` line per qualifying window, the reader's lines and `Policy: .claude/doctrine/rate-limit-checkpoint.md`. It always exits 0 and never blocks.
- **Marker.** `<main checkout>/.gaia/local/cache/rate-limit-checkpoint/<session_id>.json` records, per window, the `resets_at` and the highest band spoken. A fall to a lower band lowers the marked band silently, so the next climb speaks again. A reset time more than 600 seconds from the marked one starts from clear.
- **Cost.** The hook runs at most two jq processes: the report program and, only past the tier threshold, the profile read. It fails open on a bad own file or an unwritable marker folder.
- **Doctrine.** `.claude/doctrine/rate-limit-checkpoint.md` owns the policy by band word. The planner's `**Phase order**` bullet and the PR merge workflow's audit-loop dispatch step run the reader before they fan out and open the doctrine only when a reader line prints `warning` or `critical`.

## Divergence

- **Hook timing.** The below-warning and band-marked paths pay the libraries, the root resolution and one jq, and the tier-read path pays a second jq for the profile. On a loaded machine all three run far above the no-op baseline. Figures: `wiki/concepts/Workflow Doctrine.md` `## Measurements`.
- **Reset bounds.** The writer keeps the window-length bounds on a reset time: a reset later than now plus the window's longest length plus the 600-second same-window slack is refused, and one earlier than now minus it is ignored.
