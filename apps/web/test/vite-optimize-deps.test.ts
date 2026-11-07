import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import reactRouterConfig from '../react-router.config';

// The browser loads the MSW mock modules through a dynamic import in
// entry.client, after Vite's startup dependency scan. A package one of them
// imports that optimizeDeps.include does not list is optimized only when a page
// first requests it, and Vite then reloads that page, failing whatever test it
// was running. An include entry names one import path: 'msw/http' does not
// cover a bare 'msw'.

const webRoot = fileURLToPath(new URL('..', import.meta.url));
const mocksRoot = path.join(webRoot, 'test/mocks');
const forwardHandlerPath = path.join(
  webRoot,
  'test/msw-seed/forward-handler.ts'
);

const LOCAL_PREFIXES = ['.', '~/', 'test/', 'node:'];

// Type-only imports and re-exports are erased before the browser sees the file.
const readRuntimeImports = (file: string): string[] =>
  ts
    .createSourceFile(
      file,
      fs.readFileSync(file, 'utf8'),
      ts.ScriptTarget.Latest
    )
    .statements.flatMap((statement) => {
      if (
        ts.isImportDeclaration(statement) &&
        statement.importClause?.phaseModifier !== ts.SyntaxKind.TypeKeyword
      ) {
        return [statement.moduleSpecifier];
      }

      if (
        ts.isExportDeclaration(statement) &&
        !statement.isTypeOnly &&
        statement.moduleSpecifier !== undefined
      ) {
        return [statement.moduleSpecifier];
      }

      return [];
    })
    .filter(ts.isStringLiteral)
    .map((specifier) => specifier.text);

// Reads only the first match, so each key read here must appear once in
// vite.config.ts.
const readViteConfigList = (key: string): string[] => {
  const viteConfigSource = fs.readFileSync(
    path.join(webRoot, 'vite.config.ts'),
    'utf8'
  );
  const list = new RegExp(String.raw`\b${key}:\s*\[([^\]]*)\]`).exec(
    viteConfigSource
  )?.[1];

  return [...(list ?? '').matchAll(/['"]([^'"]+)['"]/g)].map(
    (match) => match[1]
  );
};

const readPlaywrightOutputDirectory = (): string => {
  const playwrightConfigSource = fs.readFileSync(
    path.join(webRoot, 'playwright.config.ts'),
    'utf8'
  );
  const directory = /\boutputDir:\s*['"]([^'"]+)['"]/.exec(
    playwrightConfigSource
  )?.[1];

  if (directory === undefined) {
    throw new Error('playwright.config.ts sets no string outputDir.');
  }

  return directory;
};

const listSourceFiles = (directory: string): string[] =>
  fs
    .readdirSync(directory, {recursive: true, withFileTypes: true})
    .filter(
      (entry) =>
        entry.isFile() &&
        /\.tsx?$/.test(entry.name) &&
        !/\.test\.tsx?$/.test(entry.name)
    )
    .map((entry) => path.join(entry.parentPath, entry.name));

const resolveLocal = (
  fromFile: string,
  specifier: string
): string | undefined => {
  const base =
    specifier.startsWith('~/') ? path.join(webRoot, 'app', specifier.slice(2))
    : specifier.startsWith('test/') ? path.join(webRoot, specifier)
    : specifier.startsWith('.') ?
      path.resolve(path.dirname(fromFile), specifier)
    : undefined;

  if (base === undefined) return undefined;

  return [
    base,
    `${base}.ts`,
    `${base}.tsx`,
    path.join(base, 'index.ts'),
    path.join(base, 'index.tsx'),
  ].find(
    (candidate) => fs.existsSync(candidate) && fs.statSync(candidate).isFile()
  );
};

// Maps each package import path the walk reaches to the first file found
// importing it.
const collectPackageImports = (roots: string[]): Map<string, string> => {
  const firstImporterBySpecifier = new Map<string, string>();
  const visited = new Set<string>();
  const pending = [...roots];

  while (pending.length > 0) {
    const file = pending.pop() as string;
    const specifiers = visited.has(file) ? [] : readRuntimeImports(file);

    visited.add(file);

    for (const specifier of specifiers) {
      if (LOCAL_PREFIXES.some((prefix) => specifier.startsWith(prefix))) {
        const resolved = resolveLocal(file, specifier);

        if (resolved !== undefined) pending.push(resolved);
      } else if (!firstImporterBySpecifier.has(specifier)) {
        firstImporterBySpecifier.set(specifier, path.relative(webRoot, file));
      }
    }
  }

  return firstImporterBySpecifier;
};

describe('Vite dependency pre-bundling', () => {
  test('every package the browser-loaded mock modules import is pre-bundled', () => {
    const include = readViteConfigList('include');
    const firstImporterBySpecifier = collectPackageImports([
      forwardHandlerPath,
      ...listSourceFiles(mocksRoot),
    ]);

    expect(include.length).toBeGreaterThan(0);
    expect(firstImporterBySpecifier.size).toBeGreaterThan(0);

    const missing = [...firstImporterBySpecifier]
      .filter(([specifier]) => !include.includes(specifier))
      .map(([specifier, file]) => `${specifier} (imported by ${file})`);

    expect(missing).toEqual([]);
  });

  // Without the flag React Router gives Vite no scan entries, so Vite finds the
  // app's packages only when a page first loads, then re-optimizes and reloads
  // that page.
  test('React Router hands the client entry and route modules to the startup scan', () => {
    expect(reactRouterConfig.future.unstable_optimizeDeps).toBe(true);
  });

  // Playwright writes trace HTML to its outputDir while tests run, and Vite
  // full-reloads every page on an HTML change it watches. Vite's default watch
  // ignore covers Playwright's default outputDir, test-results, not a
  // configured one.
  test('the dev server does not watch the Playwright output folder', () => {
    // Vite's watcher matches its ignore globs against absolute paths, with
    // `dot: true`. A fixed root keeps the checkout's own dot folders (a
    // worktree under `.claude`) out of `path.matchesGlob`, which takes no
    // `dot` option.
    const traceFile = path.join(
      '/project',
      readPlaywrightOutputDirectory(),
      'traces/resources/page.html'
    );

    expect(
      readViteConfigList('ignored').some((glob) =>
        path.matchesGlob(traceFile, glob)
      )
    ).toBe(true);
  });
});
