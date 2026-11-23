---
type: decision
status: active
priority: 2
date: 2026-11-24
created: 2026-11-24
updated: 2026-11-24
tags: [decision, quality, ci, single-source-of-truth]
---

# Decision: Duplicate Value Set Check

`gaia value-sets` fails when two value sets in a project's TypeScript or shell hold the same values, or one hand-narrows another, unless a verified marker declares the copy. It enforces the code half of `.claude/rules/single-source-of-truth.md` deterministically: a session follows that rule only when it remembers to search, and a pull request audit sees only the branch's diff, so a copy made earlier in an untouched file drifts unseen.

Two places run it: the first step of the [[Quality Gate]], on every commit whatever is staged, and a CI job on every pull request.

## What is a value set

- **TypeScript** (read with the compiler's single-file parser, loaded from the scanned project's own `typescript` install): an array of only string literals bound to a `const` (with or without `as const`, an annotation or `satisfies`) or passed to `Object.freeze`; a type alias that is a union of only string literals; a `z.enum([...])` or `z.literal([...])` call of only string literals.
- **Shell**: an array of literal words (`name=(...)`, `local -a`, `declare -a`, `declare -ra`, `readonly`), and a `case` arm of two or more literal alternatives. Arms of options only (every alternative begins with `-`) are skipped.

Never read: a set computed from another (filtered, sliced, spread), a set holding an expansion, a glob or a non-literal element, enums, tuple types, associative arrays, a mixed union, and any text inside a comment, a heredoc body or a quoted string. A type annotation never exempts a literal set. Comparison is case-sensitive and order-free.

## Strict rules

- Two sets holding the same three or more values fail, in one file or across files, and across the two languages. A group of identical sets is one finding naming every site.
- A set of three or more values strictly contained in a set in a different file fails, once, against the smallest set holding it (ties go to the site that sorts first by path then line). A subset pair inside one file is only a candidate.
- A case arm is a use site: it is reported as the copy when it repeats a declaration, as the subset when it is a strict subset of a declared set, and it is never the superset in a subset finding or the source a marker names.
- Sets of fewer than two values are never compared, and two-value sets never fail strict mode.

## Scope

Every tracked, staged and untracked-but-not-ignored file with a TypeScript extension (`.ts`, `.tsx`, `.mts`, `.cts`) or a shell extension (`.sh`, `.bash`, `.bats`), or no extension and a first-line shebang naming `sh`, `bash` or `bats` directly or through `env`. Content is the working tree's, never the index. A path that is not a regular file (a symbolic link, a FIFO or another special file) is skipped. The run always reads the whole project, never only the changed files.

Any path under a directory named `node_modules`, `.git`, `dist`, `build`, `.react-router`, `storybook-static`, `coverage`, `fixtures`, `test-fixtures` or `__snapshots__` is never read. The CLI fixes this list; only the config below extends it.

## Exclusion config

An optional, adopter-owned `.gaia/value-sets.json` extends the exclusions:

```json
{"version": 1, "exclude": [{"path": "<glob>", "reason": "<text>"}]}
```

Every entry needs a path glob and a non-empty reason. A config that is not valid JSON, is not an object, has a `version` other than 1, holds a key other than `version` and `exclude`, or has an entry missing its path or reason makes the run exit 2. `--config <path>` reads the exclusions from that file instead, and a named file that cannot be read exits 2. The file is absent from the GAIA manifest.

## GAIA's own files on an adopter

An adopter run reads every file in scope, GAIA's shipped files included, so a shipped set can be a comparison partner and a marker source. A finding whose every site is a GAIA harness file goes unreported: the adopter cannot fix it and GAIA fixes it upstream. The harness is every `.gaia/manifest.json` entry, of any class, outside `apps/` and `packages/`; the starter app under `apps/` is the adopter's code, so a duplicate inside it, or between it and the adopter's files, is reported. A finding with at least one site outside the harness is reported, an adopter file copying a shipped set included. An unparseable manifest exits 2.

<!-- gaia:maintainer-only:start -->
The maintainer repo is recognized by `.claude/rules/maintainers/harness-triage-threshold.md`. There the harness set is empty, so a duplicate between two harness files is reported too.
<!-- gaia:maintainer-only:end -->

## Markers

A literal set that must stay a copy, or a deliberately narrower one, carries a marker; the syntax and how each form is verified live in `.claude/rules/single-source-of-truth.md` `## Code`. The check resolves a marker only against named sets already collected in scope, never by opening the named file, so a marker naming an absolute or repository-escaping path, an excluded or out-of-scope file, an unnamed set or a case arm fails as source not found. A marker that matches more than one set, is malformed, conflicts with a second marker on the same set, sits above no set, or names a marked source fails with its own finding. A valid sanctioned copy is left out of the duplicate comparison; a valid subset marker exempts the set from every subset finding, whichever set holds its values, but not from a duplicate finding.

## Exit codes

- `0`: clean, or `--candidates` ran.
- `1`: at least one finding.
- `2`: the check cannot run, or the arguments are bad. The cause is one stderr line, no findings are printed, and the check never passes a scope it could not read: the project's `typescript` cannot be loaded from the scanned project root while TypeScript files are in scope, a file cannot be read, a TypeScript file has syntax errors, a shell file is not valid UTF-8, the run is outside a git work tree, the manifest cannot be parsed, the config is malformed, or an argument is unknown or repeated, or `--config` and `--policy-from` are both given.

## Output

Findings print on stdout, one per line, sites ordered by path then line, values sorted and joined by `, `. A site reads `<name> (<path>:<line>)`, with `(case arm)` or `(unnamed)` for a set with no identifier. The line forms:

- `value-sets: duplicate: <site> and <site> hold <values>`
- `value-sets: arm copies set: <arm site> repeats <set site>: <values>`
- `value-sets: subset: <site> is a subset of <site>, which also holds <values>`
- `value-sets: copy drifted: <site> copies <path>#<name>; missing <values>; extra <values>`
- `value-sets: copy source not found: <site> names <path>#<name>`
- `value-sets: copy of a copy: <site> names <path>#<name>, which is itself a sanctioned copy`
- `value-sets: subset holds values its source lacks: <site> holds <values>, which <path>#<name> lacks`
- `value-sets: subset equals source: <site> holds no value fewer than <path>#<name>; it is a duplicate, not a subset`
- `value-sets: subset source not found: <site> names <path>#<name>`
- `value-sets: ambiguous source`, `value-sets: malformed marker`, `value-sets: conflicting markers`, `value-sets: stray marker` and `value-sets: marked source`, each naming the marker's site

A clean run prints `value-sets: no duplicate value sets`. A run that cannot read its scope prints `value-sets: cannot run: <cause>` on stderr.

## Candidates

`gaia value-sets --candidates` prints a JSON array to stdout and exits 0 whatever it finds. Each object is `{"kind", "values", "sites"}`: `kind` is `two-value-duplicate`, `two-value-subset` or `same-file-subset`, `values` the sorted strings, and `sites` a list of `{"path", "line", "name"}`. It holds the matches strict mode does not fail on, ordered by the first site's path then line, never repeats a strict finding, and never collects an options-only arm. No match prints `[]`. A scope it cannot read exits 2 with nothing on stdout.

## CI

The shipped Tests workflow has a `Value sets` job that runs on every pull request, with no path filter, no `if:` condition and no early exit, so a pull request that changes only shell files, or only a README, still runs it. It checks out the whole head tree and installs the root dependencies so the project's `typescript` loads from the repository root, then runs `gaia value-sets --policy-from <dir>`. `<dir>` holds the base commit's copies of `.gaia/value-sets.json` and `.gaia/manifest.json`, so a pull request cannot exclude its own duplicate or list its own file as harness through `.gaia/value-sets.json` or `.gaia/manifest.json`. One that edits the workflow job or the committed CLI bundle is not stopped by this; review of those files covers it. A file absent at the base stays absent in `<dir>`: no config means no exclusions, and no manifest means no harness files; a failed fetch for any other reason exits 2, never falling back to the head's copy. The head's own config is still checked for shape and never applied. Its name is in the required-check list `/setup-gaia` registers (`.claude/skills/gaia/references/setup/required-ci-checks.md`).

<!-- gaia:maintainer-only:start -->
In the maintainer repo the base commit's `.claude/rules/maintainers/harness-triage-threshold.md` also lands in `<dir>`, so a pull request that deletes the marker file keeps its harness findings.
<!-- gaia:maintainer-only:end -->

## Fixing a finding

In this order:

1. Import the source, in TypeScript.
2. Derive the other shape from it (`.filter`, `.slice`, a spread, `typeof X[number]`), or in shell source one library both scripts use. A derived set holds no literals and is never read.
3. Keep a literal set that must stay a copy, or must hold fewer values, with a marker per `.claude/rules/single-source-of-truth.md` `## Code`.
4. Exclude a path that holds deliberate frozen data with an entry and a reason in `.gaia/value-sets.json`.

## See also

[[Quality Gate]] runs the check as its first step. [[Shell Testing and CI]] describes the CI jobs.
