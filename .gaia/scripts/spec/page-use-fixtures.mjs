// The test.extend fixture half of page-use.mjs: which fixture names are
// page-backed, read from one file and from the fixtures modules it imports
// `test` from. page-use.mjs is the only importer; its header states the rule.

import {readFileSync, statSync} from 'node:fs';
import path from 'node:path';

// Page-backed fixtures the template defines in another module:
// apps/web/.playwright/fixtures.ts builds makeAxeBuilder over `{page}`.
const PAGE_BACKED_FIXTURES = ['makeAxeBuilder'];

export const BROWSER_FIXTURES = new Set(['page', 'context', 'browser']);
// A fixtures chain is a base module plus a layer or two; the cap only keeps a
// pathological import graph from walking the whole tree.
const MAXIMUM_IMPORT_DEPTH = 8;
const MODULE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.js', '.mjs', '.jsx'];

export const isFunctionNode = (ts, node) =>
  ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isMethodDeclaration(node);
const nameTextOf = (ts, name) =>
  name !== undefined && (ts.isIdentifier(name) || ts.isStringLiteralLike(name))
    ? name.text
    : null;
export const isExtendCall = (ts, node) =>
  ts.isCallExpression(node) &&
  ts.isPropertyAccessExpression(node.expression) &&
  node.expression.name.text === 'extend';

// The {callback, name} of every fixture a test.extend({...}) in the file defines.
export function extendFixturesOf(ts, sourceFile) {
  const fixtures = [];
  const visit = (node) => {
    if (isExtendCall(ts, node)) {
      for (const argument of node.arguments) {
        if (!ts.isObjectLiteralExpression(argument)) continue;
        for (const property of argument.properties) {
          const name = nameTextOf(ts, property.name);
          let callback = null;
          if (ts.isMethodDeclaration(property)) {
            callback = property;
          } else if (ts.isPropertyAssignment(property)) {
            const value = property.initializer;
            if (isFunctionNode(ts, value)) callback = value;
            else if (
              ts.isArrayLiteralExpression(value) &&
              value.elements.length > 0 &&
              isFunctionNode(ts, value.elements[0])
            ) {
              callback = value.elements[0];
            }
          }
          if (name !== null && callback !== null) fixtures.push({callback, name});
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return fixtures;
}

export const destructuredKeysOf = (ts, callback) => {
  const first = callback.parameters[0];
  if (first === undefined || !ts.isObjectBindingPattern(first.name)) return [];
  return first.name.elements.map((element) => ({
    element,
    key: nameTextOf(ts, element.propertyName ?? element.name),
  }));
};

// Adds every fixture whose callback destructures a browser fixture or a name
// already in `pageBacked`, until nothing changes.
const growPageBacked = (ts, fixtures, pageBacked) => {
  let grew = true;
  while (grew) {
    grew = false;
    for (const {callback, name} of fixtures) {
      if (pageBacked.has(name)) continue;
      const backed = destructuredKeysOf(ts, callback).some(
        ({key}) => key !== null && (BROWSER_FIXTURES.has(key) || pageBacked.has(key)),
      );
      if (backed) {
        pageBacked.add(name);
        grew = true;
      }
    }
  }
};

const isFile = (candidate) => {
  try {
    return statSync(candidate).isFile();
  } catch {
    return false;
  }
};

// The file a relative specifier names, with TypeScript's extension and index
// lookups (a `./fixtures.js` written for a `.ts` source included), or null.
const resolveRelative = (fromFile, specifier) => {
  const base = path.resolve(path.dirname(fromFile), specifier);
  const stem = base.replace(/\.[cm]?jsx?$/, '');
  const candidates = [
    base,
    ...MODULE_EXTENSIONS.map((extension) => stem + extension),
    ...MODULE_EXTENSIONS.map((extension) => path.join(base, `index${extension}`)),
  ];
  return candidates.find(isFile) ?? null;
};

// Relative specifiers this file imports `test` or `it` from, under any local
// name: the modules defining the fixtures its tests destructure.
const testImportsOf = (ts, sourceFile) => {
  const specifiers = [];
  for (const statement of sourceFile.statements) {
    if (
      !ts.isImportDeclaration(statement) ||
      !ts.isStringLiteral(statement.moduleSpecifier) ||
      !statement.moduleSpecifier.text.startsWith('.')
    ) {
      continue;
    }
    const bindings = statement.importClause?.namedBindings;
    if (bindings === undefined || !ts.isNamedImports(bindings)) continue;
    const suppliesTest = bindings.elements.some((specifier) =>
      ['test', 'it'].includes((specifier.propertyName ?? specifier.name).text),
    );
    if (suppliesTest) specifiers.push(statement.moduleSpecifier.text);
  }
  return specifiers;
};

// Page-backed fixture names the modules this file imports `test` from define,
// transitively. `namesByModule` memoizes each module, so a module two imports
// reach is read once and counts for both; an entry is empty while its module
// is being read, which ends an import cycle. An unreadable module adds nothing.
function importedPageBacked(ts, filePath, sourceFile, namesByModule, depth) {
  const names = new Set();
  if (depth >= MAXIMUM_IMPORT_DEPTH) return names;
  for (const specifier of testImportsOf(ts, sourceFile)) {
    const resolved = resolveRelative(filePath, specifier);
    if (resolved === null) continue;
    if (namesByModule.has(resolved)) {
      for (const name of namesByModule.get(resolved)) names.add(name);
      continue;
    }
    const moduleBacked = new Set(PAGE_BACKED_FIXTURES);
    namesByModule.set(resolved, moduleBacked);
    let moduleSource;
    try {
      moduleSource = ts.createSourceFile(
        resolved,
        readFileSync(resolved, 'utf8'),
        ts.ScriptTarget.Latest,
        true,
        /\.[jt]sx$/.test(resolved) ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
      );
    } catch {
      continue;
    }
    for (const name of importedPageBacked(ts, resolved, moduleSource, namesByModule, depth + 1)) {
      moduleBacked.add(name);
    }
    growPageBacked(ts, extendFixturesOf(ts, moduleSource), moduleBacked);
    for (const name of moduleBacked) names.add(name);
  }
  return names;
}

// Every page-backed fixture name a test in this file can destructure: the
// named list, the imported fixtures modules' names, and this file's own.
export function pageBackedFixturesOf(ts, sourceFile, filePath, fixtures) {
  const namesByModule = new Map([[path.resolve(filePath), new Set()]]);
  const pageBacked = new Set([
    ...PAGE_BACKED_FIXTURES,
    ...importedPageBacked(ts, filePath, sourceFile, namesByModule, 0),
  ]);
  growPageBacked(ts, fixtures, pageBacked);
  return pageBacked;
}
