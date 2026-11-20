import {dump as dumpYaml, load as parseYaml} from 'js-yaml';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {deriveExcludedRefTokens} from './excluded-refs.js';
import {listGitFiles, parseExcludeLines} from './manifest.js';
import {stripPnpmMember} from './pnpm-member-strip.js';
import {globToRegex, loadConfig, parseKeyPath, run} from './scrub.js';

const JSON_STRIP_CONFIG = `
transforms:
  - type: json-strip
    paths:
      - "package.json"
    keys:
      - "bin"
      - "scripts.test:forensics"
`;

const ARRAY_ELEMENT_CONFIG = `
transforms:
  - type: json-strip-array-element
    paths:
      - ".claude/settings.json"
    selectors:
      - path: "hooks.PreToolUse[].hooks[]"
        match: {command: ".claude/hooks/pr-merge-audit-check.sh"}
`;

type Sandbox = {
  cleanup: () => void;
  configPath: string;
  rootDir: string;
  stagingDir: string;
  writeSource: (relativePath: string, contents: string) => void;
  writeStaged: (relativePath: string, contents: string) => void;
};

type SandboxOptions = {
  config: string;
};

const setupSandbox = (options: SandboxOptions): Sandbox => {
  const rootDir = mkdtempSync(path.join(tmpdir(), 'gaia-release-scrub-'));
  const stagingDir = path.join(rootDir, 'staging');
  mkdirSync(stagingDir, {recursive: true});
  mkdirSync(path.join(rootDir, '.gaia'), {recursive: true});
  const configPath = path.join(rootDir, '.gaia', 'release-scrub.yml');
  writeFileSync(configPath, options.config, 'utf8');

  return {
    cleanup: () => {
      rmSync(rootDir, {force: true, recursive: true});
    },
    configPath,
    rootDir,
    stagingDir,
    writeSource: (relativePath, contents) => {
      const absolute = path.join(rootDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
    },
    writeStaged: (relativePath, contents) => {
      const absolute = path.join(stagingDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
    },
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

const MARKER_ONLY_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "wiki/**/*.md"
      - ".claude/**/*.md"
    start: "<!-- gaia:maintainer-only:start -->"
    end: "<!-- gaia:maintainer-only:end -->"
`;

const LEAK_ONLY_CONFIG = String.raw`
transforms:
  - type: leak-check
    checks:
      - id: flow-narrative
        pattern: "FLOW-[0-9]{3}"
        scope:
          - ".claude/**"
        line-allowlist:
          - "flow[-_]id"
      - id: maintainer-paths
        pattern: "\\.gaia/cli/src/"
        scope:
          - ".claude/**"
          - "wiki/**"
        path-allowlist:
          - "wiki/decisions/Allowed Page.md"
`;

const FULL_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "wiki/**/*.md"
    start: "<!-- gaia:maintainer-only:start -->"
    end: "<!-- gaia:maintainer-only:end -->"

  - type: leak-check
    checks:
      - id: flow-narrative
        pattern: "FLOW-[0-9]{3}"
        scope:
          - "wiki/**"
`;

// Mirrors the shipped `workflow-denylist` check in .gaia/release-scrub.yml. The
// leak-check tests are hermetic (they do not load the real config), so the
// pattern is copied verbatim; the FP-guard case below is what proves the inline
// alternation stays quote-anchored if either side drifts.
const WORKFLOW_DENYLIST_CONFIG = String.raw`
transforms:
  - type: leak-check
    checks:
      - id: workflow-denylist
        pattern: "^\\s*paths-ignore\\s*:|^\\s*-\\s*['\"]?!|\\[[^\\]]*['\"]!"
        scope:
          - ".github/workflows/**"
`;

// One scrub run over a mkdtemp sandbox, described by a case row. Rows differ
// only in data (config, files, expected exit and output), so each describe
// below is a single `test.each` table. Optional columns default to "no
// assertion"; `seed` is a setup function for fixtures built from code.
type ScrubCase = {
  after?: Record<string, string[]>;
  afterJson?: Record<string, unknown>;
  afterRaw?: Record<string, string>;
  args?: string[];
  config: string;
  deps?: NonNullable<Parameters<typeof run>[1]>;
  err?: string[];
  exit: number;
  name: string;
  notAfter?: Record<string, string[]>;
  notOut?: string[];
  out?: string[];
  outMatch?: RegExp[];
  report?: Record<string, unknown>;
  seed?: (target: Sandbox) => void;
  source?: Record<string, string>;
  staged?: Record<string, string>;
};

const readStaged = (target: Sandbox, file: string): string =>
  readFileSync(path.join(target.stagingDir, file), 'utf8');

const expectStagedFiles = (target: Sandbox, row: ScrubCase): void => {
  const {after = {}, afterJson = {}, afterRaw = {}, notAfter = {}} = row;

  for (const [file, needles] of Object.entries(after)) {
    for (const needle of needles) {
      expect(readStaged(target, file)).toContain(needle);
    }
  }

  for (const [file, needles] of Object.entries(notAfter)) {
    for (const needle of needles) {
      expect(readStaged(target, file)).not.toContain(needle);
    }
  }

  for (const [file, contents] of Object.entries(afterRaw)) {
    expect(readStaged(target, file)).toBe(contents);
  }

  for (const [file, value] of Object.entries(afterJson)) {
    expect(JSON.parse(readStaged(target, file))).toEqual(value);
  }
};

const runScrubCase = (row: ScrubCase): void => {
  const {
    args = [],
    config,
    deps = {},
    err = [],
    exit,
    notOut = [],
    out = [],
    outMatch = [],
    report = {},
    seed,
    source = {},
    staged = {},
  } = row;
  const target = setupSandbox({config});
  const stdio = captureStdio();

  try {
    seed?.(target);

    for (const [file, contents] of Object.entries(source)) {
      target.writeSource(file, contents);
    }

    for (const [file, contents] of Object.entries(staged)) {
      target.writeStaged(file, contents);
    }

    const code = run(
      [target.stagingDir, '--config', target.configPath, ...args],
      {cwd: target.rootDir, ...deps}
    );
    const stdout = stdio.outputs.join('');
    const stderr = stdio.errors.join('');

    expect(code).toBe(exit);

    for (const needle of out) expect(stdout).toContain(needle);
    for (const needle of notOut) expect(stdout).not.toContain(needle);
    for (const pattern of outMatch) expect(stdout).toMatch(pattern);

    for (const needle of err) {
      expect(stderr).toContain(
        needle.replaceAll('<staging>', target.stagingDir)
      );
    }

    expectStagedFiles(target, row);

    const parsedReport = (
      Object.keys(report).length > 0 ?
        JSON.parse(stdout)
      : {}) as Record<string, unknown>;

    for (const [key, value] of Object.entries(report)) {
      expect(parsedReport[key]).toEqual(value);
    }
  } finally {
    stdio.restore();
    target.cleanup();
    vi.restoreAllMocks();
  }
};

describe('globToRegex', () => {
  test.each([
    {
      glob: 'CLAUDE.md',
      matches: ['CLAUDE.md'],
      misses: ['foo/CLAUDE.md'],
      name: 'matches single-segment files',
    },
    {
      glob: 'wiki/**/*.md',
      matches: ['wiki/foo.md', 'wiki/sub/foo.md', 'wiki/a/b/c/foo.md'],
      misses: ['other/foo.md'],
      name: '** matches zero or more segments',
    },
    {
      glob: '.claude/**',
      matches: ['.claude/skills/foo.md', '.claude/rules/wiki-style.md'],
      misses: ['app/components/Foo.tsx'],
      name: 'trailing /** matches everything below the prefix',
    },
    {
      glob: 'wiki/*.md',
      matches: ['wiki/foo.md'],
      misses: ['wiki/sub/foo.md'],
      name: '* matches a single segment only',
    },
  ])('$name', ({glob, matches, misses}) => {
    const re = globToRegex(glob);

    for (const candidate of matches) expect(re.test(candidate)).toBe(true);
    for (const candidate of misses) expect(re.test(candidate)).toBe(false);
  });
});

describe('release scrub CLI', () => {
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

  test('strips a multi-line maintainer-only block', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        '## Public',
        '',
        '- thing',
        '',
        '<!-- gaia:maintainer-only:start -->',
        '## Maintainer-only',
        '',
        '- secret',
        '<!-- gaia:maintainer-only:end -->',
        '',
        '## More public',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.stagingDir, 'wiki/index.md'),
      'utf8'
    );
    expect(after).not.toContain('Maintainer-only');
    expect(after).not.toContain('secret');
    expect(after).not.toContain('gaia:maintainer-only');
    expect(after).toContain('## Public');
    expect(after).toContain('## More public');
  });

  test('leaves files without markers untouched', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    const original = '# Foo\n\nbody\n';
    sandbox.writeStaged('wiki/foo.md', original);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.stagingDir, 'wiki/foo.md'),
      'utf8'
    );
    expect(after).toBe(original);
  });

  test('keeps the executable bit on a file it strips', () => {
    sandbox = setupSandbox({
      config: `
transforms:
  - type: marker-strip
    paths:
      - ".githooks/*"
    start: "# gaia:maintainer-only:start"
    end: "# gaia:maintainer-only:end"
`,
    });
    sandbox.writeStaged(
      '.githooks/pre-commit',
      [
        '#!/usr/bin/env bash',
        '# gaia:maintainer-only:start',
        'echo maintainer',
        '# gaia:maintainer-only:end',
        'echo public',
        '',
      ].join('\n')
    );
    const hookPath = path.join(sandbox.stagingDir, '.githooks/pre-commit');
    chmodSync(hookPath, 0o755);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    expect(readFileSync(hookPath, 'utf8')).not.toContain('echo maintainer');
    expect(statSync(hookPath).mode % 0o1000).toBe(0o755);
  });

  test.each([
    {
      content: [
        '# Broken',
        '<!-- gaia:maintainer-only:start -->',
        'never closed',
        '',
      ].join('\n'),
      name: 'refuses on unbalanced start without end',
      needles: ['start_without_end'],
    },
    {
      content: ['# Broken', '', '<!-- gaia:maintainer-only:end -->', ''].join(
        '\n'
      ),
      name: 'refuses on unbalanced end without start',
      needles: ['end_without_start'],
    },
    {
      content: [
        '# Broken',
        'Adopter prose the strip would drop. <!-- gaia:maintainer-only:start -->',
        'maintainer note',
        '<!-- gaia:maintainer-only:end -->',
        '',
      ].join('\n'),
      name: 'refuses a start marker line that carries prose before the marker',
      needles: ['wiki/broken.md:2', 'marker_line_has_text'],
    },
    {
      content: [
        '# Broken',
        '<!-- gaia:maintainer-only:start --> note <!-- gaia:maintainer-only:end --> Adopter prose.',
        '',
      ].join('\n'),
      name: 'refuses a single-line block with prose outside its markers',
      needles: ['marker_line_has_text'],
    },
  ])('$name', ({content, needles}) => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged('wiki/broken.md', content);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    for (const needle of needles) {
      expect(stdio.outputs.join('')).toContain(needle);
    }
  });

  test.each([
    {
      content: [
        '# Broken',
        '<!-- gaia:maintainer-only:start -->',
        'never closed',
        '',
      ].join('\n'),
      expected: {file: 'wiki/broken.md', line: 2, reason: 'start_without_end'},
      name: '--json reports an unbalanced marker with file, line, and reason',
    },
    {
      content: [
        '# Broken',
        '<!-- gaia:maintainer-only:start -->',
        'maintainer note',
        '<!-- gaia:maintainer-only:end --> Adopter prose the strip would drop.',
        '',
      ].join('\n'),
      expected: {
        file: 'wiki/broken.md',
        line: 4,
        reason: 'marker_line_has_text',
      },
      name: 'refuses an end marker line that carries prose after the marker',
    },
  ])('$name', ({content, expected}) => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged('wiki/broken.md', content);

    const exit = run([sandbox.stagingDir, '--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const report = JSON.parse(stdio.outputs.join('')) as {
      unbalanced_markers: {file: string; line: number; reason: string}[];
    };
    expect(report.unbalanced_markers).toEqual([expected]);
  });

  test.each([
    {
      content: [
        '# Single',
        '  <!-- gaia:maintainer-only:start --> note <!-- gaia:maintainer-only:end -->',
        'public',
        '',
      ].join('\n'),
      expected: '# Single\npublic\n',
      file: 'wiki/single.md',
      name: 'accepts a single-line block with nothing outside its markers',
    },
    {
      content: [
        '- a list item',
        '  <!-- gaia:maintainer-only:start -->',
        '  maintainer note',
        '  <!-- gaia:maintainer-only:end -->',
        '- another item',
        '',
      ].join('\n'),
      expected: '- a list item\n- another item\n',
      file: 'wiki/indented.md',
      name: 'accepts indented marker lines and strips their block',
    },
  ])('$name', ({content, expected, file}) => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged(file, content);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(path.join(sandbox.stagingDir, file), 'utf8');
    expect(after).toBe(expected);
  });

  test('exempts allowlisted paths from leak-check', () => {
    sandbox = setupSandbox({config: LEAK_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/decisions/Allowed Page.md',
      '# Allowed\n\nReferences `.gaia/cli/src/foo.ts` legitimately.\n'
    );
    sandbox.writeStaged(
      'wiki/decisions/Other.md',
      '# Other\n\nReferences `.gaia/cli/src/bar.ts` illegitimately.\n'
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const out = stdio.outputs.join('');
    expect(out).toContain('wiki/decisions/Other.md');
    expect(out).not.toContain('wiki/decisions/Allowed Page.md');
  });

  test('--json emits structured report', () => {
    sandbox = setupSandbox({config: FULL_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        '<!-- gaia:maintainer-only:start -->',
        'Refers to FLOW-007 inside the maintainer block.',
        '<!-- gaia:maintainer-only:end -->',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir, '--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: readonly {check: string; file: string; line: number}[];
      marker_strip: {
        blocks_stripped: number;
        files_touched: readonly string[];
      };
      unbalanced_markers: readonly {
        file: string;
        line: number;
        reason: string;
      }[];
    };

    expect(parsed.marker_strip.blocks_stripped).toBe(1);
    expect(parsed.marker_strip.files_touched).toContain('wiki/index.md');
    expect(parsed.leaks).toHaveLength(0);
    // The distribution leak-replay harness reads this section by length, and
    // `null | length` is 0 in jq, so an omitted section would read as clean
    // there. Pin its presence and shape here so the contract is held from the
    // producing end too, the same way `leaks` already is.
    expect(parsed.unbalanced_markers).toEqual([]);
  });

  test('marker-strip happens before leak-check (block content not flagged)', () => {
    sandbox = setupSandbox({config: FULL_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        'Public content.',
        '<!-- gaia:maintainer-only:start -->',
        'FLOW-001 maintainer reference.',
        '<!-- gaia:maintainer-only:end -->',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test.each([
    {
      args: (target: Sandbox) => [path.join(target.rootDir, 'no-such')],
      config: MARKER_ONLY_CONFIG,
      exit: 1,
      name: 'exits 1 when staging dir does not exist',
      needle: 'staging_dir_missing',
    },
    {
      args: () => [] as string[],
      config: MARKER_ONLY_CONFIG,
      exit: 1,
      name: 'exits 1 when staging dir argument is missing',
      needle: 'missing_staging_dir',
    },
    {
      args: (target: Sandbox) => [target.stagingDir],
      config: 'transforms:\n  - type: marker-strip\n',
      exit: 2,
      name: 'exits 2 on malformed config',
      needle: 'config_load_failed',
    },
    {
      args: (target: Sandbox) => [target.stagingDir, '--bogus'],
      config: MARKER_ONLY_CONFIG,
      exit: 1,
      name: 'rejects unknown flags',
      needle: 'unknown flag',
    },
  ])('$name', ({args, config, exit: expectedExit, needle}) => {
    sandbox = setupSandbox({config});
    sandbox.writeStaged('wiki/index.md', '# x\n');

    const exit = run(args(sandbox), {cwd: sandbox.rootDir});
    expect(exit).toBe(expectedExit);
    expect(stdio.errors.join('')).toContain(needle);
  });
});

describe('workflow-denylist leak-check', () => {
  test.each<ScrubCase>([
    {
      config: WORKFLOW_DENYLIST_CONFIG,
      exit: 1,
      name: 'flags an inverted entry in an inline flow array',
      out: ['workflow-denylist', '.github/workflows/tests.yml'],
      staged: {
        '.github/workflows/tests.yml': [
          'on:',
          '  push:',
          '    paths: ["src/**", "!*.md"]',
          '',
        ].join('\n'),
      },
    },
    {
      config: WORKFLOW_DENYLIST_CONFIG,
      exit: 1,
      name: 'flags a block-list inverted entry and a paths-ignore key',
      out: ['workflow-denylist'],
      staged: {
        '.github/workflows/chromatic.yml': [
          'on:',
          '  push:',
          '    paths-ignore:',
          '      - "!*.md"',
          '',
        ].join('\n'),
      },
    },
    {
      config: WORKFLOW_DENYLIST_CONFIG,
      exit: 0,
      name: 'does not flag a pure allowlist inline array (quote-anchored FP guard)',
      out: ['leaks: none'],
      staged: {
        '.github/workflows/tests.yml': [
          'on:',
          '  push:',
          '    paths: ["src/**", "app/**"]',
          'jobs:',
          '  build:',
          '    steps:',
          '      - run: echo "[!warn] no bang leak here"',
          '',
        ].join('\n'),
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

describe('json-strip transform', () => {
  const BIN = {gaia: './.gaia/cli/gaia'};
  const FORENSICS = 'bats .gaia/tests/forensics/unit.bats';
  const noopOriginal = JSON.stringify(
    {name: 'my-app', scripts: {build: 'react-router build'}},
    null,
    2
  );
  const untouchedOther = JSON.stringify({bin: BIN}, null, 2);

  test.each<ScrubCase>([
    {
      afterJson: {'package.json': {name: 'my-app', scripts: {}}},
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'removes a top-level key',
      staged: {
        'package.json': JSON.stringify(
          {bin: BIN, name: 'my-app', scripts: {}},
          null,
          2
        ),
      },
    },
    {
      afterJson: {
        'package.json': {scripts: {build: 'react-router build'}},
      },
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'removes a nested key via dot-notation',
      staged: {
        'package.json': JSON.stringify(
          {
            scripts: {
              build: 'react-router build',
              'test:forensics': FORENSICS,
            },
          },
          null,
          2
        ),
      },
    },
    {
      afterJson: {
        'package.json': {
          name: 'my-app',
          scripts: {build: 'react-router build'},
        },
      },
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'removes multiple keys in one pass',
      staged: {
        'package.json': JSON.stringify(
          {
            bin: BIN,
            name: 'my-app',
            scripts: {
              build: 'react-router build',
              'test:forensics': FORENSICS,
            },
          },
          null,
          2
        ),
      },
    },
    {
      afterJson: {'package.json': JSON.parse(noopOriginal)},
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'no-ops when key does not exist',
      staged: {'package.json': noopOriginal},
    },
    {
      afterRaw: {'other.json': untouchedOther},
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'only processes files matching the paths glob',
      staged: {'other.json': untouchedOther},
    },
    {
      config: JSON_STRIP_CONFIG,
      err: ['transform_failed'],
      exit: 2,
      name: 'exits 2 on invalid JSON',
      staged: {'package.json': 'not { valid json'},
    },
    {
      args: ['--json'],
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: '--json report includes json_strip section',
      report: {
        json_strip: {files_touched: ['package.json'], keys_removed: 1},
      },
      staged: {
        'package.json': JSON.stringify({bin: BIN, scripts: {}}, null, 2),
      },
    },
    {
      args: ['--json'],
      config: JSON_STRIP_CONFIG,
      exit: 0,
      name: 'no-op when no matching files produces zero counts',
      report: {json_strip: {files_touched: [], keys_removed: 0}},
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

const hook = (command: string): {command: string; type: string} => ({
  command,
  type: 'command',
});
const settingsJson = (value: unknown): string => JSON.stringify(value, null, 2);

describe('json-strip-array-element transform', () => {
  const TARGET_HOOK = '.claude/hooks/pr-merge-audit-check.sh';
  const SETTINGS_PATH = '.claude/settings.json';
  const TARGET_ENTRY = {
    command: TARGET_HOOK,
    statusMessage: 'Checking PR-merge audit gate…',
    type: 'command',
  };
  const staleSelector = settingsJson({
    hooks: {
      PreToolUse: [
        {
          hooks: [
            hook('.claude/hooks/block-bare-test.sh'),
            hook('.claude/hooks/block-rm-rf.sh'),
          ],
          matcher: 'Bash',
        },
      ],
    },
  });
  const missingPath = settingsJson({
    permissions: {allow: ['Bash(pnpm test:*)']},
  });
  // PreToolUse is an object, not the array the selector expects.
  const wrongShape = settingsJson({hooks: {PreToolUse: {matcher: 'Bash'}}});

  test.each<ScrubCase>([
    {
      // The array stays well-formed: the surviving sibling remains, the
      // target hook is gone.
      afterJson: {
        [SETTINGS_PATH]: {
          hooks: {
            PreToolUse: [
              {
                hooks: [hook('.claude/hooks/block-bare-test.sh')],
                matcher: 'Bash',
              },
            ],
          },
        },
      },
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'removes the matching element and leaves a well-formed array',
      staged: {
        [SETTINGS_PATH]: settingsJson({
          hooks: {
            PreToolUse: [
              {
                hooks: [hook('.claude/hooks/block-bare-test.sh'), TARGET_ENTRY],
                matcher: 'Bash',
              },
            ],
          },
        }),
      },
    },
    {
      // A no-op must leave the shipped settings byte-for-byte untouched.
      afterRaw: {[SETTINGS_PATH]: staleSelector},
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'no-ops when the predicate matches nothing (stale selector safety)',
      staged: {[SETTINGS_PATH]: staleSelector},
    },
    {
      // The emptied matcher entry survives with a well-formed empty hooks
      // array; it is neither collapsed nor removed, and its sibling is
      // untouched.
      afterJson: {
        [SETTINGS_PATH]: {
          hooks: {
            PreToolUse: [
              {
                hooks: [hook('.claude/hooks/audit-loop-bound.sh')],
                matcher: 'Skill',
              },
              {hooks: [], matcher: 'Bash'},
            ],
          },
        },
      },
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'leaves an emptied hooks[] as [] and keeps its matcher entry',
      staged: {
        [SETTINGS_PATH]: settingsJson({
          hooks: {
            PreToolUse: [
              {
                hooks: [hook('.claude/hooks/audit-loop-bound.sh')],
                matcher: 'Skill',
              },
              {hooks: [TARGET_ENTRY], matcher: 'Bash'},
            ],
          },
        }),
      },
    },
    {
      // Non-targeted entries are untouched; only the target hook's element is
      // removed from the Bash entry; unrelated sections survive.
      afterJson: {
        [SETTINGS_PATH]: {
          env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1'},
          hooks: {
            PreToolUse: [
              {
                hooks: [
                  hook('.claude/hooks/block-env-write.sh'),
                  hook('.claude/hooks/block-manifest-write.sh'),
                ],
                matcher: 'Edit|Write',
              },
              {
                hooks: [
                  hook('.claude/hooks/block-no-verify.sh'),
                  hook('.claude/hooks/block-rm-rf.sh'),
                ],
                matcher: 'Bash',
              },
            ],
            Stop: [
              {
                hooks: [hook('.claude/hooks/wiki-session-stop.sh')],
                matcher: '',
              },
            ],
          },
        },
      },
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'removes only the targeted element across multiple matcher entries',
      staged: {
        [SETTINGS_PATH]: settingsJson({
          env: {CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1'},
          hooks: {
            PreToolUse: [
              {
                hooks: [
                  hook('.claude/hooks/block-env-write.sh'),
                  hook('.claude/hooks/block-manifest-write.sh'),
                ],
                matcher: 'Edit|Write',
              },
              {
                hooks: [
                  hook('.claude/hooks/block-no-verify.sh'),
                  TARGET_ENTRY,
                  hook('.claude/hooks/block-rm-rf.sh'),
                ],
                matcher: 'Bash',
              },
            ],
            Stop: [
              {
                hooks: [hook('.claude/hooks/wiki-session-stop.sh')],
                matcher: '',
              },
            ],
          },
        }),
      },
    },
    {
      afterRaw: {[SETTINGS_PATH]: missingPath},
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'no-ops without throwing when the selector path is missing',
      staged: {[SETTINGS_PATH]: missingPath},
    },
    {
      afterRaw: {[SETTINGS_PATH]: wrongShape},
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: 'no-ops without throwing when a path segment has the wrong shape',
      staged: {[SETTINGS_PATH]: wrongShape},
    },
    {
      config: ARRAY_ELEMENT_CONFIG,
      err: ['transform_failed'],
      exit: 2,
      name: 'exits 2 on invalid JSON',
      staged: {[SETTINGS_PATH]: 'not { valid json'},
    },
    {
      args: ['--json'],
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: '--json report includes the json_strip_array_element section',
      report: {
        json_strip_array_element: {
          elements_removed: 1,
          files_touched: [SETTINGS_PATH],
        },
      },
      staged: {
        [SETTINGS_PATH]: settingsJson({
          hooks: {PreToolUse: [{hooks: [TARGET_ENTRY], matcher: 'Bash'}]},
        }),
      },
    },
    {
      args: ['--json'],
      config: ARRAY_ELEMENT_CONFIG,
      exit: 0,
      name: '--json report reports zero when no element matches',
      report: {
        json_strip_array_element: {elements_removed: 0, files_touched: []},
      },
      staged: {
        [SETTINGS_PATH]: settingsJson({
          hooks: {
            PreToolUse: [
              {
                hooks: [hook('.claude/hooks/block-bare-test.sh')],
                matcher: 'Bash',
              },
            ],
          },
        }),
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

describe('parseKeyPath', () => {
  test.each([
    {
      expected: ['scripts', 'test:forensics'],
      input: 'scripts.test:forensics',
      name: 'splits on unescaped dots',
    },
    {
      expected: ['bin'],
      input: 'bin',
      name: 'returns a single segment for a plain key',
    },
  ])('$name', ({expected, input}) => {
    expect(parseKeyPath(input)).toEqual(expected);
  });
});

// Derived wikilink-to-excluded check

const WIKILINK_DERIVED_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: wikilink-to-excluded
        derive: excluded-slugs
        scope:
          - "wiki/**/*.md"
        path-allowlist:
          - "wiki/hot.md"
          - "wiki/log.md"
`;

// Representative `.gaia/release-exclude` body: a comment, blank lines, two
// bare-directory excludes (entities, meta), two `.md` file excludes, and
// non-wiki lines that the slug derivation must ignore.
const EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '',
  'wiki/entities',
  'wiki/meta',
  'wiki/concepts/Release Workflow.md',
  'wiki/decisions/Bundle-time Scrub.md',
  '.gaia/release-exclude',
  '.claude/commands/gaia-release.md',
].join('\n');

// Lay down the source-tree inputs the derived check reads from cwd: the
// release-exclude manifest plus real pages inside the excluded directories
// (slugs that are NEVER enumerated as exclude lines).
const seedExcludedSource = (sandbox: Sandbox): void => {
  sandbox.writeSource('.gaia/release-exclude', EXCLUDE_FIXTURE);
  sandbox.writeSource('wiki/entities/GAIA.md', '# GAIA\n');
  sandbox.writeSource('wiki/entities/Steven Sacks.md', '# Steven Sacks\n');
  sandbox.writeSource('wiki/meta/dashboard.md', '# Wiki Dashboard\n');
  sandbox.writeSource(
    'wiki/meta/lint-report-2026-06-25.md',
    '# Lint Report: 2026-06-25\n'
  );
};

describe('wikilink-to-excluded derived check', () => {
  const MIXED_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: flow-narrative
        pattern: "FLOW-[0-9]{3}"
        scope:
          - "wiki/**"
      - id: wikilink-to-excluded
        derive: excluded-slugs
        scope:
          - "wiki/**/*.md"
        path-allowlist:
          - "wiki/hot.md"
`;

  test.each<ScrubCase>([
    {
      // The #1 trap: `.gaia/release-exclude` excludes itself, so it is absent
      // from the staging tree every other check scans. An implementation that
      // reads it from staging finds nothing and silently passes.
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'derives the slug set from cwd release-exclude, not the staging tree',
      out: ['wikilink-to-excluded', 'Bundle-time Scrub'],
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/Foo.md':
          '# Foo\n\nSee [[Bundle-time Scrub]] for the rationale.\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a wikilink to a page inside a bare-directory exclude',
      out: ['GAIA', 'Steven Sacks'],
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/Bar.md':
          '# Bar\n\nBuilt on [[GAIA]] and [[Steven Sacks]].\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a wikilink to a dated artifact inside an excluded directory',
      out: ['lint-report-2026-06-25'],
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/Baz.md': '# Baz\n\nSee [[lint-report-2026-06-25]].\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a newly excluded page with no config change (drift-proof)',
      out: ['Brand New Decision'],
      seed: seedExcludedSource,
      // A slug that never appeared in the old hand-maintained alternation.
      source: {
        '.gaia/release-exclude': `${EXCLUDE_FIXTURE}\nwiki/decisions/Brand New Decision.md\n`,
      },
      staged: {
        'wiki/concepts/Qux.md': '# Qux\n\nSee [[Brand New Decision]].\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag wikilinks to shipped (non-excluded) pages',
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/Quux.md':
          '# Quux\n\nSee [[Some Shipped Concept]] and [[Another Page]].\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 0,
      name: 'exempts allowlisted hot.md / log.md from the derived check',
      seed: seedExcludedSource,
      staged: {
        'wiki/hot.md': '# Hot\n\n[[Bundle-time Scrub]]\n',
        'wiki/log.md': '# Log\n\n[[GAIA]]\n',
      },
    },
    {
      // The old regex required `]]` immediately after the slug, so it missed
      // `[[GAIA|alias]]` and `[[Bundle-time Scrub#anchor]]`. extractWikilinks
      // normalizes both away before the Set test.
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'flags an aliased or anchored wikilink to an excluded slug',
      out: ['Bundle-time Scrub', 'Release Workflow'],
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/Aliased.md':
          '# Aliased\n\nSee [[Bundle-time Scrub|the scrub ADR]] and [[Release Workflow#Step 3]].\n',
      },
    },
    {
      config: WIKILINK_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a wikilink to an excluded directory name (case-insensitive)',
      seed: seedExcludedSource,
      staged: {
        'wiki/concepts/DirLink.md':
          '# DirLink\n\nSee [[Entities]] and [[meta]].\n',
      },
    },
    {
      config: MIXED_CONFIG,
      exit: 1,
      name: 'runs a static check and the derived check in one config',
      out: ['flow-narrative', 'wikilink-to-excluded'],
      seed: seedExcludedSource,
      staged: {
        'wiki/a.md': '# A\n\nFLOW-007 reference.\n',
        'wiki/b.md': '# B\n\n[[Bundle-time Scrub]]\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Derived excluded-workflow-ref check

const WORKFLOW_DERIVED_CONFIG = String.raw`
transforms:
  - type: leak-check
    checks:
      - id: excluded-workflow-ref
        derive: excluded-workflows
        scope:
          - ".claude/**"
          - ".github/workflows/**"
          - ".gaia/cli/templates/**"
        line-allowlist:
          - "\\[ -f \\.github/workflows/forensics-triage\\.yml \\]"
`;

// Representative `.gaia/release-exclude`: three excluded workflows plus
// non-workflow lines the workflow derivation must ignore.
const WORKFLOW_EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '',
  '.github/workflows/release.yml',
  '.github/workflows/forensics-triage.yml',
  '.github/workflows/maintainer-only.yml',
  '.gaia/release-exclude',
  'wiki/entities',
].join('\n');

const seedWorkflowSource = (sandbox: Sandbox): void => {
  sandbox.writeSource('.gaia/release-exclude', WORKFLOW_EXCLUDE_FIXTURE);
};

// Code Audit Team: audit-ci.yml / shipped-shell marker-strip +
// maintainer-audit-members leak-check

const AUDIT_CI_MARKER_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - ".gaia/audit-ci.yml"
      - "**/*.sh"
    start: "# gaia:maintainer-only:start"
    end: "# gaia:maintainer-only:end"
`;

const MAINTAINER_AUDIT_MEMBERS_LEAK_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: maintainer-audit-members
        pattern: "code-audit-maintainer-"
        scope:
          - ".claude/**"
          - ".gaia/scripts/**"
          - ".gaia/audit-ci.yml"
`;

describe('audit-ci.yml / shipped-shell marker-strip', () => {
  test.each<ScrubCase>([
    {
      after: {'.gaia/audit-ci.yml': ['code-audit-frontend']},
      config: AUDIT_CI_MARKER_CONFIG,
      exit: 0,
      name: 'strips a marker-wrapped roster entry from a .gaia/audit-ci.yml-shaped fixture',
      notAfter: {
        '.gaia/audit-ci.yml': [
          'code-audit-maintainer-shell',
          'gaia:maintainer-only',
        ],
      },
      staged: {
        '.gaia/audit-ci.yml': [
          'auditors:',
          '  - name: code-audit-frontend',
          '    globs:',
          '      - "app/**"',
          '    audience: adopter',
          '    default: true',
          '  # gaia:maintainer-only:start',
          '  - name: code-audit-maintainer-shell',
          '    globs:',
          '      - ".gaia/**/*.sh"',
          '    audience: maintainer',
          '  # gaia:maintainer-only:end',
          '',
        ].join('\n'),
      },
    },
    {
      after: {
        '.gaia/scripts/resolve-audit-members.sh': ['code-audit-frontend'],
      },
      config: AUDIT_CI_MARKER_CONFIG,
      exit: 0,
      name: 'strips a marker-wrapped block from a shipped .sh fixture',
      notAfter: {
        '.gaia/scripts/resolve-audit-members.sh': [
          'code-audit-maintainer-shell',
        ],
      },
      staged: {
        '.gaia/scripts/resolve-audit-members.sh': [
          '#!/usr/bin/env bash',
          'builtin_roster() {',
          '  cat <<YAML',
          'auditors:',
          '  - name: code-audit-frontend',
          '    default: true',
          '  # gaia:maintainer-only:start',
          '  - name: code-audit-maintainer-shell',
          '  # gaia:maintainer-only:end',
          'YAML',
          '}',
          '',
        ].join('\n'),
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

describe('maintainer-audit-members leak-check', () => {
  const HEADER_TRIPWIRE_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "**/*.sh"
    start: "# gaia:maintainer-only:start"
    end: "# gaia:maintainer-only:end"

  - type: leak-check
    checks:
      - id: maintainer-audit-members
        pattern: "code-audit-maintainer-"
        scope:
          - ".gaia/scripts/**"
`;

  test.each<ScrubCase>([
    {
      config: MAINTAINER_AUDIT_MEMBERS_LEAK_CONFIG,
      exit: 1,
      name: 'flags an un-wrapped code-audit-maintainer- reference in a scoped path',
      out: ['maintainer-audit-members', 'code-audit-maintainer-'],
      staged: {
        '.gaia/scripts/some-script.sh':
          '#!/usr/bin/env bash\necho "dispatching code-audit-maintainer-shell"\n',
      },
    },
    {
      config: MAINTAINER_AUDIT_MEMBERS_LEAK_CONFIG,
      exit: 0,
      name: 'passes a clean tree with no code-audit-maintainer- references',
      staged: {
        '.gaia/scripts/some-script.sh':
          '#!/usr/bin/env bash\necho "dispatching code-audit-frontend"\n',
      },
    },
    {
      // Guards the exact collision between the resolver's own documentation
      // and the strip boundary: a code-audit-maintainer-* literal named in
      // prose ABOVE the markers (not inside a wrapped block) is never
      // stripped, so it must be caught by the leak-check instead. The header
      // comment (outside the markers) survives the strip, and the wrapped
      // roster entry (inside the markers) is gone.
      after: {
        '.gaia/scripts/resolve-audit-members.sh': [
          '# resolve-audit-members.sh: dispatches to code-audit-maintainer-shell',
        ],
      },
      config: HEADER_TRIPWIRE_CONFIG,
      exit: 1,
      name: 'DP-003 tripwire: a literal in a header comment outside the markers survives the strip and trips the leak-check',
      notAfter: {
        '.gaia/scripts/resolve-audit-members.sh': [
          '  - name: code-audit-maintainer-shell',
          'gaia:maintainer-only',
        ],
      },
      out: ['maintainer-audit-members'],
      staged: {
        '.gaia/scripts/resolve-audit-members.sh': [
          '#!/usr/bin/env bash',
          '# resolve-audit-members.sh: dispatches to code-audit-maintainer-shell',
          '# and code-audit-maintainer-node when present.',
          '',
          'builtin_roster() {',
          '  cat <<YAML',
          'auditors:',
          '  - name: code-audit-frontend',
          '    default: true',
          '  # gaia:maintainer-only:start',
          '  - name: code-audit-maintainer-shell',
          '  # gaia:maintainer-only:end',
          'YAML',
          '}',
          '',
        ].join('\n'),
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

describe('excluded-workflow-ref derived check', () => {
  test.each<ScrubCase>([
    {
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a reference to a never-present excluded workflow',
      out: ['excluded-workflow-ref', '.github/workflows/forensics-triage.yml'],
      seed: seedWorkflowSource,
      staged: {
        '.claude/commands/pinned-note.md':
          '# Pinned SHAs match `.github/workflows/forensics-triage.yml`:\n',
      },
    },
    {
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 0,
      name: 'exempts a `[ -f ]` existence guard via the line-allowlist',
      seed: seedWorkflowSource,
      staged: {
        '.claude/commands/setup-gaia.md':
          'elif [ -f .github/workflows/forensics-triage.yml ] && gh repo view; then\n',
      },
    },
    {
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag a shipped (non-excluded) workflow reference',
      seed: seedWorkflowSource,
      staged: {
        '.claude/agents/foo.md':
          'All gating mirrors .github/workflows/tests.yml at the step level.\n',
      },
    },
    {
      // No excluded workflow is installed from a template, so a stray
      // template file never exempts a reference to it.
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 1,
      name: 'flags an excluded workflow whatever else exists in the source tree',
      out: ['.github/workflows/maintainer-only.yml'],
      seed: seedWorkflowSource,
      source: {
        '.gaia/cli/templates/maintainer-only.yml.tmpl':
          'name: Maintainer Only\n',
      },
      staged: {
        '.claude/commands/setup-gaia.md':
          'It installs `.github/workflows/maintainer-only.yml` (the PR gate).\n',
      },
    },
    {
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a newly excluded workflow with no config change (drift-proof)',
      out: ['brand-new-maintainer.yml'],
      seed: seedWorkflowSource,
      // A workflow that never appeared in any hand-maintained alternation.
      source: {
        '.gaia/release-exclude': `${WORKFLOW_EXCLUDE_FIXTURE}\n.github/workflows/brand-new-maintainer.yml\n`,
      },
      staged: {
        '.claude/agents/foo.md':
          'Pinned SHAs match .github/workflows/brand-new-maintainer.yml.\n',
      },
    },
    {
      // `.gaia/release-exclude` excludes itself, so it never reaches staging.
      // An implementation reading it from the staging tree finds nothing and
      // passes.
      config: WORKFLOW_DERIVED_CONFIG,
      exit: 1,
      name: 'derives the workflow set from cwd release-exclude, not staging',
      out: ['.github/workflows/release.yml'],
      seed: seedWorkflowSource,
      staged: {
        '.claude/agents/bar.md':
          'See .github/workflows/release.yml for the tag trigger.\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Derived excluded-titles check

const TITLE_DERIVED_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: excluded-titles
        derive: excluded-titles
        scope:
          - "wiki/**/*.md"
        path-allowlist:
          - "wiki/hot.md"
          - "wiki/log.md"
        title-opt-out:
          - "GAIA"
          - "dashboard"
          - "Steven Sacks"
          - "Release Workflow"
`;

const TITLE_WITH_MARKER_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "wiki/**/*.md"
    start: "<!-- gaia:maintainer-only:start -->"
    end: "<!-- gaia:maintainer-only:end -->"

  - type: leak-check
    checks:
      - id: excluded-titles
        derive: excluded-titles
        scope:
          - "wiki/**/*.md"
        path-allowlist:
          - "wiki/hot.md"
          - "wiki/log.md"
        title-opt-out:
          - "GAIA"
          - "dashboard"
          - "Steven Sacks"
          - "Release Workflow"
`;

// Representative `.gaia/release-exclude` for the title derivation: two bare
// directory excludes (entities, meta), four distinctive `.md` file excludes, and
// non-wiki lines the derivation must ignore. `Release Workflow` is a `.md`
// exclude so the config-level opt-out is observable against a title that IS in
// the derived set.
const TITLE_EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '',
  'wiki/entities',
  'wiki/meta',
  'wiki/concepts/Forensics Triage Workflow.md',
  'wiki/decisions/Bundle-time Scrub.md',
  'wiki/concepts/Release Workflow.md',
  'wiki/decisions/CLI-Binary-Split.md',
  '.gaia/release-exclude',
  '.claude/commands/gaia-release.md',
].join('\n');

// Lay down the source-tree inputs the derivation reads from cwd: the
// release-exclude manifest plus real pages inside the excluded directories
// (basenames NEVER enumerated as their own exclude lines). `Distinctive Meta
// Page` is a non-opted-out page beneath the bare `wiki/meta` exclude; the
// directory basename `meta` itself is deliberately never contributed.
const seedTitleSource = (sandbox: Sandbox): void => {
  sandbox.writeSource('.gaia/release-exclude', TITLE_EXCLUDE_FIXTURE);
  sandbox.writeSource('wiki/entities/GAIA.md', '# GAIA\n');
  sandbox.writeSource('wiki/entities/Steven Sacks.md', '# Steven Sacks\n');
  sandbox.writeSource('wiki/meta/dashboard.md', '# Wiki Dashboard\n');
  sandbox.writeSource(
    'wiki/meta/Distinctive Meta Page.md',
    '# Distinctive Meta Page\n'
  );
};

const NON_TITLE_CHECK_CONFIG = (check: string): string => `
transforms:
  - type: leak-check
    checks:
${check}
        title-opt-out:
          - "GAIA"
`;

describe('excluded-titles derived check', () => {
  const FOO = 'wiki/concepts/Foo.md';
  const MIXED_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: flow-narrative
        pattern: "FLOW-[0-9]{3}"
        scope:
          - "wiki/**"
      - id: excluded-titles
        derive: excluded-titles
        scope:
          - "wiki/**/*.md"
        path-allowlist:
          - "wiki/hot.md"
        title-opt-out:
          - "Release Workflow"
`;

  test.each<ScrubCase>([
    {
      // The #1 trap: `.gaia/release-exclude` excludes itself and never reaches
      // the staging tree, so the set must be derived from cwd.
      args: ['--json'],
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a bare-prose title, derived from cwd, with file/line/match',
      report: {
        leaks: [
          {
            check: 'excluded-titles',
            file: FOO,
            line: 3,
            match: 'Forensics Triage Workflow',
          },
        ],
      },
      seed: seedTitleSource,
      staged: {
        [FOO]: [
          '# Foo',
          '',
          'The Forensics Triage Workflow governs incident capture.',
          '',
        ].join('\n'),
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag a title that appears only as a wikilink',
      seed: seedTitleSource,
      staged: {
        [FOO]: '# Foo\n\nSee [[Forensics Triage Workflow]] for the details.\n',
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag a title inside an inline-code span or a fenced block',
      seed: seedTitleSource,
      staged: {
        [FOO]: [
          '# Foo',
          '',
          'Inline `Bundle-time Scrub` reference.',
          '',
          '```',
          'Bundle-time Scrub inside a fenced block.',
          '```',
          '',
        ].join('\n'),
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag a lowercase concept-prose mention that is not the exact title',
      seed: seedTitleSource,
      staged: {
        [FOO]: '# Foo\n\nConfigure the bundle-time scrub before shipping.\n',
      },
    },
    {
      // The directory basenames `meta` / `entities` are deliberately NOT in
      // the set; a naive `buildExcludedSlugSet`-style derivation would flag
      // them.
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'does not flag the excluded directory basenames themselves',
      seed: seedTitleSource,
      staged: {
        [FOO]:
          '# Foo\n\nThe meta directory and the entities folder hold working notes.\n',
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'does not fire on a title abutted by an extra word char or hyphen',
      seed: seedTitleSource,
      staged: {
        [FOO]: [
          '# Foo',
          '',
          'We finished Bundle-time Scrubbing last week.',
          'The CLI-Binary-Split-Extra step and the Pre-CLI-Binary-Split step differ.',
          '',
        ].join('\n'),
      },
    },
    {
      // marker-strip runs before leak-check and re-reads the file fresh, so
      // the wrapped mention is gone before the title check ever sees the line.
      config: TITLE_WITH_MARKER_CONFIG,
      exit: 0,
      name: 'does not flag a bare title inside a stripped maintainer-only block',
      seed: seedTitleSource,
      staged: {
        [FOO]: [
          '# Foo',
          '',
          'Public prose.',
          '<!-- gaia:maintainer-only:start -->',
          'The Forensics Triage Workflow handles this internally.',
          '<!-- gaia:maintainer-only:end -->',
          '',
        ].join('\n'),
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'subtracts an opted-out title while flagging a non-opted-out one on the same page',
      notOut: ['Release Workflow'],
      out: ['Bundle-time Scrub'],
      seed: seedTitleSource,
      staged: {
        [FOO]: [
          '# Foo',
          '',
          'The Release Workflow and the Bundle-time Scrub both run at release time.',
          '',
        ].join('\n'),
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a newly excluded title with no config change (drift-proof)',
      out: ['Newly Excluded Decision'],
      seed: seedTitleSource,
      source: {
        '.gaia/release-exclude': `${TITLE_EXCLUDE_FIXTURE}\nwiki/decisions/Newly Excluded Decision.md\n`,
      },
      staged: {
        [FOO]: '# Foo\n\nThe Newly Excluded Decision changed our approach.\n',
      },
    },
    {
      // Span-level, not line-level: the `[[wikilink]]` span is removed, but
      // the bare mention of a different excluded title on the same line still
      // fires.
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a bare title on a line that also carries a wikilink to a different excluded title',
      notOut: ['Bundle-time Scrub'],
      out: ['Forensics Triage Workflow'],
      seed: seedTitleSource,
      staged: {
        [FOO]:
          '# Foo\n\nSee [[Bundle-time Scrub]] and the Forensics Triage Workflow config.\n',
      },
    },
    {
      // The directory contributes its pages (Distinctive Meta Page) even
      // though the directory name (meta) itself is never contributed.
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'flags a page beneath a bare-directory exclude by its basename',
      out: ['Distinctive Meta Page'],
      seed: seedTitleSource,
      staged: {
        [FOO]: '# Foo\n\nThe Distinctive Meta Page documents the layout.\n',
      },
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 1,
      name: 'fires on a standalone hyphenated title',
      out: ['CLI-Binary-Split'],
      seed: seedTitleSource,
      staged: {
        [FOO]: '# Foo\n\nThe CLI-Binary-Split boundary is deliberate.\n',
      },
    },
    {
      config: NON_TITLE_CHECK_CONFIG(
        [
          '      - id: wikilink-to-excluded',
          '        derive: excluded-slugs',
          '        scope:',
          '          - "wiki/**/*.md"',
        ].join('\n')
      ),
      err: ['config_load_failed'],
      exit: 2,
      name: 'exits 2 when title-opt-out is placed on a non-title derived check',
      staged: {'wiki/index.md': '# x\n'},
    },
    {
      config: NON_TITLE_CHECK_CONFIG(
        [
          '      - id: flow-narrative',
          '        pattern: "FLOW-[0-9]{3}"',
          '        scope:',
          '          - "wiki/**"',
        ].join('\n')
      ),
      err: ['config_load_failed'],
      exit: 2,
      name: 'exits 2 when title-opt-out is placed on a static check',
      staged: {'wiki/index.md': '# x\n'},
    },
    {
      config: TITLE_DERIVED_CONFIG,
      exit: 0,
      name: 'exempts allowlisted hot.md / log.md from the title check',
      seed: seedTitleSource,
      staged: {
        'wiki/hot.md': '# Hot\n\nThe Forensics Triage Workflow is next.\n',
        'wiki/log.md': '# Log\n\nThe Bundle-time Scrub landed.\n',
      },
    },
    {
      config: MIXED_CONFIG,
      exit: 1,
      name: 'runs a static check and the title derived check in one config',
      out: ['flow-narrative', 'excluded-titles'],
      seed: seedTitleSource,
      staged: {
        'wiki/a.md': '# A\n\nFLOW-007 reference.\n',
        'wiki/b.md': '# B\n\nThe Bundle-time Scrub runs here.\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

type ShippedLeakCheck = {
  id: string;
  pattern?: string;
  'ref-opt-out'?: string[];
  scope?: string[];
};
type ShippedLeakTransform = {checks?: ShippedLeakCheck[]; type?: string};

// A leak check read from `.gaia/release-scrub.yml` itself rather than mirrored
// inline the way the hermetic configs above are. The defects these tests pin
// live in the config, not in the engine, so a mirrored copy goes on passing
// while the shipped check stays narrow. The holding transform comes back too,
// since its `scope-skip` is part of how the check behaves as shipped.
const shippedLeakCheck = (
  id: string
): {check: ShippedLeakCheck; transform: ShippedLeakTransform} => {
  const configPath = path.join(
    resolveRepoRootFromImportMeta(import.meta.url),
    '.gaia',
    'release-scrub.yml'
  );
  const config = parseYaml(readFileSync(configPath, 'utf8')) as {
    transforms: ShippedLeakTransform[];
  };

  for (const transform of config.transforms) {
    const check = (transform.checks ?? []).find(
      (candidate) => candidate.id === id
    );

    if (check !== undefined) return {check, transform};
  }

  throw new Error(`no ${id} check in .gaia/release-scrub.yml`);
};

// Release-excluded trees the derived check must always cover; a derivation
// change that drops one of them narrows the guard.
const ALWAYS_EXCLUDED_TREES = [
  '.gaia/cli/src',
  '.gaia/cli/test-fixtures',
  '.gaia/cli/health',
  '.gaia/cli/gaia-maintainer',
  '.gaia/tests',
  '.gaia/scripts/tests',
  '.github/audit/tests',
  '.github/forensics',
  '.claude/rules/maintainers',
  '.claude/maintainers',
];

describe('shipped excluded-refs check', () => {
  const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

  test('scans the whole shipped tree', () => {
    const {check} = shippedLeakCheck('excluded-refs');

    expect(check.scope).toEqual(['**']);
  });

  test('derives every long-standing release-excluded tree', () => {
    const {paths} = deriveExcludedRefTokens({
      excludeLines: parseExcludeLines(
        readFileSync(path.join(repoRoot, '.gaia', 'release-exclude'), 'utf8')
      ),
      isExecutable: () => false,
      optOut: shippedLeakCheck('excluded-refs').check['ref-opt-out'] ?? [],
      shippedBasenames: new Set(),
      tracked: listGitFiles(repoRoot),
    });

    expect(paths).toEqual(expect.arrayContaining(ALWAYS_EXCLUDED_TREES));
  });
});

const REFS_CONFIG = String.raw`
transforms:
  - type: leak-check
    checks:
      - id: excluded-refs
        derive: excluded-refs
        scope:
          - "**"
        ref-opt-out:
          - ".github/CODEOWNERS"
        line-allowlist:
          - "^\\s*-\\s*'\\.gaia/cli/src/\\*\\*'$"
`;

const REFS_EXCLUDE_FIXTURE = [
  '.claude/commands/gaia-release.md',
  '.gaia/cli/src',
  '.gaia/scripts/lint-hook-jq-availability.sh',
  '.github/CODEOWNERS',
  '.gaia/local',
  '.tool-state',
].join('\n');

const seedRefsSource = (sandbox: Sandbox): void => {
  sandbox.writeSource('.gaia/release-exclude', `${REFS_EXCLUDE_FIXTURE}\n`);
  sandbox.writeSource('.claude/commands/gaia-release.md', '# release\n');
  sandbox.writeSource('.gaia/cli/src/wiki/chain.ts', 'export {};\n');
  sandbox.writeSource(
    '.gaia/scripts/lint-hook-jq-availability.sh',
    '#!/bin/sh\n'
  );
  sandbox.writeSource('.github/CODEOWNERS', '* @maintainer\n');
  // Present on disk but untracked, the way a maintainer's local state is.
  sandbox.writeSource('.tool-state/config.yml', 'languages: []\n');
  sandbox.writeSource('.gaia/local/plans/notes.md', '# notes\n');
  execFileSync('git', ['init', '-q'], {cwd: sandbox.rootDir});
  execFileSync(
    'git',
    [
      'add',
      '.gaia/release-exclude',
      '.claude/commands/gaia-release.md',
      '.gaia/cli/src/wiki/chain.ts',
      '.gaia/scripts/lint-hook-jq-availability.sh',
      '.github/CODEOWNERS',
    ],
    {cwd: sandbox.rootDir}
  );
};

describe('excluded-refs derived check', () => {
  const flagsRow = (
    label: string,
    stagedPath: string,
    contents: string,
    expected: string
  ): ScrubCase => ({
    config: REFS_CONFIG,
    exit: 1,
    name: `flags ${label}`,
    out: [`[excluded-refs] ${stagedPath}:1  ${expected}`],
    seed: seedRefsSource,
    staged: {[stagedPath]: contents},
  });
  const passesRow = (
    label: string,
    stagedPath: string,
    contents: string
  ): ScrubCase => ({
    config: REFS_CONFIG,
    exit: 0,
    name: `does not flag ${label}`,
    seed: seedRefsSource,
    staged: {[stagedPath]: contents},
  });

  test.each<ScrubCase>([
    flagsRow(
      'a slash command',
      'wiki/concepts/A.md',
      'Run `/gaia-release` first.\n',
      '/gaia-release'
    ),
    flagsRow(
      'an excluded script path',
      '.claude/hooks/a.sh',
      '# see .gaia/scripts/lint-hook-jq-availability.sh\n',
      '.gaia/scripts/lint-hook-jq-availability.sh'
    ),
    flagsRow(
      'a code basename in Markdown',
      'wiki/concepts/B.md',
      'It comes from `chain.ts`.\n',
      'chain.ts'
    ),
    passesRow(
      'an opted-out path',
      'wiki/concepts/A.md',
      'Write `.github/CODEOWNERS` yourself.\n'
    ),
    passesRow(
      'an untracked excluded entry',
      'wiki/concepts/A.md',
      'The tool reads `.tool-state/config.yml`.\n'
    ),
    passesRow(
      'a nested untracked excluded entry',
      'wiki/concepts/A.md',
      'Plans live under `.gaia/local/plans/`.\n'
    ),
    passesRow(
      'a code basename outside Markdown',
      '.claude/hooks/a.sh',
      '# mirrors chain.ts\n'
    ),
    passesRow(
      'a line-allowlisted config glob',
      '.claude/rules/a.md',
      "  - '.gaia/cli/src/**'\n"
    ),
    {
      config: REFS_CONFIG,
      exit: 1,
      name: 'flags a newly excluded path with no config change (drift-proof)',
      out: ['.gaia/scripts/brand-new-lint.sh'],
      seed: (target) => {
        seedRefsSource(target);
        target.writeSource(
          '.gaia/release-exclude',
          `${REFS_EXCLUDE_FIXTURE}\n.gaia/scripts/brand-new-lint.sh\n`
        );
        target.writeSource('.gaia/scripts/brand-new-lint.sh', '#!/bin/sh\n');
        execFileSync('git', ['add', '.'], {cwd: target.rootDir});
      },
      staged: {
        'wiki/concepts/A.md': 'See .gaia/scripts/brand-new-lint.sh.\n',
      },
    },
    {
      config: REFS_CONFIG,
      exit: 0,
      name: 'does not warn about allowlist and opt-out entries that are in use',
      notOut: ['unused allowlist entries'],
      seed: seedRefsSource,
      staged: {'.claude/rules/a.md': "  - '.gaia/cli/src/**'\n"},
    },
    {
      config: REFS_CONFIG.replace(
        '".github/CODEOWNERS"',
        '".github/no-such-file"'
      ),
      exit: 0,
      name: 'warns, without failing, on unused allowlist and opt-out entries',
      out: [
        'unused allowlist entries (2, warning only):',
        '[excluded-refs] ref-opt-out: .github/no-such-file',
        String.raw`[excluded-refs] line-allowlist: ^\s*-\s*'\.gaia/cli/src/\*\*'$`,
      ],
      seed: seedRefsSource,
      staged: {'wiki/concepts/A.md': 'Nothing to see.\n'},
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

const SCOPE_SKIP_CONFIG = String.raw`
transforms:
  - type: leak-check
    scope-skip:
      - "**/*.png"
    checks:
      - id: flow-narrative
        pattern: "FLOW-[0-9]{3}"
        scope:
          - "**"
      - id: maintainer-paths
        pattern: "\\.gaia/cli/src\\b"
        scope:
          - "**"
`;

describe('leak-check scope-skip', () => {
  test.each<ScrubCase>([
    {
      config: SCOPE_SKIP_CONFIG,
      exit: 0,
      name: 'skips a file the skip list names even when the scope admits it',
      out: ['leaks: none'],
      staged: {'public/icon.png': 'FLOW-042'},
    },
    {
      config: SCOPE_SKIP_CONFIG,
      exit: 0,
      name: 'one skip list covers every check in the transform',
      staged: {'public/icon.png': 'see .gaia/cli/src/scrub.ts'},
    },
    {
      config: SCOPE_SKIP_CONFIG,
      exit: 1,
      name: 'still scans a file the skip list does not name',
      out: ['docs/notes.md'],
      staged: {'docs/notes.md': 'FLOW-042'},
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Handed to the real engine as shipped: the check plus its holding transform,
// with the sibling checks filtered out so an unrelated pattern cannot fire on
// these fixtures.
const shippedAbsolutePathsConfig = (): string => {
  const {check, transform} = shippedLeakCheck('absolute-paths');

  return dumpYaml({transforms: [{...transform, checks: [check]}]});
};

describe('shipped absolute-paths check', () => {
  const config = shippedAbsolutePathsConfig();

  test.each<ScrubCase>([
    {
      // The ban is repo-wide, not `.claude/`-only (gaia-react/gaia#1479), so
      // the two surfaces are one assertion rather than a rule and an
      // exception.
      config,
      exit: 1,
      name: 'flags an absolute path anywhere in the shipped tree',
      out: [
        '.gaia/scripts/audit-key-lib.sh',
        'wiki/index.md',
        '.claude/hooks/some-hook.sh',
      ],
      staged: {
        '.claude/hooks/some-hook.sh': 'root="/Users/steven/dev/thing"\n',
        '.gaia/scripts/audit-key-lib.sh': 'root="/Users/steven/dev/thing"\n',
        'wiki/index.md': 'See /home/steven/notes.md.\n',
      },
    },
    {
      // The gate has to permit what Exception 2 tells an author to write, or
      // following the rule fails the bundle. Prefix use is how every shipped
      // instance spells them; a bare mention still flags, which
      // `.gaia/release-scrub.yml` records as the narrower of the two
      // available edges. `/Users/username` is where they ship today, in the
      // captured Storybook parser stack trace.
      config,
      exit: 0,
      name: 'allows each sanctioned placeholder used as a path prefix',
      out: ['leaks: none'],
      staged: {
        'app/components/errors/error-stack/tests/index.stories.tsx':
          '    at constructor (/Users/username/Development/gaia/node_modules/x.cjs:1:2)\n',
        'docs/linux.md': 'Or into /home/bar/projects.\n',
        'docs/notes.md': 'Clone into /Users/you/projects.\n',
      },
    },
    {
      // Why the trailing `/` is load-bearing rather than incidental: without
      // it the alternation would release a path of this shape, and that shape
      // names a real machine. These two are deliberate near-misses of the
      // sanctioned placeholders, not further placeholders.
      config,
      exit: 1,
      name: 'does not let a placeholder exempt a longer real path that extends it',
      out: ['leaks (2)', 'docs/a.md', 'docs/b.md'],
      staged: {
        'docs/a.md': 'Built at /Users/youngster/dev/thing.\n',
        'docs/b.md': 'Built at /home/barbara/dev/thing.\n',
      },
    },
    {
      config,
      exit: 0,
      name: 'allows the elided /Users/.../ placeholder',
      out: ['leaks: none'],
      staged: {
        '.gaia/scripts/spec/spec-session-lock.sh':
          '#   level 1: /bin/zsh -c source /Users/.../.claude/shell-snapshots/snap\n',
      },
    },
    {
      // One leak, on line 2: the count is what proves the exemption released
      // the placeholder and nothing else, since the reporter prints the
      // matched pattern rather than the offending line.
      config,
      exit: 1,
      name: 'still flags a real machine path on its own line',
      out: ['leaks (1)', 'spec-session-lock.sh:2'],
      staged: {
        '.gaia/scripts/spec/spec-session-lock.sh':
          '#   level 1: /bin/zsh -c source /Users/.../.claude/shell-snapshots/snap\n' +
          'LOCK_DIR="/Users/steven/Development/gaia/.gaia/local/locks"\n',
      },
    },
    {
      // The accepted gap, pinned rather than left to be rediscovered: the
      // engine drops a line-allowlisted line before the pattern runs, so the
      // exemption releases the line and not just the match it fired on.
      // Narrowing it to the match is an engine change; `.gaia/release-scrub.yml`
      // records why that trade is not worth making for the shapes these
      // entries cover.
      config,
      exit: 0,
      name: 'does not scan a real machine path sharing a line with a placeholder',
      out: ['leaks: none'],
      staged: {
        'docs/notes.md':
          'Use /Users/you/projects, not /Users/steven/Development/gaia.\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Handed to the real engine as shipped, same shape as the blocks above. The
// previous owner's name is assembled at runtime so this file never carries a
// literal reference to it.
const shippedProjectIssueRefsConfig = (): string => {
  const {check, transform} = shippedLeakCheck('project-issue-refs');

  return dumpYaml({transforms: [{...transform, checks: [check]}]});
};

describe('shipped project-issue-refs check', () => {
  const oldOwner = ['gaia', 'react'].join('-');
  const config = shippedProjectIssueRefsConfig();
  const leakRow = (
    name: string,
    file: string,
    reference: string
  ): ScrubCase => ({
    config,
    exit: 1,
    name,
    out: [file, reference.replace('https://', '')],
    staged: {[file]: `See ${reference} for detail.\n`},
  });

  test.each<ScrubCase>([
    leakRow(
      'flags a qualified reference under the previous owner',
      'docs/notes.md',
      `${oldOwner}/gaia#123`
    ),
    leakRow(
      'flags a qualified reference under the current owner',
      'docs/notes.md',
      'gaia-harness/gaia#123'
    ),
    leakRow(
      'flags an issue URL under the previous owner',
      'docs/issue.md',
      `https://github.com/${oldOwner}/gaia/issues/123`
    ),
    leakRow(
      'flags a pull request URL under the current owner',
      'docs/pull.md',
      'https://github.com/gaia-harness/gaia/pull/123'
    ),
    {
      config,
      exit: 0,
      name: 'passes a third-party tracker reference',
      out: ['leaks: none'],
      staged: {'docs/notes.md': 'See capricorn86/happy-dom#978.\n'},
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Handed to the real engine as shipped, same shape as the absolute-paths block
// above: the check plus its holding transform, siblings filtered out so an
// unrelated pattern cannot decide these fixtures.
const shippedAudienceVocabularyConfig = (): string => {
  const {check, transform} = shippedLeakCheck('audience-label-vocabulary');

  return dumpYaml({transforms: [{...transform, checks: [check]}]});
};

describe('shipped audience-label-vocabulary check', () => {
  const config = shippedAudienceVocabularyConfig();

  test.each<ScrubCase>([
    {
      // One fixture per branch of the alternation, six in all, each written so
      // that branch is the only one it matches. Pinning by carrier instead
      // would leave `maintainer` untested, because the brace-form and
      // AUDIENCE_VALUES carriers happen to also contain the word: dropping
      // `maintainer|` from the pattern would keep every fixture matching while
      // a maintainer-side re-add shipped unflagged. A naive
      // `audience:(adopter|maintainer)` pattern catches only two of the six
      // (gaia-react/gaia#1437), so a tree still shipping the whole
      // enforcement block would clear it.
      config,
      exit: 1,
      name: 'flags every spelling the axis actually ships in',
      out: [
        'wiki/page.md',
        '.claude/skills/file-tech-debt/SKILL.md',
        '.claude/skills/gaia/references/cleanse.md',
        '.gaia/scripts/check.sh',
        '.claude/agents/some-agent.md',
        '.claude/skills/vocabulary.md',
      ],
      staged: {
        '.claude/agents/some-agent.md': 'one of `audience:adopter`\n',
        '.claude/skills/file-tech-debt/SKILL.md':
          '--label audience:<side> \\\n',
        '.claude/skills/gaia/references/cleanse.md':
          '  audience: {adopter | maintainer, against the rubric}\n',
        '.claude/skills/vocabulary.md':
          '| `audience:maintainer` | observable only in the GAIA repository. |\n',
        '.gaia/scripts/check.sh':
          'readonly AUDIENCE_VALUES="adopter maintainer"\n',
        'wiki/page.md': 'exactly one `audience:*` label\n',
      },
    },
    {
      // The reason whitespace is allowed only before the brace. The roster's
      // `audience:` field ships on every adopter member, in the config and in
      // the built-in fallback roster, and the registry's JSON field ships on
      // every adopter-audience entry; flagging any of them would fail every
      // release build on a legitimate file.
      config,
      exit: 0,
      name: 'does not flag the shipped roster field, the registry field, or the CLI flag',
      out: ['leaks: none'],
      staged: {
        '.claude/hooks/lib/audit-scope.sh': '    audience: maintainer\n',
        '.claude/skills/some-skill.md':
          '.gaia/cli/gaia labels sync --audience maintainer\n',
        '.gaia/audit-ci.yml':
          '  - name: code-audit-frontend\n    audience: adopter\n',
        '.gaia/labels.json': '{"name": "bug", "audience": "adopter"}\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

const PNPM_FIXTURE_ROOT = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'test-fixtures',
  'pnpm-member-strip'
);
const STAGED_LOCKFILE = 'pnpm-lock.yaml';
const STAGED_WORKSPACE = 'pnpm-workspace.yaml';

const PNPM_STRIP_CONFIG = `
transforms:
  - type: pnpm-member-strip
    member: ".gaia/cli"
    workspace: "${STAGED_WORKSPACE}"
    lockfile: "${STAGED_LOCKFILE}"
`;

const PNPM_LEAK_ONLY_CONFIG = String.raw`
transforms:
  - type: leak-check
    checks:
      - id: pnpm-workspace-member
        pattern: "\\.gaia/cli"
        scope:
          - "pnpm-lock.yaml"
          - "pnpm-workspace.yaml"
`;

const readPnpmFixture = (caseName: string, fileName: string): string =>
  readFileSync(path.join(PNPM_FIXTURE_ROOT, caseName, fileName), 'utf8');

describe('pnpm-member-strip transform', () => {
  const inputs = (caseName: string): Record<string, string> => ({
    [STAGED_LOCKFILE]: readPnpmFixture(caseName, 'input.lock.fixture.yaml'),
    [STAGED_WORKSPACE]: readPnpmFixture(
      caseName,
      'input.workspace.fixture.yaml'
    ),
  });
  const refusalRow = (
    caseName: string,
    file: string,
    token: string
  ): ScrubCase => ({
    afterRaw: inputs(caseName),
    config: PNPM_STRIP_CONFIG,
    err: ['pnpm_member_strip_refused', `"<staging>/${file}"`, token],
    exit: 1,
    name: `${caseName} exits non-zero naming ${file} and ${token}, writing neither file`,
    staged: inputs(caseName),
  });

  const variant = 'use-sync-external-store@1.2.2(react@17.0.2)';
  const syntheticLock = inputs('synthetic')[STAGED_LOCKFILE] ?? '';
  const blockStart = syntheticLock.indexOf(`\n\n  ${variant}:`);
  const leftover = syntheticLock.slice(
    blockStart,
    syntheticLock.indexOf('\n\n', blockStart + 2)
  );

  test.each<ScrubCase>([
    {
      afterRaw: {
        [STAGED_LOCKFILE]: readPnpmFixture(
          'synthetic',
          'expected.lock.fixture.yaml'
        ),
        [STAGED_WORKSPACE]: readPnpmFixture(
          'synthetic',
          'expected.workspace.fixture.yaml'
        ),
      },
      args: ['--json'],
      config: PNPM_STRIP_CONFIG,
      exit: 0,
      name: 'strips the member from both staged files and reports the counts',
      // The counts come from a second, direct call of the transform; a getter
      // keeps a non-stripped outcome a failure of this row, not of the file.
      get report(): Record<string, unknown> {
        const outcome = stripPnpmMember({
          lockfile: readPnpmFixture('synthetic', 'input.lock.fixture.yaml'),
          member: '.gaia/cli',
          workspace: readPnpmFixture(
            'synthetic',
            'input.workspace.fixture.yaml'
          ),
        });
        const {removed} = outcome as {
          removed: {packages: string[]; snapshots: string[]};
        };

        expect(outcome.kind).toBe('stripped');

        return {
          pnpm_member_strip: {
            files_touched: [STAGED_WORKSPACE, STAGED_LOCKFILE],
            importers_removed: 1,
            packages_removed: removed.packages.length,
            snapshots_removed: removed.snapshots.length,
          },
        };
      },
      staged: inputs('synthetic'),
    },
    {
      config: PNPM_STRIP_CONFIG,
      exit: 0,
      name: 'prints the removal counts in the human report',
      outMatch: [
        /release scrub: removed 1 pnpm importer\(s\), [1-9]\d* package\(s\), [1-9]\d* snapshot\(s\)/,
      ],
      staged: inputs('synthetic'),
    },
    {
      afterRaw: inputs('noop'),
      config: PNPM_STRIP_CONFIG,
      exit: 0,
      name: 'leaves a pair with no member and no importer byte-identical',
      out: [
        'release scrub: removed 0 pnpm importer(s), 0 package(s), 0 snapshot(s)',
      ],
      staged: inputs('noop'),
    },
    refusalRow(
      'unknown-version-document-1',
      STAGED_LOCKFILE,
      'unknown-lockfile-version'
    ),
    refusalRow(
      'unknown-version-document-2',
      STAGED_LOCKFILE,
      'unknown-lockfile-version'
    ),
    refusalRow(
      'member-without-importer',
      STAGED_WORKSPACE,
      'member-without-importer'
    ),
    refusalRow(
      'importer-without-member',
      STAGED_LOCKFILE,
      'importer-without-member'
    ),
    refusalRow('missing-snapshot', STAGED_LOCKFILE, 'missing-snapshot'),
    {
      afterRaw: inputs('synthetic'),
      config: PNPM_STRIP_CONFIG,
      deps: {
        stripPnpmMember: (stripInput) => {
          const outcome = stripPnpmMember(stripInput);

          return outcome.kind === 'stripped' ?
              {...outcome, lockfile: `${outcome.lockfile}${leftover}\n`}
            : outcome;
        },
      },
      err: ['cli-only-key-survives', variant],
      exit: 1,
      name: 'the self-check refuses a prune that leaves a member-only snapshot',
      staged: inputs('synthetic'),
    },
    {
      config: PNPM_LEAK_ONLY_CONFIG,
      exit: 1,
      name: 'the leak check fails the build when the member survives',
      outMatch: [/\[pnpm-workspace-member\] pnpm-workspace\.yaml:\d+/],
      staged: inputs('synthetic'),
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

describe('shipped release-scrub config', () => {
  const configPath = path.join(
    resolveRepoRootFromImportMeta(import.meta.url),
    '.gaia',
    'release-scrub.yml'
  );

  test('parses through the loader run() uses', () => {
    const config = loadConfig(configPath);

    expect(config.transforms).toContainEqual({
      lockfile: 'pnpm-lock.yaml',
      member: '.gaia/cli',
      type: 'pnpm-member-strip',
      workspace: 'pnpm-workspace.yaml',
    });
  });

  test('json-strips the maintainer-only lint:cli script from the root package.json', () => {
    const jsonStrip = loadConfig(configPath).transforms.find(
      (transform) =>
        transform.type === 'json-strip' &&
        transform.paths.includes('package.json')
    );
    const sandbox = setupSandbox({
      config: dumpYaml({transforms: [jsonStrip]}),
    });
    const stdio = captureStdio();

    try {
      sandbox.writeStaged(
        'package.json',
        `${JSON.stringify({scripts: {'lint:cli': 'pnpm -C .gaia/cli lint', test: 'vitest'}}, null, 2)}\n`
      );

      expect(run([sandbox.stagingDir, '--config', sandbox.configPath])).toBe(0);
      expect(
        JSON.parse(
          readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8')
        )
      ).toEqual({scripts: {test: 'vitest'}});
    } finally {
      stdio.restore();
      sandbox.cleanup();
    }
  });
});

const shippedLocalArtifactPathsConfig = (): string => {
  const {check, transform} = shippedLeakCheck('local-artifact-paths');

  return dumpYaml({transforms: [{...transform, checks: [check]}]});
};

describe('shipped local-artifact-paths check', () => {
  const config = shippedLocalArtifactPathsConfig();

  test.each<ScrubCase>([
    {
      config,
      exit: 1,
      name: 'flags a dated notebook research path in a shipped file',
      out: ['wiki/concepts/example.md'],
      staged: {
        'wiki/concepts/example.md':
          'See .notebook/research/2026-10-01-topic/README.md.\n',
      },
    },
    {
      config,
      exit: 1,
      name: 'still flags a dated .gaia/local research path',
      out: ['wiki/concepts/example.md'],
      staged: {
        'wiki/concepts/example.md':
          'See .gaia/local/research/2026-10-01-topic/README.md.\n',
      },
    },
    {
      config,
      exit: 0,
      name: 'does not flag the date-topic placeholder',
      staged: {
        'wiki/concepts/example.md':
          'Folders look like .notebook/research/<date>-<topic>/.\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});

// Handed to the real engine as shipped: the check plus its holding transform,
// siblings filtered out so an unrelated pattern cannot decide these fixtures.
const shippedFlowNarrativeConfig = (): string => {
  const {check, transform} = shippedLeakCheck('flow-narrative');

  return dumpYaml({transforms: [{...transform, checks: [check]}]});
};

describe('shipped flow-narrative check', () => {
  const config = shippedFlowNarrativeConfig();

  test.each<ScrubCase>([
    {
      config: LEAK_ONLY_CONFIG,
      exit: 1,
      name: 'flags FLOW-NNN narrative in shipped instruction surfaces',
      out: ['flow-narrative', 'FLOW-007'],
      staged: {
        '.claude/skills/foo/SKILL.md':
          '# Foo\n\nImplements FLOW-007 (working-doc reference).\n',
      },
    },
    {
      config: LEAK_ONLY_CONFIG,
      exit: 0,
      name: 'exempts lines with structural identifier fragments',
      staged: {
        '.claude/skills/foo/SKILL.md':
          '# Foo\n\nUse `--flow-id FLOW-099` to filter; the `flow_id` field is required.\n',
      },
    },
    {
      config,
      exit: 1,
      name: 'flags a flow id in a shipped instruction file',
      out: ['flow-narrative', 'FLOW-123'],
      staged: {
        '.claude/skills/example/SKILL.md':
          '# Example\n\nImplements FLOW-123 end to end.\n',
      },
    },
    {
      config,
      exit: 0,
      name: 'passes a frontmatter-style flow_id line',
      out: ['leaks: none'],
      staged: {
        '.claude/skills/example/SKILL.md':
          '---\nflow_id: FLOW-123\n---\n\n# Example\n',
      },
    },
  ])('$name', (row) => {
    expect.hasAssertions();
    runScrubCase(row);
  });
});
