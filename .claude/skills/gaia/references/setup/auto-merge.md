# Auto-merge

`/setup-gaia` Phase 5 (`standalone-features.md`) and `/update-gaia` Step 9c run this file for the `auto-merge` feature. It turns on GitHub's `allow_auto_merge` setting, which `gh pr merge --auto` needs and GitHub leaves off by default. GAIA's merges queue behind required checks with `--auto`; with the setting off GitHub refuses that with `Auto merge is not allowed`.

Contents: Detect; Apply; Record.

## Detect

Read the remote and the runner's permission:

```bash
.gaia/cli/gaia setup detect-remote --json
```

When it reports `found: false` or a `host` other than `github.com`, record `not-applicable` (`## Record`) and stop. Otherwise, with its `owner` and `repo`:

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

When `admin` is not `true` or `auth_status` is not `"ok"`, record nothing, say `Turning on auto-merge needs a repository admin: ask one to run /setup-gaia.`, and stop.

```bash
gh api "repos/<owner>/<repo>" --jq .allow_auto_merge
```

On `true`, record `applied` and stop. On anything else, continue to `## Apply`.

## Apply

When this run created the repository (`REPO_CHOICE` is `create`) and `RECONFIGURE` is not set, enable with no question: a brand-new repository has no merge convention to preserve. Otherwise ask once with `AskUserQuestion`:

> GitHub is set to NOT allow auto-merge, so GAIA cannot queue a merge behind required checks. Enabling `allow_auto_merge` lets GAIA queue it and GitHub completes it when the checks pass. Without it GAIA waits for the required checks itself, then merges.
>
> - **Enable auto-merge** (Recommended)
> - **Skip** (GAIA waits for required checks before each merge)

To enable:

```bash
gh api -X PATCH "repos/<owner>/<repo>" -F allow_auto_merge=true --jq .allow_auto_merge
```

GitHub offers auto-merge on some plans only, and on the others it can leave the setting off. When that prints `true`, the setting is on. When it prints anything else or the call fails with a plan message, say `GitHub does not offer auto-merge for this repository, so GAIA waits for required checks before each merge.` and record `not-applicable`. Any other failure records nothing, so the next run retries.

## Record

```bash
.gaia/cli/gaia setup record auto-merge <applied|declined|not-applicable>
```

`declined` is the opt-out. An opted-out repository merges through the wait in `wiki/concepts/PR Merge Workflow.md`, `**When --auto is refused:**`.
