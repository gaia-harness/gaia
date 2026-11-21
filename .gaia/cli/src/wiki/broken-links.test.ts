import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {findBrokenLinks, run} from './broken-links.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-broken-links-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeFile: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
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

const EXISTING_PAGE = [
  '---',
  'type: concept',
  '---',
  '# Existing Title',
  '',
  '## Heading',
  '',
].join('\n');

describe('wiki broken-links', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  const brokenTargets = (relativePath: string, body: string): string[] => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile(relativePath, body);

    return findBrokenLinks(sandbox.root).broken.map((link) => link.target);
  };

  test('reports exactly the dangling links of the full fixture, as compact JSON', () => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile('wiki/overview.md', '# Overview\n');
    sandbox.writeFile('wiki/meta/Meta Note.md', '# Meta Note\n');
    sandbox.writeFile('wiki/_archived/Archived Page.md', '# Archived Page\n');
    sandbox.writeFile(
      'wiki/concepts/Links.md',
      [
        '---',
        'type: concept',
        'depends_on: [[Missing Dep]]',
        '---',
        '[[Existing Title]]',
        '[[existing]]',
        '[[Existing Title|alias]]',
        '[[Existing Title#Heading]]',
        '[[concepts/Existing]]',
        '[[overview]]',
        '[[Meta Note]]',
        '[[Missing Page]]',
        '[[#Heading]]',
        '[[Archived Page]]',
        String.raw`| a | [[Existing Title\|alias]] |`,
        '`[[Missing In Code]]`',
        '```',
        '[[Missing In Fence]]',
        '```',
        '',
      ].join('\n')
    );
    sandbox.writeFile('wiki/meta/x.md', '[[Missing Exempt]]\n');
    sandbox.writeFile('wiki/log.md', '[[Missing Exempt]]\n');
    sandbox.writeFile('wiki/_archived/y.md', '[[Missing Exempt]]\n');

    const exit = run(['--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe(
      '{"broken":[{"path":"wiki/concepts/Links.md","line":3,"target":"Missing Dep"},{"path":"wiki/concepts/Links.md","line":12,"target":"Missing Page"},{"path":"wiki/concepts/Links.md","line":14,"target":"Archived Page"}]}\n'
    );
  });

  describe('resolution by link form', () => {
    test.each(
      Array.of<{
        cases: [body: string, expected: string[]][];
        extraFiles: Record<string, string>;
        name: string;
      }>(
        {
          cases: [['[[EXISTING]]\n', []]],
          extraFiles: {},
          name: 'slug match is case-insensitive',
        },
        {
          cases: [['[[existing title]]\n', []]],
          extraFiles: {},
          name: 'H1 title match is case-insensitive',
        },
        {
          cases: [
            ['[[Existing Title|shown]]\n', []],
            ['[[Gone|Existing Title]]\n', ['Gone']],
          ],
          extraFiles: {},
          name: 'an alias is dropped before matching',
        },
        {
          cases: [
            ['[[Existing Title#Nope]]\n', []],
            ['[[Gone#Heading]]\n', ['Gone']],
          ],
          extraFiles: {},
          name: 'an anchor is dropped before matching',
        },
        {
          cases: [
            ['| x | [[Existing Title\\|shown]] |\n', []],
            ['| x | [[Gone\\|shown]] |\n', ['Gone']],
          ],
          extraFiles: {},
          name: 'an escaped table pipe separates the alias',
        },
        {
          cases: [
            ['[[concepts/Existing]]\n', []],
            ['[[concepts/Gone]]\n', ['concepts/Gone']],
          ],
          extraFiles: {},
          name: 'a folder prefix resolves by its final segment and reports the full target',
        },
        {
          cases: [['[[overview]] [[Meta Note]]\n', []]],
          extraFiles: {
            'wiki/meta/Meta Note.md': '# Meta Note\n',
            'wiki/overview.md': 'no title here\n',
          },
          name: 'a wiki-root page and a wiki/meta page are valid targets',
        },
        {
          cases: [
            ['`[[Gone]]` and ``[[Gone Too]]`` [[Real Gone]]\n', ['Real Gone']],
          ],
          extraFiles: {},
          name: 'an inline code span is ignored, and a link after it still counts',
        },
        {
          cases: [
            [
              [
                '```',
                '[[Gone In Backticks]]',
                '```',
                '~~~',
                '[[Gone In Tildes]]',
                '~~~',
                '[[Gone After]]',
                '',
              ].join('\n'),
              ['Gone After'],
            ],
          ],
          extraFiles: {},
          name: 'a backtick fence and a tilde fence each hide their lines',
        },
        {
          cases: [['[[Old]]\n', ['Old']]],
          extraFiles: {'wiki/_archived/Old.md': '# Old\n'},
          name: 'a link into wiki/_archived is broken',
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {cases, extraFiles}) => {
      for (const [relativePath, contents] of Object.entries(extraFiles)) {
        sandbox.writeFile(relativePath, contents);
      }

      for (const [body, expected] of cases) {
        expect(brokenTargets('wiki/a.md', body)).toEqual(expected);
      }
    });

    test('a same-page anchor is neither reported nor counted', () => {
      sandbox.writeFile('wiki/a.md', '[[#Heading]]\n');

      expect(findBrokenLinks(sandbox.root)).toEqual({
        broken: [],
        scannedLinkCount: 0,
      });
    });

    test('a frontmatter link is reported with its file line', () => {
      sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
      sandbox.writeFile(
        'wiki/a.md',
        ['---', 'type: concept', 'related: [[Gone]]', '---', ''].join('\n')
      );

      expect(findBrokenLinks(sandbox.root).broken).toEqual([
        {line: 3, path: 'wiki/a.md', target: 'Gone'},
      ]);
    });

    test('links inside exempt files are not reported', () => {
      sandbox.writeFile('wiki/meta/x.md', '[[Gone]]\n');
      sandbox.writeFile('wiki/log.md', '[[Gone]]\n');
      sandbox.writeFile('wiki/_archived/y.md', '[[Gone]]\n');

      expect(findBrokenLinks(sandbox.root)).toEqual({
        broken: [],
        scannedLinkCount: 0,
      });
    });
  });

  test('orders links by column within a line and files by path', () => {
    sandbox.writeFile('wiki/b.md', '[[Zed]]\n');
    sandbox.writeFile('wiki/a.md', 'x [[Second]] y [[Third]]\n[[Fourth]]\n');

    expect(
      findBrokenLinks(sandbox.root).broken.map(
        (link) => `${link.path}:${link.line}:${link.target}`
      )
    ).toEqual([
      'wiki/a.md:1:Second',
      'wiki/a.md:1:Third',
      'wiki/a.md:2:Fourth',
      'wiki/b.md:1:Zed',
    ]);
  });

  test.each(
    Array.of<{
      expectedOutput: string;
      files: Record<string, string>;
      name: string;
    }>(
      {
        expectedOutput: 'wiki/a.md:1  One\nwiki/a.md:3  Two\n',
        files: {'wiki/a.md': '[[One]]\n\n[[Two]]\n'},
        name: 'human mode prints one path:line  target line per entry',
      },
      {
        expectedOutput: '',
        files: {
          'wiki/a.md': '[[Existing Title]]\n',
          'wiki/concepts/Existing.md': EXISTING_PAGE,
        },
        name: 'human mode prints nothing when clean',
      }
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {expectedOutput, files}) => {
    for (const [relativePath, contents] of Object.entries(files)) {
      sandbox.writeFile(relativePath, contents);
    }

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe(expectedOutput);
  });

  test('counts every non-skipped link', () => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile(
      'wiki/a.md',
      [
        '[[Existing Title]]',
        '[[Gone]]',
        '[[#Heading]]',
        '`[[Code]]`',
        '```',
        '[[Fence]]',
        '```',
        '[[Existing Title|alias]]',
        '',
      ].join('\n')
    );
    sandbox.writeFile('wiki/log.md', '[[Exempt]]\n');

    expect(findBrokenLinks(sandbox.root).scannedLinkCount).toBe(3);
  });

  test('an unknown flag is an invalid_arguments error', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });

  test('an absent wiki directory yields an empty report', () => {
    const exit = run(['--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('{"broken":[]}\n');
  });
});
