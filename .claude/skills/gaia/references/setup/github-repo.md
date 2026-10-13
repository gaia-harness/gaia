# GitHub repository connection and remaining defaults

`/setup-gaia` Phase 3 reads this file, whole, when the repo does not exist yet or its default branch is not pushed. Run `## Connect the repository` first; Options 1 and 2 return to `### Recommended defaults` in `setup-gaia.md`, and Option 3 and the authentication refusal skip the rest of Phase 3 and continue at Phase 3.5 in `setup-gaia.md`. After the registration there, `## Remaining defaults` runs.

Contents: Connect the repository; Remaining defaults.

## Connect the repository

Ask (AskUserQuestion) with these three options:

> How do you want to connect this project to GitHub?
>
> - **Create the repo on GitHub** (Recommended): I'll create it private, push your default branch, and set the recommended defaults.
> - **Adopt an existing repo**: you already have a github `origin`; I'll skip creation and apply the recommended defaults.
> - **Set one up manually**: I'll print guidance and leave GitHub untouched.

### Option 1: Create the repo on GitHub

**Pre-creation authz check (distinct from the existing-repo admin probe).** `check-admin` needs a repo that already exists, so it cannot gate creation. Confirm an **authenticated gh with repo-creation rights** first:

```bash
gh auth status
```

If `gh` is unauthenticated (or the active token lacks the `repo` scope needed to create a repository), do NOT attempt creation. Print:

```
Creating a GitHub repo needs an authenticated gh with repo-creation rights. Run `gh auth login` (grant the `repo` scope), then re-run /setup-gaia and pick "Create the repo on GitHub". Or choose "Adopt an existing repo" / "Set one up manually".
```

Exit the repo phase without mutating GitHub: skip the rest of Phase 3 and continue at Phase 3.5 in `setup-gaia.md`.

**Choose the owner (personal account or organization).** Before creating, decide *where* the repo lives. Resolve the personal login and enumerate the orgs the user belongs to:

```bash
gh api user --jq .login                       # personal login
gh api --paginate /user/orgs --jq '.[].login' # org memberships (best-effort; may need the read:org scope)
```

Org enumeration is best-effort: `/user/orgs` only returns orgs the active token can see. A missing org is not fatal; the free-text path below covers it.

**If the user belongs to no orgs, skip the owner question entirely** and create under the personal account (the default create command below).

Otherwise, rank the orgs by the user's own recent commit activity so the most-likely target is offered first. The contributions graph is the precise "committed to" signal (last-year window), one call:

```bash
gh api graphql -f query='
{ viewer { contributionsCollection { commitContributionsByRepository(maxRepositories: 100) {
  repository { owner { login } } contributions { totalCount } } } } }' --jq '
  [.data.viewer.contributionsCollection.commitContributionsByRepository[]
   | {owner: .repository.owner.login, n: .contributions.totalCount}]
  | group_by(.owner) | map({owner: .[0].owner, n: (map(.n) | add)})
  | sort_by(-.n) | .[].owner'
```

Order the org set by this ranking; orgs the ranker omits fall to the end in membership order. If the GraphQL call fails or returns nothing (older gh, missing scope, no recent activity), fall back to plain `/user/orgs` order. Ranking is cosmetic: it only decides which orgs appear as buttons; the final choice is always correct.

Then AskUserQuestion with these options **in this exact order**:

> Where should this repository live?
>
> - **Personal account (@<login>)** (Recommended): create it under your own GitHub account.
> - **<org>**: create it in this organization. (one option per org, ranked; **at most 3**)

If the user belongs to **more than three** orgs, print the full ranked list first, offer the personal account plus the **top 3** ranked orgs as buttons, and add to the question: "If the org you want isn't a button, choose Other and type its exact login from the list above." (AskUserQuestion supplies the free-text Other option automatically.) Record the chosen owner for the create command below.

**Create private by default.** Non-interactive `gh repo create` requires one of `--public` / `--private` / `--internal`; default to `--private`. Create under the owner chosen above: omit the positional for the personal account, or pass `<owner>/<name>` for an org (deriving `<name>` from the project directory):

```bash
# Personal account:
gh repo create --source=. --push --private
# Organization <owner>:
gh repo create "<owner>/$(basename "$PWD")" --source=. --push --private
```

Because the repo is created `--private`, the pushed history lands in a private repo and is never publicly exposed by this push. A **public or internal** repo is created **only** after a separate, explicit confirmation:

> Create this repository **public or internal** instead of private? Its full pushed git history becomes visible to everyone who can see the repo.
>
> - **Keep it private** (Recommended)
> - **Make it public**
> - **Make it internal** (org-visible)

Never flip the repo to public/internal without this second confirmation. Private-by-default is the primary mitigation for exposing historical secrets in the pushed history.

**Secret-scanning push-protection (best-effort).** Immediately after create, enable secret-scanning push-protection so it guards every later push and is in place before any public/internal flip:

```bash
gh api -X PATCH "repos/<owner>/<repo>" --input - <<'JSON'
{"security_and_analysis": {"secret_scanning_push_protection": {"status": "enabled"}}}
JSON
```

If this is unavailable on the plan (e.g. a private repo without GitHub Advanced Security), degrade gracefully: print a one-line note that push-protection could not be enabled and continue. Do not halt.

After creation, cache `owner`/`repo` from the new remote and return to `### Recommended defaults` in `setup-gaia.md`.

### Option 2: Adopt an existing repo

The user already has a github `origin` (cached in Phase 1). Skip creation and return to `### Recommended defaults` in `setup-gaia.md`.

### Option 3: Set one up manually

Print:

```
Create a repo on your provider, then:
  git remote add origin <url>
  git push -u origin <default-branch>
When it's pushed, re-run /setup-gaia to apply the recommended defaults (branch protection and the GAIA-Audit required check need repo admin).
```

Exit the repo phase without mutating GitHub: skip the rest of Phase 3 and continue at Phase 3.5 in `setup-gaia.md`.

## Remaining defaults

**delete_branch_on_merge.** Read the current setting:

```bash
gh api "repos/<owner>/<repo>" --jq .delete_branch_on_merge
```

If `false`, AskUserQuestion:

> GitHub is set to NOT delete branches when PRs merge, so every merged branch stays on the remote until someone deletes it by hand. GAIA runs no branch cleanup of its own. Enabling `delete_branch_on_merge` has GitHub delete each pull request's branch as it merges.
>
> - **Enable delete_branch_on_merge** (Recommended)
> - **Skip** (merged branches stay on the remote)

On Enable:

```bash
.gaia/cli/gaia setup enable-delete-branch --owner <owner> --repo <repo>
```

If already `true`, print `delete_branch_on_merge is already enabled.` and continue.

**Squash-only merges.** Phase 3.7 owns this offer; it runs there, after the team settings, because `--reconfigure` re-opens it on a repo this phase no longer touches.

**Dependabot posture.** Dependabot is a data source for `/update-deps`, never a pull-request producer: alerts stay on and automated security fixes stay off. First warn about any existing Dependabot or Renovate config, without editing either file:

```bash
.gaia/cli/gaia setup warn-existing-tools --json
```

When `found` contains `dependabot` and `dependabot_unparseable` is not true, print:

```
.github/dependabot.yml has an npm entry. GAIA's /update-deps covers npm and pnpm, and running both opens duplicate dependency PRs.

To remove it: delete the `package-ecosystem: npm` entry from .github/dependabot.yml (other ecosystems can stay). /setup-gaia leaves the file untouched.
```

When `dependabot_unparseable` is true, print instead:

```
.github/dependabot.yml could not be read. Check it for an npm entry: GAIA's /update-deps covers npm and pnpm, and running both opens duplicate dependency PRs.

To remove one: delete the `package-ecosystem: npm` entry from .github/dependabot.yml (other ecosystems can stay). /setup-gaia leaves the file untouched.
```

When `found` contains `renovate`, print:

```
A Renovate configuration was detected in this repo. GAIA's /update-deps covers npm and pnpm, and running both opens duplicate dependency PRs.

To remove the overlap: disable Renovate's npm and pnpm package management. /setup-gaia will NOT change the Renovate configuration.
```

Then set the posture through the CLI, which owns the GitHub calls:

```bash
.gaia/cli/gaia setup configure-dependabot-alerts --owner <owner> --repo <repo> --json
```

On success, print `Dependabot alerts are on and automated security fixes are off for <owner>/<repo>.` When `changed` is non-empty, also print each change; the change is reported, not asked about. On failure, print `Could not set the Dependabot posture on <owner>/<repo> (failed at <step>). Finish with repo-admin access:` followed by each `manual_commands` entry, and note that an organization-enforced security configuration can refuse the change, in which case an organization admin must change it. Do not halt setup on a failure.

GAIA writes no `.github/dependabot.yml` and enables no setting that makes Dependabot open pull requests. `/update-deps` resolves security advisories through the local quality gate, with Dependabot alerts as its data source. Turning automated security fixes off is repository-wide, so it also stops Dependabot security pull requests for any other ecosystem your own `dependabot.yml` covers.

All Phase-3 GitHub mutations (create, protection, required-check registration, the Dependabot alerts-on and security-fixes-off posture, delete-branch) are net-new, admin-gated, security-sensitive calls. A non-admin runner degrades gracefully: skip the mutation, print the admin-note in `setup-gaia.md`'s `### Recommended defaults (admin-gated)`, and continue to Phase 3.5.
