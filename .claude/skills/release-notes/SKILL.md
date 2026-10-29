---
name: release-notes
description: Maintainer-only. Rewrites a version's GAIA CHANGELOG entries as plain-language public release notes for the marketing site (gaiaharness.com), writing a release-data `.ts` file under `../website/src/pages/changelog/releases/` plus an editorial-decisions report for human review. Use when the maintainer wants the public notes for a version ("write release notes", "what's new on the site for v1.5.0"), right after cutting a release, or to backfill a historical `## [x.y.z]` block. Not for editing `CHANGELOG.md` or cutting a release (`/gaia-release`).
---

# release-notes

Rewrite one version's CHANGELOG entries as adopter-facing release notes. The CHANGELOG is written for engineers (mechanics, file paths, flags, exact steps); the website is a marketing page. A visitor skims it to learn what GAIA now does for _their_ project, in plain language, and follows a docs link when they want the detail.

Contents: Pre-flight: Worktree check; Inputs; Output (a): the release data file; Output (b): the editorial-decisions report; The rewriting rules; Worked exemplars; Workflow; See.

It pairs with `/gaia-release` but runs independently: point it at the `[Unreleased]` block while cutting a release, or at any historical `## [x.y.z]` block to backfill the website.

**It never edits `CHANGELOG.md`; it only reads it.**

## Pre-flight: Worktree check

This skill writes into the sibling website checkout, so run this first; it refuses in a linked worktree and names the main checkout:

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/release-notes" || exit 1
```

## Inputs

Invocation carries a target version, e.g. `release-notes 1.4.0` (no leading `v`). Resolve which CHANGELOG block to rewrite, and where the date comes from, by that version:

- **Released / historical**: `CHANGELOG.md` contains `## [<version>] - <YYYY-MM-DD>`. Rewrite that block. Take `version` and `date` **verbatim from the header**. The release already happened on that date; the shell clock is irrelevant.
- **Live cut**: the version isn't released yet; its entries live under `## [Unreleased]`. Rewrite that block. `version` is the argument (the maintainer is cutting it now). `date` is **today from the shell clock** (`date +%F`).

If no version was supplied and an `[Unreleased]` block exists, ask the maintainer which version is being cut. The version label has to come from a human, not a guess.

### The date is never yours to invent

Whether historical or live, the date comes from the CHANGELOG header or the shell, **never** from your own notion of "today." Models routinely misdate by months; a wrong `date` silently ships a wrong timeline to every visitor.

## Output (a): the release data file

Write to `../website/src/pages/changelog/releases/<version>.ts` (version with no leading `v`; `mkdir -p` the directory if it's missing). The changelog page discovers every file in that directory through `import.meta.glob`, so there is no index or import list to update.

**The schema lives in `../website/src/pages/changelog/types.ts` (the `Release` type); read it as the source of truth for the fields.** For the serialization, mirror the newest `releases/*.ts` exactly, since export style and key order have drifted before. Omit any optional key with no content. Today's form, for illustration:

```ts
export default {
  added: ['...'],
  date: '2026-06-02',
  fixed: ['...'],
  headline: 'A short title or one plain sentence.',
  improved: ['...'],
  version: '1.4.0',
};
```

- `added` → "New" (capabilities that didn't exist before). `improved` → "Improved" (changed/enhanced behavior). `fixed` → "Fixed".
- `headline`, **required for any bucketed release** (one or more `added`/`improved`/`fixed` items). A short title or one plain sentence, leading with the release's reason to exist. The buckets render with no title of their own, so a bucketed card with no `headline` ships titleless. A grab-bag with no single story still gets a `headline`: use a descriptive umbrella line naming the two or three biggest items ("Built-in a11y testing, dead-code detection, and stories as tests"), never nothing. The only way to omit `headline` is to let a `summary` carry the lead instead (see below). For a newly shipped capability, carry rule 3's `now` into the headline too, "GAIA apps now ship with a CSP", not "ship with". Rule 17 governs tone.
- `summary` vs buckets, **mutually exclusive.** The renderer shows `summary` as a single paragraph _instead of_ the `added`/`improved`/`fixed` lists. The choice is driven by **how many distinct adopter-facing items survive the cut, not by the release's age or whether it's a backfill.** Use **buckets** whenever one or more itemizable adopter-facing changes remain; each lands as its own bullet under New/Improved/Fixed. Reserve `summary` for: (1) an **internal-only** release where every change was dropped as maintainer plumbing, a one-line "no adopter-facing changes" note; (2) a genuine **one-sentence** story; or (3) a broad **inaugural / overview** release where a narrative reads better than a long list (the `1.0.0` entry). Never set both.
- `preamble`, **only when the version's block carries the routing line** (a line equal to the output of `bash .gaia/scripts/compose-release-body.sh --routing-line`). Copy the `preamble` of the newest `releases/*.ts` that has one, verbatim: the routing line, the Proceed line, and the sha256 line of the bundle the routing line downloads. The renderer emits it before the headline, so the GitHub release body still leads with the routing line after `/gaia-release` overwrites it. The routing line itself is never a bullet.
- Bullet strings are markdown-lite: inline code in backticks, links as `[text](url)` (rendered as a new-tab link). Docs links carry the detail (rule 15): `https://docs.gaiaharness.com/<section>/<page>/#<anchor>`, verified against `../docs/src/content/docs/` before writing. Link a GitHub issue or pull request only when no docs page covers the subject, with the link on descriptive words.

## Output (b): the editorial-decisions report

After writing the file, print a report to the terminal (don't write a file; this is a human gate the maintainer reads before accepting the notes). It makes your editorial judgment auditable. Use this structure:

```
## Release notes, v<version> (<date>)

Wrote ../website/src/pages/changelog/releases/<version>.ts

**Dropped** (with reason)
- <changelog line>, <why: pure-internal / housekeeping / docs-only>

**Consolidated**
- <N changelog lines about X> → one <bucket> item

**Needs a human ruling** (ambiguous actor, see rule 9; borderline drop, see rule 7)
- <line>, feature or housekeeping? <why it's ambiguous>
```

Omit a section if it's empty. Never drop something silently: if it didn't make the notes, it appears under Dropped or Needs a human ruling.

**Resolve every human ruling with `AskUserQuestion` before you finish**, one question per line, options `Keep` and `Drop`, the recommended one first and labelled `(Recommended)`. Put the proposed plain-language rewrite in the question so the maintainer rules on the text that would ship. Then apply the answers to the `.ts` file.

## The rewriting rules

1. **Plain language, one short sentence where possible.** The reader is a developer deciding whether GAIA is worth trying, not an engineer applying the update. Say what changed for them and stop. Cut the mechanism (how it works, which script, which file, which flag, which config key, which error code, which env input), the step-by-step instructions, and the edge-case qualifiers. Aim for about 25 words a bullet; past 40 is a smell. Detail goes behind a docs link (rule 15), never into the bullet.
2. **Name only what the reader knows or types.** Name the _what_, not the tool that implements it: "a monorepo", not "a pnpm workspace". Never lean on a GAIA term the reader hasn't met ("the red band", "worthiness verdict", "residue"): say what it does, and let the docs link teach the term. Never name GAIA's internal CLI commands, scripts or skill references (`gaia scaffold route`, `gaia migrate-csf4`, `gaia fitness check`, `verify-audit-roster.sh`): Claude calls them, the reader never types them. Generalize to what GAIA does, and put the docs link on the noun ("GAIA creates a `[new route](…)` with everything it needs"). Name a command only when the reader types it: a slash command (`/update-gaia`) or a documented terminal command (`npx create-gaia`, `pnpm install`). A slash command or subcommand GAIA invokes on its own (`/gaia-spec reopen`) is internal too: say what GAIA does, or drop it when it only fixes a problem the reader would never meet.
3. **Restate at capability and impact level, with a concrete subject.** Name the component the adopter touches: CI, the Code Audit Team, `/update-gaia`, the quality gate. "What changed and what it means for me," not "which function moved." The scaffolded React app is **GAIA apps** (apps built from the template); the repository as a whole is **GAIA projects** ("GAIA projects are now monorepos", not "your project is now"); effects on the developer's own code or files are **your …** (your utility classes, your `package.json`). So "the app ships with a CSP" becomes "GAIA apps now ship with a CSP."
4. **Name who GAIA is talking to.** Claude is GAIA's primary worker, so many changes are GAIA instructing Claude (a refusal, a rule, a hook's message), and others are GAIA or Claude talking to you (a statusline nudge, a question, a report). Say which: "it now tells Claude what to do instead", not "it now tells you what Claude can do"; "GAIA's coding guidelines now tell Claude to…"; "GAIA has Claude save its place and ask you…". Check the CHANGELOG's actor before writing, since passive voice there hides it (rule 9).
5. **Be specific about the outcome, not the mechanism.** Plain language is not vague language: name the command, component or result the reader would recognize. But specific means "`pnpm install` in CI is bounded at 3 minutes with one retry", not the input name that raises the bound. When a line carries two unrelated changes, split it, then judge each half on its own (one half often drops).
6. **Every bullet names what changed and its observable result.** "Optimized" says optimized _what_, with what result; a bullet a reader can't act on or verify is noise, so cut or rewrite it. Frame the lead descriptively ("Maintenance release", "Security release"), never by semver tier, which the version number already conveys.
7. **Drop changes with no adopter relevance; judge by relevance, not residence.** The test is whether an adopter _building their own product_ would notice or benefit, not whether the changed file physically ships to their machine. A hook, guard, or workflow can ship to every adopter and still be maintainer-only in effect. Drop: ADR reframes, leak-check tweaks, internal status stamping, test-harness changes, docs-only edits, and fixes to GAIA's _own_ development and release plumbing, sibling-repo push handling, release lockstep, contributor-only guard edge cases. The adopter's product behaves identically with or without them. Trap: "strip surrounding quotes from literal `git -C` captures so a quoted sibling-repo push is recognized as foreign" ships inside an adopter hook, yet only fires when _you_ push across GAIA's own sibling repos during a release; drop it. (Contrast: a change to the Code Audit Team an adopter runs before every merge _is_ adopter-facing, residence aside; keep it.)

   For **fixes**, the bar is higher: keep a fix only when users reported it, or it clearly reaches them (a wrong statusline nudge, a command that failed or did nothing, a slow or hung CI run, a security advisory, a broken install). Drop fixes to under-the-hood mechanics no one would notice: lock races, guard-bypass spellings, cache and metadata edge cases, revert-point internals, init/de-branding internals, dependency pre-check edge cases, renames in formats only GAIA's own tooling reads (plan criterion lines), and rewording or cleanup of Claude's own instructions. Also drop a fix only the maintainer could have hit: a limit no adopter could reach yet because the feature is too new (the 1000-closed-issue dedupe cap, a few days after tech-debt filing shipped in 2.0). When you can't tell, route it to **Needs a human ruling** with a recommendation.
8. **Drop maintainer housekeeping on GAIA's own repo/wiki.** Promoting memories, reorganizing the wiki, dated audit artifacts, version-stamp bumps. These change GAIA's _own_ state, not what GAIA _does_ for an adopter.
9. **Flag ambiguous actors; don't guess.** Imperative/passive changelog voice often hides the subject. "promote machine-local feedback memories into shared wiki" _reads_ like a feature ("GAIA now promotes memories") but was the maintainer running `/gaia-cleanse` on GAIA's own wiki, housekeeping; drop it. When a line could mean "GAIA now does X" (keep) or "I did X to the repo" (drop) and the voice won't tell you which, put it under **Needs a human ruling** rather than picking. Guessing wrong either invents a feature or buries a real one.
10. **Consolidate scattered lines about one subject.** Four Code Review Audit lines describing one coherent change become one item. The adopter wants the story, not the commit-by-commit trail.
11. **Keep breaking changes and migrations, plainly framed, with a pointer.** Plain does not mean painless. State the breakage in one adopter-terms sentence, say whether `/update-gaia` handles it, then point to the steps instead of reciting them: link the docs migration note (`maintenance/update-gaia/#...`) when one exists, else "See the full [changelog](https://github.com/gaia-harness/gaia/blob/main/CHANGELOG.md) for exact steps." Dropping the scary part to sound friendly is the one unforgivable edit; reciting the steps on the website is the other common one.
12. **House style: no em-dashes, no explanatory colons, present tense.** Use commas and periods. The "Abc: xyz" shape (a colon introducing an explanation, a definition or a list) reads as an AI tell, so write a new sentence or use a comma instead ("Accessibility testing is built in. axe-core runs…", not "built in: axe-core runs…"). Labels such as `**BREAKING:**` are fine. The raw CHANGELOG violates all three freely, so never pipe a line through verbatim; always rewrite.
13. **Bucket mapping.** `### Added` → `added` ("New"). `### Changed` → `improved` ("Improved"). `### Fixed` → `fixed` ("Fixed"). `### Removed` → `improved` ("Improved"): the website has no "Removed" bucket, and a removal that survives the cut reads to an adopter as a cleanup or simplification, but see rule 14; most marked removals are reframed or dropped, not bucketed verbatim. A `**BREAKING:**` or **Migration** sub-bullet stays in whatever bucket its parent lives in (usually `improved`).
14. **A `/update-gaia`-automated cleanup is not a manual step.** When a `### Removed` / `### Changed` entry carries the adopter-action marker (an **Action required:** line and/or a literal `pnpm` command, see `CHANGELOG.md`) **and** the action reduces to a single mechanical command `/update-gaia` surfaces for the adopter (a `pnpm remove`/`pnpm install`-style cleanup), do **not** present it as a chore the reader must perform. Either **reframe at impact level**, naming the cleanup as a benefit and noting the tooling handles it ("GAIA dropped the vestigial `react-router-dom` shim; `/update-gaia` cleans it up for you"), or **drop it** as no adopter-behavior-change. Log the decision in Output (b): a drop goes under **Dropped** with the reason "agent-automated by `/update-gaia`"; a reframe is visible in the notes themselves. Never a silent cut. **Guardrail (does not erode rule 11):** a genuine breaking change or hand-migration, anything the agent cannot do for the adopter (editing their code, resolving a conflict patch, a real API break), is still **kept**, plainly framed, with a pointer to the exact steps. The marker is the discriminator: a one-command cleanup is automatable (reframe/drop); an **Action required:** that demands human code changes is a migration (keep). When you cannot tell which from the entry, route it to **Needs a human ruling**; never guess.
15. **Link to the docs; don't inline them.** When a bullet's subject has a page on docs.gaiaharness.com (a command, an audit member, a migration note), link the subject text to that page or anchor. Verify the anchor exists in `../docs/src/content/docs/` (Starlight anchors are the heading lowercased, punctuation dropped, spaces as hyphens: "Stories in 2.3.0" → `#stories-in-230`). One link per bullet at most; never a bare "learn more". Put the link on words the reader understands, never on a raw identifier: "closing a `[high-severity advisory](…)`", not "`([GHSA-27r3-jxmh-p828](…))`". The same goes for issue and PR numbers.
16. **A fix is not a feature.** Describe a fix as the bug going away, not as a new capability. "Filing a tech-debt issue reads every closed tech-debt issue, so..." reads like new behavior; the truth is a lookup that capped at 1000 now doesn't. Lead with what no longer goes wrong. Keep the bug's scope exact: when a fix only matters past a limit or in an edge case, name that boundary ("now cover every closed issue, not just the most recent 1000"). Stripping it to sound outcome-first ("no longer re-files a finding you declined") implies the whole feature was broken.
17. **Personality lives in the headline only, as dry understatement.** Bullets stay plain and precise. A headline may carry a little wit by naming the frustration the reader actually had: "`/update-gaia` stops fighting you over your own files", "Setup no longer asks you to restart Claude", "Claude stops handing you chores". No puns, pop-culture references, exclamation points, cute personification, mascot voice or "we squashed some bugs". The wit has to trace to a real item in the release, never stand in for one. Skip it on internal-only and security releases, and on a major release where the list of features is the story. A plain headline is always acceptable; a forced joke is worse than none. Because model-written humor drifts into repeated tells, never ship a witty headline unreviewed: draft two or three options, recommended first, and let the maintainer pick (in prose, not a picker).

## Worked exemplars

### `1.3.5`, seven Added, five Changed, four Fixed → two / three / one

```ts
export default {
  added: [
    'New package versions are quarantined for 7 days before GAIA installs them, and downgrades are blocked, defending against a compromised fresh release.',
    'GAIA apps now ship with a Content-Security-Policy that restricts which scripts can run, hardening them against script injection.',
  ],
  date: '2026-06-02',
  fixed: [
    'Your utility classes on `Form/Chain` now override its defaults instead of conflicting with them.',
  ],
  headline: 'Faster, cheaper CI and a hardened dependency supply chain.',
  improved: [
    'Code Review Audit on CI is now opt-in and installs on demand. When it runs, it only audits changes since the last green run instead of the whole codebase, so CI is faster and cheaper.',
    'Your app is ready for React Router v8 early. If you customized `app/root.tsx`, a small migration is needed. See the full changelog for the steps.',
    'Kickoff prompts print to the terminal instead of silently copying to your clipboard.',
  ],
  version: '1.3.5',
};
```

Report for `1.3.5`:

```
**Dropped** (with reason)
- stamp GAIA-Audit status on out-of-scope skips, internal status stamping, no adopter effect
- clarify the gate owns formatting; make PR merge marker-first, internal workflow mechanics
- document useDebounce return semantics, docs-only
- detect orphaned wiki drift in preflight via suggested_base, internal release tooling
- recover the un-evaluated window on sync re-anchor, internal wiki-sync mechanics
- gaia-release updates softwareVersion, maintainer-only release tooling

**Consolidated**
- four Code Review Audit / CI lines (install on demand, honor both tokens, gate on since-last-green delta, incremental scope, opt-in) → one "Improved" item
- two pnpm supply-chain lines (minimumReleaseAge quarantine, no-downgrade trustPolicy) → one "New" item
```

### `1.4.0`, note the housekeeping drop (rules 8/9)

```ts
export default {
  date: '2026-06-02',
  fixed: [
    '`/update-gaia` no longer re-adds files you intentionally deleted.',
    '`/update-gaia` only raises conflicts for files that actually changed in the release, instead of flooding you with spurious patches.',
    'Wiki entries take their dates from your system clock instead of the model, so timestamps are always correct.',
  ],
  headline: '`/update-gaia` stops fighting you over your own files.',
  version: '1.4.0',
};
```

Report for `1.4.0`:

```
**Dropped** (with reason)
- promote machine-local feedback memories into shared wiki, reads like a feature but was the maintainer running /gaia-cleanse, a content action on GAIA's own wiki, not adopter-visible behavior (rules 8/9)
```

### Before → after calibration (from 2.2.0 and 2.3.0)

These pairs show the plain-language level rules 1 and 2 ask for. The before lines are what an earlier run of this skill shipped.

| Before (too technical) | After |
|---|---|
| The Code Review Audit gains a shell member, `code-audit-shell`, that reviews the shell scripts you author... `bats` joins your devDependencies with a `pnpm test:shell` script..., and `tests.yml` adds a `Tests / Shellcheck and bats` check... `"shellcheck": false` in `.gaia/project.json` turns the lint off. | The Code Audit Team roster has a new member, [`code-audit-shell`](https://docs.gaiaharness.com/workflow/code-audit-team/#members), that reviews the shell scripts Claude writes when you add your own hooks. |
| Storybook stories move to CSF Next with test syntax on: GAIA's scaffolds write `meta.story(...)`... if you update without it, run `.gaia/cli/gaia migrate-csf4` once... needs a fresh worthiness verdict for each one. | Storybook stories are now written using CSF Next syntax. `/update-gaia` converts your stories for you. See [Stories in 2.3.0](https://docs.gaiaharness.com/maintenance/update-gaia/#stories-in-230) for details. |
| `pnpm install` in CI no longer hangs for ten minutes on one stuck registry request. Each attempt is bounded (3 minutes by default, raised with the new `install-attempt-seconds` input) and retried once. | `pnpm install` attempts in CI are now bounded at 3 minutes with a single retry (previously one could hang for 10 minutes). |
| `gaia fitness check` no longer flags a project path such as `src/pages/home/...` as a machine-specific home directory, so a false warning stops lowering your fitness grade and arming the `/gaia-fitness` nudge. | The `/gaia-fitness` statusline nudge no longer appears when it shouldn't. |
| After `npx create-gaia`, `/gaia-init` continues straight into `/setup-gaia` instead of telling you to exit and restart Claude twice. Setup ends with no restart... the statusline shows `⚙️ /setup-gaia (Required)`. | `npx create-gaia` now fully installs GAIA in a single session. |
| Storybook's viewport toolbar shows your project's Landscape, Portrait and mobile viewports... The unused `controls.hideNoControlsWarning` parameter is gone... | Storybook's viewport toolbar now shows Landscape, Portrait and mobile viewports. |
| GAIA apps now use query-string 10... throws a `TypeError`... instead of quietly sending `[object Object]`. If your code passes such values, convert them to strings first or use query-string's `replacer` option. | (same, minus the last sentence: the behavior change stays, the how-to goes) |

Dropped outright as under-the-hood (rule 7): Storybook Controls reading props through TypeScript; plan `Story test criterion` line rename; Playwright apt-package caching on a slow Ubuntu mirror; two `/update-deps` edge cases (stale cached metadata, revert-point snapshot); `strip-branding` de-branding the Storybook sidebar; the RED-capture re-run skipping pnpm's dependency check; a lock-directory race on Ubuntu 26.04.

### When `summary` fits, internal-only or one-line releases

A release with no distinct adopter-facing items left after the cut, an internal-only patch where everything was dropped as maintainer plumbing, or a genuinely one-sentence story, collapses to a single `summary` paragraph. This is about item count, not age: a backfilled old release with two real adopter changes still earns buckets. The shape, for an internal-only patch like `2.0.1` (its one fix only the maintainer could have hit, rule 7):

```ts
export default {
  date: '2026-10-23',
  headline: 'Maintenance release',
  summary:
    'A fix to how GAIA saves usage data. No change to how GAIA apps behave.',
  version: '2.0.1',
};
```

## Workflow

1. Resolve the version → block → date (Inputs above). For a live cut, run `date +%F` now.
2. Read `../website/src/pages/changelog/types.ts` for the current `Release` fields and the newest `releases/*.ts` for the current file form. Then read the version's block from `CHANGELOG.md`. Classify every line: keep, drop (rules 7/8), consolidate with siblings (rule 10), reframe or drop a `/update-gaia`-automated cleanup (rule 14), or ambiguous (rule 9).
3. Rewrite the kept lines through the rules. Group by bucket (rule 13). Merge consolidations. Find the docs page for each subject and link it (rule 15).
4. Draft two or three `headline` options per Output (a) and rule 17, recommended first, or a `summary` in place of buckets when one of Output (a)'s three `summary` cases applies.
5. Assemble the `.ts` in the form of the file you read in step 2, with a `preamble` when the block carries the routing line (Output (a)). Sweep for em-dashes, explanatory colons, bullets with no observable result, and bullets over 40 words or carrying a file path, flag, config key or instruction the reader doesn't need (rules 1/2/6/12).
6. Write `<version>.ts`.
7. Print the editorial-decisions report. Every changelog line that didn't survive appears under Dropped or Needs a human ruling, no silent cuts.
8. Put each **Needs a human ruling** line to the maintainer with `AskUserQuestion` (Keep / Drop, recommended first), then apply the answers to the `.ts` file.

## See

- `.claude/commands/gaia-release.md`, the release process this feeds: Step 14 invokes this skill for the changelog page entry and locksteps the other website version sites.
- `CHANGELOG.md`, the source.
