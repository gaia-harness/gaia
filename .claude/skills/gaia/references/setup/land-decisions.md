# Land setup decisions, the setup ping and the closing message

`/setup-gaia` reads this file, whole: Phase 5.5 runs `## Land the decisions` when project decisions may be recorded, and Phase 6 runs `## The setup ping` and then `## The closing message` on every run.

Contents: Land the decisions; The setup ping; The closing message.

## Land the decisions

Project-scope decisions live in `.gaia/project.json`, which is committed and team-shared, so a decision recorded this run reaches the team only once it lands on the default branch. The whole file is compared, not `setup_decisions` alone, so a team key an owed question wrote after Phase 3.5's commit lands with it, and a run that changed nothing commits nothing:

```bash
if [ ! -f .gaia/project.json ]; then
  echo NOTHING_TO_LAND
elif ! git cat-file -e HEAD:.gaia/project.json 2>/dev/null; then
  echo LAND
elif git show HEAD:.gaia/project.json | cmp -s - .gaia/project.json; then
  echo NOTHING_TO_LAND
else
  echo LAND
fi
```

On `NOTHING_TO_LAND`, stop here. On `LAND`, commit and push in three separate Bash calls, the same main-branch hook standdown Phase 3.5's commit uses: the `block-main-destructive-git.sh` PreToolUse hook denies `git commit` and `git push` on `main` or `master`, and a machine-local sentinel in `.gaia/local/` suspends it for this one commit and push.

**Separate Bash call, first** (the hook reads the sentinel before a command runs, so it must exist before the call holding the commit):

```bash
mkdir -p .gaia/local
touch .gaia/local/setup-in-progress
```

**Then, in its own call**, with `DEFAULT_BRANCH` declared from the cached value:

```bash
git add .gaia/project.json
if ! git commit -m "chore(gaia): record setup decisions"; then
  echo "Could not commit the setup decisions; nothing was pushed."
elif git push origin "$DEFAULT_BRANCH"; then
  echo "LANDED $(git rev-parse --short HEAD)"
else
  echo "The push to $DEFAULT_BRANCH failed: the setup decisions are committed locally and need a push or a pull request."
fi
```

**Then, in its own call, unconditionally** (even when the commit or push failed: a lingering sentinel keeps main-branch protection suspended on this machine):

```bash
rm -f .gaia/local/setup-in-progress
```

## The setup ping

A fire-and-forget adoption ping, the last substantive step of the run. Run with `SETUP_TYPE` and `REPO_CHOICE` from Phase 6 and the cached `OWED_AT_START`, each passed as one quoted argument (an empty value is fine):

```bash
bash .gaia/scripts/setup-ping.sh --owed "$OWED_AT_START" --type "$SETUP_TYPE" --repo "$REPO_CHOICE"
```

The decision runs in a bash script because Claude's Bash tool may be zsh, which does not split a space-separated id list the way an inline loop needs. It prints `PING_SKIPPED` when no ping is owed.

- `--sandbox` always carries the machine's real sandbox decision: `on` when the marker's outcome is `enabled`, `off` for `declined`, `incapable` or no marker.
- `--type` rides only when `SETUP_TYPE` is set. With it empty (a plain re-run on a provisioned project), the ping fires only when this run decided an id that was owed at its start; a run that decided nothing sends no ping, so a no-op re-run never inflates setup counts.
- `--repo` rides only when this run answered the connect question. The CLI's values (`create`, `adopt`, `manual`) describe that choice, and a run that made none has no honest value to send.
- A drift failure counts as nothing newly decided.

## The closing message

A run can reach Phase 6 with its GitHub setup undone: Phase 3's clean-tree refusal on Create, the set-up-manually answer, or an authentication or admin refusal each skip the rest of Phase 3. So the closing line never claims completion just because the run reached the end. A non-admin (cached admin false) cannot record project settings, and Phase 5 skips the admin-gated features such as the required CI checks for them, so their run must not end on the done line while one is unapplied either. Nor must a run on a github.com origin whose admin probe was not `ok` (`gh` not signed in, GitHub not answering, or no repository yet when setup checked): no admin answer is cached then, so the predicate alone names nothing for the admin-gated settings. Read three sets, after every record this run made: the project settings still owed that this machine can act on, through the same predicate the statusline's `⚙️ /setup-gaia` nudge counts so the message and the nudge never disagree; on a github.com origin whose probe was not `ok`, every undecided admin-gated setting; and the admin-gated settings a cached non-admin leaves for an admin. Run it with Phase 1's cached `HOST` and `AUTH_STATUS` declared in the same call (`AUTH_STATUS` empty when the probe did not run):

```bash
. .gaia/statusline/setup-owed.sh
ADMIN_UNCHECKED_AT_END=""
if [ "$HOST" = github.com ] && [ "$AUTH_STATUS" != ok ]; then
  ADMIN_UNCHECKED_AT_END="$(gaia_setup_admin_gated_ids .)"
fi
printf 'OWED_AT_END=%s\nADMIN_OWED_AT_END=%s\nADMIN_UNCHECKED_AT_END=%s\n' "$(gaia_setup_owed_ids .)" "$(gaia_setup_admin_owed_ids .)" "$ADMIN_UNCHECKED_AT_END"
```

The predicate's header in `.gaia/statusline/setup-owed.sh` says which owed ids count for an admin, a non-admin and a machine with no cached admin answer, and why the nudge stays quiet for a non-admin. An origin on another host, or no origin, leaves `ADMIN_UNCHECKED_AT_END` empty: the GitHub settings do not apply there.

When the run's summary lists what changed on GitHub and this run applied the Dependabot posture, its Dependabot item is this line verbatim, never a shortened form, because the reason is what keeps a first-time adopter from turning Dependabot's security fix pull requests back on:

```text
Dependabot security alerts are on. GAIA updates vulnerable packages for you and tests the result before anything changes, so Dependabot's own security fix pull requests are turned off.
```

Then output these lines (in the user's language), each its own paragraph with a blank line between them, in this order. The closing never asks for a reload command or a restart: a plugin setup installs from the shell loads in this session, and `per-machine.md`'s install-tools names the one case where a skill appears only from the next session.

**The status line.** When `OWED_AT_END`, `ADMIN_UNCHECKED_AT_END` and `ADMIN_OWED_AT_END` are all empty:

```text
You're all set: your GAIA project is ready.
```

When `OWED_AT_END` is not empty, name its ids in place of the placeholder:

```text
Setup isn't finished: these project settings are still owed: <the OWED_AT_END ids>. Fix what stopped them above, then re-run /setup-gaia; it resumes from the first owed step.
```

When `OWED_AT_END` is empty and `ADMIN_UNCHECKED_AT_END` is not, name its ids in place of the placeholder:

```text
Your part of setup is done, but these project settings are still undecided: <the ADMIN_UNCHECKED_AT_END ids>. GAIA couldn't check whether you're a repository admin, because gh isn't signed in, GitHub didn't answer, or the repository didn't exist yet when setup checked. Re-run /setup-gaia (after gh auth login if gh isn't signed in), or ask a repository admin to run it on the default branch.
```

When `OWED_AT_END` and `ADMIN_UNCHECKED_AT_END` are empty and `ADMIN_OWED_AT_END` is not, name its ids in place of the placeholder:

```text
Your part of setup is done, but these project settings still need a repository admin: <the ADMIN_OWED_AT_END ids>. They stay unapplied until a repo admin runs /setup-gaia on the default branch, so ask one to.
```

**The sandbox line.** After the status line, add this line when its condition holds:

- When `SANDBOX_ANSWER` is `enable` (this run's Phase 2 enabled the sandbox; a sandbox an earlier run enabled does not count): `The sandbox you enabled takes effect from your next Claude Code session.`

**The auto-mode line**, always. Its wording holds in any permission mode, so it prints without Claude judging which mode the session is in, a judgment that does not hold run to run:

```text
If this session is in auto mode, press Shift+Tab to leave it, or start Claude with plain claude next time.
```

**The fresh-context line**, always:

```text
Type /clear to start your first feature with a fresh context.
```

**The docs line**, always, last:

```text
New to GAIA? The docs walk you through your first feature: https://docs.gaiaharness.com/getting-started/onboarding/
```
