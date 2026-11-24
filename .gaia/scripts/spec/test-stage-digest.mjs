// The test stage's digest builder: writes, verbatim and with no model in the
// loop, the parts of a plan the test-stage lens needs, so the lens reads one
// small file instead of re-reading the plan from a cold cache. Called by
// `test-stage-check.mjs --plan-dir <dir> [--spec <SPEC.md>] --digest <path>`,
// which prints the sha256 of the written file. Owner of the heading patterns
// and `sectionLines` the coverage check also uses.
//
// Format: each section opens with one line
//
//   <!-- gaia:digest-section <absolute source path> -->
//
// then the source text verbatim. Spec-derived order: the SPEC's `## Behaviors`
// section (heading through the line before the next `## ` heading); the SPEC
// frontmatter's `flows:` key (its line through the line before the next
// top-level key); then, for each `task-*.md` of the plan folder in sorted
// order, the whole doc when it carries a `- Flow test (` line, else its
// `## Tests` section (a doc with no such heading gives none); then
// ORCHESTRATOR.md's closing phase entry, the `**Phase <N>, ` entry with the
// highest N outside code fences, through the line before the next `**Phase `
// or `## ` line outside a fence (the extent `plan-verify-lib.sh` `phase_entry`
// reads). Spec-less order: for each task doc, its `## Acceptance criteria`
// section, then its `## Tests` section; no SPEC, flow or closing-phase section.
//
// Refusal: a source line that starts, after leading whitespace, with
// `<!-- gaia:digest-section` would forge a delimiter, so the digest is refused,
// naming the file, and no file is left behind. The output is written to a
// temporary file beside it and renamed.

import {createHash} from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';

export const TESTS_HEADING = /^## Tests\s*$/;
export const CRITERIA_HEADING = /^## Acceptance criteria\s*$/;
export const ANY_HEADING = /^## /;
export const FLOW_TEST_LINE = /^\s*- Flow test \(([^)]*)\): (.*)$/;

const BEHAVIORS_HEADING = /^## Behaviors\s*$/;
const DELIMITER_PREFIX = '<!-- gaia:digest-section';
const FENCE_LINE = /^```/;

export class DigestRefusal extends Error {}

// The lines of one `##` section, between its heading and the next.
export function sectionLines(text, headingPattern) {
  const collected = [];
  let inSection = false;
  for (const line of text.split('\n')) {
    const clean = line.replace(/\r$/, '');
    if (headingPattern.test(clean)) {
      inSection = true;
      continue;
    }
    if (inSection && ANY_HEADING.test(clean)) break;
    if (inSection) collected.push(clean);
  }
  return collected;
}

// The same section with its heading, every line as it stands in the source.
function rawSection(text, headingPattern) {
  const collected = [];
  let inSection = false;
  for (const line of text.split('\n')) {
    const clean = line.replace(/\r$/, '');
    if (headingPattern.test(clean)) {
      inSection = true;
      collected.push(line);
      continue;
    }
    if (inSection && ANY_HEADING.test(clean)) break;
    if (inSection) collected.push(line);
  }
  return collected;
}

// The frontmatter's `flows:` key, through the line before the next top-level key.
function flowsKeyLines(specText) {
  const lines = specText.split('\n');
  if (lines[0].replace(/\r$/, '') !== '---') return [];
  const collected = [];
  let inFlows = false;
  for (const line of lines.slice(1)) {
    const clean = line.replace(/\r$/, '');
    if (clean === '---') break;
    if (/^flows:/.test(clean)) inFlows = true;
    else if (inFlows && /^[A-Za-z_][\w-]*:/.test(clean)) break;
    if (inFlows) collected.push(line);
  }
  return collected;
}

// The highest-numbered phase entry, fence-aware like `phase_entry`.
function closingPhaseLines(orchestratorText) {
  const lines = orchestratorText.split('\n');
  let inFence = false;
  let closing = null;
  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (FENCE_LINE.test(trimmed)) {
      inFence = !inFence;
      return;
    }
    const match = inFence ? null : /^\*\*Phase ([0-9]+), /.exec(trimmed);
    if (match && (!closing || Number(match[1]) > closing.number)) {
      closing = {index, number: Number(match[1])};
    }
  });
  if (!closing) return [];
  const collected = [lines[closing.index]];
  inFence = false;
  for (const line of lines.slice(closing.index + 1)) {
    const trimmed = line.trim();
    if (FENCE_LINE.test(trimmed)) inFence = !inFence;
    else if (!inFence && (/^\*\*Phase /.test(trimmed) || /^## /.test(trimmed))) {
      break;
    }
    collected.push(line);
  }
  return collected;
}

function readSource(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    throw new Error(`cannot read ${file}`);
  }
}

function refuseForgedDelimiter(file, lines) {
  if (lines.some((line) => line.trimStart().startsWith(DELIMITER_PREFIX))) {
    throw new DigestRefusal(
      `${file} holds a line that starts a digest section delimiter`,
    );
  }
}

// Writes the digest to `output` and returns its sha256 hex digest. Throws a
// DigestRefusal for a refused source, an Error for an unreadable one.
export function writeDigest({planDir, spec, output}) {
  const sections = [];
  const add = (file, lines) => {
    if (lines.length === 0) return;
    refuseForgedDelimiter(file, lines);
    sections.push(`${DELIMITER_PREFIX} ${file} -->\n${lines.join('\n')}\n`);
  };

  const specFile = spec ? path.resolve(spec) : null;
  if (specFile) {
    const specText = readSource(specFile);
    add(specFile, rawSection(specText, BEHAVIORS_HEADING));
    add(specFile, flowsKeyLines(specText));
  }

  const taskFiles = readdirSync(planDir)
    .filter((name) => /^task-.*\.md$/.test(name))
    .sort();
  for (const name of taskFiles) {
    const file = path.resolve(planDir, name);
    const text = readSource(file);
    const lines = text.split('\n');
    refuseForgedDelimiter(file, lines);
    if (!specFile) {
      add(file, rawSection(text, CRITERIA_HEADING));
      add(file, rawSection(text, TESTS_HEADING));
    } else if (
      lines.some((line) => FLOW_TEST_LINE.test(line.replace(/\r$/, '')))
    ) {
      add(file, text.endsWith('\n') ? lines.slice(0, -1) : lines);
    } else {
      add(file, rawSection(text, TESTS_HEADING));
    }
  }

  const orchestrator = path.resolve(planDir, 'ORCHESTRATOR.md');
  if (specFile && existsSync(orchestrator)) {
    add(orchestrator, closingPhaseLines(readSource(orchestrator)));
  }

  const content = sections.join('');
  const temporary = `${output}.tmp-${process.pid}`;
  try {
    mkdirSync(path.dirname(output), {recursive: true});
    writeFileSync(temporary, content);
    renameSync(temporary, output);
  } catch (error) {
    rmSync(temporary, {force: true});
    throw new Error(`cannot write ${output}: ${error.message}`);
  }
  return createHash('sha256').update(content).digest('hex');
}
