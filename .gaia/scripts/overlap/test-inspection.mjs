// Source inspection for the overlap check: whether a located test is skipped,
// and whether its subject touches a seam (a boundary where the lowest layer
// is not enough). check-proposals.mjs owns the file cache and the verdicts;
// everything here reads an already loaded entry.

import {createRequire} from 'node:module';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';

// check-proposals.mjs reports a missing "typescript" with its own exit code
// before any function here runs, so a failed resolve is left unset.
let ts = null;
try {
  ts = createRequire(import.meta.url)('typescript');
} catch {
  ts = null;
}

// Seams -----------------------------------------------------------------------

const BUILT_IN_STEMS = [
  'auth', 'session', 'login', 'permission', 'role', 'owner', 'forbid', 'refus',
  'deny', 'deni', 'hide', 'hid', 'hidden', 'forg', 'csrf', 'escap', 'sanitiz',
  'inject', 'transaction', 'integrity',
];
const REFUSAL_STATUS_WORDS = new Set(['401', '403', '404']);
const REFUSAL_HELPER_NAME =
  /refus|deny|deni|forbid|notfound|not_found|unauthori[sz]ed|unauthenticated/i;
const BY_ROLE_CALL = /^(get|query|find)(All)?ByRole$/;

const wordsOf = (text) =>
  text
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter((word) => word.length > 0)
    .map((word) => word.toLowerCase());

// A project word list only ever adds to the built-in stems.
export const loadStems = (root) => {
  const stems = [...BUILT_IN_STEMS];
  const extra = path.join(root, '.gaia', 'overlap-seams.txt');
  if (existsSync(extra)) {
    for (const line of readFileSync(extra, 'utf8').split('\n')) {
      const word = line.trim().toLowerCase();
      if (word.length > 0 && !word.startsWith('#')) stems.push(word);
    }
  }
  return stems;
};

const wordsHitSeam = (words, stems) =>
  words.some((word) => REFUSAL_STATUS_WORDS.has(word) || stems.some((stem) => word.includes(stem))) ||
  /\bnot found\b/.test(words.join(' '));

export const pathIsSeam = (file) => /auth|session/i.test(file);
const lineAt = (entry, position) => entry.sourceFile.getLineAndCharacterOfPosition(position).line + 1;

// Skips -----------------------------------------------------------------------

const SKIP_PROPERTIES = new Set(['skip', 'todo', 'fixme']);
const SKIP_ROOTS = new Set(['xit', 'xtest', 'xdescribe']);
const STRUCTURAL_ROOTS = new Set(['test', 'it', 'describe', 'suite']);

function calleeShape(node) {
  let expression = node.expression;
  for (;;) {
    if (ts.isCallExpression(expression)) expression = expression.expression;
    else if (ts.isTaggedTemplateExpression(expression)) expression = expression.tag;
    else break;
  }
  const properties = [];
  while (ts.isPropertyAccessExpression(expression)) {
    properties.push(expression.name.text);
    expression = expression.expression;
  }
  return {root: ts.isIdentifier(expression) ? expression.text : null, properties};
}

const callsOf = (entry) => {
  if (entry.calls === null) {
    entry.calls = [];
    const collect = (node) => {
      if (ts.isCallExpression(node)) entry.calls.push(node);
      ts.forEachChild(node, collect);
    };
    collect(entry.sourceFile);
  }
  return entry.calls;
};

export function isSkipped(entry, test) {
  const region = entry.isStories ? test.ranges[test.ranges.length - 1] : test.ranges[0];
  const call = callsOf(entry).find(
    (node) =>
      lineAt(entry, node.getStart(entry.sourceFile)) === region[0] && lineAt(entry, node.getEnd() - 1) === region[1],
  );
  if (!call) return false;
  const own = calleeShape(call);
  if (SKIP_ROOTS.has(own.root)) return true;
  if (own.properties.some((name) => SKIP_PROPERTIES.has(name)) && (STRUCTURAL_ROOTS.has(own.root) || own.properties.includes('test'))) {
    return true;
  }
  for (let ancestor = call.parent; ancestor; ancestor = ancestor.parent) {
    if (!ts.isCallExpression(ancestor)) continue;
    const shape = calleeShape(ancestor);
    if (SKIP_ROOTS.has(shape.root)) return true;
    if (STRUCTURAL_ROOTS.has(shape.root) && shape.properties.some((name) => SKIP_PROPERTIES.has(name))) return true;
  }
  // An unconditional test.skip() or test.fixme() in the body skips the test.
  let bodySkips = false;
  const scan = (node) => {
    if (ts.isCallExpression(node) && node !== call && node.arguments.length === 0) {
      const shape = calleeShape(node);
      if (shape.root === 'test' && shape.properties.length === 1 && ['skip', 'fixme'].includes(shape.properties[0])) {
        bodySkips = true;
      }
    }
    ts.forEachChild(node, scan);
  };
  scan(call);
  return bodySkips;
}

// Subject seam scan -----------------------------------------------------------

export function subjectIsSeam(entry, test, stems) {
  const found = [];
  let helperHit = false;
  const inside = (node) => {
    const line = lineAt(entry, node.getStart(entry.sourceFile));
    return test.ranges.some(([start, end]) => start <= line && line <= end);
  };
  const visit = (node) => {
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const name = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : null;
      // getByRole('button', {name}) names an accessibility role, not a
      // permission: drop the call with its arguments, keep what it hangs off.
      if (name !== null && BY_ROLE_CALL.test(name)) {
        if (ts.isPropertyAccessExpression(callee)) visit(callee.expression);
        return;
      }
      if (name !== null && inside(node) && REFUSAL_HELPER_NAME.test(name)) helperHit = true;
    }
    const textual =
      ts.isIdentifier(node) ||
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      ts.isNumericLiteral(node) ||
      node.kind === ts.SyntaxKind.TemplateHead ||
      node.kind === ts.SyntaxKind.TemplateMiddle ||
      node.kind === ts.SyntaxKind.TemplateTail;
    if (textual && inside(node)) found.push(node.text);
    ts.forEachChild(node, visit);
  };
  visit(entry.sourceFile);
  const words = [...wordsOf(test.fullName), ...found.flatMap(wordsOf)];
  return helperHit || wordsHitSeam(words, stems);
}
