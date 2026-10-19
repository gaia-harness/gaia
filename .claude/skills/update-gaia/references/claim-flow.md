# Update claim flow

SKILL.md reads this file at its claim check, at Step 4's claim paragraph and at Step 11. A **claim** is an open, same-repository pull request whose head branch is `update/<tag>-...`: it tells a teammate the update is in progress. `update-claim.sh` owns the definition and takes `--tree` on every call. A `gh` failure never blocks an update: it warns and the run continues with no claim.

## Claim check

Runs in both modes, in the checkout the run starts in (`<starting checkout>`: the main checkout in mode 2, the worktree in mode 1), after the decision log check and before Step 3b. It creates nothing except the local branch `fetch-branch` fetches for a mode-2 own claim, so each stop below leaves no download, worktree, prune or cache change and no other branch change. Run the two reads as separate calls:

```bash
bash .gaia/scripts/update-claim.sh list --tree <starting checkout>
```

```bash
bash .gaia/scripts/update-claim.sh login --tree <starting checkout>
```

`list` prints one `CLAIM <number> <tag> <login> <createdAt> <headRefName>` line per live claim, and `login` prints `LOGIN <login>`: the current login, which decides whose claim each one is. Persist the login.

- **Exit 3 from either** (`CLAIM_CHECK_SKIPPED` or `LOGIN_UNAVAILABLE`): print `Warning: team claim skipped (<reason>).` and continue with no claim. Step 4 makes none, and Step 11 opens the PR after the commit.
- **A claim whose login differs from the current login**, whatever its tag: stop before any download. Take the lowest-numbered such claim. Compute `<age>` from `createdAt` against `date -u +%Y-%m-%dT%H:%M:%SZ`, in whole days, or whole hours under a day. Print exactly:

  `GAIA <tag> is already being updated in PR #<number> by @<login>, opened <age> ago. Wait for it to merge, then run /update-gaia again.`

- **The user's own claim for `<LATEST_TAG>`** is this person's earlier run:
  - Its branch is the current branch (mode 1): continue.
  - Mode 1 on any other branch: stop, naming the PR and its branch, and tell the user to run `/update-gaia` from the default branch's checkout.
  - Mode 2, on whichever branch the main checkout holds: when `git -C <starting checkout> show-ref --verify --quiet refs/heads/<headRefName>` finds no local branch, fetch it with `bash <starting checkout>/.gaia/scripts/update-claim.sh fetch-branch --tree <starting checkout> --branch <headRefName>`; `FETCH_FAILED` stops, naming the branch and the PR. Then classify the claim's own branch, not the most recent one Step 3 found:

    ```bash
    bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LATEST_TAG> --latest <LATEST> --branch <headRefName>
    ```

    Follow Step 3's default-branch routes for that result and persist what they persist. A `COMMITTED` own claim reports the PR's state and exits instead of resuming. Step 4's claim is then idempotent.
- **The user's own claim for another tag**: report its PR number and age, then ask with `AskUserQuestion` "Close it and start fresh (Recommended)" or "Stop". On Stop, exit. On close, run the call below, then continue as a fresh run. A second update PR is never opened while an own claim is open.

  ```bash
  bash .gaia/scripts/update-claim.sh close-own --tree <starting checkout> --number <number> --branch <headRefName>
  ```

  `CLOSED <number>` continues. `CLOSE_REFUSED <reason>` or exit 3 stops, relaying the line.

## Claim after Proceed

Runs in Step 4 after the provisioning wait and before Step 4b, in both modes, and not when the claim check was skipped. Read `<default branch>` the way Step 11 does, then call:

```bash
bash <main checkout path>/.gaia/scripts/update-claim.sh start --tree <worktree path> --tag <LATEST_TAG> --branch <branch> --base <default branch>
```

- `CLAIM_SKIPPED <reason>`: print `Warning: team claim skipped (<reason>).` and continue; `CLAIM_PR` stays unset.
- `CLAIMED <number> <url>`: persist `<number>` as `CLAIM_PR`, then settle a race with another run:

```bash
bash <main checkout path>/.gaia/scripts/update-claim.sh tie-break --tree <worktree path> --own <number>
```

- `WON` or `TIE_BREAK_SKIPPED <reason>`: continue.
- `LOST <other> <login>`: this run's PR is closed and its remote branch deleted. Unset `CLAIM_PR`. When `CREATED_WORKTREE=true`, the worktree holds only the claim commit, so release it per `.claude/skills/gaia/references/work-lifecycle.md` (`## Releasing an empty worktree`), which also deletes the branch. Otherwise print the worktree notice instead. Stop, naming PR `<other>` and its author.

A resumed run (mode 1, or mode 2 resuming a claimed branch) calls `start` too: it adds no second commit and no second pull request. A claimed run reaches the merge agent with exactly one empty claim commit pushed to origin and its draft PR open.

## Step 11: the claim-aware pull request

**Re-list before the push.** Step 11's `list` call catches a teammate who claimed since the claim check, and is the only check a run with no claim has. A `CLAIM` line on a branch other than `<branch>` whose login differs from the current login stops before pushing: name its PR and author with the claim check's stop line, leave the update commit local, and print the worktree notice. Run `login` the same way first when the claim check did not persist one. Exit 3 continues.

**Adopt an own open claim when `CLAIM_PR` is unset.** A run that reached Step 11 with the update commit already on the branch never passed the claim check's resume or Step 4's claim, so `CLAIM_PR` is empty while its claim PR may be open. Read it from the re-list above (`list --tree <main checkout path>`, with the login from `login --tree <main checkout path>`) rather than listing again: a `CLAIM` line whose `headRefName` equals `<branch>` and whose login equals the current login is this run's own claim, so set `CLAIM_PR` to its number and continue as a claimed run. Nothing here closes, creates or forces anything. When the list or `login` exits 3, or no line matches, `CLAIM_PR` stays unset and the run continues unclaimed.

**After the push, when `CLAIM_PR` is set.** The push updated the claim PR, so replace its placeholder body with the review point's summary: the counts per status, the auto-merged files, the answers and what is still deferred, the follow-ups, the report states, the Step 9d addendum and the quality gate result, in Markdown under the line `Pulls GAIA <LATEST_TAG> into the project.`. Write it with one `printf '%s\n'` command, each line single-quoted (a quote inside a line is written `'\''`):

```bash
printf '%s\n' '<summary line>' '<summary line>' > <main checkout path>/.gaia/local/cache/shared/update-gaia/run/pr-body.md
```

```bash
gh pr edit <CLAIM_PR> --body-file <main checkout path>/.gaia/local/cache/shared/update-gaia/run/pr-body.md
```

A failed `gh pr edit` prints the summary for the user to paste into the PR and continues; the push has landed. Then clear the claim from the cache so the statusline stops offering resume:

```bash
bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode gaia --version <LATEST> --drop-claim <CLAIM_PR>
```

`SKIPPED no cache` and a non-zero exit are reported and never fail the update.
