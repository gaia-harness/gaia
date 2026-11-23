---
type: concept
status: active
created: 2026-11-24
updated: 2026-11-24
tags: [concepts, autonomy]
---

# Autonomy switch

One file decides whether GAIA runs unattended, for example under `/loop`. Only a human writes it, from their own terminal, and Claude can't set it for itself. Autonomy is off by default: GAIA ships no switch file, and the maintainer repo reads it exactly as an adopter project does.

## The file

`<main checkout>/.gaia/local/protected/autonomy.json`. A linked worktree reaches it through its `.gaia/local` symlink, so the switch is **checkout-wide**: while it is live, every session in the main checkout and in every linked worktree is unattended. No session is bound to it; the SessionStart notice below is how a session learns it.

Fields, all required unless marked:

- `enabled` (boolean): the switch.
- `expires_at` (UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ`): from then on the file reads as off.
- `may_merge` (boolean): whether an unattended run may merge an audited pull request.
- `audit_extra_units_per_pr` (whole number, optional): the most extra audit units the budget may answer for a single pull request. One unit is one grant window ([[PR Merge Workflow#The branch checkpoint]]).
- `audit_units_pool` (whole number, optional): audit units shared by every pull request under this file. The audit loop records the spend; nothing writes it here.

## Turning it on and off

Run these in your own terminal from the main checkout's root. Never run them through Claude: not as a request to Claude, not as a `!` command, not as a typed prompt line. A typed-prompt recorder is ruled out on purpose: a `/loop`, `ScheduleWakeup` or `CronCreate` prompt is Claude-authored and fires `UserPromptSubmit` like a typed one, with no field that tells them apart.

On for 8 hours (change `8` to set the length, and `may_merge` to `true` to let the run merge):

```
mkdir -p .gaia/local/protected && jq -n --argjson hours 8 '{enabled: true, expires_at: (now + $hours * 3600 | todate), may_merge: false, audit_extra_units_per_pr: 1, audit_units_pool: 3}' > .gaia/local/protected/autonomy.json
```

Off:

```
rm -f .gaia/local/protected/autonomy.json
```

No hook, script or CLI verb writes the file, and nothing counts it down.

## How it reads

`.gaia/scripts/autonomy-lib.sh` is the only reader. Every unattended behaviour sources it, and nothing else parses the file.

- `autonomy_active [directory]` returns 0 when the switch is live for the checkout holding `directory`.
- `autonomy_field <name> [directory]` prints one validated field of a live switch, and nothing, with status 1, when it is off.

Expiry is read against the clock on every call, never cached at session start. Each of these reads as **not autonomous**, the same answer, never an error that stops a session:

- no file, or `enabled: false`, or `expires_at` in the past
- a malformed file: not one JSON object, an unknown field, a missing required field, a wrong type, or a timestamp in any other form or naming an impossible date
- a symlinked file or `protected` folder, a missing `jq`, or a directory whose main checkout can't be resolved

The two `audit_*` fields are the exception to malformed: missing, non-integer or negative reads as `0` (no budget is spent) and the file stays valid, so autonomy stays on without a budget.

## The SessionStart notice

`.claude/hooks/autonomy-session-start.sh` shows the person and Claude that the session is unattended, with `expires_at` and `may_merge`, whenever the switch is live at session start. It is silent otherwise.

## The guard and its accepted residuals

`.claude/hooks/block-audit-loop-write.sh` guards everything under `.gaia/local/protected/` by placement, so it denies Claude's Edit, Write, MultiEdit, Bash and Monitor writes that name the switch, in the main-checkout and worktree spellings. Like the audit-loop allowance in the same folder, the guard stops drift, not an adversary. These stay open on purpose:

- a path held in a variable
- `cd` into the folder, then a relative name
- a `..` hop that skips the guard's pre-filter
- `eval` and `bash -c` wrappers
- a script Claude writes that never names the file

`NotebookEdit` is not a write path: it refuses any file that is not `.ipynb`.
