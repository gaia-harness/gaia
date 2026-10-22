# Context checkpoint

This session's context reached a checkpoint band. The hook cannot see whether a human is present or whether work is in flight, so you apply this yourself. The header above names the band, the session id and the fallback save path.

## Bands

- Yellow: getting high, look for a chance to clear. Statusline only, no question.
- Red: clear unless the remaining work is small or runs in sub-agents.
- Fire and skull: clear now.

## Stopping point

Act only at a stopping point: no background task, sub-agent or monitor is running and nothing is half-applied. Not at one yet: finish the step, then act.

## Save first, then ask

1. Commit and push first when the work is committed work at a clean point.
2. Save the place before you ask anything. Owner-routed targets, in order:
   - the plan orchestrator's `RUNNING` plus `PROGRESS.md`, stopping at a committed phase boundary
   - `/gaia-spec`'s draft cache
   - a research folder's current-state file
   - `.gaia/local/runs/<branch>/STATE.md`
   - on the default branch or a detached HEAD with no run folder, `.gaia/local/runs/session-<session id>/STATE.md`

   The `Save path:` line names the resolved fallback. Never the scratchpad. A saved checkpoint can expire: the backstop reaper removes a run folder once its branch and worktree are gone and it has gone untouched past the grace, and a detached-HEAD `session-<session id>` save expires after its own longer window. The registry `runs` row holds the windows.
3. STATE.md holds the goal, open decisions and re-verify commands under `Facts`; done items in a `Status checklist`; the next step as the one `NEXT:` line. At most 4 KB, rewritten in place.
4. Then ask (interactive only): one `AskUserQuestion` with exactly two options, `Continue here` and `Clear and resume`, the recommended one first and marked `(Recommended)`, with a one-line reason.

## Recommending

At red, recommend `Continue here` only when the remaining work is a few steps, runs mostly in sub-agents, or a handoff now would be riskier than finishing (mid-sequence, state hard to capture). Otherwise, and when unsure, recommend `Clear and resume`. A pending pre-merge audit counts toward `Clear and resume`: the audit loop asks at the same line.

Never skip the save and ask because the work is nearly done; a nearly-done session gets `Continue here` as its recommendation.

At fire and skull, always recommend `Clear and resume`, whatever the remaining work. The reason states the band.

## Answers

- `Continue here`: keep working until the next band.
- `Clear and resume`: print one instruction line (run `/clear`, then paste the prompt below) and a continuation prompt naming the state file path, the goal and the next step. Then end the turn with no further tool calls.

## Carry the run's cost across

Before printing any continuation prompt, run `bash .gaia/scripts/usage.sh handoff`. When it prints a line, write that line into STATE.md and make running it verbatim the prompt's first step: it binds the next session to the run this one started, so the run's cost record covers every session. No line means no recorded run is open, and the prompt carries nothing for it.

## Unattended

With no human in the session, never ask. At red and fire, save and continue. At skull, save, print the continuation prompt in a bare fenced block, report, and stop; the next `/loop` iteration resumes from the saved state, as a fresh session would. Headless and scheduled runs render no statusline, so they have no reading and never fire.
