# Rate-limit checkpoint

The header above names a usage window that reached a band, then prints the reading: one line per window from `bash .gaia/scripts/rate-limits.sh read`. The reading is shared across the checkout and the account, so every session and worktree sees the same figures. The hook cannot see whether a human is present, so you judge that yourself. The dispatch that triggered the hook already ran; this policy governs your next dispatches.

Bands are `warning` and `critical`. Their values live in `.gaia/scripts/rate-limits-lib.sh` (`GAIA_RATE_LIMIT_WARNING_PERCENTAGE`, `GAIA_RATE_LIMIT_CRITICAL_PERCENTAGE`); this file spells none.

## Human present, 5-hour window at or above the warning band

Ask one `AskUserQuestion`, recommendation first and its label ending `(Recommended)`. Options:

- `Chunk it`: offered when the work splits at a phase boundary.
- `Wait until HH:MM` (the reset time): offered when the reader's projection reaches 100% before the reset. A projection of `unknown` counts as not reaching it.
- `Push through`: always offered (it draws paid credits).

Recommend `Chunk it` when it is offered beside `Wait until`; `Wait until` when it is offered without `Chunk it`; otherwise `Push through`. When only `Push through` qualifies, ask nothing and proceed.

Never offer a smaller model: nothing verifies that a smaller model draws less from the same pool.

## No human

Never ask.

- At the warning band, chunk the work at the next phase boundary.
- At the critical band, save state as `.claude/doctrine/context-checkpoint.md` does (`## Save first, then ask`, steps 1 to 3), then stop with a continuation prompt naming the reset time. Under a self-pacing loop, schedule the wakeup after the reset.

Outside such a loop nothing resumes the work after the reset; the continuation prompt is the only way back.

## Coordinated lane

Send the reading to the coordinator and ask the maintainer nothing. With no answer from the coordinator, apply the no-human policy.

## The 7-day window

It never gates a single dispatch. At or above the warning band it names optional heavy work for deferral: fitness sweeps, tuning trials, debt batches.

## Before a fan-out

Each large fan-out step runs `bash .gaia/scripts/rate-limits.sh read` before it dispatches, whatever the hook's once-per-band marker says. It opens this file only when a window prints at or above the warning band.
