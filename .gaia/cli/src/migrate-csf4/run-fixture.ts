import typescript from 'typescript';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import type {Repairs} from './repairs/index.js';
import type {CommandResult, CommandRunner, MigrateDeps} from './types.js';

export const CSF3_STORY = `import type {Meta, StoryObj} from '@storybook/react-vite';
export default {title: 'x'} satisfies Meta;
export const Primary: StoryObj = {args: {}};
`;

export const CSF4_STORY = `import preview from '#.storybook/preview';
const meta = preview.meta({});
export const Primary = meta.story({});
`;

export const CSF3_PREVIEW = `const preview: Preview = {parameters: {}};
export default preview;
`;

export const CSF4_PREVIEW = `export default definePreview({parameters: {}});
`;

export const PLAIN_MAIN = `const config = {stories: ['../app/**/*.stories.@(ts|tsx)']};
export default config;
`;

export const FLAGGED_MAIN = `const config = {stories: ['../app/**/*.stories.@(ts|tsx)'], features: {experimentalTestSyntax: true}};
export default config;
`;

export const git = (cwd: string, ...args: string[]): string =>
  execFileSync('git', args, {cwd, encoding: 'utf8'});

export const writeTree = (
  root: string,
  files: Record<string, string>
): void => {
  Object.entries(files).forEach(([relative, text]) => {
    const target = path.join(root, relative);

    mkdirSync(path.dirname(target), {recursive: true});
    writeFileSync(target, text);
  });
};

export const read = (root: string, relative: string): string =>
  readFileSync(path.join(root, relative), 'utf8');

export const fakeRepairs: Repairs = {
  capturePreCodemodFacts: () => ({
    factoryExports: [],
    leadingComment: undefined,
    metaArgsType: undefined,
  }),
  classifyStoryFile: (_ts, source) => {
    if (source.includes('storiesOf(') || source.includes('.bind({})'))
      return 'csf2';
    if (source.includes('preview.meta(')) return 'csf4';
    if (source.includes('export default')) return 'csf3';

    return 'unknown';
  },
  ensurePreviewImportsSubpath: (text) =>
    text.includes('"imports"') ?
      {changed: false, text}
    : {
        changed: true,
        text: text.replace(
          '{',
          '{"imports": {"#.storybook/preview": "./.storybook/preview.ts"},'
        ),
      },
  mainAddonSpecifiers: () => [],
  repairStoryFile: (_ts, codemodOutput) => ({
    notes: [],
    source: `${codemodOutput}// repaired\n// preview.meta(\n`,
  }),
  restoreLeadingComment: (_before, after) => after,
  rewirePreview: (_ts, source, _mainAddons) =>
    source.includes('definePreview') ?
      {changed: false, source, unknownAddons: []}
    : {
        changed: true,
        source: 'export default definePreview({});\n',
        unknownAddons: ['some-addon'],
      },
  setTestSyntaxFlag: (_ts, source) =>
    source.includes('experimentalTestSyntax') ?
      {changed: false, source}
    : {changed: true, source: FLAGGED_MAIN},
};

export type Behavior = {
  codemodExitCode?: number;
  /** Runs inside any fake tool call. */
  duringAny?: (command: string, args: readonly string[]) => void;
  /** Runs inside the fake codemod, with `work/` as its cwd. */
  duringCodemod?: (workDir: string) => void;
  eslintJson?: string;
  failingTests?: Record<string, string[]>;
  /** Story files (package-relative) to leave out of the Vitest report. */
  missingFromReport?: string[];
  typecheckOutput?: string;
};

export type Calls = {args: readonly string[]; command: string; cwd: string}[];

export type Harness = {
  calls: Calls;
  deps: MigrateDeps;
  err: string[];
  out: string[];
  packageDir: string;
  root: string;
};

const exec = (
  command: string,
  args: readonly string[],
  cwd: string
): CommandResult => {
  try {
    return {
      exitCode: 0,
      stderr: '',
      stdout: execFileSync(command, [...args], {cwd, encoding: 'utf8'}),
    };
  } catch (error) {
    return {exitCode: 1, stderr: String(error), stdout: ''};
  }
};

/** A temp git repo shaped like a GAIA checkout: registered `frontend` package, committed. */
export const makeRepo = (
  files: Record<string, string>,
  storybookVersion = '10.6.3'
): string => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'migrate-csf4-')));

  git(root, 'init', '-q');
  git(root, 'config', 'user.email', 'a@b.c');
  git(root, 'config', 'user.name', 'a');
  git(root, 'config', 'commit.gpgsign', 'false');
  writeFrontendRegistry(root, 'frontend');
  writeTree(root, {
    '.gitignore': 'node_modules\n',
    'frontend/node_modules/msw-storybook-addon/build/migrate.mjs': '',
    'frontend/node_modules/msw-storybook-addon/package.json': JSON.stringify({
      bin: {'msw-storybook-addon': './build/migrate.mjs'},
    }),
    'frontend/node_modules/storybook/package.json': JSON.stringify({
      version: storybookVersion,
    }),
    'frontend/package.json': '{"name": "frontend"}\n',
    ...files,
  });
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'init');

  return root;
};

const vitestReport = (
  packageDir: string,
  behavior: Behavior,
  storyFiles: string[]
): string =>
  JSON.stringify({
    testResults: storyFiles
      .filter((file) => !(behavior.missingFromReport ?? []).includes(file))
      .map((file) => ({
        assertionResults: [
          {fullName: `${file} ok`, status: 'passed'},
          ...(behavior.failingTests?.[file] ?? []).map((fullName) => ({
            fullName,
            status: 'failed',
          })),
        ],
        name: path.join(packageDir, file),
        status: 'passed',
      })),
  });

export const makeHarness = (
  root: string,
  behavior: Behavior = {},
  options: {repairs?: Repairs; withoutTypescript?: boolean} = {}
): Harness => {
  const packageDir = path.join(root, 'frontend');
  const calls: Calls = [];
  const out: string[] = [];
  const err: string[] = [];

  const runCommand: CommandRunner = (command, args, {cwd}) => {
    calls.push({args, command, cwd});
    behavior.duringAny?.(command, args);
    if (command === 'git') return exec(command, args, cwd);

    if (command === 'pnpm' && args[0] === 'dlx') {
      behavior.duringCodemod?.(cwd);
      const glob = String(args.find((arg) => arg.startsWith('--glob=')));
      const files = glob
        .slice('--glob='.length)
        .replaceAll(/[{}]/gu, '')
        .split(',');

      files.forEach((file) => {
        const target = path.join(cwd, file);

        writeFileSync(target, `${readFileSync(target, 'utf8')}// codemod\n`);
      });
      writeFileSync(path.join(cwd, '.storybook/main.ts'), '// codemod main\n');
      writeFileSync(
        path.join(cwd, '.storybook/preview.ts'),
        '// codemod preview\n'
      );
      writeFileSync(path.join(cwd, 'package.json'), '{"codemod": true}\n');

      return {exitCode: behavior.codemodExitCode ?? 0, stderr: '', stdout: ''};
    }

    if (command === 'node') {
      writeFileSync(path.join(cwd, '.storybook/main.ts'), '// msw main\n');

      return {exitCode: 0, stderr: '', stdout: ''};
    }

    if (args.includes('typecheck')) {
      return {
        exitCode: behavior.typecheckOutput === undefined ? 0 : 2,
        stderr: '',
        stdout: behavior.typecheckOutput ?? '',
      };
    }

    if (args.includes('--format')) {
      return {
        exitCode: behavior.eslintJson === undefined ? 0 : 1,
        stderr: '',
        stdout: behavior.eslintJson ?? '[]',
      };
    }

    if (args.includes('vitest')) {
      const outputFile = String(
        args.find((arg) => arg.startsWith('--outputFile='))
      ).slice('--outputFile='.length);
      const stories = exec('git', ['ls-files', '-z', '--', 'app'], packageDir)
        .stdout.split('\0')
        .filter((file) => file.endsWith('.stories.tsx'));

      writeFileSync(outputFile, vitestReport(packageDir, behavior, stories));

      return {exitCode: 0, stderr: '', stdout: ''};
    }

    return {exitCode: 0, stderr: '', stdout: ''};
  };

  return {
    calls,
    deps: {
      cwd: root,
      loadTypescript: () =>
        options.withoutTypescript === true ? undefined : typescript,
      repairs: options.repairs ?? fakeRepairs,
      runCommand,
      writeErr: (text) => err.push(text),
      writeOut: (text) => out.push(text),
    },
    err,
    out,
    packageDir,
    root,
  };
};
