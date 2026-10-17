# GitHub repository connection and remaining defaults

`/setup-gaia` Phase 3 reads this file, whole, when the repo does not exist yet or its default branch is not pushed. Run `## Connect the repository` first; Options 1 and 2 return to `### Recommended defaults` in `setup-gaia.md`, and Option 3, the authentication refusal, and the clean-tree refusal skip the rest of Phase 3 and continue at Phase 3.5 in `setup-gaia.md`. After the registration there, `## Remaining defaults` runs. `setup-gaia.md` Phase 3.5 also reads this file to run `## Owed and recorded settings`, when a GitHub setting has no recorded decision.

Every project-scope record line below is gated on `MAY_RECORD_PROJECT` (`setup-decisions.md`), and the owed and declined checks are the lines that file defines. In each block, declare `OWNER`, `REPO`, `DEFAULT_BRANCH` and `MAY_RECORD_PROJECT` with the cached values.

Contents: Connect the repository; Push protection; Remaining defaults; Owed and recorded settings.

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

**Clean-tree check.** `gh repo create --push` pushes commits only, so uncommitted changes never reach the new repository, and every branch or worktree cut later starts without them. Before asking anything else, read the working tree:

```bash
git status --porcelain
```

If it prints anything, do NOT create the repository. Print the paths it listed, then:

```
These changes are not committed, and creating the repo pushes only what is committed. Review them with `git status`, commit them on your default branch from your terminal, then re-run /setup-gaia and pick "Create the repo on GitHub".
```

Exit the repo phase without mutating GitHub, the same way as the authentication refusal above.

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

**Secret-scanning push-protection (best-effort).** Immediately after create, run `## Push protection` below, so it guards every later push and is in place before any public/internal flip.

After creation, cache `owner`/`repo` from the new remote. The repo exists with its default branch pushed, so record it, then return to `### Recommended defaults` in `setup-gaia.md`:

```bash
[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record github-repository applied
```

### Option 2: Adopt an existing repo

The user already has a github `origin` (cached in Phase 1). Skip creation. Once its default branch is pushed, record it as Option 1 does (`[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record github-repository applied`), then return to `### Recommended defaults` in `setup-gaia.md`.

### Option 3: Set one up manually

Print:

```
Create a repo on your provider, then:
  git remote add origin <url>
  git push -u origin <default-branch>
When it's pushed, re-run /setup-gaia to apply the recommended defaults (branch protection and the GAIA-Audit required check need repo admin).
```

Exit the repo phase without mutating GitHub: skip the rest of Phase 3 and continue at Phase 3.5 in `setup-gaia.md`. This option records nothing.

## Push protection

Secret-scanning push protection, read first and enabled only when it is off:

```bash
read_push_protection() {
  gh api "repos/$OWNER/$REPO" --jq '.security_and_analysis.secret_scanning_push_protection.status // "absent"' 2>/dev/null
}
PUSH_STATUS="$(read_push_protection)"
PATCH_ERROR=""
if [ "$PUSH_STATUS" != enabled ]; then
  PATCH_ERROR="$(printf '%s' '{"security_and_analysis": {"secret_scanning_push_protection": {"status": "enabled"}}}' \
    | gh api -X PATCH "repos/$OWNER/$REPO" --input - 2>&1 >/dev/null)"
  PUSH_STATUS="$(read_push_protection)"
fi
if [ "$PUSH_STATUS" = enabled ]; then
  echo "Secret-scanning push protection is enabled."
  [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record push-protection applied
elif [ "$PUSH_STATUS" = absent ] || printf '%s' "$PATCH_ERROR" | grep -qiE 'secret scanning|advanced security'; then
  echo "Push protection could not be enabled: GitHub does not offer it for this repository."
  [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record push-protection not-applicable
else
  echo "Could not enable push protection on $OWNER/$REPO: ${PATCH_ERROR:-status ${PUSH_STATUS:-unreadable}}"
fi
```

When GitHub does not offer it for this repository (e.g. a private repo without GitHub Advanced Security), the one-line note says so and the id records `not-applicable`. Any other failure records nothing, so the next run retries. Never halt here.

## Remaining defaults

When this section runs from `## Owed and recorded settings`, run only the items whose id is owed.

**delete_branch_on_merge.** Read the current setting:

```bash
DELETE_BRANCH="$(gh api "repos/$OWNER/$REPO" --jq .delete_branch_on_merge)"
if [ "$DELETE_BRANCH" = true ]; then
  echo "delete_branch_on_merge is already enabled."
  [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record delete-branch-on-merge applied
else
  printf 'delete_branch_on_merge=%s\n' "$DELETE_BRANCH"
fi
```

If `false`, run the declined check for `delete-branch-on-merge` first: when it passes, the question was declined before, so skip it silently. Otherwise AskUserQuestion:

> GitHub is set to NOT delete branches when PRs merge, so every merged branch stays on the remote until someone deletes it by hand. GAIA runs no branch cleanup of its own. Enabling `delete_branch_on_merge` has GitHub delete each pull request's branch as it merges.
>
> - **Enable delete_branch_on_merge** (Recommended)
> - **Skip** (merged branches stay on the remote)

On Enable:

```bash
.gaia/cli/gaia setup enable-delete-branch --owner "$OWNER" --repo "$REPO" \
  && { [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record delete-branch-on-merge applied; }
```

On Skip, change nothing on GitHub and record the decision: `[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record delete-branch-on-merge declined`.

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

On success, print `Dependabot alerts are on and automated security fixes are off for <owner>/<repo>.` and record it: `[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record dependabot-posture applied`. When `changed` is non-empty, also print each change; the change is reported, not asked about. On failure, record nothing, print `Could not set the Dependabot posture on <owner>/<repo> (failed at <step>). Finish with repo-admin access:` followed by each `manual_commands` entry, and note that an organization-enforced security configuration can refuse the change, in which case an organization admin must change it. Do not halt setup on a failure.

GAIA writes no `.github/dependabot.yml` and enables no setting that makes Dependabot open pull requests. `/update-deps` resolves security advisories through the local quality gate, with Dependabot alerts as its data source. Turning automated security fixes off is repository-wide, so it also stops Dependabot security pull requests for any other ecosystem your own `dependabot.yml` covers.

All Phase-3 GitHub mutations (create, protection, required-check registration, the Dependabot alerts-on and security-fixes-off posture, delete-branch) are net-new, admin-gated, security-sensitive calls. A non-admin runner degrades gracefully: skip the mutation, print the admin-note in `setup-gaia.md`'s `### Recommended defaults (admin-gated)`, and continue to Phase 3.5.

## Owed and recorded settings

`setup-gaia.md` Phase 3.5 runs this section when `MAY_RECORD_PROJECT` is not `none` and a GitHub id is owed. Each block decides only owed ids, so a decided one is never re-recorded.

**An origin not on github.com** (`MAY_RECORD_PROJECT` is `not-applicable-only`): none of the GitHub settings can apply, so each owed one records `not-applicable`:

```bash
owed() { .gaia/cli/gaia setup drift --json | jq -e --arg id "$1" 'any(.undecided[]?; .id == $id)' >/dev/null; }
if [ "$MAY_RECORD_PROJECT" = not-applicable-only ]; then
  owed github-repository && .gaia/cli/gaia setup record github-repository not-applicable
  owed push-protection && .gaia/cli/gaia setup record push-protection not-applicable
  owed branch-protection && .gaia/cli/gaia setup record branch-protection not-applicable
  owed gaia-audit-check && .gaia/cli/gaia setup record gaia-audit-check not-applicable
  owed delete-branch-on-merge && .gaia/cli/gaia setup record delete-branch-on-merge not-applicable
  owed dependabot-posture && .gaia/cli/gaia setup record dependabot-posture not-applicable
  owed squash-only && .gaia/cli/gaia setup record squash-only not-applicable
  owed label-sync && .gaia/cli/gaia setup record label-sync not-applicable
fi
true
```

**A github.com repo and an admin** (`MAY_RECORD_PROJECT` is `admin`): probe each owed setting this section owns and record what it shows:

```bash
owed() { .gaia/cli/gaia setup drift --json | jq -e --arg id "$1" 'any(.undecided[]?; .id == $id)' >/dev/null; }
if [ "$MAY_RECORD_PROJECT" = admin ] && [ "$HOST" = github.com ]; then
  branch_path="repos/$OWNER/$REPO/branches/$DEFAULT_BRANCH"
  if owed github-repository && gh api "$branch_path" --jq .name >/dev/null 2>&1; then
    .gaia/cli/gaia setup record github-repository applied
  fi
  if owed branch-protection && gh api "$branch_path/protection" >/dev/null 2>&1; then
    .gaia/cli/gaia setup record branch-protection applied
  fi
  if owed gaia-audit-check && gh api "$branch_path/protection/required_status_checks" --jq '.contexts' 2>/dev/null \
    | jq -e 'any(.[]; . == "GAIA-Audit") and all(.[]; . != "code-review-audit")' >/dev/null 2>&1; then
    .gaia/cli/gaia setup record gaia-audit-check applied
  fi
fi
true
```

A probe that finds branch protection or the `GAIA-Audit` registration missing records nothing: Phase 1 already sends an admin whose registration is owed down Phase 3's partial re-run path, which applies both, so a miss here means that path failed and the next run retries it.

Then, when `push-protection` is owed, run `## Push protection`; and run the owed items of `## Remaining defaults` (`delete-branch-on-merge`, `dependabot-posture`). `squash-only` is decided in Phase 3.7 and `label-sync` in Phase 4.5.
