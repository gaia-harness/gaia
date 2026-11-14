// Source inspection of one located test for the drift check: whether it is a
// test that counts. A skipped, todo, fixme or conditionally skipped test, or
// one with an empty body, is no test (`.claude/doctrine/testing.md`,
// `## Honesty`), and a row naming a parameterized test needs its own case in
// the test's case table.
//
// `test` is one record of .gaia/scripts/test-signals/extract-test-signals.mjs
// (its `ranges` locate the call). `entry` is one parsed file:
// {sourceFile, isStories, calls: null} for TypeScript, {lines} for bats.

import {createRequire} from 'node:module';

let ts = null;
try {
  ts = createRequire(import.meta.url)('typescript');
} catch {
  ts = null;
}

export const typescriptModule = () => ts;

// skipIf and runIf are conditional skips: a test that may not run proves
// nothing about the run that skipped it.
const SKIP_PROPERTIES = new Set(['skip', 'todo', 'fixme', 'skipIf', 'runIf']);
const SKIP_ROOTS = new Set(['xit', 'xtest', 'xdescribe']);
const STRUCTURAL_ROOTS = new Set(['test', 'it', 'describe', 'suite']);
const TABLE_PROPERTIES = new Set(['each', 'for']);

const lineAt = (entry, position) =>
  entry.sourceFile.getLineAndCharacterOfPosition(position).line + 1;

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

// The call expression whose lines are the test's own region: the first range
// for a test, the last for a story entry (its earlier ranges are the story).
function locateCall(entry, test) {
  const region = entry.isStories ? test.ranges[test.ranges.length - 1] : test.ranges[0];
  return (
    callsOf(entry).find(
      (node) =>
        lineAt(entry, node.getStart(entry.sourceFile)) === region[0] &&
        lineAt(entry, node.getEnd() - 1) === region[1],
    ) ?? null
  );
}

export function isSkipped(entry, test) {
  const call = locateCall(entry, test);
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
  // A test.skip(...) or test.fixme(...) in the body skips the test, with or
  // without a condition argument.
  let bodySkips = false;
  const scan = (node) => {
    if (ts.isCallExpression(node) && node !== call) {
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

// True when the test call has no callback, or its callback has no statement.
// An expression-bodied arrow (`() => expect(x)`) is a body.
export function hasEmptyBody(entry, test) {
  const call = locateCall(entry, test);
  if (!call) return false;
  const callback = [...call.arguments].reverse().find((argument) => ts.isFunctionLike(argument));
  if (!callback || !callback.body) return true;
  return ts.isBlock(callback.body) && callback.body.statements.length === 0;
}

// Every string literal in the `.each`/`.for` tables of the test's own call and
// of each enclosing call (a `describe.each` table), as a Set.
export function caseTableLiterals(entry, test) {
  const literals = new Set();
  const collect = (node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) literals.add(node.text);
    ts.forEachChild(node, collect);
  };
  const scanCallee = (call) => {
    let expression = call.expression;
    for (;;) {
      if (ts.isCallExpression(expression)) {
        if (ts.isPropertyAccessExpression(expression.expression) && TABLE_PROPERTIES.has(expression.expression.name.text)) {
          expression.arguments.forEach(collect);
        }
        expression = expression.expression;
      } else if (ts.isTaggedTemplateExpression(expression)) {
        if (ts.isPropertyAccessExpression(expression.tag) && TABLE_PROPERTIES.has(expression.tag.name.text)) {
          collect(expression.template);
        }
        expression = expression.tag;
      } else if (ts.isPropertyAccessExpression(expression)) {
        expression = expression.expression;
      } else {
        break;
      }
    }
  };
  for (let node = locateCall(entry, test); node; node = node.parent) {
    if (ts.isCallExpression(node)) scanCallee(node);
  }
  return literals;
}

// Bats ------------------------------------------------------------------------

// The lines between a block's `{` and its closing `}`; a one-line block's text
// between its first `{` and its last `}`.
function batsBody(entry, test) {
  const [start, end] = test.ranges[0];
  if (start === end) {
    const line = entry.lines[start - 1] ?? '';
    return [line.slice(line.indexOf('{') + 1, line.lastIndexOf('}'))];
  }
  return entry.lines.slice(start, end - 1);
}

// `skip` as a command word: at a line start, or after `;`, `&&`, `||`, `{`,
// `then` or `do`, so a conditional `[ ... ] && skip` counts too.
const BATS_SKIP = /(?:^|[;&|{]|\bthen|\bdo)\s*skip(?:\s|;|$)/;

export const batsSkipped = (entry, test) => batsBody(entry, test).some((line) => BATS_SKIP.test(line));

export const batsEmpty = (entry, test) =>
  batsBody(entry, test).every((line) => line.trim() === '' || line.trim().startsWith('#'));
