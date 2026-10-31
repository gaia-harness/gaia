# RED-observation ledger

Mechanical TDD RED-verification records each test the agent observed failing,
so the commit gate can confirm a new passing test was seen failing first. Two
hooks share this directory's contract: a PostToolUse capture hook appends
observations, and a PreToolUse check denies a commit whose new passing test has
no matching RED on record.

## Ledger

- **Directory:** `.gaia/local/red-ledger/<tree_key>/` (under the gitignored
  `.gaia/local/`, so the ledger never gets committed). `<tree_key>` identifies
  the working tree, printed by `bash .gaia/scripts/main-root-lib.sh
  --tree-key`. The capture hook `mkdir -p`s it on first write.
- **File:** `.gaia/local/red-ledger/<tree_key>/observations.jsonl`;
  append-only JSON Lines, one observation per line. Capture never rewrites or
  dedups; duplicate observations for the same `(file, fullName, signal)` are
  harmless and the check treats "at least one matching valid RED exists" as
  satisfied.

## Record schema

```json
{
  "schema": 1,
  "file": "frontend/app/x/index.test.ts",
  "fullName": "X does Y",
  "signal": "sha256:…",
  "failureKind": "assertion",
  "observedAt": "2026-06-04T20:55:00Z"
}
```

- `schema` (number); version, currently `1`. Readers ignore lines whose
  schema they do not understand (forward-compat).
- `file` (string); repo-relative POSIX path to the test file. No leading
  `./`, never absolute.
- `fullName` (string); vitest's `assertionResults[].fullName`: the enclosing
  describe titles plus the test title, space-joined.
- `signal` (string); `sha256:` followed by the lowercase-hex sha256 of the
  test's normalized source span (see below).
- `failureKind` (string); `"assertion"` or `"runtime"`. Both are valid REDs.
  A `"collection"` kind is never written: a suite-level collection or compile
  error where no test body ran is not a valid RED.
- `observedAt` (string); ISO-8601 UTC timestamp.

## Content signal

vitest's `--reporter=json` emits `location: null` for every assertion, so the
signal is derived from the test file source, not the reporter. The signal binds
a RED to a specific test body: editing what the test executes changes the
signal and invalidates the RED, so a fresh failing run must be observed.

Comments are excluded from the signal, so a comment-only edit does not
invalidate a RED. The guarantee covers a comment's **text**: rewording a
comment, and deleting a comment that has whitespace on both sides, leave the
signal byte-identical. Deleting a comment that sits with **no adjacent
whitespace on one side** leaves the separating space behind and **does** rotate
the signal, the accepted price of never fusing the two tokens the comment sat
between.

## Helper: `extract-test-signals.mjs`

Node ESM, Node stdlib only (resolves `typescript` from `node_modules` for a
robust AST walk).

```
node .gaia/scripts/red-ledger/extract-test-signals.mjs <repo-relative-test-path>
node .gaia/scripts/red-ledger/extract-test-signals.mjs <path> --stdin
```

Reads the file from disk (or stdin with `--stdin`) and prints one JSON object
per discovered `test(...)`/`it(...)` call, newline-delimited:
`{"fullName":"…","signal":"sha256:…","kind":"runtime"|"type-only","firstLine":N,"ranges":[[start,end],…]}`.
`firstLine` and `ranges` are 1-based inclusive line numbers of the regions the
signal hashes (a story entry lists its story, play, meta and, for a `.test()`
entry, the test statement); they are not part of the signal. Exit `0`
on success (no output when no tests are found); non-zero with a one-line stderr
message on a failure. The exit codes are listed in the helper's header.

**Story mode.** A path ending `.stories.tsx` or `.stories.ts` is read as a
CSF4 story file (`preview.meta`, `meta.story`, `.extend`, `.test()`), whose
stories `@storybook/addon-vitest` runs as tests. The helper prints
`{"fullName","signal","kind":"runtime"}` lines in export order: for a story
carrying any `.test()`, `<Story Name>   base story` and then
`<Story Name>   <test name>` per test (three spaces, as Storybook's Vitest
reporter names them); for a story with an effective play and no tests, the
plain `<Story Name>`; nothing for a render-only story without tests or a story
tagged `!test`. `<Story Name>` is Storybook's start-cased export name, or a
string-literal `name` in the story's own call argument; an `.extend` story
keeps its own export's name, never its source's `name`. An `.extend` story
without its own play inherits its source's, then the meta's. Every entry of a
story signs the story's declaration, its resolved play and the meta call, and
a test entry also its `.test(…)` call, so editing a story's play rotates its
base story, every test and every `.extend` story inheriting that play, while
editing one test rotates that test only.

The format is decided from the source text by `story-format.mjs`, the
predicate the migration command and quick-classify share. A CSF2 or CSF3 file
exits `8` with empty stdout and one stderr line naming the migration command
(`.gaia/cli/gaia migrate-csf4`). A CSF4 shape the helper cannot resolve, or a
file in no story format, exits `7` with an `unsupported story shape` stderr
line and empty stdout, never an empty success. The rules and the refusal list
live in the header of `extract-story-signals.mjs`.

`fullName` is the enclosing describe titles (outermost first) plus the test
title, single-space-joined. `signal` is `sha256:` plus the lowercase-hex
sha256 of the test call expression's normalized, comment-free content;
trimmed, with internal whitespace runs collapsed to single spaces, so it stays
stable across pure reformatting and across a comment reword. Any change to
what the test executes still rotates it.

Comment spans come from `ts.getLeadingCommentRanges` /
`ts.getTrailingCommentRanges` read at parsed token boundaries, which is what
keeps a doubled forward slash inside a string, template, or regular-expression
literal out of reach. Every range overlapping a `JsxText` node is discarded
**before** the ranges are deduplicated and merged (that order is load-bearing:
the swallow range a `>` token produces in `<div>// alpha</div>` strictly
contains an adjacent genuine `{/* … */}` comment, and merging first would fuse
them and then drop both). Each surviving span is replaced by a single space,
never the empty string, so the two tokens a tight inline comment sat between
are never fused.

`kind` is `"type-only"` when the test's assertions are all type-level (an
`expectTypeOf`/`assertType` call, or a `@ts-expect-error` proof) and it carries
no runtime assertion (`expect`/`assert`); `"runtime"` otherwise. A type-only
test has no runtime failure mode, so the commit check exempts it from the
runtime-RED demand and delegates its correctness to the `tsc` Quality Gate
step. The predicate defaults to `"runtime"` (enforce) when no type-level signal
is present, so a no-assertion test is never silently exempted. `kind` is part
of the helper output only; it is not stored in the ledger schema above.
