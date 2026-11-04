#!/usr/bin/env node
// The one definition of "this Playwright file opens a browser page".
//
// A real-server test drives the running server through the `request` fixture
// and opens no page; a browser test opens one. Two places need that line drawn
// the same way: the UAT gate's no-page check on a rendered real-server test
// and the overlap check's layer map (a spec that opens no page is on the
// real-server layer). This module is
// that definition. It reads the file's AST with the TypeScript compiler API, so
// words in a title, a string or a comment are never a use.
//
// A use is one of these reasons:
//   page-fixture          a test, hook (beforeEach, beforeAll, afterEach,
//                         afterAll) or test.extend fixture callback whose first
//                         parameter destructures `page`, `context` or `browser`,
//                         or reads `.page`, `.context` or `.browser` off a
//                         non-destructured first parameter
//   project-page-fixture  the first parameter destructures a page-backed project
//                         fixture: a name on PAGE_BACKED_FIXTURES
//                         (page-use-fixtures.mjs), or a test.extend fixture
//                         whose callback destructures page,
//                         context, browser or another page-backed fixture,
//                         defined in this file or in a module it imports `test`
//                         from by a relative path (followed through that
//                         module's own such imports). Never a name-suffix rule:
//                         `apiContext` built over `request` is not a use
//   new-page              `.newPage(` or `.newContext(` on any receiver except
//                         an identifier named `request` or `playwright.request`
//                         (those build an API context, not a page)
//   context-request       `context.request` or `.context().request`
//   browser-import        an import of chromium, firefox or webkit from
//                         `@playwright/test` or `playwright`
//
// Honest limit: a page opened inside an imported helper is caught only through
// the fixture the test hands the helper. A page-backed fixture is found in
// another module only through a relative import of `test`; one reached through
// a path alias or a package is caught only when its name is on
// PAGE_BACKED_FIXTURES, which must grow when the template adds one. An import
// that does not resolve to a readable file adds nothing, so the verdict falls
// back to this file alone.
//
// Callers: uat-gate.sh through uat-gate-floor.sh (the CLI) and
// overlap/check-proposals.mjs (the pageUsesOf export).
//
// Usage: node page-use.mjs <file>...
// Output: one line per use, `<file>\t<line>\t<test title or ->\t<reason>`.
// Exit: 0 no use, 1 a use, 2 usage, 3 unreadable file or no TypeScript.

import {createRequire} from 'node:module';
import {readFileSync, realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {
  BROWSER_FIXTURES,
  destructuredKeysOf,
  extendFixturesOf,
  isExtendCall,
  isFunctionNode,
  pageBackedFixturesOf,
} from './page-use-fixtures.mjs';

const HOOK_NAMES = new Set(['beforeEach', 'beforeAll', 'afterEach', 'afterAll']);
const BROWSER_LAUNCHERS = new Set(['chromium', 'firefox', 'webkit']);
const PLAYWRIGHT_MODULES = new Set(['@playwright/test', 'playwright']);

// The page uses in one parsed Playwright file. `filePath` locates it on disk
// for its relative imports: pass it when sourceFile.fileName is not a path
// from the current working directory.
export function pageUsesOf(ts, sourceFile, filePath = sourceFile.fileName) {
  const uses = [];
  const isFunction = (node) => isFunctionNode(ts, node);
  const lineOf = (node) =>
    sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;

  // The callee of a test( ... ) call: `test`, `it`, a bare hook, or a member
  // chain rooted at `test` (test.only, test.beforeEach) or ending in a hook.
  const isTestCallee = (callee) => {
    if (ts.isIdentifier(callee)) {
      return (
        callee.text === 'test' ||
        callee.text === 'it' ||
        HOOK_NAMES.has(callee.text)
      );
    }
    if (ts.isPropertyAccessExpression(callee)) {
      if (HOOK_NAMES.has(callee.name.text)) return true;
      let root = callee.expression;
      while (ts.isPropertyAccessExpression(root)) root = root.expression;
      return ts.isIdentifier(root) && (root.text === 'test' || root.text === 'it');
    }
    return false;
  };

  const fixtures = extendFixturesOf(ts, sourceFile);
  const testCallbacks = [];
  const visitCollect = (node) => {
    if (!isExtendCall(ts, node) && ts.isCallExpression(node) && isTestCallee(node.expression)) {
      for (const argument of node.arguments) {
        if (isFunction(argument)) testCallbacks.push({call: node, callback: argument});
      }
    }
    ts.forEachChild(node, visitCollect);
  };
  visitCollect(sourceFile);

  const pageBacked = pageBackedFixturesOf(ts, sourceFile, filePath, fixtures);

  const staticTitle = (call) => {
    const first = call.arguments[0];
    return first !== undefined && ts.isStringLiteralLike(first) ? first.text : null;
  };
  const record = (node, test, reason) =>
    uses.push({line: lineOf(node), reason, test});

  const analyze = (callback, test) => {
    const first = callback.parameters[0];
    if (first === undefined) return;
    if (ts.isObjectBindingPattern(first.name)) {
      for (const {element, key} of destructuredKeysOf(ts, callback)) {
        if (key === null) continue;
        if (BROWSER_FIXTURES.has(key)) record(element, test, 'page-fixture');
        else if (pageBacked.has(key)) record(element, test, 'project-page-fixture');
      }
    } else if (ts.isIdentifier(first.name) && callback.body !== undefined) {
      const parameterName = first.name.text;
      const visit = (node) => {
        if (
          ts.isPropertyAccessExpression(node) &&
          ts.isIdentifier(node.expression) &&
          node.expression.text === parameterName &&
          BROWSER_FIXTURES.has(node.name.text)
        ) {
          record(node, test, 'page-fixture');
        }
        ts.forEachChild(node, visit);
      };
      visit(callback.body);
    }
  };

  for (const {call, callback} of testCallbacks) analyze(callback, staticTitle(call));
  for (const {callback} of fixtures) analyze(callback, null);

  // The enclosing test( call's static title for a node, or null.
  const enclosingTitle = (node) => {
    for (let current = node.parent; current !== undefined; current = current.parent) {
      if (
        isFunction(current) &&
        ts.isCallExpression(current.parent) &&
        isTestCallee(current.parent.expression)
      ) {
        return staticTitle(current.parent);
      }
    }
    return null;
  };
  const isRequestReceiver = (receiver) =>
    (ts.isIdentifier(receiver) && receiver.text === 'request') ||
    (ts.isPropertyAccessExpression(receiver) &&
      receiver.name.text === 'request' &&
      ts.isIdentifier(receiver.expression) &&
      receiver.expression.text === 'playwright');

  const visitCalls = (node) => {
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      (node.expression.name.text === 'newPage' ||
        node.expression.name.text === 'newContext') &&
      !isRequestReceiver(node.expression.expression)
    ) {
      record(node, enclosingTitle(node), 'new-page');
    } else if (
      ts.isPropertyAccessExpression(node) &&
      node.name.text === 'request' &&
      ((ts.isIdentifier(node.expression) && node.expression.text === 'context') ||
        (ts.isCallExpression(node.expression) &&
          ts.isPropertyAccessExpression(node.expression.expression) &&
          node.expression.expression.name.text === 'context'))
    ) {
      record(node, enclosingTitle(node), 'context-request');
    } else if (
      ts.isImportDeclaration(node) &&
      ts.isStringLiteral(node.moduleSpecifier) &&
      PLAYWRIGHT_MODULES.has(node.moduleSpecifier.text) &&
      node.importClause?.namedBindings !== undefined &&
      ts.isNamedImports(node.importClause.namedBindings)
    ) {
      for (const specifier of node.importClause.namedBindings.elements) {
        if (BROWSER_LAUNCHERS.has((specifier.propertyName ?? specifier.name).text)) {
          record(specifier, null, 'browser-import');
        }
      }
    }
    ts.forEachChild(node, visitCalls);
  };
  visitCalls(sourceFile);

  return uses.sort(
    (left, right) => left.line - right.line || left.reason.localeCompare(right.reason),
  );
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
  const fail = (code, message) => {
    process.stderr.write(`page-use: ${message}\n`);
    process.exit(code);
  };
  const files = process.argv.slice(2);
  if (files.length === 0) fail(2, 'usage: page-use.mjs <file>...');

  let ts;
  try {
    ts = createRequire(import.meta.url)('typescript');
  } catch {
    fail(3, 'cannot resolve "typescript" from node_modules');
  }

  let found = false;
  for (const file of files) {
    let text;
    try {
      text = readFileSync(file, 'utf8');
    } catch (error) {
      fail(3, `cannot read ${file}: ${error.message}`);
    }
    const sourceFile = ts.createSourceFile(
      file,
      text,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TSX,
    );
    for (const use of pageUsesOf(ts, sourceFile)) {
      found = true;
      process.stdout.write(`${file}\t${use.line}\t${use.test ?? '-'}\t${use.reason}\n`);
    }
  }
  process.exit(found ? 1 : 0);
}
