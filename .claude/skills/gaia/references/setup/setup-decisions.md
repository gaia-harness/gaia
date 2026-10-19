# Setup decisions

`/setup-gaia` Phase 1 reads this file, whole, on every run: it finds which listed setup features have no recorded decision, and who may record a project decision. Every later phase uses the two check lines and the values below by name.

The shipped list `.gaia/setup-features.json` names each setup feature by a stable id. A decision is one of `applied`, `declined` or `not-applicable`, written only by `.gaia/cli/gaia setup record <id> <value>`: a project-scope id lands in `.gaia/project.json` `setup_decisions` (committed), a machine-scope id in `.gaia/local/setup-state.json` `decisions` (this machine only).

## The owed check

Run once, at the start of the run, and cache `OWED_AT_START` (the ping at the end compares against it):

```bash
if DRIFT_JSON="$(.gaia/cli/gaia setup drift --json)"; then
  printf 'OWED_AT_START=%s\n' "$(printf '%s' "$DRIFT_JSON" | jq -r '[.undecided[]?.id] | join(" ")')"
else
  echo DRIFT_FAILED
fi
```

`DRIFT_FAILED` (an unreadable list or record file; drift names it on stderr) means no id is owed this run: `OWED_AT_START` is empty and each phase falls back to its own gate. Surface the error and continue.

A phase asks about one id with one of these two lines, substituting the id. Each reads the records as they stand now, so a decision recorded earlier in this run counts.

- **The owed check** exits 0 when the id has no recorded decision:

  ```bash
  .gaia/cli/gaia setup drift --json | jq -e --arg id <id> 'any(.undecided[]?; .id == $id)' >/dev/null
  ```

- **The declined check** exits 0 when the id is recorded `declined`:

  ```bash
  .gaia/cli/gaia setup drift --json | jq -e --arg id <id> '.decided[$id] == "declined"' >/dev/null
  ```

When drift fails, both exit non-zero: nothing is owed and nothing reads as declined.

## Who records project decisions

Run with Phase 1's cached values: `FOUND`, `HOST`, `ADMIN` and `AUTH_STATUS` from `detect-remote` and `check-admin` (empty when that probe did not run), and `DEFAULT_BRANCH` from Phase 1's repo probe on a github.com origin (empty otherwise). Cache both printed values:

```bash
if [ "$FOUND" = true ] && [ "$HOST" != "github.com" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
fi
[ "$FOUND" = true ] || DEFAULT_BRANCH=""
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
MAY_RECORD_PROJECT=none
if [ -n "$DEFAULT_BRANCH" ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  if [ "$HOST" != "github.com" ]; then
    MAY_RECORD_PROJECT=not-applicable-only
  elif [ "$ADMIN" = true ] && [ "$AUTH_STATUS" = ok ]; then
    MAY_RECORD_PROJECT=admin
  fi
fi
printf 'DEFAULT_BRANCH=%s\nMAY_RECORD_PROJECT=%s\n' "$DEFAULT_BRANCH" "$MAY_RECORD_PROJECT"
```

- `admin`: a github.com origin, a repo admin with an authenticated `gh`, on the default branch. Records every project-scope id.
- `not-applicable-only`: an origin on another host whose `origin/HEAD` names the default branch, and this checkout is on it. Records only `not-applicable` for the GitHub ids.
- `none`: anything else (no origin, a non-admin, an unknown default branch, another branch). Records no project-scope id.

Every project-scope record line is gated on this value (`[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record <id> <value>`); declare it with the cached value in the same call. Machine-scope record lines are never gated.

A run that cannot record a project id leaves it owed; the next admin run on the default branch records it.

## Probe first

An owed phase probes before it asks or applies:

- The feature is already in place: record the value its own state shows, with no question.
- Optional and undecided: ask once, as an `AskUserQuestion` with the recommended answer first and marked ` (Recommended)`, and record the answer. A dismissed question records nothing. A feature with a shipped default (the isolation policy, the sandbox recommendation, and the sandbox unless the team recommends it) asks nothing on a plain run: it records the default, and `--reconfigure` asks.
- Required and missing: apply it and record `applied` on success. A failed apply records nothing, so the next run retries.
- The feature cannot apply here (no global statusline, an incapable sandbox, an origin not on github.com): record `not-applicable`.

## Precedence

A feature's own state (`.gaia/local/sandbox.json`, `.gaia/local/settings.json`, the `.gaia/project.json` keys, the GitHub settings) governs behavior and its phase's own gate; the record only says the id was decided.

- A `declined` record satisfies the phase's own gate on a plain run: a declined feature is never re-asked, even when its own state is missing, until `--reconfigure` re-opens it. The missing state already behaves like the decline. The one exception is `sandbox`: a `declined` record with no sandbox marker is the shipped default-off, not an answer, so a team recommendation still asks that machine (`setup-gaia.md` Phase 2).
- An `applied` or `not-applicable` record never suppresses a phase its own gate says is owed. The phase asks or applies again, and the new answer overwrites the record.
