# Context yield

A hook told you this sub-agent's context reached a band. The header above names the band, its reading and the handoff path. You apply this yourself.

## When to yield

Only a hook-delivered sub-agent context checkpoint instruction starts a yield; never yield on your own estimate of your context.

A stopping point means no tool call, background task or nested sub-agent in flight, and no file half-edited.

## Bands

- Red: yield at the next stopping point.
- Fire: yield before starting any new unit of work.
- Skull: write the handoff and reply now.

## Handoff, then reply

1. Write the handoff before replying, at the absolute path the header names. Use Bash with a heredoc, then read it back; the Edit and Write tools can refuse a path outside your worktree.
2. The handoff opens with the goal, then `Facts` (open decisions, re-verify commands), a `Status checklist` of done and remaining items, and one `NEXT:` line. At most 4 KB.
3. It also names the band that fired, the in-flight state (what was mid-way and how to finish it) and the files touched so far. A planner also names its scratch path and the plan files it already wrote.
4. Leave edits uncommitted: never commit, stash or discard at a yield. The dispatcher owns commits.
5. Reply with a first line of exactly `YIELDED <band>: <handoff path>`, the band in lowercase (`red`, `fire` or `skull`), then stop. Dispatch nothing after writing the handoff.

A nested sub-agent you dispatch never gets a `Yield handoff:` line.
