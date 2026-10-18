# /gaia-residue

A triage drain over the keyed audit residue recorded under the two canonical headings in merged pull-request bodies. It never fixes anything and never edits a file a residual cites; fixing is `/gaia-debt`'s job.

Contents: Execution model, READ FIRST; Naming disambiguation; Invocation; Fetch the live candidate list; Bounding the run; Present each candidate; The three arms; Record; Sweep batch by batch; Resume after /clear; Refresh the statusline nudge (end of run); Publish approved changes (end of run); Cost record (run end); Guardrails.

## Execution model, READ FIRST

Interactive and human-gated. Promote is one question per entry and never auto-advances. One run sweeps batch after batch (`## Sweep batch by batch`): every aged residual without asking, then newer ones a batch at a time on a yes. The agent never runs `git add`, `git commit`, or `git push` during the sweep; one end-of-run publish step runs after the sweep ends, so the whole sweep lands in one pull request.

## Naming disambiguation

This tree spends the word "residue" on a second meaning: orphaned machine-local state, carried by the `residue` array in `.gaia/state-registry.json`. That is a different thing from what this command drains. The audit sense this command triages is always spelled "residual": a residual is one keyed entry recorded under a canonical heading in a merged pull request's body. The collision is confined to maintainer-internal registry vocabulary and shadows nothing a user types, but any prose where both senses could be read together disambiguates explicitly, the way this paragraph does.

## Invocation

`/gaia-residue` takes no arguments: every run is the full interactive triage.

## Fetch the live candidate list

**An owed run first.** A run cleared at the context checkpoint whose continuation prompt was never pasted still holds store changes on its own branch. Before the tally, list the state files such runs leave, from the main checkout's root:

```bash
find .gaia/local/runs/residue -name STATE.md -exec grep -l 'Publish: owed' {} + 2>/dev/null
```

For each path printed, ask one `AskUserQuestion` (header `"Residue"`), naming the file's `Branch:` line:

1. `{ label: "Resume it (Recommended)", description: "Continue that sweep, then publish it." }` → follow `## Resume after /clear` with that path.
2. `{ label: "Publish it now", description: "Publish what that sweep recorded, without more batches." }` → follow `## Resume after /clear` steps 1 to 4 with that path, then go straight to the refresh and the publish.

Anything typed into the built-in Other, or a declined or dismissed prompt, stops this run before the tally: report the path and that a fresh run would append to the store on a second branch, which conflicts with the owed one. Nothing printed means no run is owed; go on to the tally.

Read the live list from the tally primitive. Re-run it; never trust a stale count.

```bash
.gaia/cli/gaia residue-tally
```

Bind to the top-level fields it prints: `gh_ok`, `count_approximate`, `candidate_count`, `remaining_count`, `aged_candidate_count`, `total_keyed_count`, `candidates`, `malformed`, `store_skipped`, and `window`. The four counts are four different populations and are not interchangeable:

- `total_keyed_count` is every keyed unit attributed, before any suppression. The corpus size. It never shrinks as the drain proceeds.
- `remaining_count` is the suppression survivors, before the cursor skip and before the cap. What is still open.
- `aged_candidate_count` is the subset of `remaining_count` whose age crosses the nudge's threshold. The nudge's numerator.
- `candidate_count` is this tally's emitted batch, after the cursor skip and the cap.

`count_approximate: true` means the counts came from a mode that performed no line resolution, so a dismissal whose recorded line content no longer matches the current one may still be suppressed. The interactive run never sets it.

Then the three terminating reads:

- `gh_ok` is `false`: report, verbatim, `could not complete the GitHub reads; this is not an all-clear, re-run when \`gh\` is available`, then report the populations below and stop. Never claim no findings. Two independent reads set it, the merged-PR window and the tech-debt issue list, and the emit does not say which; naming one of them would send the operator to debug a call that succeeded.
- `gh_ok` is `true` and `candidate_count` is `0`: report the populations below, then that no keyed residual is currently open, and stop.
- Otherwise: proceed to the triage loop below.

Which populations a stop arm carries live differs by arm. The zero-candidate arm carries both, and it is the one that bites: announcing that nothing is open over a truncated corpus, or over a dismissal store some of whose lines could not be read, is exactly the false all-clear this section exists to prevent. The `gh_ok` is `false` arms carry `store_skipped` live, but their `malformed` is always emitted empty whether or not malformed keys exist, so an empty `malformed` there means **unknown**, never none; report it as unknown rather than reporting nothing.

These populations never reach the triage loop, so nothing else will mention them. Report each one that is non-empty, carrying the `reason` each entry gives rather than a summary of it; where the arm above says a population is unknown rather than empty, report it as unknown instead of staying silent. On a run that reaches triage that is alongside the candidate list, before the first question; on either terminating stop above, alongside that stop's own report, before the run ends:

- `malformed` holds entry units whose key matched the gate's grammar but failed field validation. They are withheld from triage by design, and the reason is reported so the key can be repaired in its own pull-request body. A run that stays silent here leaves a residual no one can act on and no one knows about.
- `store_skipped` holds dismissal-store lines that could not be read. Each one is a disposition that has stopped suppressing, so a suppression a reviewer believes is in place is not.

`window` is different: the emit always carries it, and it holds no reason to relay. Report it, on the same terms and at the same point, only when `window.truncated` is `true`. That means the window read hit its own iteration bound, so the corpus may be incomplete and every count is a floor rather than a total. Say so; never present a truncated read as a whole one.

## Bounding the run

`GAIA_RESIDUE_CAP` (default 10) sets the size of one batch, which is also the most one batch-dismiss confirmation lists. It does not bound the run: `## Sweep batch by batch` below triages batch after batch. Candidates are ordered oldest merge date first. The cursor at `.gaia/local/cache/residual-cursor.json` advances after each confirmed disposition, so an interrupted run resumes where it stopped rather than re-asking; `.gaia/cli/gaia residue-cursor clear` starts the list over.

```bash
.gaia/cli/gaia residue-cursor advance --token <the candidate's cursor_token>
```

Pass only the candidate's own `cursor_token` from the tally emit, never a path. A residual's path is text from a merged pull request, and this call is agent Bash, a shell; the token is closed over `[A-Za-z0-9_-]` by construction so it cannot carry a shell metacharacter, a space, or a leading dash, and there is no `--path` flag to reach for instead.

Each tally emits one batch, never the whole population. Report `remaining_count` as what is left when a human asks, never `total_keyed_count`.

## Present each candidate

For each candidate present: its canonical disposition (accept or waive), its failure mode, its cited path and line, its resolved line text, and its resolution class.

A candidate whose resolution is `gone` is labelled a likely-already-fixed dismiss candidate and still requires a human disposition; content vanishing is evidence of a fix, not proof of one, so it is never applied unattended. A candidate carrying a `previously_promoted_issue` is labelled as previously promoted to that issue, which closed as completed, and dismiss is presented as the default disposition for it.

## The three arms

State the default posture explicitly before offering them: dismiss or keep is the default, and promotion is the exception that needs a reason. A drainer whose happy path files issues is a migration wearing a drain's clothes, and promoting freely would grow the backlog rather than drain it.

### Promote

One human answer per residual, never batched, collected through an explicit user-question step. It files through `bash .gaia/scripts/file-tech-debt.sh file --finding <finding.json> --outcome-file <outcome.jsonl>` (the recipe in `.claude/skills/file-tech-debt/SKILL.md` section 0 owns the finding JSON, the screen, the probe and the divert) rather than reimplementing filing, and hands it:

- **The finding class is the residual's own.** Pass the `class` carried in the candidate's `raw_key` verbatim as the recipe's `<finding_class>`, so the filed issue's dedup key is byte-identical to the residual's own key. Never mint a fresh class.
- **`footprint:<class>`** comes from the recipe's own step 6 rubric, applied to the cited line the command has already read. It is a reach grade (`narrow`, `wide`, or `spec`), never the finding class above.
- **`severity:<tier>`** comes from the recipe's own severity vocabulary, chosen from the residual's failure-mode text and its canonical disposition, and it is a judgment asked of the human alongside the promote answer, not guessed by the command.
  <!-- gaia:maintainer-only:start -->
- **`audience:<side>`** comes from the cited path, per the recipe's own adopter/maintainer split. Maintainer repository only; scrubbed from adopter bundles.
  <!-- gaia:maintainer-only:end -->
- **`difficulty:<grade>`** is supplied: the command has already read the cited line to resolve it, so a promoted residual is graded using the recipe's own rubric.
- **`security`** is the human's read of the residual's failure-mode text, true when it reads as an exploitable weakness; the script diverts a security-class finding to a local record rather than filing it publicly, and an absent value is treated as security-class.

When the recipe refuses to file because the key matches one of its own dedup arms, append a `suppressed` record (see Record below), so no refusal is silent and no residual is offered forever.

### Dismiss

The safe arm, and the default. It may be offered in a batch, bounded by the batch size, and the batch takes an explicit confirmation that lists every entry it will dismiss before anything is appended. Each dismissal appends one `dismissed` record.

### Keep

A snooze, not a permanent disposition. It appends a `kept` record; the tally suppresses the residual until the record ages past the keep window (14 days by default, `GAIA_RESIDUE_KEEP_DAYS`), then offers it again.

## Record

A promotion is recorded by the filed issue itself, which carries the residual's key; no second store entry is needed for it. A dismissal, a keep, and a filing refusal each append one record to `.gaia/audit-residual-dismissals.jsonl`, and the only way this command writes that file is the CLI.

**Isolate before the first append**, once per run, so the store's change lands on this run's own branch and never on whatever branch the checkout holds. Mint the name and carry it as a literal, `<RESIDUE_BRANCH>`, into every later call, since shell variables do not persist between calls:

```bash
bash .gaia/scripts/branch-name-lib.sh name residue
```

Then read `.claude/skills/gaia/references/isolation.md` and apply it now, with `{{SUBJECT}}` = "this residue triage", `{{WORKER}}` = "the triage", `{{OWNER}}` = "this triage", `{{SIBLING}}` = "another task", passing `<RESIDUE_BRANCH>` as the branch name. Carry `RESOLVED_MODE` and `RESOLVED_ROOT` to the publish step. Every append, and everything after it, runs from `RESOLVED_ROOT`. A run that appends nothing (every disposition a promotion that filed) never isolates.

```bash
printf '%s\n' "<the reason text>" > .gaia/local/audit/residue-reason-<unique>.txt
.gaia/cli/gaia residue-record --disposition dismissed \
  --token <the candidate's cursor_token> \
  --reason-file .gaia/local/audit/residue-reason-<unique>.txt
```

Delete the reason file in a **separate** tool call, for the same reason the filing recipe splits its own cleanup: one `PreToolUse` decision covers a whole Bash invocation, so a denied cleanup would take the write standing beside it. Batch dismissal passes one `--token` per entry in a single call, so one confirmation produces one append.

**Check the exit code before reporting anything.** Exit `0` means the record is written. Any non-zero means nothing was recorded: tell the user the disposition did not persist and why, and do not claim success. The residual re-surfaces on the next tally, which is the honest consequence.

The store is append-only JSON Lines, carries a schema version, and is named above; point at the CLI rather than restating its fields. Never hand-write a line into the store.

## Sweep batch by batch

After the last disposition of a batch, re-run `.gaia/cli/gaia residue-tally` and bind its fields afresh; never reuse the previous emit. Every confirmed disposition already suppresses its residual and the cursor already sits past the batch, so the fresh emit is the next batch.

A fresh emit whose `gh_ok` is `false` ends the sweep: report it in the words `## Fetch the live candidate list` gives, then run the end-of-run steps below, since the dispositions this run already confirmed still refresh and publish. Otherwise report `malformed`, `store_skipped`, and a truncated `window` as that section says, but only where one differs from what this run already reported.

### Required: every aged residual

While `aged_candidate_count` and `candidate_count` are both above `0`, triage the next batch without asking. The aged residuals are what the statusline nudge counts, so a run that stops with any left keeps telling the user to run the command they just ran. A sweep that clears them leaves the end-of-run refresh writing `0`, and the nudge stays gone until aged residue builds up again.

A promotion whose filing ends diverted, absent, transient, or failed files no issue the tally reads, so its residual stays open and, once aged, stays in `aged_candidate_count`. Hold the `cursor_token` of every candidate this run disposed of, and never present a held one again in this run. When a fresh batch holds nothing new to present, or `candidate_count` is `0` while `aged_candidate_count` is above `0`, every aged residual left is one this run cannot clear (held, or sitting behind the cursor), and the end-of-run refresh still counts it. End the sweep, and never silently: report the count, that it keeps the statusline nudge up while it meets the nudge's threshold, and the next step for each kind. A held promotion that ended absent, transient, or failed is promoted again on a later run once its filing can complete; one that ended diverted waits on its local record, then takes dismiss or keep on a later run. Anything behind the cursor is offered again after `.gaia/cli/gaia residue-cursor clear`. Without this arm the loop re-tallies forever.

### Extended: newer residuals, one batch per yes

Once `aged_candidate_count` is `0`, a `candidate_count` above `0` means newer residuals remain, ones the nudge does not count yet. Sweeping them is optional work, so never start one of their batches without asking. Before each batch ask one `AskUserQuestion`, its numbers taken from the fresh emit:

- **header:** `"Residue"`
- **question:** `"Sweep the next <candidate_count> newer residuals? More: https://docs.gaiareact.com/maintenance/residue/"`
- **options (this exact order):**
  1. `{ label: "Sweep the next <candidate_count> (of <remaining_count> remaining)", description: "Triage one more batch, then ask again." }`
  2. `{ label: "Stop here", description: "End the sweep and publish what this run recorded." }`

`<candidate_count>` is the batch size, smaller than the cap on the last batch. The question leads with the action and the count and never explains what the newer residue is; the link carries that. `Stop here`, anything typed into the built-in Other, or a declined or dismissed prompt ends the sweep. A `candidate_count` of `0`, or a batch holding nothing new to present, ends it with no question.

### Between batches

Between two batches is the sweep's stopping point for the context checkpoint (`.claude/doctrine/context-checkpoint.md`): every disposition is in the store and the cursor has moved, so nothing is half-applied. When the checkpoint fires mid-batch, finish the batch first.

At that point, save before asking, as the checkpoint says, to this run's own state file:

- once this run has isolated (`## Record`), the run folder of `<RESIDUE_BRANCH>`: `.gaia/local/runs/<RESIDUE_BRANCH>/STATE.md`;
- before it has, the checkpoint's `Save path:` fallback.

`.gaia/local` is shared with the main checkout, so write the file with Bash at the main checkout's absolute path (`bash .gaia/scripts/main-root-lib.sh` prints it), never with Edit or Write from a worktree. It holds these lines, its one `NEXT:` line last:

- `Command: /gaia-residue`
- `Phase: required` or `Phase: extended`
- `Branch: <RESIDUE_BRANCH>` and `Tree: <RESOLVED_ROOT>` and `Mode: <RESOLVED_MODE>`, or `Branch: none` before isolating
- `Publish: owed` once this run has isolated, `Publish: none` before
- `Disposed: <count of dispositions this run confirmed>`, which the refresh's run condition reads
- `Held: <the held cursor tokens, space-separated>`, or `Held: none`
- `NEXT: re-run residue-tally and start the next batch`

Then ask the checkpoint's question. On `Continue here`, start the next batch. On `Clear and resume`, run `bash .gaia/scripts/usage.sh handoff` as the checkpoint says, and print the continuation prompt in a fenced code block with info string `text`, filling in the state file's absolute path and, when the handoff printed one, its line as the first step:

```text
<the usage.sh handoff line, when it printed one: run it first, verbatim>
Resume an interrupted /gaia-residue sweep. The sweep triages the keyed audit residue recorded in merged pull-request bodies, batch after batch, until no aged residual is left, then offers newer ones one batch per yes. Every disposition confirmed so far is in the dismissal store and the cursor has moved past it; one end-of-run publish lands the whole sweep in a single pull request. Read .claude/skills/gaia/references/residue.md and follow its `## Resume after /clear`, with the state file <absolute path to STATE.md>. Do not run /gaia-residue: the resume enters residue.md directly.
```

Then end the turn. Clearing ends the session's turn, not the run: no cost record is written here, and the resumed session writes it when the run ends.

When the sweep ends, by any arm above, run the refresh and the publish below once. A user who stops between batches, by `Stop here` or by saying so, ends the sweep the same way: the store changes this run made always reach the publish step.

## Resume after /clear

A resumed run never enters through `/gaia-residue`: the continuation prompt sends it here, so the command file's pre-flight runs on fresh starts only. Resume is detectable from the state file alone, a `Command: /gaia-residue` STATE.md under `.gaia/local/runs/`, carrying `Publish: owed` once the run has isolated.

1. Read the state file the prompt names. Bind `Phase`, `Branch`, `Tree`, `Mode`, `Publish`, `Disposed`, and `Held` from it.
2. **`Branch: none`**: the run never isolated. Stay in the main checkout; the isolate step in `## Record` runs before the first append as on any run.
3. **Otherwise**, find the run's tree. Under `Mode: worktree`, read `git worktree list --porcelain` and take the `worktree <path>` line whose following `branch refs/heads/<Branch>` line matches. When the session is not already inside that path, re-enter it with `EnterWorktree({name: "<Branch>"})`. Under `Mode: feature-branch`, `git branch --show-current` in the main checkout must print `<Branch>`. Set `RESOLVED_MODE` from `Mode` and `RESOLVED_ROOT` from the path found, and skip the isolate step in `## Record`: this run already isolated, and the publish step reads both values.
4. **The tree or branch is not found**: stop. Report the state file path and the branch, that the store changes it held may be lost, and that `git branch --list "<Branch>"` and `git worktree list` show what remains. Never start a new branch over it.
5. Restore the held tokens, then continue at `## Sweep batch by batch` with a fresh tally: in `Phase: extended`, that batch's question comes first. The run's refresh, publish, and cost record follow as on any run, with `Disposed` counting toward the refresh's run condition.
6. Once the publish step ends the run, delete the state file (`rm <absolute path to STATE.md>`), so no finished run reads as owed.

A run whose user cleared and never pasted the prompt still owes its publish. `## Fetch the live candidate list` finds it on the next fresh start.

## Refresh the statusline nudge (end of run)

Runs once, after the sweep ends and before the publish step, whenever this run confirmed at least one disposition: a store record, or a promotion's filed issue. The statusline reads `residueCandidateCount` from the shared update-check cache, which `.gaia/scripts/check-updates.sh` recomputes only once its 6-hour TTL lapses, so without this step a user who just drained the residue keeps being told to run the command again.

Rewrite that one field from a fresh count, and leave every other field alone:

```bash
CACHE_ROOT="$(bash .gaia/scripts/main-root-lib.sh 2>/dev/null || git rev-parse --show-toplevel)"
CACHE="$CACHE_ROOT/.gaia/local/cache/shared/update-check.json"
if [ -f "$CACHE" ] && command -v jq >/dev/null 2>&1; then
  AGED="$(.gaia/cli/gaia residue-tally --count-only 2>/dev/null \
    | jq -r 'select(.gh_ok == true) | .aged_candidate_count // empty' 2>/dev/null)"
  case "$AGED" in
    ''|*[!0-9]*) ;;
    *)
      TMP="$(mktemp)"
      jq --argjson n "$AGED" '.residueCandidateCount = $n' "$CACHE" > "$TMP" && mv "$TMP" "$CACHE"
      ;;
  esac
fi
```

`--count-only` is the mode the refresher uses, for the same reason: the count needs no line resolution, and resolution costs seconds per fetch. When `gh_ok` is not `true` the field is left as it was, the refresher's rule too, because a failed read is not a zero. `checkedAt` is not stamped: resetting it would make the next render re-fetch every signal just because residuals were drained. With no cache file there is nothing to correct, and the next refresh computes the count from scratch.

## Publish approved changes (end of run)

Runs once, after the sweep ends, only when this run isolated (`## Record`). It runs from `RESOLVED_ROOT`, on `<RESIDUE_BRANCH>`, whichever branch the main checkout holds.

**Confirm there are real changes.**

```bash
git status --porcelain
```

If it is empty, nothing landed: release the isolation per isolation.md's `## Releasing an isolation that holds nothing`, say so, and stop.

**Repo-state safety.** If a merge / cherry-pick / bisect is in progress in `RESOLVED_ROOT`, do not commit: leave the changes on `<RESIDUE_BRANCH>`, name its path, tell the engineer they ship through normal PR review, and stop.

Commit through a message file (never `-m`), push, and open a PR. Subject: `chore(residue): <what the drain promoted or dismissed>`.

**Commit and push, then open the PR, as two calls.**

```bash
git add -A && git commit -F <commit-message-file> && git push -u origin <RESIDUE_BRANCH>
```

```bash
gh pr create --draft --title "<commit subject>" --body-file <pr-body-file>
```

Before any `gh pr merge`:

```bash
bash .gaia/scripts/resolve-audit-members.sh
```

Empty output confirms no marker is owed, and the merge gate's out-of-scope bypass posts the status itself, but only for a `gh pr merge <N>` run as its own command: a merge sharing its tool call with anything else (a `cd` before it, a pipe into `tail`) denies until it is respelled. If it names any member, dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit` like any in-scope PR, then post the status per `#### Posting the status last`.

**Merge decision.** Ask once via `AskUserQuestion` whether to merge:

- **header:** `"Merge residue PR?"`
- **question:** `"Merge PR #<N> now, or leave it open for review?"`
- **options (this exact order):**
  1. `{ label: "Merge", description: "Squash-merge PR #<N> now." }`
  2. `{ label: "Leave open", description: "Keep the PR open; you merge it after review." }`

**Merge** → drive it to merge through `wiki/concepts/PR Merge Workflow.md` (read it, don't merge from memory): `gh pr merge <N> --squash --delete-branch --auto`, then run the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N>`, per `.claude/skills/gaia/references/work-lifecycle.md` `## 7. Merge (when asked)`. The merge above is already queued and the script issues no `gh pr merge` of its own, so nothing here re-merges. One arm per verdict plus one for the exit-2 refusal. Every arm below but `CONFLICTING` ends the run and writes its cost record (`## Cost record (run end)`):

- On `MERGED` (exit 0), clean up per `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, with `<branch-name>` = `<RESIDUE_BRANCH>`: `### Worktree entered by name in this session` under `RESOLVED_MODE=worktree`, `### Feature branch` under `feature-branch`. Print the merged PR URL.
- On `CONFLICTING` (exit 3), repair it per `wiki/concepts/PR Merge Workflow.md`'s `### Conflict found mid-wait` and run the wait again.
- On `CHECK_FAILED` (exit 4), print the PR URL and the failing check, and leave the branch in place.
- On `TIMEOUT` (exit 5), the window closed with the pull request still open: print the PR URL, note the merge is queued, and leave the branch in place.
- On `CLOSED` (exit 6), the pull request was closed without merging, so no wait can clear it: report the closure, print the PR URL, and leave the branch in place.
- On exit 2 the wait refused rather than answered: report what it could not read, print the PR URL, leave the branch in place, and assert no state for the pull request, since nothing about it was read. The merge queued above may still land.

**Leave open** → report the PR URL and stop.

Every arm that leaves the branch in place names its worktree path under `RESOLVED_MODE=worktree`, so a kept worktree never goes unreported.

If any `git` or `gh` command above exits non-zero, print the error and STOP. Do not retry, force-push, or amend.

## Cost record (run end)

Every path that ends a `/gaia-residue` run appends exactly one cost record, the run-ending paths above:

- The `gh_ok: false` and zero-candidate stops from the live candidate fetch.
- Publish's no-change stop (nothing landed in the working tree).
- Publish's unsafe-repo-state stop.
- A run that appended nothing, which never isolated and publishes nothing.
- Publish's merge outcomes: `MERGED`, still queued, a failed required check, a pull request closed without merging, a merge wait that refused because it read nothing, or "Leave open".
- Publish's non-zero-exit STOP on a `git` or `gh` command.
- The owed-run question declined at a fresh start, which stops before the tally.
- A resume whose tree or branch is not found.

Apply the shared record recipe in `.claude/skills/gaia/references/cost-record.md` with `{{COMMAND}}` = `gaia-residue`.

## Guardrails

- Never edit a file a residual cites.
- Never file a tech-debt issue without a human answer for that specific residual.
- Never widen the recognizer beyond the two canonical headings.
- Never sweep keyless entries into the candidate list.
- Never change the merge gate's attribution logic.
<!-- gaia:maintainer-only:start -->
- Never ship the store's contents to adopters.
<!-- gaia:maintainer-only:end -->
- Never record a keep that does not expire, or any suppression that leaves no tracked record a reviewer can remove.
- Never interpolate a residual's path, or any other residual-derived text, into a shell command.

**The complete set of files a run may write:**

- `.gaia/audit-residual-dismissals.jsonl`, the dismissal store;
- `.gaia/local/cache/residual-attribution.json`, the derived read cache;
- `.gaia/local/cache/residual-cursor.json`, the resumable cursor;
- the sweep's state file, `.gaia/local/runs/<RESIDUE_BRANCH>/STATE.md` or the context checkpoint's fallback, written only when the checkpoint fires between batches and deleted when the run ends;
- the `residueCandidateCount` field of `.gaia/local/cache/shared/update-check.json`, the statusline cache, rewritten by the end-of-run refresh and no other field of it;
- the transient reason file under `.gaia/local/audit/`, deleted in its own tool call;
- the filing recipe's own transient issue-body file under `.gaia/local/audit/`, and the debt-count staleness sentinel that recipe touches;
- `.gaia/local/telemetry/usage.jsonl`, the shared machine-local usage ledger the mandatory cost record appends to (written by `usage.sh record`). Not this workflow's own file, but a run does write it, so a self-check against this list has to expect it.

Nothing else. Not a source file, not a configuration file, and above all not a file any residual cites.
