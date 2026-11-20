/**
 * The emit/answer-gate tests (`--ship`/`--withhold`/`--allow-undecided`,
 * `--out`/`--stdout`) live in `manifest-cli.test.ts`. The flag-grammar tests
 * live in `manifest-cli-args.test.ts`.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './manifest-cli.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
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

type ManifestDriftJson = {
  drift: {actual: string; expected: string; file: string}[];
  extra: {actual: string; file: string}[];
  missing: {expected: string; file: string}[];
};

type ManifestEdit = {
  files: Record<string, string>;
  regions: {id: string; paths: string[]}[];
  version: string;
};

describe('run --check', () => {
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

  const seedAndGenerate = (extraFiles: Record<string, string> = {}): void => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
      'wiki/concepts/Bar.md': '# bar\n',
      'wiki/index.md': '# index\n',
      ...extraFiles,
    });

    // No committed manifest yet, so every classified path is unanswered; the
    // escape hatch is how a manifest gets bootstrapped from nothing.
    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;
  };

  test('clean case: exits 0 with empty diff', () => {
    seedAndGenerate();

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
    expect(stdio.errors.join('')).toBe('');
  });

  const manifestFile = (): string =>
    path.join(sandbox.root, '.gaia/manifest.json');

  const editManifest = (edit: (manifest: ManifestEdit) => void): void => {
    const manifest = JSON.parse(
      readFileSync(manifestFile(), 'utf8')
    ) as ManifestEdit;
    edit(manifest);
    writeFileSync(
      manifestFile(),
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );
  };

  const runCheck = (): number =>
    run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

  test.each<{
    contains: string[];
    edit: (manifest: ManifestEdit) => void;
    files?: Record<string, string>;
    name: string;
  }>([
    {
      contains: [
        'newly ship',
        'app/foo.ts',
        '--ship',
        '--withhold',
        'does not withhold',
      ],
      edit: (manifest) => {
        delete manifest.files['app/foo.ts'];
      },
      name: 'missing entry: exits non-zero and names the missing file',
    },
    {
      contains: ['extra in manifest', 'app/ghost.ts'],
      edit: (manifest) => {
        manifest.files['app/ghost.ts'] = 'owned';
      },
      name: 'extra entry: exits non-zero and names the extra file',
    },
    {
      contains: ['class drift', 'app/foo.ts', 'shared → owned'],
      edit: (manifest) => {
        manifest.files['app/foo.ts'] = 'shared';
      },
      name: 'classification drift: exits non-zero and names the drift',
    },
    {
      contains: ['version drift', '0.9.0', '1.0.0'],
      edit: (manifest) => {
        manifest.version = '0.9.0';
      },
      name: 'version drift: exits non-zero and names both versions',
    },
    {
      // Hand-edit the committed manifest so its region declaration disagrees
      // with a fresh scan of the repo, with no file-level drift at all.
      contains: ['region declaration drift', '.claude/agents/test-auditor.md'],
      edit: (manifest) => {
        manifest.regions = manifest.regions.map((region) =>
          region.id === 'audit-remit' ? {...region, paths: []} : region
        );
      },
      files: {
        '.claude/agents/test-auditor.md': [
          '# Test Auditor',
          '',
          '## Remit and self-skip',
          '',
          '<!-- gaia:audit-remit:start -->',
          '- `app/**`',
          '',
          'Filter the changed-file list against the globs above.',
          '<!-- gaia:audit-remit:end -->',
          '',
        ].join('\n'),
        '.gaia/audit-ci.yml': [
          'auditors:',
          '  - name: test-auditor',
          '    globs:',
          '      - "app/**"',
          '    audience: adopter',
          '    default: true',
          '',
        ].join('\n'),
      },
      name: 'region drift only (no file drift): exits non-zero and names the offending path',
    },
  ])('$name', ({contains, edit, files}) => {
    seedAndGenerate(files);
    editManifest(edit);

    expect(runCheck()).toBe(1);
    const out = stdio.outputs.join('');

    for (const fragment of contains) {
      expect(out).toContain(fragment);
    }
  });

  test.each<{
    contains: string[];
    exit: number;
    name: string;
    prepare: () => void;
  }>([
    {
      contains: ['manifest_parse_failed', 'malformed'],
      exit: 2,
      name: 'malformed manifest (not an object): exits 2 with a parse error',
      prepare: () => {
        writeFileSync(manifestFile(), '["not", "a", "manifest"]\n', 'utf8');
      },
    },
    {
      contains: ['manifest_parse_failed'],
      exit: 2,
      name: 'malformed manifest (bad class value): exits 2 with a parse error',
      prepare: () => {
        editManifest((manifest) => {
          manifest.files['app/foo.ts'] = 'bogus-class';
        });
      },
    },
    {
      contains: ['manifest_build_failed', 'literal'],
      exit: 2,
      name: 'glob-shaped release-exclude line: exits 2 loudly instead of silently mis-excluding',
      prepare: () => {
        writeFileSync(
          path.join(sandbox.root, '.gaia/release-exclude'),
          'app/foo*\n',
          'utf8'
        );
      },
    },
    {
      contains: ['manifest_build_failed'],
      exit: 2,
      name: 'indented release-exclude line: exits 2 loudly',
      prepare: () => {
        writeFileSync(
          path.join(sandbox.root, '.gaia/release-exclude'),
          '  app/foo\n',
          'utf8'
        );
      },
    },
    {
      // The remedy it names must be one that actually works: the bare command
      // refuses on any tree carrying a classified file.
      contains: [
        'manifest_missing',
        'gaia-maintainer release manifest --allow-undecided',
      ],
      exit: 1,
      name: 'missing manifest file: exits non-zero with manifest_missing error',
      prepare: () => {
        rmSync(manifestFile());
      },
    },
  ])('$name', ({contains, exit, prepare}) => {
    seedAndGenerate();
    prepare();

    expect(runCheck()).toBe(exit);
    const errors = stdio.errors.join('');

    for (const fragment of contains) {
      expect(errors).toContain(fragment);
    }
  });

  test('--check --json emits structured report', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/extra.ts'] = 'owned';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check', '--json'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const parsed = JSON.parse(stdio.outputs.join('')) as ManifestDriftJson;
    expect(parsed.extra).toEqual([{actual: 'owned', file: 'app/extra.ts'}]);
    expect(parsed.missing).toEqual([]);
    expect(parsed.drift).toEqual([]);
  });
});
