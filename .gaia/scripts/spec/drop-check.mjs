#!/usr/bin/env node
// The drop-destination check: refuses a review fixer's output that cannot say
// where every case it removed now lives. Owner of the fixes-file format, the
// refusal list and the plan-mode rules; the spec audit and the plan
// decomposition audit point here instead of restating them.
//
// Usage: node drop-check.mjs --fixes <file> --findings <dir> --pre <file|dir>
//   --post <file|dir> [--dest <file>]... [--requirements <file>]
//   [--mode spec|plan]
// Output: one stdout line per refusal, `drop-check: <finding id>: <reason>`
// (a refusal about a line no finding owns reads `drop-check: untraced edit:
// <reason>`). Nothing on stdout when the output is accepted.
// Exit: 0 accepted, 1 refused, 2 usage error or an unreadable file.
//
// Fixes file (`fixes.json` in the findings directory):
//
//   {"fixes": [
//     {"finding": "TST-003", "route": "spec|directive|plan|rejected",
//      "edits": [{"change": "edited|narrowed|dropped", "quote": "<six or more words of the pre-fix line>"}],
//      "drops": [{"behavior": "B4", "case": "<old case text>",
//                 "destination": "still-stated|restored|refusal|out-of-scope|corrected-value|deferred",
//                 "file": "SPEC.md", "fragment": "<six or more words, verbatim from the destination file>"}]}
//   ]}
//
// --findings: every `*.json` file in the directory except `fixes.json`, each
// `{"findings": [{"id": ...}]}`; the set of ids is the expected set.
// --pre / --post: spec mode, the pre-fix and post-fix SPEC files; plan mode,
// directories whose same-named `.md` files are compared. Compared lines: spec
// mode, every behavior sentence (a behavior line or a case line of the
// `## Behaviors` section); plan mode, every bullet under a `## Acceptance
// criteria` heading of a task doc. Lines compare after whitespace is collapsed.
// --dest: the valid destination files, matched by basename against a drop's
// `file`. Spec mode: the --dest files, else the --post file; the name SPEC.md
// reaches the --post file too when no --dest file is named SPEC.md, since the
// draft is a cache copy. Plan mode: the post-fix README.md and every
// task-*.md, plus any --dest file (the caller passes the post-fix SPEC).
// REQUIREMENTS.md is never a destination.
// --mode defaults to spec.
//
// Refusals:
//   - a finding id missing, duplicated or extra against the findings set;
//   - an id whose prefix is not in LENS_PREFIXES;
//   - a drop with no destination, or one outside the destination enum;
//   - a drop whose file is not a valid destination;
//   - a fragment under six words;
//   - a fragment absent from its destination file after whitespace
//     normalization, except one found in --requirements under a heading the
//     post-fix SPEC points to with `REQUIREMENTS.md § <heading text>` (for a
//     `Q<n>. ...` heading the text up to the first period);
//   - a drop from an access, forgery, secret or refusal behavior whose
//     destination is not still-stated, restored, refusal or deferred (deferred:
//     the fragment sits in the post-fix SPEC's clarifications.deferred[] text);
//   - a compared line removed or changed between pre and post that no
//     edits[].quote matches (six or more words found in the pre-fix line);
//   - a case removed beyond any it replaced with fewer `drops` entries than
//     removed cases: spec mode counts per behavior id (the drop's `behavior`),
//     plan mode counts acceptance bullets across all files, since a bullet has
//     no id. In plan mode the strict-kind rule reaches only a drop whose `behavior` names a behavior of the --dest SPEC.
//
// Plan mode: a structural finding (one the main thread does not fix in place)
// is listed with route `plan` and no edits or drops, so every finding id stays
// accounted for. The check runs after the main thread applied the localized
// fixes, and --pre is the plan as it stood after any planner re-spawn (the
// re-spawned plan, never the pre-correction one), so a re-spawn's rewrites are
// not read as untraced edits.

import {existsSync, realpathSync, statSync} from 'node:fs';
import {basename} from 'node:path';
import {fileURLToPath} from 'node:url';
import {normalizeWhitespace, SECURITY_KINDS} from './behaviors.mjs';
import {
  behaviorKinds,
  comparedLines,
  deferredText,
  destinationFiles,
  findingIdsIn,
  readText,
  removedCounts,
  requirementsHold,
  UsageError,
  wordCount,
} from './drop-check-lib.mjs';

export const LENS_PREFIXES = [
  'TST',
  'COV',
  'SEC',
  'BRIEF-FIT',
  'FG',
  'A11Y',
  'MIG',
  'PERF',
  'DOC',
  'DP',
  'CG',
];

const DESTINATIONS = [
  'still-stated',
  'restored',
  'refusal',
  'out-of-scope',
  'corrected-value',
  'deferred',
];
const STRICT_DESTINATIONS = ['still-stated', 'restored', 'refusal', 'deferred'];
const STRICT_KINDS = [...SECURITY_KINDS, 'refusal'];
const MINIMUM_WORDS = 6;
const USAGE =
  'usage: drop-check.mjs --fixes <file> --findings <dir> --pre <file|dir> --post <file|dir> [--dest <file>]... [--requirements <file>] [--mode spec|plan]';


function idRefusals(fixes, expectedIds) {
  const refusals = [];
  const seen = new Map();
  for (const fix of fixes) {
    seen.set(fix.finding, (seen.get(fix.finding) ?? 0) + 1);
  }
  const expected = new Set(expectedIds);
  for (const id of expected) {
    if (!seen.has(id)) {
      refusals.push(`drop-check: ${id}: finding missing from the fixes file`);
    }
  }
  for (const [id, count] of seen) {
    if (count > 1) {
      refusals.push(`drop-check: ${id}: finding listed ${count} times`);
    }
    if (!expected.has(id)) {
      refusals.push(`drop-check: ${id}: finding is in no findings file`);
    }
    const prefix = /^(.+)-\d+$/.exec(String(id))?.[1];
    if (!LENS_PREFIXES.includes(prefix)) {
      refusals.push(`drop-check: ${id}: id prefix is not a known lens prefix`);
    }
  }
  return refusals;
}

function dropRefusals(fix, context) {
  const refusals = [];
  const id = fix.finding;
  for (const drop of fix.drops ?? []) {
    const caseLabel = normalizeWhitespace(String(drop.case ?? '')).slice(0, 60);
    const label = `${drop.behavior ?? '?'} case "${caseLabel}"`;
    const refuse = (reason) =>
      refusals.push(`drop-check: ${id}: ${label} ${reason}`);
    if (!drop.destination || !drop.file) {
      refuse('has no destination');
      continue;
    }
    if (!DESTINATIONS.includes(drop.destination)) {
      refuse(`has unknown destination "${drop.destination}"`);
      continue;
    }
    const kind = context.kinds.get(drop.behavior);
    if (
      STRICT_KINDS.includes(kind) &&
      !STRICT_DESTINATIONS.includes(drop.destination)
    ) {
      refuse(
        `is ${kind} and cannot resolve to ${drop.destination}; use still-stated, restored, refusal or deferred`,
      );
      continue;
    }
    const filePath = context.destinations.get(basename(String(drop.file)));
    if (!filePath) {
      refuse(`names ${drop.file}, which is not a valid destination file`);
      continue;
    }
    const fragment = normalizeWhitespace(String(drop.fragment ?? ''));
    if (wordCount(fragment) < MINIMUM_WORDS) {
      refuse(`fragment is under ${MINIMUM_WORDS} words: "${fragment}"`);
      continue;
    }
    if (drop.destination === 'deferred') {
      if (!deferredText(context.specText).includes(fragment)) {
        refuse(
          `fragment is not in the SPEC's clarifications.deferred text: "${fragment}"`,
        );
      }
      continue;
    }
    const fileText = normalizeWhitespace(readText(filePath));
    if (
      !fileText.includes(fragment) &&
      !requirementsHold(fragment, context.requirementsText, context.specText)
    ) {
      refuse(`fragment is not in ${drop.file}: "${fragment}"`);
    }
  }
  return refusals;
}

function editRefusals(fixes, lines) {
  const quotes = [];
  for (const fix of fixes) {
    for (const edit of fix.edits ?? []) {
      const quote = normalizeWhitespace(String(edit.quote ?? ''));
      if (wordCount(quote) >= MINIMUM_WORDS) quotes.push(quote);
    }
  }
  const refusals = [];
  for (const line of lines.pre) {
    if (lines.post.has(line)) continue;
    if (quotes.some((quote) => line.includes(quote))) continue;
    refusals.push(
      `drop-check: untraced edit: line removed or changed with no fix quoting six or more of its words: "${line}"`,
    );
  }
  return refusals;
}

function untracedDropRefusals(fixes, settings) {
  const drops = fixes.flatMap((fix) => fix.drops ?? []);
  const counts = removedCounts(settings);
  const refusals = [];
  if (settings.mode === 'spec') {
    for (const [id, removed] of counts) {
      const declared = drops.filter((drop) => drop.behavior === id).length;
      if (declared < removed) {
        refusals.push(
          `drop-check: untraced drop: ${id} lost ${removed} case(s) and ${declared} drops entries name it`,
        );
      }
    }
    return refusals;
  }
  let removed = 0;
  for (const count of counts.values()) removed += count;
  if (drops.length < removed) {
    refusals.push(
      `drop-check: untraced drop: ${removed} acceptance criteria were removed and ${drops.length} drops entries account for them`,
    );
  }
  return refusals;
}

export function checkFixes(settings) {
  let parsed;
  try {
    parsed = JSON.parse(readText(settings.fixes));
  } catch (error) {
    if (error instanceof UsageError) throw error;
    return {refusals: ['drop-check: fixes: the fixes file is not valid JSON']};
  }
  if (!Array.isArray(parsed?.fixes)) {
    return {
      refusals: ['drop-check: fixes: the fixes file has no "fixes" array'],
    };
  }
  const fixes = parsed.fixes;
  const destinations = destinationFiles(settings);
  const specPath =
    settings.mode === 'spec' ? settings.post : destinations.get('SPEC.md');
  const specText = specPath ? readText(specPath) : '';
  const kindSources = [specText];
  if (settings.mode === 'spec') kindSources.unshift(readText(settings.pre));
  const context = {
    destinations,
    kinds: behaviorKinds(kindSources),
    requirementsText: settings.requirements
      ? readText(settings.requirements)
      : '',
    specText,
  };
  const refusals = [
    ...idRefusals(fixes, findingIdsIn(settings.findings)),
    ...fixes.flatMap((fix) => dropRefusals(fix, context)),
    ...editRefusals(fixes, comparedLines(settings)),
    ...untracedDropRefusals(fixes, settings),
  ];
  return {refusals};
}

function parseArguments(argv) {
  const options = {dest: [], mode: 'spec'};
  const valueFlags = {
    '--fixes': 'fixes',
    '--findings': 'findings',
    '--pre': 'pre',
    '--post': 'post',
    '--requirements': 'requirements',
    '--mode': 'mode',
  };
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (value === undefined) throw new UsageError(`${flag} needs a value`);
    if (flag === '--dest') options.dest.push(value);
    else if (valueFlags[flag]) options[valueFlags[flag]] = value;
    else throw new UsageError(`unknown argument ${flag}`);
  }
  for (const required of ['fixes', 'findings', 'pre', 'post']) {
    if (!options[required]) throw new UsageError(`--${required} is required`);
  }
  if (!['spec', 'plan'].includes(options.mode)) {
    throw new UsageError('--mode is spec or plan');
  }
  for (const key of ['pre', 'post']) {
    const isDirectory =
      existsSync(options[key]) && statSync(options[key]).isDirectory();
    if ((options.mode === 'plan') !== isDirectory) {
      throw new UsageError(
        `--${key} must be a ${options.mode === 'plan' ? 'directory' : 'file'} in ${options.mode} mode`,
      );
    }
  }
  return options;
}

function main(argv) {
  try {
    const {refusals} = checkFixes(parseArguments(argv));
    for (const line of refusals) console.log(line);
    return refusals.length > 0 ? 1 : 0;
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    console.error(`drop-check: ${error.message}`);
    console.error(USAGE);
    return 2;
  }
}

const isEntryPoint = () => {
  try {
    return (
      realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
    );
  } catch {
    return false;
  }
};

if (isEntryPoint()) {
  process.exitCode = main(process.argv.slice(2));
}
