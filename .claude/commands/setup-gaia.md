---
name: setup-gaia
description: Runs the single post-init onboarding. Detects the situation and runs only the owed phases; safe to re-run. --reconfigure re-asks the sandbox, isolation-policy, squash-only-merge, and statusline decisions.
disable-model-invocation: true
---

Run this once after `/gaia-init`, and re-run it any time. `/setup-gaia` is the single onboarding command for a GAIA project. It detects the situation and runs only the phases this clone actually owes:

- **Per-machine work** every clone needs (tool installs, plugins, statusline bit, `.env`, the sandbox decision, and, for a developer with a global statusline, which statusline draws the left side).
- **GitHub repository provisioning** (create / adopt / manual, private by default), plus branch protection, the `GAIA-Audit` required-check registration, and squash-only merge settings when the runner is a repo admin.
- **Team settings** a repo admin records once in `.gaia/project.json`: the git isolation policy and the sandbox recommendation.

It is safe for **any developer** to run at any time. A phase is owed when its own gate says so, or when the shipped setup feature list (`.gaia/setup-features.json`) holds its feature with no recorded decision; each decision it makes is recorded. A plain (no-flag) re-run on a provisioned project whose decisions are all recorded prints the already-provisioned line and mutates nothing: it never re-provisions the repo or changes branch protection. The one exception is a repo admin re-running it on a repo whose required checks still lack `GAIA-Audit` (or still carry the stale `code-review-audit` context): that run owes the registration and makes it. Pass `--reconfigure` to re-ask the sandbox decision (Phase 2), the team git isolation policy (Phase 3.5), the squash-only-merge offer (Phase 3.7), and the statusline left-side choice (Phase 4.6).

The slash command name intentionally does NOT start with `gaia-` so it does not pollute the `/gaia` autocomplete namespace.

Contents: Pre-flight: Worktree check; Argument parse; Phase 0: Prerequisites; Phase 1: Detect situation; Phase 2: Per-machine setup; Phase 3: GitHub repository; Phase 3.5: Team settings; Phase 3.7: Squash-only merges; Phase 4.5: Label sync; Phase 4.6: Statusline left side; Phase 5: Owed setup features; Phase 5.5: Land setup decisions; Phase 6: Finalize; Idempotence / re-run safety; On failure: re-run.

This command reads these references, all under `.claude/skills/gaia/references/setup/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:
- `setup-decisions.md`: Phase 1, every run, for the owed check and who may record project decisions.
- `sandbox.md`: Phase 2, when the sandbox gate says the decision is owed, or to record a settled decision.
- `per-machine.md`: Phase 2, when `completed_at` is null or a per-machine id is owed.
- `github-repo.md`: Phase 3, when no repo exists yet or its default branch is not pushed; Phase 3.5, for owed GitHub settings.
- `isolation-question.md`: Phase 3.5, once both gates say the question is owed.
- `sandbox-recommendation.md`: Phase 3.5, when the team sandbox recommendation is owed.
- `squash-only.md`: Phase 3.7, once both gates say the question is owed.
- `statusline-left.md`: Phase 4.6, every invocation for the routing warning, and when a choice or record is owed.
- `standalone-features.md`: Phase 5, every run.
- `land-decisions.md`: Phase 5.5, to land project decisions, and Phase 6, for the setup ping.

## Pre-flight: Worktree check

This command does per-machine and per-clone provisioning, writes `.gaia/local/setup-state.json`, and provisions the GitHub repository. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/setup-gaia" || exit 1
```

If the detection does not fire, fall through to `## Argument parse` below.

## Argument parse

Parse `$ARGUMENTS` for the `--reconfigure` flag. Cache the boolean as `RECONFIGURE`. It re-opens four settled decisions and nothing else: the sandbox decision in Phase 2, the isolation policy in Phase 3.5, the squash-only-merge offer in Phase 3.7, and the statusline left-side choice in Phase 4.6.

## Phase 0: Prerequisites (every invocation, never skipped)

These run on every invocation and record no setup-state step. They sit outside the per-machine skip gate.

### 0a. Self-heal worktree symlinks

If this clone is being set up from a linked worktree (e.g. one created via `git worktree add` outside the Claude Code harness), the shared-state links that `.gaia/scripts/link-worktree.sh` creates (its header lists them) may not exist yet. Run the self-heal:

```bash
bash .gaia/scripts/link-worktree.sh
```

In a main checkout this is a no-op (prints `not a linked worktree`). In a linked worktree that lacks them it creates them; where a real file or directory already sits at one of those paths, it is backed up to `<path>.bak.<timestamp>` first, so nothing is clobbered.

The script always exits 0, so read its output: if it prints a `failed:` line (e.g. Windows symlink permission failure), HALT and surface that line verbatim. The user must fix the underlying issue (typically: enable Windows Developer Mode) and re-run `/setup-gaia`.

### 0b. Ensure pnpm + node_modules

Tell the user: "Checking pnpm + node_modules…"

If `corepack` is available, run `corepack enable pnpm`. Otherwise `npm install -g pnpm`. If `node_modules/` does not exist at the project root, run `pnpm install`. `pnpm install` is fast on a clean clone and fast-no-op when up to date.

### 0c. GitHub CLI prerequisites (advisory)

Advisory only: warnings surface but do not halt setup, because a contributor may legitimately set up GAIA without `gh` wired up yet.

```bash
if ! command -v gh &>/dev/null; then
  echo "Warning: GitHub CLI ('gh') is not installed. The PR merge gate, /gaia-plan, and forensics workflows depend on it. Install: https://cli.github.com/" >&2
elif ! gh auth status &>/dev/null; then
  echo "Warning: GitHub CLI is not authenticated. Run: gh auth login" >&2
elif [ -f .github/workflows/forensics-triage.yml ] && gh repo view &>/dev/null; then
  .gaia/cli/gaia labels sync
fi
```

Surface every warning and the sync report verbatim, then continue. `gaia labels sync` reconciles this repo's labels against the registry for whichever audience and feature set it resolves to. `gaia-forensics` is a maintainer-audience entry, so an adopter's sync never creates it; an adopter files forensics reports upstream, never locally, regardless of what this step finds.

## Phase 1: Detect situation

Classify the clone by reading state, gating on **file existence, not key presence**. Every input is optional; a missing file is a signal, not an error.

```bash
.gaia/cli/gaia setup status --json
```

From `.gaia/local/setup-state.json` (per-machine, gitignored), cache `completed_at` and `completed_steps`.

Then read the **repo / branch / push / required-check** state, not merely whether an `origin` remote exists:

```bash
.gaia/cli/gaia setup detect-remote --json
```

Cache `found`, `host`, `owner`, `repo`. When `found` and `host == "github.com"`, probe the live repo state (each degrades to "absent" on a non-zero exit):

```bash
gh api "repos/<owner>/<repo>" --jq '.default_branch' 2>/dev/null                                              # repo exists + its default branch
gh api "repos/<owner>/<repo>/branches/<default-branch>" --jq '.name' 2>/dev/null                              # default branch has been pushed
```

When the repo exists, run the admin probe once and cache `admin` and `auth_status` (Phase 3 reuses them):

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

When `admin` is `true` and `auth_status == "ok"`, read the default branch's required contexts:

```bash
gh api "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null  # GAIA-Audit registered?
```

The **registration is owed** when that probe fails (no protection rule, or a rule without required status checks), when its output lacks `GAIA-Audit`, or when it still lists `code-review-audit`. Nothing posts a `code-review-audit` context, so a repo that requires it holds every pull request until the context is dropped. For a non-admin runner the probe does not run: branch protection is not theirs to read or change, so nothing on GitHub is owed by them.

Then Read `.claude/skills/gaia/references/setup/setup-decisions.md` now, the whole file, and run its `## The owed check` and `## Who records project decisions`. Cache `OWED_AT_START`, `DEFAULT_BRANCH` and `MAY_RECORD_PROJECT`; every later phase uses them.

Classify into one of these, first match wins:

- **First adopter**: no GitHub repo yet (`detect-remote` reported `found: false`, or the repo probe came back absent).
- **Partial re-run**: the repo exists but its default branch is not pushed, or the runner is an admin and the registration is owed.
- **Fresh clone**: the repo exists with its default branch pushed, nothing on GitHub is owed by this runner, and `completed_at` is null (per-machine work still owed).
- **Provisioned**: the repo exists, its default branch is pushed, `GAIA-Audit` is a required context with no `code-review-audit` beside it (or the runner is a non-admin, for whom nothing on GitHub is owed), and `completed_at` is non-null.

Detect an **incomplete provisioning** (repo created, `origin` added, but the default-branch push or the `GAIA-Audit` registration did not complete) from the repo/branch/push/required-check probes above, and complete only the owed steps. Because `gh repo create` adds `origin` **before** the push, `origin`-presence alone would wedge a failed-push state; judge from actual push/registration state.

The classification only routes the phases below; each phase re-checks its own completion and no-ops when already done, so misclassification cannot corrupt state.

## Phase 2: Per-machine setup (skip if finalized and nothing is owed)

If `setup status --json` reports a non-null `completed_at` and no per-machine id is owed, this whole phase no-ops **except for the sandbox decision below** (a first adopter finished per-machine work inside `/gaia-init`, so the repo prompt in Phase 3 is their first real interaction, with no tool-install log lines before it, and the recorded per-machine steps are unchanged).

**Sandbox decision (runs even when `completed_at` is non-null).** This clause surfaces the OS-level Bash sandbox enablement decision whenever no per-machine resolution has been recorded. It runs even when `completed_at` is non-null because Phase 2 otherwise short-circuits once per-machine setup is complete and would skip the decision. So before falling through to Phase 3, always evaluate this:

```bash
RESOLVED="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r '.resolved // false')"
```

- `RESOLVED` is `true` and `RECONFIGURE` is NOT set: the decision stands; do NOT re-prompt and do NOT flip the settled value. When `sandbox` is owed (the owed check), run `sandbox.md`'s `## Record a settled decision` alone, with no question.
- The marker is absent, `RECONFIGURE` is NOT set, and the declined check passes for `sandbox`: the developer declined it before; skip silently.
- Otherwise (marker absent, or `--reconfigure`): run the decision body, which records the outcome.

This clause is gated on the `gaia sandbox status` marker, never on a `SETUP_STEPS` value: no `SETUP_STEPS` entry is added and `gaia setup mark-step` is never called for the sandbox decision. The marker governs the decision; the record only says it was made.

Except when skipping silently, Read `.claude/skills/gaia/references/setup/sandbox.md` now, the whole file, and run it (only its `## Record a settled decision` when the decision stands).

**Per-machine steps (when `completed_at` is null, or any of `install-tools`, `install-plugins`, `chmod-statusline`, `bootstrap-env` is owed).** Read `.claude/skills/gaia/references/setup/per-machine.md` now, the whole file, and run its steps. On a halt, the user fixes the cause and re-runs `/setup-gaia`; each step resumes from its recorded state.

## Phase 3: GitHub repository (skip if provisioning already complete)

Judge this phase from the **repo/branch/push/required-check state cached in Phase 1**, not merely `origin` presence. Three cases:

- **The repo exists, the default branch is pushed, and the registration is not owed** (Phase 1's **provisioned** or **fresh clone**): print `GitHub repository already provisioned.` and fall through to Phase 3.5 without touching GitHub.
- **The repo exists, the default branch is pushed, and the registration is owed** (an admin's **partial re-run**): print `GitHub repository already provisioned; registering the GAIA-Audit required check.` and skip the connect question. When the default branch has no protection rule yet (`gh api "repos/<owner>/<repo>/branches/<default-branch>/protection"` exits non-zero), run the **Default-branch protection** PUT below first; never re-PUT an existing rule, because the PUT replaces every setting on it. Then run **Register GAIA-Audit as the required check** below and fall through to Phase 3.5. The other recommended defaults already ran when the repo was provisioned, so this path skips them.
- **Otherwise** (no repo yet, or its default branch is not pushed), this is the **first user-facing interaction for a first adopter**. Read `.claude/skills/gaia/references/setup/github-repo.md` now, the whole file, and run its `## Connect the repository`.

### Recommended defaults (admin-gated)

Reached from Option 1 (after create) or Option 2 (adopt). Run the admin probe for the now-existing repo (Option 1's repo did not exist when Phase 1 ran, so its cached values cannot be reused here):

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

Cache `admin` and `auth_status`, then re-run `setup-decisions.md`'s `## Who records project decisions` with them (this repo may exist only now) and cache its new values. **If `admin` is not `true` (or `auth_status != "ok"`)**, none of the GitHub mutations below fire; print the admin-note and skip straight to Phase 3.5 (which runs its own admin probe and fails closed the same way):

```
GitHub provisioning needs repo-admin permission and an authenticated gh (yours: admin=<admin>, auth_status=<auth_status>). Skipping the admin-only steps (branch protection, the GAIA-Audit required-check registration, Dependabot alerts, delete-branch-on-merge, and squash-only merges). Per-machine setup still completes. Ask a repo admin to finish the GitHub side, or gain admin access and re-run /setup-gaia.
```

When `admin: true` and `auth_status == "ok"`:

**Default-branch protection.** No CLI verb creates a protection rule, so author the full `protection` PUT payload directly. Create protection **before** the `GAIA-Audit` registration below: a bare `required_status_checks` registration 404s when no protection rule exists. Correct order is create repo → push default branch → enable protection → register `GAIA-Audit`.

Probe for an existing rule first and PUT only when there is none. The PUT replaces every setting on a rule, so on an adopted repo that already protects its default branch it would silently drop the adopter's required reviews, other required checks, and push restrictions. An existing rule is kept as it is; the registration below then edits its required contexts alone:

```bash
protection_endpoint="repos/<owner>/<repo>/branches/<default-branch>/protection"
if gh api "$protection_endpoint" >/dev/null 2>&1; then
  echo "<default-branch> already has a protection rule; keeping it and registering GAIA-Audit only."
else
  gh api -X PUT "$protection_endpoint" --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": []},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
JSON
fi
```

When the PUT runs, `required_status_checks.contexts` starts empty; the registration below adds `GAIA-Audit` to it and keeps any sibling contexts.

`required_approving_review_count` is `0` and `enforce_admins` is `false` on purpose. GAIA's merge gate is the `GAIA-Audit` required status check (plus any sibling checks), not a human approval, so a review requirement would wedge a solo adopter: nobody can approve their own PR, and `enforce_admins: true` would block the admin override, leaving them unable to merge anything to the default branch. `enforce_admins: false` also lets the admin push the Phase 3.5 team-setting commit **directly onto the default branch**, past this protection: it records one decision in `.gaia/project.json`, so setup-gaia lands it straight rather than through a PR + audit (it suspends the local `block-main-destructive-git.sh` hook for the single commit+push via a `.gaia/local/setup-in-progress` sentinel, see Phase 3.5's **The commit**). Do not tighten these to require approvals or enforce admins without a merge path that a solo repo can actually satisfy.

#### Register GAIA-Audit as the required check

The merge gate is the `GAIA-Audit` commit status, which the local PR Merge Workflow posts when an audit clears; requiring it is what stops a pull request merged from the github.com button from skipping the audit. This registration runs for every admin, on every run where it is owed: `GAIA-Audit` is not a required context, or the stale `code-review-audit` context still is one. Nothing posts `code-review-audit`, so a repo that still requires it holds every pull request forever; the registration drops it.

**GET the current contexts, then PUT the full set back to the `/contexts` endpoint with `GAIA-Audit` added and `code-review-audit` removed.** That PUT REPLACES the list, so a static PUT would drop sibling contexts (e.g. `Tests`, `Chromatic`) and let unaudited code merge. Every other context is kept. When the GET shows nothing to change, no PUT is sent:

```bash
required_checks_endpoint="repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks"
# A failed GET sends no PUT: replacing contexts that could not be read would drop the siblings.
if ! current_contexts=$(gh api "$required_checks_endpoint" --jq '.contexts'); then
  echo "Could not read the required status checks on <default-branch>." >&2
elif printf '%s' "$current_contexts" | jq -e 'any(.[]; . == "GAIA-Audit") and all(.[]; . != "code-review-audit")' >/dev/null; then
  echo "GAIA-Audit is already the required check on <default-branch>."
else
  jq -n --argjson current "$current_contexts" \
    '{contexts: ($current | map(select(. != "code-review-audit" and . != "GAIA-Audit")) + ["GAIA-Audit"])}' \
    | gh api -X PUT "$required_checks_endpoint/contexts" --input -
fi
```

Substitute `<owner>`/`<repo>` (cached earlier) and `<default-branch>` (typically `main`). If the GET or the PUT fails (403 when not admin, 404 when the branch has no protection rule or the rule requires no status checks), surface the error verbatim and tell the user:

```
Could not register the GAIA-Audit required check (admin permission and a branch-protection rule with required status checks on the default branch are required). Run it yourself once you have admin access, listing every other required context you keep in the JSON body (leave out code-review-audit):
  printf '%s' '{"contexts":["GAIA-Audit"]}' | gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks/contexts" --input -
Until GAIA-Audit is registered, GitHub does not require the audit: a pull request merged from the github.com button skips it. While code-review-audit stays a required context, every pull request on <default-branch> stays blocked, because nothing posts it.
```

Do not halt on a registration failure; continue with the reference's `## Remaining defaults` (already read on this path), or, on the registration-only re-run path at the top of Phase 3, fall through to Phase 3.5.

#### Remaining defaults

Run `github-repo.md`'s `## Remaining defaults`.

## Phase 3.5: Team settings (always evaluated)

Every exit of Phase 3 arrives here (its three cases, the non-admin skip, the registration-failure fallthrough, and `github-repo.md`'s manual and authentication-refusal exits), so this phase runs whether Phase 3 created a repo, adopted one, or short-circuited.

### Owed GitHub settings

When `MAY_RECORD_PROJECT` is not `none` and the owed check passes for any of `github-repository`, `push-protection`, `branch-protection`, `gaia-audit-check`, `delete-branch-on-merge`, `dependabot-posture`, `squash-only` or `label-sync`, Read `.claude/skills/gaia/references/setup/github-repo.md` now, the whole file, and run its `## Owed and recorded settings`.

### The isolation policy

A **committed team setting**: whether `/gaia-plan` and `/gaia-debt` isolate their work in a feature branch or a git worktree by default. It carries its own commit, because a first adopter's policy belongs on the default branch at once.

### Gate 1: the key's own presence

```bash
HAS_POLICY="$(jq -r 'has("isolation_policy")' .gaia/project.json 2>/dev/null || echo false)"
```

- `HAS_POLICY` is `true` and `RECONFIGURE` is NOT set → the decision stands. **Skip silently**: do not
  re-prompt, do not flip the settled value.
- `HAS_POLICY` is `true`, `RECONFIGURE` is NOT set, and `isolation-policy` is owed → record it, no question:
  `[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record isolation-policy applied`.
- `HAS_POLICY` is `false`, OR `RECONFIGURE` is set → an answer is owed. Continue to Gate 2.

Answering the question below writes the key, so its presence alone is a sufficient "already asked" signal. No
separate marker file, no `SETUP_STEPS` entry, no `mark-step` call; `.gaia/project.json` is the source of
truth here, the same shape as the sandbox decision's `gaia sandbox status` marker above. A missing
`.gaia/project.json` reads as an absent key (the `|| echo false` tail covers jq's error on a missing file), and
the write below creates the file when it is absent.

### Gate 2: this clause's own `check-admin` probe (fail closed)

Gated behind Gate 1, so the `gh api` round-trip only costs anything on a repo that still owes an answer. Reuse
Phase 1's cached `detect-remote` values (`found`, `host`, `owner`, `repo`):

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

Fail closed, silently (skip the question, no error, no output), on any of:

- `detect-remote` reported `found: false` (no GitHub origin at all);
- `host != "github.com"`;
- `admin` is not `true`;
- `auth_status` is not `"ok"`.

A developer who is not a repo admin is never asked for the team policy and sees no error.

### The question

Tell the user (in their language, detected from earlier context): "Let's set your team's default git
isolation policy."

Read `.claude/skills/gaia/references/setup/isolation-question.md` now, the whole file, and ask its question.

On a choice, run **The write** below with the value `isolation-question.md`'s `## The answer` maps it to.

**Declining** ("Other", or dismissing the question) writes nothing and commits nothing. The key stays absent,
so the question re-fires on a later explicit `/setup-gaia` run, a bounded cost since this is a setup command,
not a per-task prompt.

### The write

```bash
.gaia/cli/gaia setup write-isolation-policy <always-worktree|prefer-worktree|prefer-branch>
```

If this exits non-zero, surface the structured-error JSON verbatim and skip **The commit** below. Do not
retry, do not hand-write the key. On success, record it:
`[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record isolation-policy applied`.

### The commit

This clause carries its own commit, including the main-branch hook standdown. Right after `gh repo create
--push`, HEAD is on the default branch; when that branch is `main` or `master`, the `block-main-destructive-git.sh`
PreToolUse hook denies `git commit` and `git push` there, so a machine-local sentinel in `.gaia/local/`
(gitignored, never reaching a teammate's clone) suspends it for this one commit+push. The hook does not recognize
a custom default-branch name, so on one the sentinel is inert but harmless.

**Separate Bash call, first** (the `block-main-destructive-git.sh` PreToolUse hook reads this sentinel before
the command runs, so bundling it into the same call as `git commit` would not yet exist when the hook checks):

```bash
mkdir -p .gaia/local
touch .gaia/local/setup-in-progress
```

**Then, in its own call:**

```bash
git add .gaia/project.json
git commit -m "chore(gaia): set the team git isolation policy to <value>"
git push origin <current-branch>
```

**Then, in its own call, unconditionally** (even if the commit or push failed, a lingering sentinel keeps
main-branch protection suspended on this machine):

```bash
rm -f .gaia/local/setup-in-progress
```

**Branch on the push result honestly.** A repository ruleset can reject even an admin's direct push (`GH006`).
If the push fails, say so in one line and tell the admin the value is committed locally and needs a push (or
a PR); do not report success on a failed push. The commit itself makes the policy real for this machine's next
run; the push is what makes it real for the team.

### The sandbox recommendation

Run only when `MAY_RECORD_PROJECT` is `admin`. `--reconfigure` does not re-open it, and Phase 5.5 lands what it writes.

```bash
TEAM_RECOMMENDATION="$(jq -r 'if has("sandbox_recommended") then .sandbox_recommended else "absent" end' .gaia/project.json 2>/dev/null || echo absent)"
echo "sandbox_recommended=$TEAM_RECOMMENDATION"
```

- `true` or `false` and `sandbox-recommendation` is owed: record it with no question, `.gaia/cli/gaia setup record sandbox-recommendation applied` for `true` or `.gaia/cli/gaia setup record sandbox-recommendation declined` for `false`.
- `absent` and the declined check passes: skip silently.
- `absent` otherwise: Read `.claude/skills/gaia/references/setup/sandbox-recommendation.md` now, the whole file, and ask its question. On an answer, write it with `.gaia/cli/gaia setup write-sandbox-recommendation <true|false>`, then record it as above. A dismissal writes and records nothing.

Fall through to Phase 3.7.

## Phase 3.7: Squash-only merges (owed, or `--reconfigure`)

GAIA lints pull request titles as Conventional Commits because a squash merge lands the title as the commit subject on the default branch. That holds only when squash is the one merge method and the squash commit takes the PR title. This is a **repository setting**: GitHub's merge settings are the setting itself, the decision is recorded in `.gaia/project.json` `setup_decisions`, and Phase 5.5 lands it.

### Gate 1: whether the question is owed

- `squash-only` is owed (the owed check), or `RECONFIGURE` is set → owed. Continue to Gate 2.
- Otherwise → **skip silently**. A decided `squash-only`, a Skip included, is never re-asked on a plain run, whatever the repo's current settings are; a Skip stays a Skip until someone passes `--reconfigure`.

### Gate 2: `check-admin` probe (fail closed)

When Phase 3's Recommended defaults ran this invocation, reuse the `admin` and `auth_status` it cached. Otherwise run the probe with Phase 1's cached `detect-remote` values:

```bash
.gaia/cli/gaia setup check-admin --owner <owner> --repo <repo> --json
```

Fail closed, silently (skip the question, no error, no output), on any of: `detect-remote` reported `found: false`; `host != "github.com"`; `admin` is not `true`; `auth_status` is not `"ok"`. Merge settings are a repository setting, so a non-admin is not its audience.

### The question

Read `.claude/skills/gaia/references/setup/squash-only.md` now, the whole file, and ask its question.

Fall through to Phase 4.5.

## Phase 4.5: Label sync (always evaluated)

This runs on every invocation, after Phase 3.7, whichever path Phases 3 through 3.7 took (repo created, adopted, set up manually, already provisioned, or degraded on a non-admin runner), because the feature and audience choices already on disk by then are what the label sync filters on: whether the forensics workflow is present, and whether this repo is adopter- or maintainer-audience.

Run with `LABEL_SYNC_OWED` (`true` when the owed check passes for `label-sync`) and `MAY_RECORD_PROJECT`:

```bash
SYNC_OUTPUT="$(.gaia/cli/gaia labels sync)"; SYNC_STATUS=$?
printf '%s\n' "$SYNC_OUTPUT"
if [ "$SYNC_STATUS" -eq 0 ] && ! printf '%s\n' "$SYNC_OUTPUT" | grep -qxF 'labels-sync: degraded, manual commands follow'; then
  echo LABELS_APPLIED
  [ "$LABEL_SYNC_OWED" != true ] || [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record label-sync applied
fi
```

Surface its report verbatim: labels created, labels renamed, and any color drift found. The plain sync prints its degraded marker on stdout, so the block reads stdout for it; `label-sync` records `applied` only for a clean sync. Color drift is never applied here, no `--adopt` flag; an operator's own recolor of a label always wins over the registry's suggested color.

This step is advisory, never halting. A token without label-write scope gets the manual `gh label create` / `gh label edit` commands the command itself prints, and setup continues either way; `gaia labels sync` already exits 0 in that case, so this step adds no failure path of its own. It is idempotent and safe to re-run on every plain `/setup-gaia` invocation: a repo already in sync reports zero creates and zero renames.

Fall through to Phase 4.6.

## Phase 4.6: Statusline left side (per-machine, always evaluated)

GAIA's statusline (`.gaia/statusline/gaia-statusline.sh`) always draws GAIA's nudges on the right. For the left side it runs the developer's global `statusLine.command` from `~/.claude/settings.json` when one exists, otherwise GAIA's own bar (project, branch, model and effort, and a context bar colored by the audit checkpoint line). This phase lets a developer with a global statusline choose between the two. It is per-machine state, not a team setting: the answer lives in `.gaia/local/settings.json` (gitignored, GAIA's writable per-machine opt-ins), and it runs even when `completed_at` is non-null, like the sandbox decision, so a clone set up before this phase existed still gets asked.

### The routing warning (every invocation)

Read `.claude/skills/gaia/references/setup/statusline-left.md` now, the whole file, and run its `## The routing warning`.

### Gate: a global statusline, and no recorded choice

```bash
GLOBAL_STATUSLINE="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
case "$GLOBAL_STATUSLINE" in *gaia-statusline.sh*) GLOBAL_STATUSLINE="" ;; esac
LEFT_CHOICE="$(jq -r 'if type == "object" and .version == 1 and (.statusline | type) == "object" then (.statusline.left // empty) else empty end' .gaia/local/settings.json 2>/dev/null)"
printf 'global=%s\nchoice=%s\n' "$GLOBAL_STATUSLINE" "$LEFT_CHOICE"
```

- `GLOBAL_STATUSLINE` is empty → there is nothing to choose between: GAIA's bar already draws the left side. **Skip silently and write nothing to `.gaia/local/settings.json`**; when `statusline-left` is owed, run `statusline-left.md`'s `## Record a settled choice` (it records `not-applicable`). A global statusline added later makes this phase owed again on the next run.
- `LEFT_CHOICE` is `gaia` or `user`, and `RECONFIGURE` is NOT set → the choice stands; when `statusline-left` is owed, run `## Record a settled choice`.
- `RECONFIGURE` is NOT set and the declined check passes for `statusline-left` → the developer declined before. **Skip silently.**
- Otherwise (no recorded choice, any other value, or `--reconfigure`) → ask through `statusline-left.md`'s question and write, which records the choice.

A missing `statusline.left` key means never asked. The file's presence alone is not the signal, because it holds other opt-ins too.

Fall through to Phase 5.

## Phase 5: Owed setup features (always evaluated)

Read `.claude/skills/gaia/references/setup/standalone-features.md` now, the whole file, and run it. Fall through to Phase 5.5.

## Phase 5.5: Land setup decisions (when project decisions may be recorded)

When `MAY_RECORD_PROJECT` is not `none`, Read `.claude/skills/gaia/references/setup/land-decisions.md` now, the whole file, and run its `## Land the decisions`. Otherwise skip: no project decision was recorded this run. Fall through to Phase 6.

## Phase 6: Finalize

Stamp per-machine setup-state as complete, then report. `setup finalize` refuses to finalize while any step is pending (it returns non-zero without stamping `completed_at`), and a first adopter reaches here with every step in `completed_steps` and `completed_at` stamped (their `/gaia-init` recorded each per-machine step through the shared reference and ran a plain `gaia setup finalize`), so the short-circuit below applies; this phase must both **short-circuit when already finalized** and **pass `--force` when any other run still has a step pending**.

First, defensively clear the setup sentinel, unconditionally and before the short-circuit below, so a Phase 3.5 commit that aborted between creating and removing it cannot leave main-branch protection suspended on this machine:

```bash
rm -f .gaia/local/setup-in-progress
```

Read `setup status --json`:

- If `completed_at` is non-null, setup-state is already finalized. Short-circuit, do NOT call finalize.
- Otherwise run:

  ```bash
  .gaia/cli/gaia setup finalize
  ```

  If it reports `setup_steps_pending`, re-run with `--force` rather than halting:

  ```bash
  .gaia/cli/gaia setup finalize --force
  ```

  Never leave `completed_at` unstamped because a step was skipped upstream.

**Adoption ping.** After finalize completes (or short-circuits above), compute **`$SETUP_TYPE`** from Phase 1's classification and `RECONFIGURE`:

- `RECONFIGURE` is set: `reconfigure`.
- Else Phase 1 classified this run as **first adopter**: `init`.
- Else Phase 1 classified this run as **fresh clone** or **partial re-run**: `clone`.
- Else Phase 1 classified this run as **provisioned**, with `RECONFIGURE` not set: `SETUP_TYPE` is empty. The `init|clone|reconfigure` enum has no value for a plain re-run, so the ping fires only when this run decided an owed setup feature.

Keep **`$REPO_CHOICE`**, the answer to Phase 3's connect-to-GitHub question. "Create the repo on GitHub" maps to `create`, "Adopt an existing repo" maps to `adopt`, "Set one up manually" maps to `manual`. Empty when Phase 3 asked nothing this run.

Then run `land-decisions.md`'s `## The setup ping` with `SETUP_TYPE`, `REPO_CHOICE` and `OWED_AT_START` (Read `.claude/skills/gaia/references/setup/land-decisions.md` now first when Phase 5.5 skipped it). It sends the ping, or skips it when nothing was newly decided.

Then output (in the user's language), with a blank line between the two lines:

```text
You're all set: your GAIA project is ready. Restart Claude Code to load your new plugins and skills.

New to GAIA? The docs walk you through your first feature: https://docs.gaiareact.com/
```

## Idempotence / re-run safety

A plain (no-flag) re-run on a provisioned project whose listed setup features are all decided prints the already-provisioned line and mutates nothing: default-branch protection JSON and `.gaia/project.json` are byte-identical before and after, and no mutating `gh` call fires. A run that records a decision for an id undecided at its start relaxes that promise for `setup_decisions` and the keys an owed question writes (`isolation_policy`, `sandbox_recommended`), and lands them through Phase 5.5. Never re-provision the repo or change branch protection on a plain re-run; the one branch-protection change a re-run makes is the owed `GAIA-Audit` registration (Phase 3) for an admin on a repo whose required contexts lack `GAIA-Audit` or still carry `code-review-audit`. Only `--reconfigure` re-opens the settled sandbox, isolation-policy, squash-only-merge, and statusline decisions, and their new answers overwrite the records.

## On failure: re-run

Every step and CLI primitive is idempotent and safe to re-run on partial state. After fixing any failure cause (auth missing, network error, malformed config), simply re-run `/setup-gaia`, each phase detects its own completion and resumes from the first owed step.
