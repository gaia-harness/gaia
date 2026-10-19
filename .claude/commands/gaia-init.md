---
name: gaia-init
description: Initializes a new project from the GAIA React template. Renames, strips GAIA branding, configures i18n, and installs Claude skills and plugins.
disable-model-invocation: true
---

Initialize a new project from the GAIA React template. The template already ships clean (no example code, no docs site, no auth). This command renames, strips GAIA-specific branding, configures i18n, installs Claude skills/plugins, and hands you a ready-to-build project.

**Language meta-instruction:** Conduct this entire conversation in the language the user has been typing in. Detect it from prior context, no explicit detection step needed. Do not translate source files, rules, skills, or wiki entries, those stay English regardless. Only translate the prompts you show the user.

Contents: Interactive gates: run mode and non-response policy; Step 0: Ensure pnpm is available; Step 1: Install dependencies; Step 2: Gather user input; Step 3: Run the init CLI; Step 4: Locale-specific scaffolding; Step 5: Create CODEOWNERS; Step 6: Check `.env`; Step 7: Verify the build; Step 8: Claude configuration; Step 9: Project settings; Step 10: Refresh the wiki; Step 11: Finalize; On failure: resume.

This command reads these references, all under `.claude/skills/gaia/references/setup/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:
- `per-machine.md`: Step 8, the per-machine tool, plugin, statusline and `.env` steps with their probes.

## Interactive gates: run mode and non-response policy

`/gaia-init` asks the user a series of questions ("gates"). This section governs how **every** gate behaves and overrides any harness default. Read it before the first gate and apply it to each one.

### Harness timeout note, override

After a gate sits unanswered for a while, the harness injects a stock note like "the user may be away from keyboard, proceed using your best judgment, you can re-ask later." That note is generic, it does not describe this command, and it keeps firing on gate after gate. **Do not act on it literally.** Inside `/gaia-init` it means only "apply the non-response policy below", never "the user is gone, auto-answer everything."

### No cascade

Evaluate each gate independently. A non-response on one gate is **never** evidence the user is away for any other gate. A timeout on the language question tells you nothing about the title, the CODEOWNERS handle, or the backend casing question. Re-ask the next gate normally.

### Tone

State plainly what you are doing and make no claim about why the user paused or whether they are present: non-response is not absence, and they may be reading, thinking, or opening a docs link.

### Run mode, the first gate

Before Step 0's pnpm check, ask this as the **very first** AskUserQuestion (in the user's language):

> How do you want to handle the setup questions?
>
> - **Interactive** (Recommended). GAIA asks its setup questions and waits for your answer on the consequential ones.
> - **Automatic.** GAIA selects the recommended default for every question for you, without stopping to ask. It shows you the full list of chosen defaults first, and you can change anything afterward.

List **Interactive** first (the recommended option) and **Automatic** second. This gate is itself HARD-BLOCK: on non-response, re-ask, never assume a mode.

- **Interactive**: apply the per-tier non-response rules below to every later gate.
- **Automatic**: the user has pre-consented to defaults. First show the Automatic defaults table (see "Automatic defaults, per gate" below), then apply each gate's recommended default and continue without asking. One exception, free-text identity values are still never fabricated: CODEOWNERS gets the loud placeholder, never a guess.

### Gate tiers

Every gate is one of two tiers. The tier is fixed here, do not reclassify by judgment.

**HARD-BLOCK** (consequential / irreversible / identity). On non-response in interactive mode: re-ask and wait for an explicit answer. Never apply a default and move on, never guess.

| Gate                                                                 | Where         |
| -------------------------------------------------------------------- | ------------- |
| Run mode (this section)                                              | before Step 0 |
| pnpm upgrade consent                                                 | Step 0c       |
| Primary app language (+ "Other" free-text)                           | Step 2, Q1    |
| Additional languages / i18n teardown, `STRIP_I18N` (+ free-text)     | Step 2, Q2    |
| CODEOWNERS GitHub handle (HARD-BLOCK only when `gh` can't detect it) | Step 2, Q3    |
| Project title                                                        | Step 2, Q4    |
| kebab-case slug (derived from the title, never asked on its own)     | Step 2, Q5    |

**SAFE-DEFAULT** (reversible, the recommended default is the safe outcome). On non-response in interactive mode: re-ask once; if still no answer, apply the stated default, name it plainly ("Defaulting backend casing to camelCase, you can change it later"), and continue. Do not claim the user is absent.

| Gate           | Default on non-response | Where  |
| -------------- | ----------------------- | ------ |
| Backend casing | `camelCase`             | Step 2 |
| TanStack Query | `No`                    | Step 2 |

### Free-text identity values are never fabricated

The CODEOWNERS GitHub handle, and any similar free-text identity field, must come from the user. A guessed handle is a silent correctness bug: a wrong owner ships in `.github/CODEOWNERS`. Never write a plausible-looking guess.

**Detecting the handle is not fabricating it.** The GitHub CLI, when installed and authenticated, reports the user's _own_ authenticated login. That is the user's real identity, not a guess, so using it never violates this rule. There is one authoritative detection method, used everywhere `/gaia-init` needs the handle:

```bash
handle=""
if command -v gh >/dev/null 2>&1; then
  handle="$(gh api user --jq .login 2>/dev/null)"
fi
# $handle is the authenticated login, or empty on any failure
```

`gh api user` is the most reliable method: a single call both verifies auth and returns the login. Treat detection as **failed** if `gh` is absent, unauthenticated, or the call returns empty. Do **not** fall back to `git config user.name` (a display name, not a handle) or remote-URL parsing (there is no remote at init time). What stays never-fabricated is any handle that is neither user-typed nor gh-detected: never invent a plausible-looking one.

- Interactive: offer the gh-detected handle as the recommended default; the user can override it. HARD-BLOCK applies only when detection failed (no default to fall back to): re-ask, do not reach Step 5 without a real handle.
- Automatic: use the gh-detected handle when available. Only when detection also fails, write a loud placeholder that fails visibly, never a guess. Use `REPLACE-WITH-YOUR-GITHUB-HANDLE`, GitHub flags it as an unknown owner so the gap is obvious, and surface it in the Step 11 summary as a required follow-up.

### Automatic defaults, per gate

When the user chose Automatic, first detect the project folder name (`basename "$(git rev-parse --show-toplevel)"`), run the GitHub-handle detection from "Free-text identity values are never fabricated" above, and use the already-detected primary language, then show the user this table (substitute the bracketed values, leave everything else verbatim) so they can catch anything before init proceeds:

> **Automatic mode. Applying these defaults:**
>
> | Setting                   | Value                                                                                   | Reversible?                                                |
> | ------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
> | Primary language          | {detected language, e.g. English (en)}                                                  | Costly, re-run i18n                                        |
> | Additional languages      | None, i18n scaffolding kept                                                             | Yes, fully                                                 |
> | Project title             | {title-cased folder name}                                                               | Yes, re-run rename                                         |
> | Slug                      | {folder name}                                                                           | Yes, re-run rename                                         |
> | CODEOWNERS handle         | {gh-detected handle when available, else `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder} | Placeholder: one-line edit required. Detected handle: none |
> | Backend casing            | camelCase                                                                               | Yes, rerun `gaia init configure-data-layer --casing`       |
> | TanStack Query            | No                                                                                      | Yes, rerun `gaia init configure-data-layer --query true`   |
> | Sandbox recommendation    | Not recommended (GAIA's default, never asked)                                           | Yes, `/setup-gaia --reconfigure`                           |
> | Team git isolation policy | Always use worktrees (GAIA's default, never asked)                                      | Yes, `/setup-gaia --reconfigure`                           |

Exactly one row per setting. The CODEOWNERS row shows the gh-detected handle, otherwise the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder, and nothing else.

Then apply the defaults and proceed without stopping (the user chose Automatic; do not block, they can interrupt if they want to change something):

- pnpm upgrade (0c): upgrade (Yes), it is required to continue.
- Primary language (Q1): the detected user language.
- Additional languages / i18n (Q2): primary-only, keep i18n scaffolding (`STRIP_I18N=false`). The teardown is never auto-selected.
- CODEOWNERS (Q3): the gh-detected handle when available; otherwise the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder, flagged as a required Step 11 follow-up.
- Project title (Q4): title-cased folder name.
- kebab slug (Q5): folder name.
- Backend casing (Step 2): `camelCase` (`CASING=camel`).
- TanStack Query (Step 2): `No` (`QUERY=false`).

Step 9's two team defaults are the same in both modes, so they need no Automatic default of their own.

## Step 0: Ensure pnpm is available (and new enough)

**First, ask the run-mode gate** ("Interactive gates: run mode and non-response policy" above) and hold the answer for every later gate. Then continue with the pnpm check.

GAIA needs pnpm 12+. Tell the user: "Checking for pnpm…" then read the currently-resolved version **from the project root** (so corepack's `packageManager` pin applies when it's active):

```bash
pnpm --version 2>/dev/null || echo "absent"
```

Branch on the result:

**a) `absent` (no pnpm on PATH):** auto-install. Prefer corepack (it activates the version pinned in `package.json` `packageManager`); fall back to the latest global when corepack is missing.

```bash
if command -v corepack &>/dev/null; then
  corepack enable pnpm
else
  npm install -g pnpm@latest
fi
```

If this fails, stop and report the error. Then proceed to Step 1.

**b) Major version ≥ 12:** good, proceed to Step 1.

**c) Major version < 12 (a stale pnpm, e.g. 11.x):** do **not** silently proceed. Use the **AskUserQuestion** tool to get consent before touching the user's toolchain, with exactly these two options:

_Non-response: HARD-BLOCK. Re-ask; never auto-upgrade or auto-exit on a timeout. Automatic mode: upgrade (Yes)._

- **Yes (Recommended)**: "Upgrade pnpm to a supported version (12+). Required to continue with /gaia-init."
- **No**: "Keep the current pnpm and stop /gaia-init. Nothing has been installed or renamed yet, so it's safe to exit and re-run later."

On **No** (or anything that is not an explicit Yes): stop `/gaia-init` immediately with a one-line message. Step 0 runs before any file is installed or renamed, so exiting here leaves the clone untouched.

On **Yes**: upgrade by enabling corepack (its `packageManager` pin sets the in-project version regardless of any stray global pnpm); fall back to a latest global install when corepack is missing.

```bash
if command -v corepack &>/dev/null; then
  corepack enable pnpm
else
  npm install -g pnpm@latest
fi
```

Then **re-verify from the project root** with `pnpm --version`.

If the major version is still < 12, a non-corepack pnpm (Homebrew, the standalone installer) is shadowing the upgrade earlier on `PATH`. Show which binary wins with `command -v pnpm` (e.g. `/opt/homebrew/bin/pnpm`, the shadowing install) and halt so the user can resolve it. Halt with: "pnpm <version> at <path> is older than the required 12+ and takes precedence on your PATH. Upgrade or remove it (e.g. `brew upgrade pnpm`, `pnpm self-update`) so corepack's pinned version wins, then re-run /gaia-init."

## Step 1: Install dependencies

The project was just created from the template, `node_modules/` does not exist yet. Install before doing anything else so later steps (typecheck, tests, build) can run.

Tell the user: "Installing dependencies, this may take a minute…" then run:

```bash
pnpm install --config.confirm-modules-purge=false
```

`--config.confirm-modules-purge=false` keeps the install non-interactive. `/gaia-init` runs with no TTY, so if the clone carries a stale or mismatched `node_modules/`, a bare `pnpm install` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` waiting for a purge confirmation it can never receive. The flag suppresses only that prompt and leaves lockfile resolution untouched, so the immediately-following `/update-deps` step can still mutate dependencies. (Do not use `CI=true`: it forces `--frozen-lockfile`, which refuses any lockfile change.)

If install fails, stop and report the error.

Then run `/update-deps` to bring all packages to their latest compatible versions before continuing. Tell it that `/gaia-init` invoked it: that run resolves every security advisory it can, asks no acceptance question (an advisory it cannot resolve is reported still open), reverts a failing resolution on its own, and cuts no branch and commits nothing, since no remote exists yet to push to; Step 11's init commit carries its changes. If `/update-deps` reports anything as **skipped** with a reason, surface it so the user can investigate, but proceed. Note `/update-deps` runs its own quality gate at the end, if it halts on a quality-gate failure or peer-dep error, stop here and surface the report to the user; do not silently continue.

After `/update-deps` returns, and before Step 2, refresh the statusline's update-check cache. The init-invoked run cuts no branch, so it never reaches the refresh `/update-deps` runs at branch creation, and the cache would otherwise keep showing the bumps just applied as outdated until its TTL expires:

```bash
bash .gaia/scripts/update-check-bust.sh --cache "$(git rev-parse --show-toplevel)/.gaia/local/cache/shared/update-check.json" --mode deps
```

The refresh is cosmetic: report a non-zero exit and continue.

## Step 2: Gather user input (in the user's language)

This whole conversation has been in the user's language so far. Continue in that language for every prompt below.

Before asking any questions, detect the project folder name:

```bash
basename "$(git rev-parse --show-toplevel)"
```

Use this as the slug default. Derive the title default by replacing hyphens and underscores with spaces and applying title case (e.g. `my-cool-app` → `My Cool App`).

Ask the two language questions one at a time (Q2 interpolates Q1's answer), then batch the two asked project-identity questions (the slug is derived), then ask the two data-layer questions one at a time.

### Q1, Primary app language (asked alone)

_Non-response: HARD-BLOCK. Re-ask; never auto-pick. Automatic mode: the detected user language._

Use AskUserQuestion with this single question:

> What should be the primary language for this app's UI?
>
> - {detected user language} (Recommended): what you've been typing in.
> - {second language}

`{second language}` is always a real language different from the first option, never a repeat of it:

- Detected language is not English: English.
- Detected language is English: the system locale's language when it is not English, else Spanish. Read the locale with the command below; an empty value, `C`, `POSIX`, or an English code (`en`) counts as English.

```bash
locale_code="${LC_ALL:-${LC_MESSAGES:-$LANG}}"
[ -z "$locale_code" ] && command -v defaults >/dev/null 2>&1 && locale_code="$(defaults read -g AppleLocale 2>/dev/null)"
printf '%s\n' "${locale_code%%[_.@-]*}"
```

Resolve the printed code to its English language name (e.g. `de` → German).

Do not add an "Other" option: the tool adds its own, and a hand-added one is an inert button with no input field. A language not listed arrives as typed text through the tool's own Other answer, however the user likes to write it, a name or a code, in English or its own script (e.g. `Polish`, `pl`, or `polski`).

Interpret a typed reply yourself: resolve it to an ISO 639-1 code plus English name. Only ask again if it's genuinely ambiguous or you can't identify the language.

Then confirm a typed reply with an AskUserQuestion so the user can catch a misread before anything runs, e.g. `Primary language: French (fr). Look right?`, options `Looks right (Recommended)` and `Change it`. A correction typed through Other, or `Change it`, resolves the language again and re-confirms.

Hold the resolved choice as `{primary}` (ISO code + English name); the next batch interpolates it into its labels, which is why Q1 is asked first and alone.

### Q2, Additional languages + i18n scaffolding (asked alone)

_Non-response: HARD-BLOCK. Re-ask; the i18n teardown (`STRIP_I18N=true`) is never auto-selected. Automatic mode: primary-only, keep scaffolding (`STRIP_I18N=false`)._

The primary is now known, so its name can appear in the labels below. Ask this as its own AskUserQuestion. It folds the old standalone "localize later?" decision into the no-additional-languages branch, so that decision never needs its own round-trip:

> Primary language is {primary}. Any additional languages?
>
> - {primary} only, keep i18n scaffolding (Recommended): no additional languages; scaffolding stays wired so you can localize later with no rework.
> - Add more languages now: add locales on top of {primary} during init. You can also ask Claude to add languages later if you'd rather skip this for now.
> - {primary} only, remove i18n entirely: no additional languages, remove i18n. Smaller bundle, less infra, but a long teardown now, and hard to reverse (you'd rebuild scaffolding and re-wrap every string by hand). Only do this if you're confident the app will remain single-language.

Mark "{primary} only, keep i18n scaffolding" as the recommended/default option.

If the user picks "Add more languages now", ask for the languages as a plain chat message, not AskUserQuestion (its preset options cannot capture free text, and a hand-added "Other" option is an inert button), and wait for the user to type their reply in the prompt.

> Which languages? List them however you like, names or codes, in English or their own script, separated by commas (e.g. `fr, german, 日本語`).

Interpret the reply yourself: resolve each entry to an ISO 639-1 code, dedupe, and drop any that match {primary}. Only ask again about an entry you genuinely can't identify, don't make the user learn code syntax.

Then confirm the resolved list with an AskUserQuestion so the user can catch a misread before anything runs, e.g. `Adding: German (de), Japanese (ja), Spanish (es). Look right?`, options `Looks right (Recommended)` and `Change it`. Corrections typed through Other, or `Change it`, resolve the list again and re-confirm before moving to Step 3.

Resolve two values from the answer:

- `LOCALES = unique({primary} code, any additional codes entered above)`. Either {primary}-only option leaves `LOCALES` as just `[{primary}]`.
- `STRIP_I18N = true` only when the user chose "{primary} only, remove i18n entirely"; otherwise `false`. Adding languages or keeping the scaffolding both leave it `false`.

### Q3–Q5, Project identity (one AskUserQuestion; the slug is derived)

_Non-response: title is HARD-BLOCK, re-ask, never guess. CODEOWNERS: offer the gh-detected handle as the recommended default; HARD-BLOCK only when detection failed (no default to fall back to), re-ask, never guess. The slug is never asked: it is derived from the chosen title. Automatic mode: title-cased folder name (title), folder name (slug), and the gh-detected handle (CODEOWNERS) when available, else the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder flagged as a required Step 11 follow-up._

Ask Q3 and Q4 in a single AskUserQuestion call. Each question carries exactly the two real options below, its default first and marked ` (Recommended)`; the tool's own Other takes a typed value. Never add an option that only points at Other (such as "Enter another" or "Type a value"): the tool adds its own, and a hand-added one is an inert button that returns no value.

**Q3, GitHub username for CODEOWNERS.** First run the GitHub-handle detection from "Free-text identity values are never fabricated" above (reuse the automatic-mode result if it already ran). If it yields a handle, ask with these options:

- `@{handle} (Recommended)`, description: `your authenticated GitHub login`. A gh-detected handle is the user's own identity, not a guess, so it is safe to default to.
- `Set it later`: writes the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder to `.github/CODEOWNERS` and flags it as a required Step 11 follow-up.

A different handle arrives through Other. Suggest `@username` format; store the bare handle. If detection fails there is no default, so this stays a free-text identity value that is **never fabricated**: leave Q3 out of the call and ask for the handle as a plain chat message (its answer is open-ended free text), and on interactive non-response HARD-BLOCK and re-ask rather than guessing; in automatic mode, use the loud placeholder so a wrong owner never ships.

**Q4, Project title.** Options:

- `{title-cased folder name} (Recommended)`, description: `slug {the slug it derives}`.
- `{folder name as-is}`, description: `slug {the slug it derives}`. When the folder name already equals its title-cased form (e.g. `Convene`), offer the folder name lowercased instead.

**Q5, kebab-case slug (derived, not asked).** Derive the slug from the chosen title: lowercase it, replace each run of characters other than `a-z` and `0-9` with one hyphen, and trim leading and trailing hyphens. When that leaves nothing (a title with no ASCII letters or digits, such as one in a non-Latin script), ask for the slug as a plain chat message, since its answer is free text, and re-ask until it is valid kebab-case. A title typed through Other re-derives the slug from it. A typed reply of the form `Title / slug` (e.g. `Convene / convene-app`) sets both: the part before ` / ` is the title and the part after is the slug, used as typed once it is valid kebab-case (re-ask if it is not).

### Q6, Backend casing (asked alone)

_Non-response: SAFE-DEFAULT. Re-ask once, then `camelCase` (`CASING=camel`). Automatic mode: `camelCase`._

Ask this as its own AskUserQuestion:

> How does your backend name JSON fields?
>
> - camelCase (Recommended): the backend sends camelCase, so keys pass through unchanged.
> - snake_case: the services layer converts between snake_case on the wire and camelCase in code.
> - Not sure: treated like camelCase, change it later.

Map the answer to `CASING`: `camelCase` is `camel`, `snake_case` is `snake`, `Not sure` is `camel`. Only `snake` changes a file.

### Q7, TanStack Query (asked alone)

_Non-response: SAFE-DEFAULT. Re-ask once, then `No` (`QUERY=false`). Automatic mode: `No`._

Ask this as its own AskUserQuestion:

> Add TanStack Query for client-owned data?
>
> - No (Recommended): route loaders own the data; nothing extra is installed.
> - Yes: pins TanStack Query and wires its provider and Storybook decorator. You can also add it later with `gaia init configure-data-layer --query true`.

Map the answer to `QUERY`: `No` is `false`, `Yes` is `true`.

## Step 3: Run the init CLI

The deterministic surface lives behind `gaia init`. Each subcommand is idempotent and records its own state in `.gaia/init-state.json`, so a failed step can be resumed via `gaia init resume`.

`STRIP_I18N` and `LOCALES` were resolved in Step 2: `STRIP_I18N` is `true` only when the user chose "remove i18n entirely", otherwise `false`.

Run sequentially, stopping at the first non-zero exit:

```bash
.gaia/cli/gaia init strip-branding --title "<Project Title>"
.gaia/cli/gaia init configure-i18n --locales "<comma-separated locale list>" --strip <STRIP_I18N>
.gaia/cli/gaia init configure-data-layer --casing <CASING> --query <QUERY>
.gaia/cli/gaia init rename --title "<Project Title>" --kebab "<kebab-slug>"
.gaia/cli/gaia init wire-statusline --mode project
```

`configure-data-layer` prints one JSON line on stdout, `{"changed": [...], "next": [...]}`. Run every command the `next` list names (with Query on that is `pnpm install`) before continuing.

If any of these exit non-zero, surface the structured error verbatim (the CLI prints a JSON line to stderr) and stop. The user can re-run the failing command manually after addressing the cause, then resume with `.gaia/cli/gaia init resume`, completed steps are skipped automatically.

## Step 4: Locale-specific scaffolding (when not stripping i18n)

If `STRIP_I18N == false`, also run the prose locale instructions for every non-`en` locale in `LOCALES`:

For each locale in `LOCALES` where the locale is NOT `en`:

1. Resolve the locale's English display name (e.g. `Polish`), native display name (e.g. `Polski`), and RTL flag (`true` for `ar`/`he`/`fa`/`ur`, otherwise `false`).
2. Read `frontend/.claude/instructions/add-locale.md`.
3. Substitute the four template variables: `{{LOCALE_CODE}}`, `{{LANGUAGE_NAME_EN}}`, `{{LANGUAGE_NAME_NATIVE}}`, `{{IS_RTL}}`.
4. Execute every step in the substituted instruction. Stop on any failure.

If `STRIP_I18N == true`, read `frontend/.claude/instructions/remove-i18n.md` and execute every step. Stop on any failure.

## Step 5: Create CODEOWNERS

The GAIA template does not ship a `.github/CODEOWNERS`, so create one: a single line naming the user's GitHub username as the repo-wide code owner.

```bash
printf '* @%s\n' "<github-username>" > .github/CODEOWNERS
```

`<github-username>` is the bare handle (no leading `@`); the `* @` prefix makes that user the default owner for every path.

`<github-username>` is the handle Q3 resolved: the user's typed handle, or the gh-detected login when the user accepted (or automatic mode used) that default. Any of these is a real handle, write `* @<handle>` and emit **no** Step 11 follow-up warning.

Only when Q3 obtained no real handle (the user picked `Set it later`, or automatic mode where gh detection also failed) is `<github-username>` the placeholder `REPLACE-WITH-YOUR-GITHUB-HANDLE`. Write it anyway, GitHub flags the unknown owner in its CODEOWNERS validation, so the gap is visible. Add a required follow-up to the Step 11 summary: "Edit `.github/CODEOWNERS`, it holds a placeholder owner, set your real GitHub handle."

## Step 6: Check `.env`

Run the CLI, it copies `frontend/.env.example` to `frontend/.env` when `frontend/.env` is absent, no-op otherwise. Routing through the CLI subprocess bypasses the project's `Edit(.env)` deny rule, which guards against Claude writing secrets, not against init seeding from the example file.

```bash
.gaia/cli/gaia init bootstrap-env
```

If this exits non-zero, surface the structured error verbatim and stop.

## Step 7: Verify the build

Run sequentially from the repository root, stopping at the first failure (the root scripts proxy to the `frontend` package):

```bash
pnpm typecheck && pnpm lint && pnpm test:ci && pnpm build
```

Fix any issues before moving on.

## Step 8: Claude configuration

Read `.claude/skills/gaia/references/setup/per-machine.md` now, the whole file, and run its steps in order.

On a halt, print the probe lines and stop with: "One or more components failed verification. Retry the failed install commands above, then resume with `.gaia/cli/gaia init resume`."

When every step is recorded, continue to Step 9. `/setup-gaia` runs the same reference, so a machine set up here owes it nothing per-machine.

## Step 9: Project settings

Write GAIA's two team-level defaults to `.gaia/project.json` and record them, with no question: the sandbox is not recommended, and the git isolation policy is left unset, which is GAIA's default, `always-worktree` (every `/gaia-plan`, `/gaia-debt` and ad-hoc task works in its own worktree). GAIA is built for concurrent multi-agent work, so worktrees are the default; the OS-level Bash sandbox breaks `gh`, git-over-https and `docker` until allowlisted, and GAIA's lifecycle runs on `gh`, so it is not recommended. The file is committed and team-shared, and `/update-gaia`'s merge never overwrites it. A repo admin changes either setting later with `/setup-gaia --reconfigure`.

Run, always, including on a resumed run:

```bash
.gaia/cli/gaia init write-project-config --sandbox-recommended false &&
  .gaia/cli/gaia setup record sandbox-recommendation declined &&
  .gaia/cli/gaia setup record isolation-policy applied
```

If it exits non-zero, surface the structured-error JSON verbatim and stop. The user can re-run the failing command manually after addressing the cause, then resume `/gaia-init` with `.gaia/cli/gaia init resume`.

The two records mean `/setup-gaia` owes neither decision.

End of Step 9.

## Step 10: Refresh the wiki

The template ships with a wiki shaped for the upstream GAIA project. Refresh the file that encodes "where we are right now" so the new project starts with a clean context.

Read `wiki/log.md` first, then replace the entire file with the following content (the GAIA development log is irrelevant to the new project). Substitute `<LANGUAGES>` with this run's configured locale codes, comma-separated (e.g. `en` or `en, es, de`); if i18n was stripped, write `single-language (i18n removed)`.

```md
---
type: meta
title: Log
status: active
created: <TODAY_ISO>
updated: <TODAY_ISO>
tags: [meta, log]
---

# Log

Append-only. New entries at the TOP.

## [<TODAY>] /gaia-init | project initialized

- Project name: <PROJECT_TITLE>
- Languages: <LANGUAGES>
- Removed: GAIA branding (FUNDING.yml, README, Storybook brand)
- Installed: React Doctor, Playwright CLI, Serena, typescript-lsp plugin
```

## Step 11: Finalize

Step 8 recorded each per-machine step through the shared reference, so stamp completion now. This clears "⚙️ /setup-gaia (Required)" from the statusline, which then shows a `⚙️ /setup-gaia` nudge until `/setup-gaia` records this machine's remaining choices (the sandbox, the statusline left side):

```bash
.gaia/cli/gaia setup finalize
```

If the CLI exits non-zero, it surfaces a structured error whose `code` field explains the cause (e.g. `not_a_git_repo`, `state_malformed`); surface that JSON line verbatim and stop. Do not retry or self-heal.

Then run the CLI's init finalize step, it deletes this command file and, once every init step is recorded complete, the `.gaia/init-state.json` resume cursor:

```bash
.gaia/cli/gaia init finalize
```

### Commit the init output

`/gaia-init` lands its own changes as one commit on the current branch, so `/setup-gaia`'s first push carries them: `gh repo create --push` pushes commits only, and every branch or worktree cut later starts from the last commit, never from uncommitted files. The `block-main-destructive-git.sh` PreToolUse hook denies `git commit` on `main` or `master`, so the same machine-local sentinel `/setup-gaia` uses (`.gaia/local/setup-in-progress`, gitignored) suspends it for this one commit.

**First, in its own call**, since the hook reads the sentinel before a command runs: `mkdir -p .gaia/local && touch .gaia/local/setup-in-progress`

**Then, in its own call.** The `rm` runs whether or not the commit succeeds, because a lingering sentinel keeps main-branch protection suspended on this machine:

```bash
git add -A && git commit -m "chore: initialize project with /gaia-init" && echo COMMITTED || echo COMMIT_FAILED
rm -f .gaia/local/setup-in-progress
```

On `COMMIT_FAILED`, surface the commit's error and prepend this required follow-up to the closing message below: "⚠ Required: the init changes are not committed. Review them with `git status`, then commit them before `/setup-gaia`, which pushes only what is committed." Do not retry with `--no-verify`.

### Send the adoption ping

Send a fire-and-forget adoption ping. This is its own Bash call, separate from the `init finalize` call above, and it never gates `/gaia-init`'s success or failure, run it even though `init finalize` just deleted this command file, the instructions are already loaded for the rest of this run:

```bash
.gaia/cli/gaia ping --event init --mode "$MODE" --i18n "$I18N_COUNT" || true
```

Derive the two values from state this run already holds, never from a state file:

- **`$MODE`** is the run-mode answer from the very first gate ("Interactive gates: run mode and non-response policy" above): `interactive` or `automatic`. Held for the whole run.
- **`$I18N_COUNT`** is `0` when `STRIP_I18N` is `true` (Step 2 Q2, i18n stripped); otherwise the number of locales in `LOCALES` (the count passed to `gaia init configure-i18n --locales`). Automatic mode keeps i18n with only the detected primary language, so `$I18N_COUNT` is `1` there.

Then output the message below verbatim. Output the `cd` line exactly as written, even though Claude is running inside the project folder: when the user exits Claude, their shell returns to the directory they launched from (the parent), not the project folder.

**If `.github/CODEOWNERS` holds the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder** (automatic mode where gh detection also failed, or any run where a real handle was never obtained), prepend this required follow-up to the message: "⚠ Required: `.github/CODEOWNERS` has a placeholder owner. Edit it to set your real GitHub handle before you push." A gh-detected or user-typed handle writes a real owner, so this warning does not appear.

> <Project Title> is ready for development. Exit Claude, then from your terminal:
>
> ```
> cd <project-folder-name>
> ```
>
> Then start Claude again, and run `/setup-gaia`. After your first push, `/setup-gaia` registers the `GAIA-Audit` required check.

## On failure: resume

If any `gaia init <step>` invocation exits non-zero, the structured-error JSON on stderr explains the cause. After fixing the cause, re-run with:

```bash
.gaia/cli/gaia init resume
```

Resume reads `.gaia/init-state.json`, skips already-complete steps, and replays remaining steps using the saved arguments. Use `--from-step <N>` to force restart from a specific step (1-indexed: 1=strip-branding, 2=configure-i18n, 3=configure-data-layer, 4=rename, 5=wire-statusline, 6=bootstrap-env, 7=write-project-config, 8=finalize).
