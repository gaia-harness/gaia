#!/usr/bin/env node
// The one parser of a SPEC's `## Behaviors` section, and the one definition of
// the behavior kinds. The spec lint, the test-stage check and the
// drop-destination check read the section through this module.
//
// Section shape (owner of the template: spec-template.md):
//
//   ## Behaviors
//
//   - **B1** (access): <one sentence stating the behavior>.
//     - Case: <actor, state, input> -> <outcome by value>.
//
// A behavior line is `- **B<n>** (<kind>): <text>` and a case line is
// `  - Case: <text>` (two-space indent), attached to the nearest behavior line
// above it. Lines inside a fenced code block are never read. A text with no
// `## Behaviors` section yields no behaviors and no problem: whether the
// section must exist is the caller's rule.
//
// parseBehaviors(markdownText) -> {behaviors: [{id, kind, text, cases, line}],
// problems: [string]}. `problems` names a malformed behavior or case line, a
// duplicate id, an unknown kind, and a behavior with no case.
// normalizeWhitespace(text) collapses runs of whitespace to one space and trims.
//
// Run directly, `node behaviors.mjs <spec file>` prints each problem on its own
// stdout line (nothing when there is none) and exits 0; an unreadable file is
// exit 2 with a stderr line. `node behaviors.mjs --count <spec file>` prints
// only the number of parsed behaviors, so a caller can require a non-empty
// section that is not inside a fenced block.

import {readFileSync, realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

export const BEHAVIOR_KINDS = [
  'access',
  'forgery',
  'secret',
  'refusal',
  'data-loss',
  'other',
];
export const SECURITY_KINDS = ['access', 'forgery', 'secret'];

const SECTION_HEADING = /^## Behaviors\s*$/;
const ANY_SECOND_LEVEL_HEADING = /^## /;
const FENCE = /^\s*(```|~~~)/;
const BEHAVIOR_LINE = /^- \*\*(B[1-9][0-9]*)\*\* \(([^)]*)\): (.+)$/;
const CASE_LINE = /^ {2}- Case: (.+)$/;
const LOOSE_BEHAVIOR_LINE = /^- /;
const LOOSE_CASE_LINE = /^\s+- Case\b/;

export function normalizeWhitespace(text) {
  return text.replace(/\s+/g, ' ').trim();
}

export function parseBehaviors(markdownText) {
  const behaviors = [];
  const problems = [];
  const seenIds = new Set();
  let inSection = false;
  let inFence = false;
  let current = null;

  const closeCurrent = () => {
    if (current && current.cases.length === 0) {
      problems.push(`line ${current.line}: ${current.id} has no case`);
    }
    current = null;
  };

  const lines = markdownText.split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].replace(/\r$/, '');
    const lineNumber = index + 1;
    if (FENCE.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (!inSection) {
      if (SECTION_HEADING.test(line)) inSection = true;
      continue;
    }
    if (ANY_SECOND_LEVEL_HEADING.test(line)) break;

    const behaviorMatch = BEHAVIOR_LINE.exec(line);
    if (behaviorMatch) {
      closeCurrent();
      const [, id, kind, text] = behaviorMatch;
      if (seenIds.has(id)) problems.push(`line ${lineNumber}: duplicate id ${id}`);
      seenIds.add(id);
      if (!BEHAVIOR_KINDS.includes(kind)) {
        problems.push(`line ${lineNumber}: ${id} has unknown kind "${kind}"`);
      }
      current = {
        id,
        kind,
        text: normalizeWhitespace(text),
        cases: [],
        line: lineNumber,
      };
      behaviors.push(current);
      continue;
    }
    if (LOOSE_BEHAVIOR_LINE.test(line)) {
      closeCurrent();
      problems.push(`line ${lineNumber}: malformed behavior line`);
      continue;
    }
    const caseMatch = CASE_LINE.exec(line);
    if (caseMatch) {
      if (current) current.cases.push(normalizeWhitespace(caseMatch[1]));
      else problems.push(`line ${lineNumber}: case line with no behavior above it`);
      continue;
    }
    if (LOOSE_CASE_LINE.test(line)) {
      problems.push(`line ${lineNumber}: malformed case line`);
    }
  }
  closeCurrent();
  return {behaviors, problems};
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
  const countOnly = process.argv[2] === '--count';
  const specFile = countOnly ? process.argv[3] : process.argv[2];
  let markdownText;
  try {
    markdownText = readFileSync(specFile, 'utf8');
  } catch (error) {
    process.stderr.write(`behaviors: cannot read ${specFile}: ${error.message}\n`);
    process.exit(2);
  }
  if (countOnly) {
    process.stdout.write(`${parseBehaviors(markdownText).behaviors.length}\n`);
    process.exit(0);
  }
  for (const problem of parseBehaviors(markdownText).problems) {
    process.stdout.write(`${problem}\n`);
  }
}
