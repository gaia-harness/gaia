# Owed standalone setup features

`/setup-gaia` Phase 5 reads this file, whole, on every run. It reaches a setup feature whose reference runs on its own (`standalone: true` in `.gaia/setup-features.json`) and that no earlier phase decided, so a feature a later GAIA release adds reaches a project or machine whose setup is already complete.

Run with the cached `MAY_RECORD_PROJECT`:

```bash
.gaia/cli/gaia setup drift --json | jq -r --arg may "$MAY_RECORD_PROJECT" '
  .undecided[]? | select(.standalone == true)
  | if .scope == "machine" or $may == "admin"
    then "OWED_FEATURE \(.id) \(if .required then "apply" else "ask" end) \(.reference)"
    elif $may == "not-applicable-only"
    then "OWED_FEATURE \(.id) detect \(.reference)"
    else "SKIP_PROJECT \(.id)" end'
```

The action follows the entry's `required` flag, except `detect`, which an origin on another host gets for a project feature. Drift's own `action` field is ignored here: it says `setup` for an entry that `/setup-gaia` must run, and this is that run.

For each `OWED_FEATURE <id> <action> <reference>` line, read the named reference, whole, and run it:

- `apply`: apply the feature with no question, then record `applied` with `.gaia/cli/gaia setup record <id> applied`.
- `ask`: ask its question once, as an `AskUserQuestion` with the reference's recommended answer first and marked ` (Recommended)`, then record the answer with `.gaia/cli/gaia setup record <id> <value>`. A dismissed question records nothing.
- A feature that cannot apply on this machine or project records `not-applicable`.
- A failed apply records nothing, so the next run retries it.
- `detect`: run only the reference's `## Detect`, and apply nothing. A GitHub-only feature cannot apply on another host, so when Detect says to record `not-applicable`, record it with the line below, which records nothing else and nothing off the default branch. Any other outcome records nothing: name the id as owed, as for `SKIP_PROJECT`.

```bash
if [ "$MAY_RECORD_PROJECT" = not-applicable-only ]; then
  .gaia/cli/gaia setup record <id> not-applicable
fi
```

For each `SKIP_PROJECT <id>` line, name the id in the run's output as owed by an admin run of `/setup-gaia` on the default branch, and record nothing.

No line printed means nothing is owed here; continue. A drift failure prints nothing too, and the next run retries.
