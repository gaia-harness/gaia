# Required CI checks

`/setup-gaia` Phase 5 (`standalone-features.md`) and `/update-gaia` Step 9c run this file for the `required-ci-checks` feature. It registers the two jobs of the shipped `.github/workflows/tests.yml` as required checks on the default branch, beside `GAIA-Audit`:

- `Vitest and Playwright`: typecheck, the changed-file lint, Vitest and Playwright.
- `Shellcheck and bats`: shellcheck over the changed shell, and the bats suites when shell changed.

`GAIA-Audit` alone gates the audit, not the code: a pull request whose lint or tests are red merges once the audit clears, and a commit that skipped the local Quality Gate reaches the default branch unchecked. Both jobs report on every pull request, green when nothing they cover changed, so requiring them never holds a pull request that has nothing to check.

`Run Chromatic` is never registered: Chromatic is optional, and a project that runs out of its plan's snapshots would have every merge blocked.

Contents: Detect; Register; Record.

## Detect

Read the remote and the runner's permission:

```bash
.gaia/cli/gaia setup detect-remote --json
```

When it reports `found: false` or a `host` other than `github.com`, record `not-applicable` (`## Record`) and stop. Otherwise, with its `owner` and `repo`:

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

When `admin` is not `true` or `auth_status` is not `"ok"`, record nothing, say `Registering the Vitest and Playwright and Shellcheck and bats required checks needs a repository admin: ask one to run /setup-gaia.`, and stop.

List the contexts this checkout's workflow publishes:

```bash
for context in 'Vitest and Playwright' 'Shellcheck and bats'; do
  grep -qxF "    name: $context" .github/workflows/tests.yml 2>/dev/null && printf '%s\n' "$context"
done
```

A project that removed the workflow, or a job, publishes nothing under that name, and requiring a context nothing posts would hold every pull request. No line printed: record `not-applicable` and stop. Otherwise carry the printed lines as `<contexts>`.

Read the default branch:

```bash
gh api "repos/<owner>/<repo>" --jq '.default_branch'
```

## Register

**GET the current contexts, then PUT the full set back with `<contexts>` added.** The PUT replaces the list, so every context already required (`GAIA-Audit` among them) is kept. When every one of `<contexts>` is already required, no PUT is sent. Pass `<contexts>` as one JSON array:

```bash
required_checks_endpoint="repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks"
wanted_contexts='<contexts as a JSON array>'
# A failed GET sends no PUT: replacing contexts that could not be read would drop the siblings.
if ! current_contexts=$(gh api "$required_checks_endpoint" --jq '.contexts'); then
  echo "Could not read the required status checks on <default-branch>." >&2
  exit 1
fi
if jq -en --argjson current "$current_contexts" --argjson wanted "$wanted_contexts" '$wanted - $current | length == 0' >/dev/null; then
  echo "The CI checks are already required on <default-branch>."
else
  jq -n --argjson current "$current_contexts" --argjson wanted "$wanted_contexts" \
    '{contexts: ($current + ($wanted - $current))}' \
    | gh api -X PUT "$required_checks_endpoint/contexts" --input - >/dev/null
  echo "Now required on <default-branch>: <contexts, comma-separated>."
fi
```

On a non-zero exit (a 404 means the default branch has no protection rule with required status checks yet; `/setup-gaia` creates one), relay the error and record nothing, so the next run retries. Then tell the user:

```
Could not register the CI required checks. Once the default branch has a protection rule, a repository admin can re-run /setup-gaia, or add <contexts, comma-separated> to its required status checks in the repository settings.
```

On success, tell the user once what changed for them:

```
<contexts, comma-separated> now required on <default-branch>: a pull request with red lint, typecheck, tests or shellcheck can no longer merge. Both checks report green when nothing they cover changed.
```

## Record

Run the record line `standalone-features.md` (or `/update-gaia` Step 9c) names for the outcome: `.gaia/cli/gaia setup record required-ci-checks not-applicable` for a non-GitHub origin or a project that publishes neither context, otherwise `.gaia/cli/gaia setup record required-ci-checks applied` after the registration succeeds or finds nothing to add. A failed registration records nothing.
