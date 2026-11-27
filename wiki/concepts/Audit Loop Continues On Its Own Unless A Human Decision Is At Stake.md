---
type: concept
status: active
created: 2026-11-27
updated: 2026-11-27
promoted_at: 2026-11-26T18:13:03Z
promoted_hash: sha256:16115f65c935144c20689c8995185ca049d546b2e03c3faf35944f2868c6539e
pr_number: 3876
tags: [promoted, concepts]
---
# Audit loop continues on its own unless a human decision is at stake

The pre-merge audit loop's bound hook (`.claude/hooks/audit-loop-bound.sh`) answers a branch checkpoint itself when no human decision is at stake, and asks a human only for a real decision or past a human-set round cap. The rule lives in `.gaia/scripts/audit-loop-automatic-lib.sh`; the hook supplies its inputs and records the outcome. The rule never reads the autonomy switch.

## Behavior

### Round cap C

`audit_loop.round_cap` in the protected checkpoint override (`.gaia/local/protected/checkpoint-override.json`, `version` 1) sets C; its range and invalid-value behavior are `.gaia/scripts/context-checkpoint-lib.sh`'s `Override rule`. The cap in use freezes into `history.context_config.round_cap` at the branch's first unit dispatch and is only lowered live (`gaia_loop_round_cap_effective`). C replaces the hard cap in every cap rule (unit and member decisions, the brief's `rounds_cap`, the code-review decider) except the autonomy budget's, which stays bounded by the hard cap. Claude's tool writes to the override are denied.

### Decision order at a unit dispatch

1. The hook builds the decision, recommendation, line, disputes and pinned question in memory.
2. **Automatic continue.** `gaia_loop_automatic_answer` returns `automatic` under the rule `.gaia/scripts/audit-loop-automatic-lib.sh`'s header owns (`AUTOMATIC CONTINUE AND HAND-OFF`). The hook records one unit `{admitted_on: "grant", automatic: true, start_round: used+1, through_round: min(used+K, C), after_checkpoint}`; no checkpoint, no question, `allowance` untouched. A failed write falls back to recording the ordinary checkpoint.
3. **Budget.** Only when the automatic continue declines and the autonomy switch is live, judged against the hard-cap decision.
4. **Hand-off.** When `gaia_loop_automatic_answer` returns `handoff` (the same header rule), the hook records the checkpoint with `handoff: true` and the dispatching `session_id` in one write, and denies `BLOCKED: audit checkpoint` with the hand-off lines `gaia_loop_handoff_instructions` prints and the typed Grant and Accept lines, no pinned-question fence and no park line. A fresh session's low reading continues past it with no answer.
5. Every other checkpoint pins and asks. A unit stopped `checkpoint-deny` makes the main thread dispatch the next unit, and the hook decides.

### Around the loop

- `/gaia-next` (`gaia_next_handoff_skip` in `.gaia/scripts/gaia-next-handoff-lib.sh`) skips a plan or pull request whose latest checkpoint is an unanswered hand-off from this session ([[GAIA Next#Skips in every run]] owns the skip and its line). Nothing is parked.
- The write guard's `context-writer` class (`block-audit-loop-write.sh`, matchers in `.claude/hooks/lib/hook-only-scripts-guard.sh`) denies Claude's Bash or Monitor run of the statusline context writers and sourcing the context lib or reader beside a writer function, while commands that only name them stay allowed. A reading minted through a spelling the match misses stays a residual, bounded by C.
- `audit-loop-eval.sh record-values` adds `automatic_grants` (omitted at zero) and `audit-loop-record.sh` prints `; automatic grants: <n>` after `budget grants: <n>` in the `## Audit rounds` record.

## Divergence

- A `stalled` verdict with `small-tail` whose snapshot is not accept-eligible does not continue automatically: `gaia_loop_recommended` returns `stop` for a `stalled` verdict unless the snapshot is accept-eligible, so the in-session grant does not lead and the hook asks. A stalled small tail continues automatically only when the snapshot is accept-eligible but its accept is blocked.
