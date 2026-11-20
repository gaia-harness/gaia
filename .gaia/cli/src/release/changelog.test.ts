import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  collectCommits,
  defaultRunner,
  graduateChangelog,
  groupCommits,
  renderBlock,
  run,
} from './changelog.js';
import type {CommandRunner} from './changelog.js';

// Narrows a graduateChangelog outcome to its 'ok' variant, failing the test
// loudly (rather than a conditional early-return) when it isn't.
function assertOk(
  outcome: ReturnType<typeof graduateChangelog>
): asserts outcome is Extract<
  ReturnType<typeof graduateChangelog>,
  {kind: 'ok'}
> {
  if (outcome.kind !== 'ok') {
    throw new Error(
      `expected graduateChangelog to return "ok", got "${outcome.kind}"`
    );
  }
}

// The graduated version block: everything from the new dated heading down to
// the heading of the version before it.
const blockBetween = (text: string, from: string, to: string): string =>
  text.slice(text.indexOf(from), text.indexOf(to));

// One definition of "nothing to release", shared by the unit and CLI tests so
// the two cannot drift apart about what an empty Unreleased section looks like.
const EMPTY_UNRELEASED = `# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

- old
`;

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (status: number): SpawnSyncReturns<string> => ({
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status,
  stderr: '',
  stdout: '',
});

const spawnErrorResult = (error: Error): SpawnSyncReturns<string> => ({
  error,
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status: null,
  stderr: '',
  stdout: '',
});

const buildLogOutput = (
  commits: {body?: string; subject: string}[]
): string => {
  const RECORD_SEPARATOR = '---END-COMMIT---';

  return commits
    .map(
      (commit) =>
        `${commit.subject}\n${commit.body ?? ''}\n${RECORD_SEPARATOR}\n`
    )
    .join('');
};

const buildRunner =
  (commits: {body?: string; subject: string}[]): CommandRunner =>
  (command, args) => {
    if (command === 'git' && args[0] === 'describe') {
      return failResult(128);
    }

    if (command === 'git' && args[0] === 'log') {
      return okResult(buildLogOutput(commits));
    }

    return okResult('');
  };

describe('defaultRunner', () => {
  // Asserted against a child that writes past Node's 1 MiB spawnSync default
  // rather than against the constant, so the test fails if the bound is
  // removed by any means.
  test('reads child stdout past the 1 MiB spawnSync default', () => {
    const size = 2 * 1024 * 1024;

    const result = defaultRunner(
      process.execPath,
      ['-e', `process.stdout.write('x'.repeat(${size}))`],
      {cwd: process.cwd()}
    );

    expect(result.error).toBeUndefined();
    expect(result.stdout).toHaveLength(size);
  });
});

const enobufsRunner: CommandRunner = () =>
  spawnErrorResult(new Error('spawnSync git ENOBUFS'));

describe('collectCommits', () => {
  test('throws with the spawn error rather than returning no commits', () => {
    expect(() =>
      collectCommits('/nonexistent', enobufsRunner, 'v1.0.0..HEAD')
    ).toThrow('git log failed: spawnSync git ENOBUFS');
  });
});

describe('groupCommits', () => {
  test.each<{
    commits: {body: string; subject: string}[];
    expected: {Added?: string[]; Changed?: string[]; Fixed?: string[]};
    name: string;
  }>([
    {
      commits: [
        {body: '', subject: 'feat: shiny'},
        {body: '', subject: 'fix: leak'},
        {body: '', subject: 'refactor: clean'},
        {body: '', subject: 'perf: tighten'},
        {body: '', subject: 'docs: update'},
        {body: '', subject: 'chore: bump'}, // omitted
        {body: '', subject: 'random commit'}, // omitted
      ],
      expected: {
        Added: ['shiny'],
        Changed: ['clean', 'tighten', 'update'],
        Fixed: ['leak'],
      },
      name: 'routes feat → Added, fix → Fixed, refactor/perf/docs → Changed',
    },
    {
      commits: [{body: '', subject: 'feat(auth): rotate tokens'}],
      expected: {Added: ['rotate tokens']},
      name: 'strips scope from subject',
    },
  ])('$name', ({commits, expected}) => {
    expect(groupCommits(commits)).toMatchObject(expected);
  });
});

describe('renderBlock', () => {
  test.each<{
    absent: RegExp[];
    name: string;
    present: RegExp[];
    sections: {Added: string[]; Changed: string[]; Fixed: string[]};
  }>([
    {
      absent: [/### Changed/u, /### Fixed/u],
      name: 'omits empty sections',
      present: [/### Added/u, /- a/u, /- b/u],
      sections: {Added: ['a', 'b'], Changed: [], Fixed: []},
    },
    {
      absent: [],
      name: 'orders Added → Changed → Fixed',
      present: [/### Added.*### Changed.*### Fixed/su],
      sections: {Added: ['a'], Changed: ['c'], Fixed: ['f']},
    },
  ])('$name', ({absent, present, sections}) => {
    const block = renderBlock(sections);
    for (const pattern of present) expect(block).toMatch(pattern);
    for (const pattern of absent) expect(block).not.toMatch(pattern);
  });
});

describe('graduateChangelog', () => {
  // The Unreleased body is POPULATED. Every assertion here used to run against
  // an empty one, which is what let #1146 stand: with nothing under the
  // heading there was nothing for a second block to collide with.
  const TEMPLATE = `# Changelog

## [Unreleased]

### Changed

- hand-written entry

## [1.0.0] - 2026-01-01

- Old entry
`;

  test('renames the Unreleased heading and opens a fresh empty one above', () => {
    const outcome = graduateChangelog({
      current: TEMPLATE,
      newVersion: '1.1.0',
      today: '2026-05-07',
    });
    assertOk(outcome);

    const unreleasedIdx = outcome.updated.indexOf('## [Unreleased]');
    const datedIndex = outcome.updated.indexOf('## [1.1.0] - 2026-05-07');
    expect(unreleasedIdx).toBeGreaterThan(-1);
    expect(datedIndex).toBeGreaterThan(unreleasedIdx);
    // The new Unreleased section is empty: nothing between the two headings.
    expect(outcome.updated.slice(unreleasedIdx, datedIndex).trim()).toBe(
      '## [Unreleased]'
    );
  });

  test('the released block carries the hand-written entries exactly once', () => {
    const outcome = graduateChangelog({
      current: TEMPLATE,
      newVersion: '1.1.0',
      today: '2026-05-07',
    });
    assertOk(outcome);

    const released = blockBetween(outcome.updated, '## [1.1.0]', '## [1.0.0]');
    expect(released.match(/^- hand-written entry$/gmu)).toHaveLength(1);
    expect(released.match(/^### Changed$/gmu)).toHaveLength(1);
  });

  const LINKS_ONLY = `# Changelog

## [Unreleased]

[Unreleased]: https://github.com/gaia-react/gaia/compare/v0.9.0...HEAD
`;
  const TIGHT_LINK = `# Changelog

## [Unreleased]

[Unreleased]:https://github.com/gaia-react/gaia/compare/v0.9.0...HEAD
`;

  test.each<{
    current: string;
    kind: string;
    name: string;
    newVersion: string;
  }>([
    {
      current: EMPTY_UNRELEASED,
      kind: 'empty-unreleased',
      name: 'returns empty-unreleased when the section has no entries',
      newVersion: '1.1.0',
    },
    {
      current: LINKS_ONLY,
      kind: 'empty-unreleased',
      name: 'returns empty-unreleased when only the link block follows',
      newVersion: '1.0.0',
    },
    {
      current: TIGHT_LINK,
      kind: 'empty-unreleased',
      name: 'returns empty-unreleased for a link definition with no space',
      newVersion: '1.0.0',
    },
    {
      current: TEMPLATE,
      kind: 'duplicate',
      name: 'returns duplicate when version already present',
      newVersion: '1.0.0',
    },
    {
      current: '# Changelog\n\n## [1.0.0] - 2026-01-01\n',
      kind: 'no-unreleased',
      name: 'returns no-unreleased when heading missing',
      newVersion: '1.1.0',
    },
  ])('$name', ({current, kind, newVersion}) => {
    const outcome = graduateChangelog({
      current,
      newVersion,
      today: '2026-05-07',
    });
    expect(outcome.kind).toBe(kind);
  });

  const FIRST_RELEASE = `# Changelog

## [Unreleased]

### Added

- initial thing

[Unreleased]: https://github.com/gaia-react/gaia/compare/v0.9.0...HEAD
`;
  const WITH_LINKS = `${TEMPLATE}
[Unreleased]: https://github.com/gaia-react/gaia/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0
`;

  // The positive direction of the empty-section rule: the link block ends the
  // body, it does not veto entries that precede it. Without the first row,
  // widening LINK_DEFINITION could start refusing real releases with the suite
  // green.
  test.each<{
    absent: string[];
    current: string;
    name: string;
    newVersion: string;
    present: string[];
  }>([
    {
      absent: [],
      current: FIRST_RELEASE,
      name: 'graduates entries that sit directly above the link block',
      newVersion: '1.0.0',
      present: [
        '## [1.0.0] - 2026-05-07',
        '- initial thing',
        '[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0',
      ],
    },
    {
      // [Unreleased] compare link repointed at the just-released version, the
      // new release-tag definition inserted, prior definitions preserved.
      absent: ['compare/v1.0.0...HEAD'],
      current: WITH_LINKS,
      name: 'maintains the reference-link block when one is present',
      newVersion: '1.1.0',
      present: [
        '[Unreleased]: https://github.com/gaia-react/gaia/compare/v1.1.0...HEAD',
        '[1.1.0]: https://github.com/gaia-react/gaia/releases/tag/v1.1.0',
        '[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0',
      ],
    },
    {
      absent: ['releases/tag/', '[Unreleased]:'],
      current: TEMPLATE,
      name: 'leaves the output link-free when the file has no link block',
      newVersion: '1.1.0',
      present: [],
    },
  ])('$name', ({absent, current, newVersion, present}) => {
    const outcome = graduateChangelog({
      current,
      newVersion,
      today: '2026-05-07',
    });
    assertOk(outcome);

    for (const text of present) expect(outcome.updated).toContain(text);
    for (const text of absent) expect(outcome.updated).not.toContain(text);
  });
});

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const SANDBOX_CHANGELOG =
  '# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- hand-written entry\n\n## [1.0.0] - 2026-01-01\n\n- old\n';

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-changelog-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify({name: 'gaia', version: currentVersion}, null, 2)}\n`,
    'utf8'
  );
  writeFileSync(path.join(root, 'CHANGELOG.md'), SANDBOX_CHANGELOG, 'utf8');

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

describe('release changelog CLI', () => {
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

  test.each<{
    args: string[];
    changelogAbsent: string[];
    changelogPresent: string[];
    commits: {subject: string}[];
    name: string;
    outContains: string[];
    version: string;
  }>([
    {
      args: ['--draft'],
      changelogAbsent: ['## [1.1.0]'],
      changelogPresent: [],
      commits: [
        {subject: 'feat: a'},
        {subject: 'fix: b'},
        {subject: 'docs: c'},
      ],
      name: '--draft prints rendered block to stdout',
      outContains: [
        '### Added',
        '- a',
        '### Fixed',
        '- b',
        '### Changed',
        '- c',
      ],
      version: '1.1.0',
    },
    {
      args: ['--version', '2.0.0'],
      changelogAbsent: [],
      changelogPresent: ['## [2.0.0] - 2026-05-07'],
      commits: [{subject: 'feat: shiny'}],
      name: '--version overrides package.json version',
      outContains: [],
      version: '1.0.0',
    },
  ])(
    '$name',
    ({
      args,
      changelogAbsent,
      changelogPresent,
      commits,
      outContains,
      version,
    }) => {
      sandbox = setupSandbox(version);

      const exit = run(args, {
        cwd: sandbox.root,
        runner: buildRunner(commits),
        today: '2026-05-07',
      });
      expect(exit).toBe(0);

      for (const text of outContains) {
        expect(stdio.outputs.join('')).toContain(text);
      }
      const changelog = readFileSync(
        path.join(sandbox.root, 'CHANGELOG.md'),
        'utf8'
      );
      for (const text of changelogPresent) expect(changelog).toContain(text);
      for (const text of changelogAbsent) expect(changelog).not.toContain(text);
    }
  );

  test('without --draft graduates the hand-written block and nothing generated', () => {
    sandbox = setupSandbox('1.1.0');
    // A commit that renders `### Changed` / `- shiny`, the same heading the
    // hand-written block already carries. #1146: both used to land under the
    // one dated heading.
    const runner = buildRunner([{subject: 'refactor: shiny'}]);

    const exit = run([], {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(exit).toBe(0);

    const changelog = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );
    expect(changelog).toContain('## [1.1.0] - 2026-05-07');
    expect(changelog).toContain('## [Unreleased]');

    const released = blockBetween(changelog, '## [1.1.0]', '## [1.0.0]');
    expect(released).toContain('- hand-written entry');
    expect(released.match(/^### Changed$/gmu)).toHaveLength(1);
    expect(changelog).not.toContain('- shiny');
  });

  test('idempotent: re-running with the same version is a no-op', () => {
    sandbox = setupSandbox('1.1.0');
    const runner = buildRunner([{subject: 'feat: shiny'}]);

    const first = run([], {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(first).toBe(0);
    const afterFirst = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );

    const second = run([], {cwd: sandbox.root, runner, today: '2026-05-08'});
    expect(second).toBe(0);
    const afterSecond = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );
    expect(afterSecond).toBe(afterFirst);
  });

  const unreleasedRunner = buildRunner([{subject: 'feat: shiny'}]);

  test.each<{
    args: string[];
    changelog: string;
    message: string;
    name: string;
    runner?: CommandRunner;
  }>([
    {
      args: [],
      changelog: EMPTY_UNRELEASED,
      message: 'empty_unreleased_section',
      name: 'exits 1 when the Unreleased section is empty',
      runner: unreleasedRunner,
    },
    {
      args: [],
      changelog: '# Changelog\n\n## [1.0.0] - 2026-01-01\n',
      message: 'no_unreleased_section',
      name: 'exits 1 when no Unreleased heading present',
      runner: unreleasedRunner,
    },
    {
      args: ['--bogus'],
      changelog: SANDBOX_CHANGELOG,
      message: 'unknown flag',
      name: 'rejects unknown flags',
    },
  ])('$name', ({args, changelog: seeded, message, runner}) => {
    sandbox = setupSandbox('1.1.0');
    writeFileSync(path.join(sandbox.root, 'CHANGELOG.md'), seeded, 'utf8');

    const exit = run(args, {cwd: sandbox.root, runner, today: '2026-05-07'});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(message);

    const changelog = readFileSync(
      path.join(sandbox.root, 'CHANGELOG.md'),
      'utf8'
    );
    expect(changelog).not.toContain('## [1.1.0]');
  });
});
