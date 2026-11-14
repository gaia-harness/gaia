#!/usr/bin/env node
// The one layer mapper for tests: a test file's path (and, for a Playwright
// spec, whether it opens a page) to one of unit, story, route, real-server,
// browser, flow or shell. The rule it implements is `## Layers`, `**Path to
// layer.**` in .claude/doctrine/testing.md.
//
// Usage:
//   node layer-map.mjs --root <tree> [--flow-tests <file>]
//        NUL-separated repo-relative paths on stdin; prints a JSON array of
//        {file, layer}. A path on no layer is left out of the array.
//   --flow-tests <file>  one repo-relative path per line: tests a plan names
//        as flow tests, which map to flow whatever their path says.
//
// Exit codes: 0 ok, 2 usage, 3 unreadable input or no TypeScript.
//
// Importable: layerOf(file, {root, flowTests}) for the drift check, and
// webPackageDirs(root) for modules that need the web package's folder.

import {createRequire} from 'node:module';
import {readFileSync, realpathSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {pageUsesOf} from '../spec/page-use.mjs';

const require = createRequire(import.meta.url);
let typescript = null;
try {
  typescript = require('typescript');
} catch {
  typescript = null;
}

export const typescriptModule = () => typescript;

const PACKAGES_LIBRARY = fileURLToPath(
  new URL('../../../.claude/hooks/lib/gaia-packages.sh', import.meta.url),
);
const WEB_MEMBERS_PROGRAM = `. "$1" || exit 8
gaia_packages_load "$2" || { printf '%s\\n' "$GAIA_PACKAGES_ERROR" >&2; exit 9; }
gaia_packages_web_members | cut -f2`;

const webDirCache = new Map();

// The web-stack packages' folders (repo-relative, no trailing slash), read
// through the registry's bash reader, never a literal path. Throws with the
// reader's message when the registry cannot be read.
export function webPackageDirs(root) {
  const key = path.resolve(root);
  if (webDirCache.has(key)) return webDirCache.get(key);
  const loaded = spawnSync('bash', ['-c', WEB_MEMBERS_PROGRAM, 'layer-map', PACKAGES_LIBRARY, key], {
    encoding: 'utf8',
  });
  if (loaded.status !== 0) {
    throw new Error(
      loaded.stderr.trim() ||
        'gaia-packages: the package registry could not be read. Next step: confirm bash and jq are on PATH.',
    );
  }
  const dirs = loaded.stdout
    .split('\n')
    .map((line) => line.trim().replace(/\/+$/, ''))
    .filter((line) => line.length > 0);
  webDirCache.set(key, dirs);
  return dirs;
}

// [layer, pattern] over a path relative to the web package; first match wins.
// 'playwright' is decided by whether the spec opens a page.
const WEB_PATTERNS = [
  ['flow', /^\.playwright\/flows\/(.+\/)?[^/]+\.spec\.ts$/],
  ['playwright', /^\.playwright\/(.+\/)?[^/]+\.spec\.ts$/],
  ['route', /^app\/route-tests\/(.+\/)?[^/]+\.test\.ts$/],
  ['route', /^test\/(.+\/)?[^/]+\.server\.test\.ts$/],
  ['story', /^app\/(.+\/)?[^/]+\.stories\.tsx?$/],
  ['unit', /^app\/(?!route-tests\/)(.+\/)?[^/]+\.test\.tsx?$/],
  ['unit', /^test\/(.+\/)?[^/]+\.test\.tsx?$/],
];

// An unreadable spec counts as opening a page: no assertion in it can verify.
const opensAPage = (root, file) => {
  try {
    const absolute = path.join(root, file);
    const sourceFile = typescript.createSourceFile(
      file,
      readFileSync(absolute, 'utf8'),
      typescript.ScriptTarget.Latest,
      true,
      typescript.ScriptKind.TS,
    );
    return pageUsesOf(typescript, sourceFile, absolute).length > 0;
  } catch {
    return true;
  }
};

// The layer of one repo-relative test path, or null when it sits on none.
export function layerOf(file, {root, flowTests = []} = {}) {
  const flows = flowTests instanceof Set ? flowTests : new Set(flowTests);
  if (flows.has(file)) return 'flow';
  if (/\.bats$/.test(file)) return 'shell';
  for (const dir of webPackageDirs(root)) {
    const prefix = dir === '' || dir === '.' ? '' : `${dir}/`;
    if (!file.startsWith(prefix)) continue;
    const relative = file.slice(prefix.length);
    for (const [layer, pattern] of WEB_PATTERNS) {
      if (!pattern.test(relative)) continue;
      if (layer !== 'playwright') return layer;
      return opensAPage(root, file) ? 'browser' : 'real-server';
    }
  }
  return null;
}

const fail = (code, message) => {
  process.stderr.write(`layer-map: ${message}\n`);
  process.exit(code);
};

export const readFlowTests = (file) => {
  try {
    return readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
  } catch (error) {
    return fail(3, `cannot read ${file}: ${error.message}`);
  }
};

const isMain = () => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
};

if (isMain()) {
  const argv = process.argv.slice(2);
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--root' || argument === '--flow-tests') {
      if (index + 1 >= argv.length) fail(2, `${argument} needs a value`);
      options[argument.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      fail(2, `unknown argument ${argument}`);
    }
  }
  if (options.root === undefined) fail(2, 'needs --root');
  if (typescript === null) fail(3, 'cannot resolve "typescript" from node_modules');
  const root = path.resolve(options.root);
  const flowTests = options['flow-tests'] === undefined ? [] : readFlowTests(options['flow-tests']);
  let input = '';
  try {
    input = readFileSync(0, 'utf8');
  } catch (error) {
    fail(3, `cannot read stdin: ${error.message}`);
  }
  const result = [];
  try {
    for (const file of input.split('\0').filter((entry) => entry.length > 0)) {
      const layer = layerOf(file, {flowTests, root});
      if (layer !== null) result.push({file, layer});
    }
  } catch (error) {
    fail(3, error.message);
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
