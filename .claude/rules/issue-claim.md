# In-Progress Issue Claim

`in-progress` says a GitHub issue is being worked right now. It is not tech-debt-specific: it applies to every issue type, so two agents or two people never start the same ticket.

## Claim before isolation

Before cutting a branch or a worktree for work that closes a GitHub issue, read the issue's labels:

```bash
gh issue view <n> --json labels --jq '[.labels[].name]'
```

Already carrying `in-progress` means someone else holds it. Say so and pick different work rather than racing. Otherwise claim it, then proceed:

```bash
gh issue edit <n> --add-label in-progress
```

Outside a GAIA skill, before the first edit this session will commit, read and follow `.claude/skills/gaia/references/work-lifecycle.md`: it covers the claim, branch name, isolation, draft PR, audit, merge when asked, and cleanup.

## Release

`.claude/hooks/issue-claim-release.sh` releases the claim when a `gh pr merge <n>`, run as its own command in this session, lands a pull request whose body closes the issue by keyword (`Closes #<n>`); its comments name the spellings it declines to read. No hook sees any other ending, so Claude releases the claim itself when it closes such a pull request unmerged or the user says the work is dropped, by the work lifecycle's `## Releasing the claim on an unmerged ending`.

## Scope

Claim a `tech-debt` issue only through `/gaia-debt`, never by hand: it owns that claim and the stale-claim reconcile that would release a hand-set one.
