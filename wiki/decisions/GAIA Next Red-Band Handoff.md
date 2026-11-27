---
type: decision
status: active
created: 2026-11-27
updated: 2026-11-27
promoted_at: 2026-11-27T06:37:04Z
promoted_hash: sha256:559cb202cf3d69b3096d19588600d96a9c1ca019f713d74decec72a5b8c70cf8
pr_number: 3880
tags: [promoted, decisions]
---

# GAIA Next Red-Band Handoff

A `/gaia-next` run takes no new job once the session's context reading is at the red band or past it: `gaia-next.sh pick` returns a `handoff` job before any queue tier, and the run saves its place, prints a prompt to paste after `/clear`, and ends the `/loop`, so the work continues in a fresh session. The behavior itself is described in [[GAIA Next]] (`## Ending`); this page records the choices behind it.

## Decisions

- **One rule, every run.** The band check is `pick`'s first statement and is not autonomy-gated, so a loop, a one-off run, autonomy on and autonomy off all hand off the same way. The rule lives in a script and is tested there; Claude never judges whether it is inside a loop. The cost is that one more job in a full session needs that job's own command.
- **An old reading from the same session still binds.** Context only grows within a session, except after compaction, so `pick` reads the session's own reading at any age (a future-dated one is still refused), through a sibling of the fresh-only reader. The audit loop's bound hook and the checkpoint injection keep the fresh-only reader. The worst case is one handoff that was not strictly needed, which costs one `/clear`.
- **The human starts the fresh session.** Claude Code gives a session no way to start another interactive session, so the handoff ends at a printed prompt and the human's `/clear` and paste. The save goes to the session's existing checkpoint save target (`.gaia/local/runs/session-<session id>/STATE.md` under the main checkout, one definition shared with the checkpoint hook), so any other launcher finds it by the ending session's id. Nothing is sent outside the terminal.
- **The restart prompt is the bare command.** With no join line the fenced prompt holds only `/loop`, `/loop <interval>` or `/gaia-next`, because Claude Code parses a slash command only at the start of a pasted prompt. With a join line it is two prose steps: run the join line once, then start the loop with the same interval. This departs from the continuation-prompt shape the context checkpoint doctrine gives other handoffs; the STATE.md still carries the goal.
- **The handoff fires at the next pick only.** There is no job-end band check: the iteration that crosses the line finishes normally and the next iteration hands off. A job that reaches skull still saves and stops partway and resumes from its own saved state in the fresh session; the loop handoff prompt printed later is the one to paste.
- **Below the line, the audit loop's same-session skip still applies.** At or past the line the band handoff answers first; the skip governs any session the band handoff does not answer, such as one whose reading dropped below the line after compaction, or one with no usable reading.
- **One definition of the band set.** Whether a band is at or past the line is one predicate in `.gaia/scripts/context-checkpoint-lib.sh`, which the picker's band check and the audit loop's pinned question both call.
