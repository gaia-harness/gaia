---
type: concept
status: active
created: 2026-11-24
updated: 2026-11-24
tags: [concepts, autonomy, commands]
---

# GAIA Next

`/gaia-next` runs one GAIA job per run and says when no work remains, so a `/loop` can drive GAIA. `.claude/loop.md` holds the one line ``Run `/gaia-next`.``: a bare `/loop`, or `/loop` with only an interval, runs that file in place of its built-in prompt and re-reads it each iteration. The command is model-invocable on purpose: a scheduled fire runs only skills Claude may invoke itself, so `disable-model-invocation` would leave `/loop` unable to run it.

## The queue

`.gaia/scripts/gaia-next.sh` picks the job, reading state and changing none; its header owns the output shapes. The order:

1. **A running plan**: a plan folder whose `RUNNING` sentinel stands. The plan's own `KICKOFF.md` resumes it.
2. **An open pull request** you authored whose branch exists in this clone, unless a running plan owns the branch. Tending it means fixing failing checks and acting on review comments, then driving it through [[PR Merge Workflow]].
3. **A draft spec**: interactive runs only. Under autonomy it is skipped, because spec interview answers are requirements and the question gate would take the recommended answer for each with no human approving them.
4. **The top tech-debt issue**, from `/gaia-debt`'s own ordering and backlog pass, run as `/gaia-debt <n>`.

Each job resumes from its own saved state (the plan's `PROGRESS.md`, the branch and its audit state, the spec's draft cache), so a stopped plan, pull request or draft spec is picked up by the next run. A debt fix stopped before its pull request exists is not resumed: the backlog pass excludes its `in-progress` issue, and while the fix branch exists the stale-claim reconcile counts the claim live and does not release it.

## Skips under autonomy

While the [[Autonomy Switch]] is live, the picker skips, printing one `gaia-next: skipped <item>: <reason>` line per skip:

- **A parked item**: its branch's run folder holds the parked marker that `.gaia/scripts/autonomy-park.sh` writes, and the branch head is still the head the marker records. A new commit on the branch releases it. An interactive run takes a parked item and resumes it with the user from the `## Parked` section of the run's `STATE.md`.
- **A self-governing item**: a plan whose task docs, or a debt issue whose body, names a path in the protected set the question gate enforces ([[Autonomy Switch#Self-governing files]]). The gate would deny the edit and the run would park mid-work, so the item stays in the queue for an interactive run, which takes it. An unreadable set skips every such item.
- **A draft spec**, as above.

## Untrusted input

`.claude/commands/gaia-next.md` step 2 owns the untrusted-input rule. Under autonomy, `gaia-next.sh comments` withholds every comment whose author's repository permission is not `admin` or `write`, counting it by author without printing its body, so an unattended run acts only on comments from people who could have pushed the change themselves.

## Ending

- One job per run: when it finishes or stops partway, the run ends.
- A park ends the run, and the next run skips the parked item.
- The loop ends when no work remains that the run may take: an empty queue, or one where every item is parked or skipped. The command's step 3 owns how it stops each kind of `/loop`.

## Permission mode for an unattended run

The git classifier removes git prompts only. Test, lint and script commands outside the allow list in `.claude/settings.json` still prompt, and with nobody present a prompt stalls the run. Start an unattended session in auto mode:

```
claude --permission-mode auto
```

A classifier then approves or blocks each such call instead of prompting, and deny rules and GAIA's PreToolUse hooks, the question gate among them, still apply. Auto mode goes back to prompting after 3 blocks in a row or 20 in total, which stalls the run, so a run that keeps hitting blocks needs a human. `dontAsk` never prompts but denies every call the allow list does not name, so the run fails at its first test command. `bypassPermissions` approves every call with no check beyond the deny rules and hooks.
