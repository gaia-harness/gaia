import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {run} from './strip-branding.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const TEMPLATE_README =
  '# {{PROJECT_TITLE}}\n\nWelcome to {{PROJECT_TITLE}}!\n';

// The shipped preview, not a hand-written copy: renaming its brand
// declaration has to fail here rather than leave the de-brand a silent no-op.
const PREVIEW_BEFORE = readFileSync(
  path.join(
    resolveRepoRootFromImportMeta(import.meta.url),
    'frontend',
    '.storybook',
    'preview.ts'
  ),
  'utf8'
);

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-strip-branding-'));
  writeFrontendRegistry(root);
  mkdirSync(path.join(root, '.github'), {recursive: true});
  writeFileSync(
    path.join(root, '.github', 'FUNDING.yml'),
    'github: gaia\n',
    'utf8'
  );
  mkdirSync(path.join(root, '.gaia', 'templates'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'templates', 'README.md'),
    TEMPLATE_README,
    'utf8'
  );
  writeFileSync(path.join(root, 'README.md'), '# GAIA stale\n', 'utf8');
  mkdirSync(path.join(root, '.storybook'), {recursive: true});
  writeFileSync(
    path.join(root, '.storybook', 'preview.ts'),
    PREVIEW_BEFORE,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('init strip-branding', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('removes FUNDING, replaces README, personalizes Storybook brand, records state', () => {
    sandbox = setupSandbox();

    const exit = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    expect(existsSync(path.join(sandbox.root, '.github', 'FUNDING.yml'))).toBe(
      false
    );

    const readme = readFileSync(path.join(sandbox.root, 'README.md'), 'utf8');
    expect(readme).toBe('# Hello World\n\nWelcome to Hello World!\n');

    const preview = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(preview).not.toContain("brandTitle: 'GAIA'");
    expect(preview).not.toContain('gaiaharness.com');
    expect(preview).toContain("brandTitle: 'Hello World'");

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('strip-branding');
    expect(state.step_args['strip-branding']).toEqual({title: 'Hello World'});
  });

  test('only the brand declaration changes in the definePreview preview', () => {
    sandbox = setupSandbox();

    expect(run(['--title', 'Hello World'], {cwd: sandbox.root})).toBe(0);

    const after = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    const declaration = /const storybookBrandOptions = \{[\s\S]*?\};/u;

    expect(PREVIEW_BEFORE).toContain('export default definePreview(');
    expect(after.replace(declaration, '')).toBe(
      PREVIEW_BEFORE.replace(declaration, '')
    );
    expect(after).toContain(
      "const storybookBrandOptions = {\n  brandTarget: '_blank',\n  brandTitle: 'Hello World',\n};"
    );
  });

  test('idempotent: re-running is a no-op', () => {
    sandbox = setupSandbox();

    const first = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(first).toBe(0);

    const previewAfter = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );

    const second = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(second).toBe(0);

    const previewSecond = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(previewSecond).toBe(previewAfter);

    const state = readState(sandbox.root);
    const stripCount = state.completed_steps.filter(
      (step) => step === 'strip-branding'
    ).length;
    expect(stripCount).toBe(1);
  });

  test('exit 1 when --title missing', () => {
    sandbox = setupSandbox();
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title is required');
  });

  test.each([
    ['a line feed', 'Hello\nWorld'],
    ['a carriage return', 'Hello\rWorld'],
  ])('exit 1 when --title carries %s', (_label, title) => {
    sandbox = setupSandbox();
    const exit = run(['--title', title], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      '--title must not contain a line ending'
    );
  });

  // A title carrying a quote, a backslash or a `$` is an ordinary title and is
  // escaped rather than refused. Scoped to this command's own sink: these rows
  // assert what `debrandStorybook` does, and say nothing about any other sink.
  test.each([
    ['an apostrophe', "Steve's App", String.raw`Steve\'s App`],
    ['a backslash', String.raw`A\B`, String.raw`A\\B`],
    ['a dollar token', 'Q1 $1 Report', 'Q1 $1 Report'],
  ])('accepts a title carrying %s', (_label, title, expected) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const preview = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(preview).toContain(`brandTitle: '${expected}',`);
  });

  test('exit 1 when README template missing', () => {
    sandbox = setupSandbox();
    rmSync(path.join(sandbox.root, '.gaia', 'templates', 'README.md'));

    const exit = run(['--title', 'X'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('template_missing');
  });

  test('exit 1 without recording the step when the brand declaration is missing', () => {
    sandbox = setupSandbox();
    const previewPath = path.join(sandbox.root, '.storybook', 'preview.ts');
    const customized = 'export default {};\n';
    writeFileSync(previewPath, customized, 'utf8');

    const exit = run(['--title', 'X'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('storybook_brand_missing');
    expect(readFileSync(previewPath, 'utf8')).toBe(customized);
    expect(readState(sandbox.root).completed_steps).not.toContain(
      'strip-branding'
    );
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox();
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
