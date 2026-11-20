/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync as execFileSyncMock} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  ASK_FIRST_SENTENCE,
  buildMissingPortFileMessage,
  buildPortInUseMessage,
  DEV_BASE_PORT,
  findCheckout,
  findListenerOwner,
  PORT_FILE_NAME,
  PORTS_HINT,
  requireDevPorts,
  resolveDevPorts,
  resolveSiteUrl,
  STORYBOOK_BASE_PORT,
} from '../dev-ports';
import type {DevPorts as DevelopmentPorts} from '../dev-ports';

vi.mock('node:child_process', () => {
  const execFileSync = vi.fn();

  return {default: {execFileSync}, execFileSync};
});

const slotThreeFile = [
  '# GAIA per-worktree ports',
  'GAIA_PORT_SLOT=3',
  'DEV_PORT=5176',
  'STORYBOOK_PORT=6009',
  'SITE_URL=http://localhost:5176',
  '',
].join('\n');

let sandbox: string;

const makeTree = ({
  gitFile,
  portFile,
}: {
  gitFile?: string;
  portFile?: string;
}): {packageDirectory: string; treeRoot: string} => {
  const treeRoot = fs.mkdtempSync(path.join(sandbox, 'tree-'));
  const packageDirectory = path.join(treeRoot, 'apps', 'web');
  fs.mkdirSync(packageDirectory, {recursive: true});

  if (gitFile === undefined) {
    fs.mkdirSync(path.join(treeRoot, '.git'));
  } else if (gitFile !== 'none') {
    fs.writeFileSync(path.join(treeRoot, '.git'), gitFile);
  }

  if (portFile !== undefined) {
    fs.writeFileSync(path.join(packageDirectory, PORT_FILE_NAME), portFile);
  }

  return {packageDirectory, treeRoot: fs.realpathSync(treeRoot)};
};

type Resolution = ReturnType<typeof resolveDevPorts>;

const extractResolvedPorts = (resolution: Resolution): DevelopmentPorts =>
  (resolution as Extract<Resolution, {kind: 'resolved'}>).ports;

const linkedGit = 'gitdir: /x/repo/.git/worktrees/feature\n';

beforeEach(() => {
  sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'dev-ports-'));
  vi.mocked(execFileSyncMock).mockReset();
});

afterEach(() => {
  fs.rmSync(sandbox, {force: true, recursive: true});
});

describe('resolveDevPorts defaults', () => {
  test.each(
    [
      {
        name: 'uses slot 0 in an ordinary checkout with no port file',
        treeOptions: {},
      },
      {
        name: 'uses slot 0 when no .git exists anywhere up the tree',
        treeOptions: {gitFile: 'none'},
      },
      {
        name: 'treats a submodule-shaped .git file as not a linked worktree',
        treeOptions: {gitFile: 'gitdir: ../../.git/modules/web\n'},
      },
    ].map((row) => [row.name, row] as const)
  )(
    'resolveDevPorts uses slot 0 outside a linked worktree: %s',
    (_name, {treeOptions}) => {
      const {packageDirectory} = makeTree(treeOptions);
      const resolution = resolveDevPorts(packageDirectory);
      expect(findCheckout(packageDirectory).isLinkedWorktree).toBe(false);
      expect(resolution).toMatchObject({kind: 'resolved'});
      expect(extractResolvedPorts(resolution)).toMatchObject({
        devPort: 5173,
        siteUrl: undefined,
        slot: 0,
        source: 'default',
        storybookPort: 6006,
      });
    }
  );
});

describe('resolveDevPorts port file', () => {
  test('reads a valid file in a linked worktree', () => {
    const {packageDirectory, treeRoot} = makeTree({
      gitFile: linkedGit,
      portFile: slotThreeFile,
    });
    expect(resolveDevPorts(packageDirectory)).toEqual({
      kind: 'resolved',
      ports: {
        devPort: 5176,
        siteUrl: 'http://localhost:5176',
        slot: 3,
        source: 'port-file',
        storybookPort: 6009,
        treeRoot,
      },
    });
  });

  test('refuses a linked worktree without a file with the frozen message', () => {
    const {packageDirectory, treeRoot} = makeTree({gitFile: linkedGit});
    const portFilePath = path.join(packageDirectory, PORT_FILE_NAME);
    const resolution = resolveDevPorts(packageDirectory);
    expect(resolution.kind).toBe('missing-port-file');
    const refusal = resolution as Extract<
      Resolution,
      {kind: 'missing-port-file'}
    >;
    const expected = `GAIA: ${treeRoot} is a linked worktree with no port file at ${portFilePath}, so it has no ports of its own and will not borrow the main checkout's. Run: bash .claude/hooks/provision-worktree.sh ${treeRoot} Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports.`;
    expect(refusal.message).toBe(expected);
    expect(refusal.treeRoot).toBe(treeRoot);
    expect(refusal.portFilePath).toBe(portFilePath);
    expect(
      refusal.message.endsWith(`${ASK_FIRST_SENTENCE} ${PORTS_HINT}`)
    ).toBe(true);
    expect(buildMissingPortFileMessage({portFilePath, treeRoot})).toBe(
      expected
    );
    expect(() => requireDevPorts(packageDirectory)).toThrow(
      new Error(expected)
    );
  });

  test.each([
    ['missing DEV_PORT', 'GAIA_PORT_SLOT=3\nSTORYBOOK_PORT=6009\nSITE_URL=x\n'],
    ['duplicated DEV_PORT', `${slotThreeFile}DEV_PORT=5177\n`],
    [
      'non-numeric DEV_PORT',
      slotThreeFile.replace('DEV_PORT=5176', 'DEV_PORT=abc'),
    ],
    [
      'empty SITE_URL',
      slotThreeFile.replace('SITE_URL=http://localhost:5176', 'SITE_URL='),
    ],
    ['zero DEV_PORT', slotThreeFile.replace('DEV_PORT=5176', 'DEV_PORT=0')],
    [
      'out-of-range DEV_PORT',
      slotThreeFile.replace('DEV_PORT=5176', 'DEV_PORT=70000'),
    ],
  ])('refuses a malformed file: %s', (_name, portFile) => {
    const {packageDirectory} = makeTree({gitFile: linkedGit, portFile});
    const portFilePath = path.join(packageDirectory, PORT_FILE_NAME);
    const resolution = resolveDevPorts(packageDirectory);
    expect(resolution.kind).toBe('malformed-port-file');
    const refusal = resolution as Extract<
      Resolution,
      {kind: 'malformed-port-file'}
    >;
    expect(refusal.portFilePath).toBe(portFilePath);
    expect(refusal.message).toContain(portFilePath);
    expect(refusal.message).toContain(ASK_FIRST_SENTENCE);
    expect(refusal.message).toContain(PORTS_HINT);
    expect(() => requireDevPorts(packageDirectory)).toThrow(portFilePath);
  });
});

describe('resolveSiteUrl', () => {
  const portFilePorts: DevelopmentPorts = {
    devPort: 5176,
    siteUrl: 'http://localhost:5176',
    slot: 3,
    source: 'port-file',
    storybookPort: 6009,
    treeRoot: undefined,
  };

  test.each(
    (
      [
        {
          expected: 'https://exported.test:9999',
          exportedSiteUrl: 'https://exported.test:9999',
          name: 'prefers an exported value',
          ports: portFilePorts,
        },
        {
          expected: 'http://localhost:5176',
          exportedSiteUrl: undefined,
          name: 'falls back to the port file value',
          ports: portFilePorts,
        },
        {
          expected: undefined,
          exportedSiteUrl: undefined,
          name: 'leaves the slot-0 default untouched',
          ports: {
            ...portFilePorts,
            devPort: 5173,
            siteUrl: undefined,
            slot: 0,
            source: 'default',
            storybookPort: 6006,
          },
        },
      ] satisfies readonly {
        expected: string | undefined;
        exportedSiteUrl: string | undefined;
        name: string;
        ports: DevelopmentPorts;
      }[]
    ).map((row) => [row.name, row] as const)
  )(
    'resolveSiteUrl prefers the export, then the port file, and leaves slot 0 alone: %s',
    (_name, {expected, exportedSiteUrl, ports}) => {
      expect(resolveSiteUrl({exportedSiteUrl, ports})).toBe(expected);
    }
  );
});

const returnsOutput = (output: string) => (): void => {
  vi.mocked(execFileSyncMock).mockReturnValue(output);
};

const throwsError = (message: string) => (): void => {
  vi.mocked(execFileSyncMock).mockImplementation(() => {
    throw new Error(message);
  });
};

describe('findListenerOwner', () => {
  const treeRoot = '/some/tree';
  const expectedProbeCall = [
    'bash',
    [
      path.join(treeRoot, '.gaia/scripts/server-process-lib.sh'),
      '--listener-owner',
      '5176',
      treeRoot,
    ],
    expect.objectContaining({encoding: 'utf8', timeout: 5000}),
  ];

  test.each(
    [
      {
        arrange: returnsOutput('free\n'),
        expected: {kind: 'free'},
        name: String.raw`parses "free\n"`,
      },
      {
        arrange: returnsOutput('own 4242\n'),
        expected: {kind: 'own', pid: 4242},
        name: String.raw`parses "own 4242\n"`,
      },
      {
        arrange: returnsOutput('foreign 99 /other/tree\n'),
        expected: {kind: 'foreign', ownerPath: '/other/tree', pid: 99},
        name: String.raw`parses "foreign 99 /other/tree\n"`,
      },
      {
        arrange: returnsOutput('foreign 99 unknown\n'),
        expected: {kind: 'foreign', ownerPath: undefined, pid: 99},
        name: String.raw`parses "foreign 99 unknown\n"`,
      },
      {
        arrange: returnsOutput('foreign 0 unknown\n'),
        expected: {kind: 'foreign', ownerPath: undefined, pid: 0},
        name: String.raw`parses "foreign 0 unknown\n"`,
      },
      {
        arrange: returnsOutput('unknown\n'),
        expected: {kind: 'unknown'},
        name: String.raw`parses "unknown\n"`,
      },
      {
        arrange: returnsOutput('gibberish\n'),
        expected: {kind: 'unknown'},
        name: String.raw`parses "gibberish\n"`,
      },
      {
        arrange: throwsError('ETIMEDOUT'),
        expected: {kind: 'unknown'},
        name: 'maps a thrown error to unknown',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'findListenerOwner maps script output and failures to an owner: %s',
    (_name, {arrange, expected}) => {
      arrange();
      expect(findListenerOwner({port: 5176, treeRoot})).toEqual(expected);
      expect(execFileSyncMock).toHaveBeenCalledWith(...expectedProbeCall);
    }
  );

  test('maps an undefined tree root to unknown without probing', () => {
    expect(findListenerOwner({port: 5176, treeRoot: undefined})).toEqual({
      kind: 'unknown',
    });
    expect(execFileSyncMock).not.toHaveBeenCalled();
  });
});

describe('messages', () => {
  test('port in use names the port, service, owner, and ask-first text', () => {
    const message = buildPortInUseMessage({
      ownerPath: '/other/tree',
      pid: 99,
      port: 5176,
      service: 'dev server',
    });
    expect(message).toBe(
      `GAIA: port 5176, this tree's dev server port, is already in use by PID 99 in /other/tree. Refusing to start on a different port. ${ASK_FIRST_SENTENCE} ${PORTS_HINT}`
    );
    const messageWithoutOwner = buildPortInUseMessage({
      port: 6009,
      service: 'Storybook',
    });
    expect(messageWithoutOwner).toContain('port 6009');
    expect(messageWithoutOwner).toContain('Storybook');
    expect(messageWithoutOwner).not.toContain('PID');
    expect(
      messageWithoutOwner.endsWith(`${ASK_FIRST_SENTENCE} ${PORTS_HINT}`)
    ).toBe(true);
  });
});

const matchDefaults = (text: string, pattern: RegExp): number[] =>
  [...text.matchAll(pattern)].map((match) => Number(match[1]));

describe('slot-0 base ports match the shell defaults', () => {
  const scriptsDirectory = path.resolve(
    import.meta.dirname,
    '..',
    '..',
    '..',
    '.gaia',
    'scripts'
  );
  const readScript = (name: string): string =>
    fs.readFileSync(path.join(scriptsDirectory, name), 'utf8');

  test.each(
    [
      {
        devPattern: /GAIA_PORTS_DEV_BASE_PORT:-(\d+)\}/g,
        name: 'worktree-ports-lib.sh defaults equal the TypeScript base ports',
        script: 'worktree-ports-lib.sh',
        storybookPattern: /GAIA_PORTS_STORYBOOK_BASE_PORT:-(\d+)\}/g,
      },
      {
        devPattern: /GAIA_PORTS_DEV_BASE_PORT:-\}"\s+(\d+)\)/g,
        name: 'server-process-stop.sh defaults equal the TypeScript base ports',
        script: 'server-process-stop.sh',
        storybookPattern: /GAIA_PORTS_STORYBOOK_BASE_PORT:-\}"\s+(\d+)\)/g,
      },
    ].map((row) => [row.name, row] as const)
  )(
    'shell script port defaults equal the TypeScript base ports: %s',
    (_name, {devPattern, script, storybookPattern}) => {
      const text = readScript(script);

      expect(matchDefaults(text, devPattern)).toEqual([DEV_BASE_PORT]);
      expect(matchDefaults(text, storybookPattern)).toEqual([
        STORYBOOK_BASE_PORT,
      ]);
    }
  );
});
