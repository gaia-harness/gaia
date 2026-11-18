// File and argument loading plus the line, destination and requirements
// lookups behind drop-check.mjs, which owns the format and rules they serve.

import {readdirSync, readFileSync} from 'node:fs';
import {basename, join} from 'node:path';
import {normalizeWhitespace, parseBehaviors} from './behaviors.mjs';

const REQUIREMENTS_NAME = 'REQUIREMENTS.md';

export class UsageError extends Error {}

export function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    throw new UsageError(`cannot read ${path}`);
  }
}

export const wordCount = (text) => (text ? text.split(' ').length : 0);

export function findingIdsIn(directory) {
  let names;
  try {
    names = readdirSync(directory).sort();
  } catch {
    throw new UsageError(`cannot read directory ${directory}`);
  }
  const ids = [];
  for (const name of names) {
    if (!name.endsWith('.json') || name === 'fixes.json') continue;
    let parsed;
    try {
      parsed = JSON.parse(readText(join(directory, name)));
    } catch (error) {
      if (error instanceof UsageError) throw error;
      throw new UsageError(`${join(directory, name)} is not valid JSON`);
    }
    for (const finding of parsed?.findings ?? []) ids.push(finding.id);
  }
  return ids;
}

export function markdownFilesIn(directory) {
  try {
    return readdirSync(directory).filter((name) => name.endsWith('.md'));
  } catch {
    throw new UsageError(`cannot read directory ${directory}`);
  }
}

// Each compared line of a SPEC file: the behavior lines and case lines.
function behaviorSentences(markdownText) {
  const {behaviors} = parseBehaviors(markdownText);
  const sentences = [];
  for (const behavior of behaviors) {
    sentences.push(`- **${behavior.id}** (${behavior.kind}): ${behavior.text}`);
    for (const caseText of behavior.cases) sentences.push(`- Case: ${caseText}`);
  }
  return sentences;
}

// Each bullet (wrapped lines joined) under `## Acceptance criteria`.
function acceptanceBullets(markdownText) {
  const bullets = [];
  let inSection = false;
  let inFence = false;
  for (const line of markdownText.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
    if (inFence) continue;
    if (/^## /.test(line)) {
      inSection = /^## Acceptance criteria\s*$/i.test(line);
      continue;
    }
    if (!inSection) continue;
    if (/^\s*[-*] /.test(line)) bullets.push(line);
    else if (/^\s+\S/.test(line) && bullets.length > 0) {
      bullets[bullets.length - 1] += ` ${line}`;
    }
  }
  return bullets.map(normalizeWhitespace);
}

// Each `<file name>: <bullet>` of the acceptance criteria of a plan directory.
function planBullets(directory) {
  return markdownFilesIn(directory).flatMap((name) =>
    acceptanceBullets(readText(join(directory, name))).map(
      (bullet) => `${name}: ${bullet}`,
    ),
  );
}

export function comparedLines(options) {
  if (options.mode === 'spec') {
    return {
      pre: behaviorSentences(readText(options.pre)),
      post: new Set(behaviorSentences(readText(options.post))),
    };
  }
  return {
    pre: planBullets(options.pre),
    post: new Set(planBullets(options.post)),
  };
}

export function destinationFiles(options) {
  const files = [];
  if (options.mode === 'spec') {
    if (options.dest.length > 0) files.push(...options.dest);
    else files.push(options.post);
  } else {
    for (const name of markdownFilesIn(options.post)) {
      if (name === 'README.md' || /^task-.*\.md$/.test(name)) {
        files.push(join(options.post, name));
      }
    }
    files.push(...options.dest);
  }
  const byBasename = new Map();
  for (const file of files) {
    const name = basename(file);
    if (name !== REQUIREMENTS_NAME && !byBasename.has(name)) {
      byBasename.set(name, file);
    }
  }
  // The review fixer writes a SPEC's destination as SPEC.md whatever the
  // draft file is called, so that name always reaches the --post file.
  if (options.mode === 'spec' && !byBasename.has('SPEC.md')) {
    byBasename.set('SPEC.md', options.post);
  }
  return byBasename;
}

// How many cases (spec mode, keyed by behavior id) or acceptance bullets
// (plan mode, keyed by file name) the fix removed beyond any it replaced. A
// reworded case is a removal plus an addition and nets to zero.
export function removedCounts(options) {
  const counts = new Map();
  const add = (key, removed, added) => {
    const net = removed - added;
    if (net > 0) counts.set(key, net);
  };
  if (options.mode === 'spec') {
    const post = new Map(
      parseBehaviors(readText(options.post)).behaviors.map((behavior) => [
        behavior.id,
        behavior.cases,
      ]),
    );
    for (const behavior of parseBehaviors(readText(options.pre)).behaviors) {
      const after = post.get(behavior.id) ?? [];
      add(
        behavior.id,
        behavior.cases.filter((text) => !after.includes(text)).length,
        after.filter((text) => !behavior.cases.includes(text)).length,
      );
    }
    return counts;
  }
  for (const name of markdownFilesIn(options.pre)) {
    const before = acceptanceBullets(readText(join(options.pre, name)));
    let after = [];
    try {
      after = acceptanceBullets(readText(join(options.post, name)));
    } catch (error) {
      if (!(error instanceof UsageError)) throw error;
    }
    add(
      name,
      before.filter((text) => !after.includes(text)).length,
      after.filter((text) => !before.includes(text)).length,
    );
  }
  return counts;
}

// The sections of a REQUIREMENTS.md: each heading's pointer key and the
// normalized text under it, up to the next heading of any level.
function requirementSections(markdownText) {
  const sections = [];
  let current = null;
  for (const line of markdownText.split('\n')) {
    const heading = /^#{1,6} (.+?)\s*$/.exec(line);
    if (heading) {
      const text = heading[1].trim();
      const questionKey = /^(Q\d+)\./.exec(text);
      current = {key: questionKey ? questionKey[1] : text, body: ''};
      sections.push(current);
    } else if (current) {
      current.body += ` ${line}`;
    }
  }
  return sections.map((section) => ({
    key: section.key,
    body: normalizeWhitespace(section.body),
  }));
}

function specPointsTo(specText, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`REQUIREMENTS\\.md § ${escaped}(?![A-Za-z0-9])`).test(
    normalizeWhitespace(specText),
  );
}

export function requirementsHold(fragment, requirementsText, specText) {
  if (!requirementsText || !specText) return false;
  return requirementSections(requirementsText).some(
    (section) =>
      section.body.includes(fragment) && specPointsTo(specText, section.key),
  );
}

// The normalized text of the SPEC frontmatter's clarifications.deferred list.
export function deferredText(specText) {
  const frontmatter = /^---\n([\s\S]*?)\n---/.exec(specText);
  if (!frontmatter) return '';
  const lines = frontmatter[1].split('\n');
  const start = lines.findIndex((line) => /^\s*deferred:/.test(line));
  if (start === -1) return '';
  const indent = lines[start].match(/^\s*/)[0].length;
  let collected = lines[start].replace(/^\s*deferred:/, '');
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const lineIndent = line.match(/^\s*/)[0].length;
    const belongs =
      line.trim() === '' ||
      lineIndent > indent ||
      (lineIndent === indent && /^\s*- /.test(line));
    if (!belongs) break;
    collected += ` ${line}`;
  }
  return normalizeWhitespace(collected);
}

export function behaviorKinds(texts) {
  const kinds = new Map();
  for (const text of texts) {
    for (const behavior of parseBehaviors(text).behaviors) {
      if (!kinds.has(behavior.id)) kinds.set(behavior.id, behavior.kind);
    }
  }
  return kinds;
}
