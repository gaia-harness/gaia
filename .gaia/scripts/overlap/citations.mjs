// Citation resolvers for the overlap check: finding a test by its fullName,
// proving a cited assertion line, and the source facts both lean on (the
// comment mask, the hook spans a per-test layer reads). check-proposals.mjs
// owns the file cache, the layer table and the verdicts; every function here
// reads an entry it loaded.
//
// A test is found two ways. The signal extractor reports every test whose
// title is a plain string. It skips a title with substitutions, such as one
// test per row of a `for` loop, and every title a `.each` or `.for` table
// expands, so those are found here by matching the cited fullName against the
// title's static parts, each substitution or table token standing for the
// text it prints, under enclosing describe titles that are static or
// table-expanded themselves.
//
// A cited line that only calls a helper is an assertion only when the helper
// asserts. The check follows a helper defined in the cited file (a function
// declaration, a const bound to a function, or a function-valued property of
// a const object) and refuses the citation when its body holds no expect()
// call. In a rendered test (contract marker on line 1) any cited in-file
// helper call is refused, since a rendered test's assertions belong in its own
// body. Honest limit: a helper imported from another module is not followed,
// so a call to one verifies as any other cited text does. A cited line that
// itself calls expect is an assertion and is never treated as a helper call.

import {createRequire} from 'node:module';
import {isSkipped} from './test-inspection.mjs';

// check-proposals.mjs reports a missing "typescript" with its own exit code
// before any function here runs, so a failed resolve is left unset.
let ts = null;
try {
  ts = createRequire(import.meta.url)('typescript');
} catch {
  ts = null;
}

const MARKER = /^\/\/ gaia-uat-contract sha256:/;
export const isRendered = (entry) => MARKER.test(entry?.rawLines[0] ?? '');

const lineAt = (entry, position) => entry.sourceFile.getLineAndCharacterOfPosition(position).line + 1;
const rangesHold = (test, line) => test.ranges.some(([start, end]) => start <= line && line <= end);
const collapse = (text) => text.replace(/\s+/g, ' ').trim();
const holdsText = (line, needle) => line !== undefined && (line.includes(needle) || collapse(line).includes(collapse(needle)));

// Comments --------------------------------------------------------------------

function commentSpansOf(sourceFile, source) {
  const raw = [];
  const walkTokens = (node) => {
    const children = node.getChildren(sourceFile);
    if (children.length === 0) {
      for (const range of ts.getLeadingCommentRanges(source, node.getFullStart()) ?? []) raw.push([range.pos, range.end]);
      for (const range of ts.getTrailingCommentRanges(source, node.getEnd()) ?? []) raw.push([range.pos, range.end]);
      return;
    }
    for (const child of children) walkTokens(child);
  };
  walkTokens(sourceFile);
  // JSX text that looks like a comment is not one.
  const jsxText = [];
  const findJsxText = (node) => {
    if (node.kind === ts.SyntaxKind.JsxText) jsxText.push([node.pos, node.end]);
    ts.forEachChild(node, findJsxText);
  };
  ts.forEachChild(sourceFile, findJsxText);
  return raw.filter(([a, b]) => !jsxText.some(([x, y]) => a < y && x < b));
}

/** The source with every comment character blanked, line breaks kept. */
export function maskComments(sourceFile, source) {
  let masked = '';
  let cursor = 0;
  for (const [a, b] of [...commentSpansOf(sourceFile, source)].sort((p, q) => p[0] - q[0])) {
    if (a < cursor) continue;
    masked += source.slice(cursor, a) + source.slice(a, b).replace(/[^\n]/g, ' ');
    cursor = b;
  }
  return masked + source.slice(cursor);
}

// Hooks -----------------------------------------------------------------------

const HOOK_NAMES = new Set(['beforeEach', 'beforeAll', 'afterEach', 'afterAll']);

// Line spans of the file's hook calls: a page a hook opens is opened for the
// tests around it, so it counts against every test in the file.
export function hookSpansOf(entry) {
  const spans = [];
  const visit = (node) => {
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const name = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : null;
      if (HOOK_NAMES.has(name)) spans.push([lineAt(entry, node.getStart(entry.sourceFile)), lineAt(entry, node.getEnd() - 1)]);
    }
    ts.forEachChild(node, visit);
  };
  visit(entry.sourceFile);
  return spans;
}

// Templated titles ------------------------------------------------------------

function calleeParts(call) {
  let expression = call.expression;
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

// Mirrors the extractor's block kinds, so a describe here is a describe there.
function blockKindOf(call) {
  const {root, properties} = calleeParts(call);
  if (root === 'describe' || root === 'suite') return 'describe';
  if (root === 'test' || root === 'it') return properties.includes('describe') ? 'describe' : 'test';
  return null;
}

const escapeForPattern = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Vitest's .each/.for title tokens: printf tokens take a row value, %c takes
// one and prints nothing, %% prints %, %# prints the row index and %$ the
// index plus one, and $key or $key.path (or $0 for an array row) print a
// property. Honest limit: a $key token is a wildcard here even when the rows
// are arrays, where vitest prints it literally, so such a title also verifies
// names no row prints.
const TABLE_TOKEN = /%%|%#|%\$|%c|%[sdjifoO]|\$[$\p{ID_Continue}.]+/gu;
const TABLE_TOKEN_PATTERN = {'%%': '%', '%c': '', '%#': '\\d+', '%$': '\\d+'};

function tableTitlePattern(text) {
  let pattern = '';
  let cursor = 0;
  for (const match of text.matchAll(TABLE_TOKEN)) {
    pattern += escapeForPattern(text.slice(cursor, match.index)) + (TABLE_TOKEN_PATTERN[match[0]] ?? '(?:.+)');
    cursor = match.index + match[0].length;
  }
  return pattern + escapeForPattern(text.slice(cursor));
}

function titlePartsOf(title) {
  if (title === undefined) return null;
  if (ts.isStringLiteral(title) || ts.isNoSubstitutionTemplateLiteral(title)) return [title.text];
  if (ts.isTemplateExpression(title)) return [title.head.text, ...title.templateSpans.map((span) => span.literal.text)];
  return null;
}

// ancestors holds each enclosing describe title as pattern source. A test is
// collected here only when the extractor skips it: its title has
// substitutions, it is a .each or .for test, or an enclosing describe expands
// per row.
function templatedTestsOf(entry) {
  if (entry.templated !== undefined) return entry.templated;
  const found = [];
  const visit = (node, ancestors, unmatchable, expanded) => {
    const kind = ts.isCallExpression(node) ? blockKindOf(node) : null;
    if (kind !== null) {
      const {properties} = calleeParts(node);
      const expands = properties.includes('each') || properties.includes('for');
      const title = node.arguments[0];
      const parts = titlePartsOf(title);
      const toPattern = expands ? tableTitlePattern : escapeForPattern;
      if (kind === 'test') {
        if (!unmatchable && parts !== null && (expands || expanded || parts.length > 1)) {
          const prefix = ancestors.map((ancestor) => `${ancestor} `).join('');
          found.push({
            pattern: new RegExp(`^${prefix}${parts.map(toPattern).join('(?:.+)')}$`, 's'),
            ranges: [[lineAt(entry, node.getStart(entry.sourceFile)), lineAt(entry, node.getEnd() - 1)]],
          });
        }
        ts.forEachChild(node, (child) => visit(child, ancestors, unmatchable, expanded));
        return;
      }
      if (kind === 'describe') {
        if (title !== undefined && ts.isFunctionLike(title)) {
          ts.forEachChild(node, (child) => visit(child, ancestors, unmatchable, expanded));
          return;
        }
        const matchable = parts !== null && (expands || parts.length === 1);
        const next = matchable ? [...ancestors, parts.map(toPattern).join('(?:.+)')] : ancestors;
        ts.forEachChild(node, (child) => visit(child, next, unmatchable || !matchable, expanded || expands));
        return;
      }
    }
    ts.forEachChild(node, (child) => visit(child, ancestors, unmatchable, expanded));
  };
  visit(entry.sourceFile, [], false, false);
  entry.templated = found;
  return found;
}

/** Every test in the entry whose fullName is the given one, templated titles included. */
export function locateTests(entry, fullName) {
  if (!entry) return [];
  const named = (entry.tests ?? []).filter((test) => test.fullName === fullName);
  const templated = templatedTestsOf(entry)
    .filter((test) => test.pattern.test(fullName))
    .map((test) => ({fullName, ranges: test.ranges}));
  return [...named, ...templated];
}

// Helper calls ----------------------------------------------------------------

const isFunctionNode = (node) => node !== undefined && (ts.isArrowFunction(node) || ts.isFunctionExpression(node));

function callsExpect(node) {
  let found = false;
  const visit = (child) => {
    if (found) return;
    if (ts.isCallExpression(child) && calleeParts(child).root === 'expect') {
      found = true;
      return;
    }
    ts.forEachChild(child, visit);
  };
  visit(node);
  return found;
}

// name (or `object.property`) -> whether the helper's body calls expect.
function helpersOf(entry) {
  if (entry.helpers !== undefined) return entry.helpers;
  const helpers = new Map();
  const visit = (node) => {
    if (ts.isFunctionDeclaration(node) && node.name && node.body) {
      helpers.set(node.name.text, callsExpect(node.body));
    } else if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      const owner = node.name.text;
      if (isFunctionNode(node.initializer)) {
        helpers.set(owner, callsExpect(node.initializer.body));
      } else if (ts.isObjectLiteralExpression(node.initializer)) {
        for (const property of node.initializer.properties) {
          const key = property.name && (ts.isIdentifier(property.name) || ts.isStringLiteral(property.name)) ? property.name.text : null;
          if (key === null) continue;
          if (ts.isMethodDeclaration(property) && property.body) helpers.set(`${owner}.${key}`, callsExpect(property.body));
          else if (ts.isPropertyAssignment(property) && isFunctionNode(property.initializer)) {
            helpers.set(`${owner}.${key}`, callsExpect(property.initializer.body));
          }
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(entry.sourceFile);
  entry.helpers = helpers;
  return helpers;
}

function calledHelperName(call) {
  const callee = call.expression;
  if (ts.isIdentifier(callee)) return callee.text;
  if (ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression)) {
    return `${callee.expression.text}.${callee.name.text}`;
  }
  return null;
}

// True when the line is a call to an in-file helper that does not count as an
// assertion: one whose body holds no expect(), or any in-file helper in a
// rendered test. A line that itself calls expect is never refused here.
function helperCallRefused(entry, line) {
  const helpers = helpersOf(entry);
  if (helpers.size === 0) return false;
  const onLine = [];
  const visit = (node) => {
    if (ts.isCallExpression(node) && lineAt(entry, node.getStart(entry.sourceFile)) === line) onLine.push(node);
    ts.forEachChild(node, visit);
  };
  visit(entry.sourceFile);
  if (onLine.some((call) => calleeParts(call).root === 'expect')) return false;
  const rendered = isRendered(entry);
  return onLine.some((call) => {
    const name = calledHelperName(call);
    return name !== null && helpers.has(name) && (rendered || !helpers.get(name));
  });
}

// Verification ----------------------------------------------------------------

/**
 * Verifies a {fullName, line, assertion} citation in a loaded entry. Returns
 * {reason, test}: reason null and the matched test when verified, else the
 * discard reason. postFix looks for the text anywhere in the named test, since
 * a same-file edit may have moved the recorded line.
 */
export function verifyCitation(entry, citation, postFix) {
  const candidates = locateTests(entry, citation.fullName);
  if (candidates.length === 0) return {reason: 'citation-unverified', test: null};
  const needle = citation.assertion;
  if (!postFix) {
    if (!holdsText(entry.rawLines[citation.line - 1], needle)) return {reason: 'citation-unverified', test: null};
    if (!holdsText(entry.maskedLines[citation.line - 1], needle)) return {reason: 'citation-not-live', test: null};
    const test = candidates.find((candidate) => rangesHold(candidate, citation.line));
    if (!test) return {reason: 'citation-unverified', test: null};
    if (isSkipped(entry, test)) return {reason: 'citation-not-live', test: null};
    if (helperCallRefused(entry, citation.line)) return {reason: 'citation-unverified', test: null};
    return {reason: null, test};
  }
  let notLive = false;
  for (const test of candidates) {
    for (const [start, end] of test.ranges) {
      for (let line = start; line <= end; line += 1) {
        if (holdsText(entry.maskedLines[line - 1], needle)) {
          if (isSkipped(entry, test)) notLive = true;
          else if (!helperCallRefused(entry, line)) return {reason: null, test};
        } else if (holdsText(entry.rawLines[line - 1], needle)) {
          notLive = true;
        }
      }
    }
  }
  return {reason: notLive ? 'citation-not-live' : 'citation-unverified', test: null};
}
