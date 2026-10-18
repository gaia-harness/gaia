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

**Report the push result honestly.** A repository ruleset can reject even an admin's direct push (`GH006`). On a failed push, say so in one line and tell the admin the decisions are committed locally and need a push or a pull request; never report success on a failed push.

## The setup ping

A fire-and-forget adoption ping, the last substantive step of the run. Run with `SETUP_TYPE` and `REPO_CHOICE` from Phase 6 and the cached `OWED_AT_START`:

```bash
DECIDED_NOW=" $(.gaia/cli/gaia setup drift --json 2>/dev/null | jq -r '(.decided // {}) | keys | join(" ")' 2>/dev/null) "
NEWLY_DECIDED=""
for id in $OWED_AT_START; do
  case "$DECIDED_NOW" in *" $id "*) NEWLY_DECIDED="$NEWLY_DECIDED $id" ;; esac
done
if [ -z "$SETUP_TYPE" ] && [ -z "$NEWLY_DECIDED" ]; then
  echo PING_SKIPPED
else
  SANDBOX="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r 'if .outcome == "enabled" then "on" else "off" end' 2>/dev/null)"
  set --
  [ -n "$SETUP_TYPE" ] && set -- "$@" --type "$SETUP_TYPE"
  [ -n "$REPO_CHOICE" ] && set -- "$@" --repo "$REPO_CHOICE"
  .gaia/cli/gaia ping --event setup --sandbox "${SANDBOX:-off}" "$@" || true
fi
```

- `--sandbox` always carries the machine's real sandbox decision: `on` when the marker's outcome is `enabled`, `off` for `declined`, `incapable` or no marker.
- `--type` rides only when `SETUP_TYPE` is set. With it empty (a plain re-run on a provisioned project), the ping fires only when this run decided an id that was owed at its start; a run that decided nothing sends no ping, so a no-op re-run never inflates setup counts.
- `--repo` rides only when this run answered the connect question. The CLI's values (`create`, `adopt`, `manual`) describe that choice, and a run that made none has no honest value to send.
- A drift failure counts as nothing newly decided.

## The closing message

A run can reach Phase 6 with its GitHub setup undone: Phase 3's clean-tree refusal on Create, the set-up-manually answer, or an authentication or admin refusal each skip the rest of Phase 3. So the closing line never claims completion just because the run reached the end, except for a non-admin: project settings are an admin's to record, so an admin refusal (cached admin false) owes nothing on this machine and ends on the done line. It reads the project settings still owed that this machine can act on, after every record this run made, through the same predicate the statusline's `⚙️ /setup-gaia` nudge counts, so the message and the nudge never disagree:

```bash
. .gaia/statusline/setup-owed.sh && printf 'OWED_AT_END=%s\n' "$(gaia_setup_owed_ids .)"
```

The predicate's header in `.gaia/statusline/setup-owed.sh` says which owed ids count for an admin, a non-admin and a machine with no cached admin answer.

When the run's summary lists what changed on GitHub and this run applied the Dependabot posture, its Dependabot item is this line verbatim, never a shortened form, because the reason is what keeps a first-time adopter from turning Dependabot's security fix pull requests back on:

```text
Dependabot security alerts are on. GAIA updates vulnerable packages for you and tests the result before anything changes, so Dependabot's own security fix pull requests are turned off.
```

Then output (in the user's language), with a blank line between the two lines. When `OWED_AT_END` is empty:

```text
You're all set: your GAIA project is ready. Restart Claude Code to load your new plugins and skills.

New to GAIA? The docs walk you through your first feature: https://docs.gaiareact.com/
```

When `OWED_AT_END` is not empty, name its ids in place of the placeholder:

```text
Setup isn't finished: these project settings are still owed: <the OWED_AT_END ids>. Fix what stopped them above, then re-run /setup-gaia; it resumes from the first owed step. Restart Claude Code to load your new plugins and skills.

New to GAIA? The docs walk you through your first feature: https://docs.gaiareact.com/
```
