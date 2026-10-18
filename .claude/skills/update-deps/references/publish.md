## Phase 8: Publish

**If nothing was updated** (all packages were already up to date or all were skipped, the transitive refresh did not report `landed`, and no security resolution landed), skip this phase entirely. Phase 8 runs when the only landed work is security resolutions. An accepted advisory changes no file (its dismissal lives on GitHub), so acceptance alone publishes nothing.
<!-- gaia:maintainer-only:start -->

A re-vendor diff from the Vendored skill sync step counts as an update: publish it even when no package moved, with the subject `chore(deps): re-vendor playwright-cli skill <version>`. It touches paths beyond the dependency manifests, so it gets the normal audit handshake, not the dep-bump bypass.
<!-- gaia:maintainer-only:end -->

**If `/gaia-init` invoked the run** (`INVOKED_BY_INIT=true`), skip the rest of this phase: do not commit, push, open a PR, or merge. Leave the changes uncommitted on the current branch, say so in one line, and return to `/gaia-init`, whose init commit carries them into the first push.

**Commit the update.** Stage and commit the applied changes on the current branch. Write the message to a temp file first, then commit from it:

```bash
git add -A
git commit -F <commit-message-file>
```

The commit **subject** must be `chore(deps): <concise summary of what moved>` (use `chore(deps-dev):` when every landed change is a devDependency version bump; a refresh-only run uses `chore(deps): refresh transitive dependencies`). The summary names the security work, for example `chore(deps): resolve 2 security advisories (cookie, tar)`. An in-range refresh or a security-floor override has no declared dependency type, so a run whose landed changes are only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`. A reverted resolution leaves no trace in the commit: its revert restored its files before staging. Every `/update-deps` commit follows a passing local quality gate. That subject triggers the dep-bump bypass in the merge gate (`wiki/concepts/Audit Gate Reference.md`, `#### Signals`; `.gaia/scripts/chore-deps-skip.sh` decides it) only when every path the PR changes is a dependency manifest (`.gaia/scripts/chore-deps-skip.sh` owns the manifest set); a migration edit, a root-config change, or any other path denies the bypass and the PR gets the normal audit handshake and the normal Tests/Chromatic runs. On a manifest-only PR the bypass waives code-audit-frontend only; any other member the diff dispatches still earns its own marker. Routing the message through a file rather than `-m` keeps package-manager keywords from tripping shell-hook false positives. The Wave agents already ran the full quality gate over their changes, and Phase 6 kept only the override changes that passed it, so nothing else is owed before committing. A Phase 6 gate failure with nothing to restore is already in the report's Quality gate section for the maintainer.
<!-- gaia:maintainer-only:start -->

In this checkout `.gaia/cli/package.json` also counts as a dependency manifest. A CLI dependency change touches it and the root `pnpm-lock.yaml`, so the diff routes to `code-audit-maintainer-node`.
<!-- gaia:maintainer-only:end -->

Then branch on where the run started.

**If this is a worktree run** (`CREATED_WORKTREE=true`, or a worktree run in place because the session started inside its own update worktree, mode 3). Every command takes the plain, literal-value shape; `<branch-name>` is the update branch and `<worktree path>` the worktree's root.

1. Push the branch:
   ```bash
   git push -u origin <branch-name>
   ```
2. Check for an open PR on the branch with one plain command:
   ```bash
   gh pr list --head <branch-name> --state open --json number,url
   ```
   When one exists, reuse it: a re-run after a `TIMEOUT`, a `CHECK_FAILED` or a refused wait left it open, and its number is `<N>`. Otherwise open a draft PR against `main` (`gh pr create --draft`). Title: the commit subject. Body: the migration report rendered as markdown, via `--body-file` on a temp file (same false-positive reason). Capture the PR number `<N>` and its URL.
3. Print the worktree notice from `.claude/skills/update-deps/references/worktree.md` (`## The worktree notice`) with `<worktree path>`, `<branch-name>` and `<main checkout path>` filled in.
4. **Merge when green, then clean up locally.** This step runs only on a worktree run, it is what "completes the flow." Merge per `wiki/concepts/PR Merge Workflow.md`: when the PR's diff is manifest-only, the `chore(deps)` title clears its audit-marker gate via the dep-bump bypass; otherwise run the full audit handshake in that page (the `audit-loop-unit` agent, per its `## Dispatch the audit loop unit`, for every member `resolve-audit-members.sh` names, `code-audit-frontend` included) before the merge call below.

<!-- gaia:maintainer-only:start -->

On a manifest-only run, first run `bash .gaia/scripts/resolve-audit-members.sh`; when it names a member other than `code-audit-frontend`, dispatch the `audit-loop-unit` agent per `wiki/concepts/PR Merge Workflow.md` `## Dispatch the audit loop unit`. Whenever the run changed `.gaia/cli/package.json`, `code-audit-maintainer-node` is among them. If the `pnpm -C .gaia/cli bundle` rebuild moved a committed `.gaia/cli` bundle file (Phase 8's `git add -A` picks up only a bundle that actually moved), the diff is NOT manifest-only, so `code-audit-frontend` is owed too, same as any other member. Otherwise, on a manifest-only run, the `chore(deps)` title waives only `code-audit-frontend` (see the bypass paragraph in `wiki/concepts/Audit Gate Reference.md`), so each other member's earned marker is what completes the handshake. Skip this and `GAIA-Audit` stays at `members pending` and the queued merge waits on it indefinitely. Once `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last` conditions hold, post the status per that section before the merge call below.
<!-- gaia:maintainer-only:end -->

```bash
gh pr merge <N> --squash --delete-branch --auto
```

`--auto` queues the merge so GitHub lands it once the required checks pass (or immediately if they are already green). If the repo has auto-merge disabled and `gh` rejects `--auto`, wait for the required checks to pass by reading `gh pr checks <N>` as a bounded series of single calls, not a shell loop (`.claude/hooks/block-handrolled-pr-poll.sh` denies a loop naming `gh pr checks` that reads no `mergeable`), then re-run the merge without `--auto`.

`gh pr merge` can exit success while the merge is still queued, so verify the terminal state before touching the local checkout: run the merge wait, `bash .gaia/scripts/pr-wait-merge.sh --pr <N> --attempts 20`, per `.claude/skills/gaia/references/work-lifecycle.md` `## 7. Merge (when asked)`.

The 20-attempt bound replaces the default 5, for the reason the sibling callers give: the merge queued above lands only after a fresh full CI run, which outlasts the ~2.5 minutes the default spends, so a default-bound wait would report `TIMEOUT` on essentially every run and the cleanup below would never be reached.

- **`MERGED`** (exit 0) → clean up per `.claude/skills/gaia/references/work-lifecycle.md` `## 8. Cleanup`, then print the merged PR URL. Pick the arm by how this session holds the worktree: `### Worktree entered by name in this session` when this run created and entered it (`CREATED_WORKTREE=true`), `### Worktree entered by path or in an earlier session` on a worktree run in place. Fill `<main checkout path>`, `<worktree path>` and `<branch-name>` in; that arm's fences take `git -C <main checkout path>` forms, so they run from a session launched inside the tree. The pre-removal check and the lockfile-triggered install live in those arms and are not restated here.
- **`TIMEOUT`** (exit 5, the bound was spent with the pull request still open) → print the PR URL and note that the merge queued above has not landed yet, then print the cleanup to run once it lands: a pointer to `.claude/skills/gaia/references/work-lifecycle.md` `### Worktree entered by path or in an earlier session`, with the worktree path and the branch filled in. **Do not** delete or leave anything: the worktree, the branch and the session stay as they are, the PR is still open.
- **`CONFLICTING`** (exit 3) → repair it per `wiki/concepts/PR Merge Workflow.md`'s `### Conflict found mid-wait` and run the wait again.
- **`CHECK_FAILED`** (exit 4) → print the PR URL and the failing check, and leave the worktree and branch in place as for a queued merge.
- **`CLOSED`** (exit 6) → the pull request was closed without merging, so no wait can clear it: report that, leave the worktree and branch in place, and stop.
- **the wait refused rather than answered** (exit 2) → report what it could not read, leave the worktree and branch in place, and assert no state for the pull request.

**If you were already on a non-default branch** at pre-flight (mode 5), or running in CI (mode 2); neither creates a worktree or a branch:

1. Push the branch:
   ```bash
   git push
   ```
2. Do not open a PR and do not merge, the branch owner (the user, or the CI job that invoked it) drives it from here.

If any `git push` or `gh pr create` above exits non-zero, print the command's error and STOP. Do not retry, force-push, or amend, a rejected push or failed PR creation is the user's call to resolve (usually a manual rebase or a remote-side block).

`gh pr merge` is the exception for a worktree run. It can exit non-zero on its local branch delete after the GitHub-side merge succeeded, because the branch is checked out in the worktree. That is the local-sync failure in `wiki/concepts/PR Merge Workflow.md` `## Local-sync failure mode`, not a STOP: confirm it with the merge wait above, and when the wait prints `MERGED`, do not retry the merge and clean up as that verdict says. Any other non-zero exit from `gh pr merge` that the wait does not show as merged prints the command's error and STOPs on the same terms as the commands above (a blocked merge or a failing check is the user's call to resolve).
