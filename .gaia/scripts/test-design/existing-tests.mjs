#!/usr/bin/env node
// The existing tests that drive what a plan touches: every test whose file
// imports a touched module, requests a touched route, or (bats) names a touched
// path. The planner reads it to say reuse, extend, change or retire per row.
//
// Usage:
//   node existing-tests.mjs --root <tree> --touched <file> [--flow-tests <file>]
//        --touched  touched source paths, repo-relative, one per line
//        --flow-tests  as for layer-map.mjs, so a named flow test lists as flow
//
// Output: a JSON array of {file, fullName, layer, reason}; reason is
// `imports <path>`, `requests <route>` or `names <path>`, the first that
// applies to the file. Every test in a matching file is listed.
//
// Sources of truth: the web package's route config (routes.ts applies React
// Router's flatRoutes file convention, mirrored here from the file names under
// app/routes, since routes.ts cannot run outside a build) and the package
// tsconfig's `paths` aliases. Honest limits: an import is direct, never
// transitive; a request is a string literal passed to a call named like an HTTP
// verb or a navigation (goto, get, post, fetch, Request, ...), so a URL built
// from parts or held in a variable is missed, and a map `.get('/')` over-matches.
//
// Exit codes: 0 ok, 2 usage, 3 unreadable input, no TypeScript or an
// unextractable test file.

import {readdirSync, readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {layerOf, readFlowTests, typescriptModule, webPackageDirs} from './layer-map.mjs';

const extractorPath = fileURLToPath(
  new URL('../test-signals/extract-test-signals.mjs', import.meta.url),
);

const fail = (code, message) => {
  process.stderr.write(`existing-tests: ${message}\n`);
  process.exit(code);
};

const ts = typescriptModule();
const argv = process.argv.slice(2);
const options = {};
for (let index = 0; index < argv.length; index += 1) {
  const argument = argv[index];
  if (['--root', '--touched', '--flow-tests'].includes(argument)) {
    if (index + 1 >= argv.length) fail(2, `${argument} needs a value`);
    options[argument.slice(2)] = argv[index + 1];
    index += 1;
  } else {
    fail(2, `unknown argument ${argument}`);
  }
}
if (options.root === undefined || options.touched === undefined) fail(2, 'needs --root and --touched');
if (ts === null) fail(3, 'cannot resolve "typescript" from node_modules');

const root = path.resolve(options.root);
const flowTests = options['flow-tests'] === undefined ? [] : readFlowTests(options['flow-tests']);
let touched;
try {
  touched = readFileSync(options.touched, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
} catch (error) {
  fail(3, `cannot read ${options.touched}: ${error.message}`);
}
let webDirs;
try {
  webDirs = webPackageDirs(root);
} catch (error) {
  fail(3, error.message);
}

const withoutExtension = (file) => file.replace(/\.(tsx?|jsx?|mjs|cjs)$/, '');
const joinRelative = (...parts) => path.posix.normalize(parts.filter((part) => part !== '').join('/'));
const touchedKeys = new Map(touched.map((file) => [withoutExtension(file), file]));

// An import base resolves to a touched file when it is the file less its
// extension, or the folder of a touched index module.
const touchedFileFor = (base) => {
  const key = withoutExtension(base);
  return touchedKeys.get(key) ?? touchedKeys.get(`${key}/index`) ?? null;
};

// Routes -----------------------------------------------------------------------

const ROUTE_MODULE_NAMES = new Set(['route', 'index', 'layout']);

// The flatRoutes id of a file under app/routes, or null when it is no route.
const routeIdOf = (relative) => {
  const parts = relative.split('/');
  const base = withoutExtension(parts[parts.length - 1]);
  if (!/\.(tsx?|jsx?)$/.test(parts[parts.length - 1])) return null;
  if (parts.length === 1) return base;
  if (parts.length === 2 && ROUTE_MODULE_NAMES.has(base)) return parts[0];
  return null;
};

const segmentPattern = (segment) => {
  if (segment === '$') return {display: '*', source: '/.*'};
  if (segment.startsWith('$')) return {display: `:${segment.slice(1)}`, source: '/[^/]+'};
  const optional = /^\((.+)\)$/.exec(segment);
  if (optional !== null) return {display: `${optional[1]}?`, source: `(?:/${escapeRegex(optional[1])})?`};
  const literal = segment.replace(/\[(.)\]/g, '$1');
  return {display: literal, source: `/${escapeRegex(literal)}`};
};

const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const routeOf = (id, file) => {
  const urlSegments = [];
  const keys = [];
  for (const segment of id.split('.')) {
    keys.push(segment);
    if (segment === '_index') continue;
    if (segment.startsWith('_')) continue;
    urlSegments.push(segmentPattern(segment.replace(/_$/, '')));
  }
  return {
    display: `/${urlSegments.map((entry) => entry.display).join('/')}`,
    file,
    key: keys.join('.'),
    regex: new RegExp(`^${urlSegments.map((entry) => entry.source).join('')}/?$`),
  };
};

const routes = [];
for (const dir of webDirs) {
  const routesDir = joinRelative(dir, 'app/routes');
  const walk = (folder) => {
    let entries = [];
    try {
      entries = readdirSync(path.join(root, folder), {withFileTypes: true});
    } catch {
      return;
    }
    for (const entry of entries) {
      const child = `${folder}/${entry.name}`;
      if (entry.isDirectory()) {
        walk(child);
        continue;
      }
      const id = routeIdOf(child.slice(routesDir.length + 1));
      if (id !== null) routes.push(routeOf(id, child));
    }
  };
  walk(routesDir);
}

// A request touches the route it matches and every layout that route nests in.
const routesRequestedBy = (urlPath) => {
  const hit = [];
  for (const route of routes) {
    if (!route.regex.test(urlPath)) continue;
    hit.push(route);
    for (const other of routes) {
      if (route.key.startsWith(`${other.key}.`)) hit.push(other);
    }
  }
  return hit;
};

// Imports and requests -----------------------------------------------------------

const aliasesFor = (dir) => {
  const configFile = path.join(root, dir, 'tsconfig.json');
  const read = ts.readConfigFile(configFile, ts.sys.readFile);
  const paths = read.config?.compilerOptions?.paths ?? {};
  const baseUrl = read.config?.compilerOptions?.baseUrl ?? '.';
  return Object.entries(paths).map(([pattern, targets]) => ({
    prefix: pattern.replace(/\*$/, ''),
    target: joinRelative(dir, baseUrl, String(targets[0]).replace(/\*$/, '')),
  }));
};
const aliasesByDir = new Map(webDirs.map((dir) => [dir, aliasesFor(dir)]));

const importBasesOf = (file, specifier) => {
  if (specifier.startsWith('.')) return [joinRelative(path.posix.dirname(file), specifier)];
  const bases = [];
  for (const dir of webDirs) {
    if (!file.startsWith(`${dir}/`)) continue;
    for (const {prefix, target} of aliasesByDir.get(dir)) {
      if (specifier.startsWith(prefix)) bases.push(joinRelative(target, specifier.slice(prefix.length)));
    }
  }
  return bases;
};

const REQUEST_CALLEES = new Set([
  'goto', 'get', 'post', 'put', 'patch', 'delete', 'head', 'fetch', 'Request', 'request',
  'waitForURL', 'toHaveURL', 'navigate',
]);
const MODULE_CALLEES = new Set(['require', 'mock', 'importActual', 'importMock', 'doMock']);

const pathnameOf = (literal) => {
  const match = /^(?:https?:\/\/[^/]+)?(\/(?!\/)[^?#]*)/.exec(literal);
  return match === null ? null : match[1];
};

const calleeName = (call) => {
  const callee = call.expression;
  if (ts.isIdentifier(callee)) return callee.text;
  if (ts.isPropertyAccessExpression(callee)) return callee.name.text;
  return null;
};

// The first reason a TypeScript test file matches, or null.
const tsReasonOf = (file, source) => {
  const kind = /\.tsx$/.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);
  let importReason = null;
  let requestReason = null;
  const consider = (specifier) => {
    if (importReason !== null) return;
    for (const base of importBasesOf(file, specifier)) {
      const hit = touchedFileFor(base);
      if (hit !== null) {
        importReason = `imports ${hit}`;
        return;
      }
    }
  };
  const visit = (node) => {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier !== undefined) {
      if (ts.isStringLiteralLike(node.moduleSpecifier)) consider(node.moduleSpecifier.text);
    } else if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
      const name = ts.isNewExpression(node)
        ? ts.isIdentifier(node.expression) ? node.expression.text : null
        : node.expression.kind === ts.SyntaxKind.ImportKeyword ? 'import' : calleeName(node);
      const first = node.arguments?.[0];
      if (first !== undefined && ts.isStringLiteralLike(first)) {
        if (name === 'import' || MODULE_CALLEES.has(name)) {
          consider(first.text);
        } else if (requestReason === null && REQUEST_CALLEES.has(name)) {
          const urlPath = pathnameOf(first.text);
          if (urlPath !== null) {
            const hit = routesRequestedBy(urlPath).find((route) => touched.includes(route.file));
            if (hit !== undefined) requestReason = `requests ${hit.display}`;
          }
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return importReason ?? requestReason;
};

// Walk and list ------------------------------------------------------------------

const SKIPPED_FOLDERS = new Set([
  'node_modules', '.git', '.notebook', 'dist', 'build', 'coverage', '.react-router', 'worktrees',
]);
const TEST_FILE = /\.(test\.tsx?|spec\.ts|stories\.tsx?|bats)$/;

const candidates = [];
const collect = (folder) => {
  let entries = [];
  try {
    entries = readdirSync(path.join(root, folder), {withFileTypes: true});
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (!SKIPPED_FOLDERS.has(entry.name)) collect(folder === '' ? entry.name : `${folder}/${entry.name}`);
    } else if (TEST_FILE.test(entry.name)) {
      candidates.push(folder === '' ? entry.name : `${folder}/${entry.name}`);
    }
  }
};
collect('');
candidates.sort();

const result = [];
for (const file of candidates) {
  let source;
  try {
    source = readFileSync(path.join(root, file), 'utf8');
  } catch (error) {
    fail(3, `cannot read ${file}: ${error.message}`);
  }
  let reason = null;
  if (file.endsWith('.bats')) {
    const named = touched.find((entry) => source.includes(entry));
    if (named !== undefined) reason = `names ${named}`;
  } else {
    reason = tsReasonOf(file, source);
  }
  if (reason === null) continue;
  const layer = layerOf(file, {flowTests, root});
  if (layer === null) continue;
  const extracted = spawnSync(process.execPath, [extractorPath, file], {cwd: root, encoding: 'utf8'});
  if (extracted.status !== 0) fail(3, `cannot extract tests from ${file}: ${extracted.stderr.trim()}`);
  for (const line of extracted.stdout.split('\n').filter((entry) => entry.length > 0)) {
    result.push({file, fullName: JSON.parse(line).fullName, layer, reason});
  }
}

process.stdout.write(`${JSON.stringify(result)}\n`);
