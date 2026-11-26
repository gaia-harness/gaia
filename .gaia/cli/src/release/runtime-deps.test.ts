import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {ADOPTER_OWNED_SENTINELS, extractPathRefs, run} from './runtime-deps.js';
import {SCAN_GLOBS} from './scan-globs.js';

type ManifestFiles = Record<string, 'owned' | 'shared' | 'wiki-owned'>;

type Sandbox = {
  cleanup: () => void;
  rootDir: string;
  writeFile: (relativePath: string, contents: string) => void;
  writeManifest: (files: ManifestFiles) => void;
  writeStagingManifest: (stagingDir: string, files: ManifestFiles) => void;
};

const writeManifestAt = (root: string, files: ManifestFiles): void => {
  const absolute = path.join(root, '.gaia', 'manifest.json');
  mkdirSync(path.dirname(absolute), {recursive: true});
  writeFileSync(
    absolute,
    `${JSON.stringify(
      {
        files,
        generated: '2026-05-08T00:00:00Z',
        version: '1.0.0',
      },
      null,
      2
    )}\n`,
    'utf8'
  );
};

const setupSandbox = (): Sandbox => {
  const rootDir = mkdtempSync(path.join(tmpdir(), 'gaia-runtime-deps-'));

  return {
    cleanup: () => {
      rmSync(rootDir, {force: true, recursive: true});
    },
    rootDir,
    writeFile: (relativePath, contents) => {
      const absolute = path.join(rootDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
    },
    writeManifest: (files) => {
      writeManifestAt(rootDir, files);
    },
    // A `--staging` run reads the manifest from inside the staging tree, not
    // the repo root, so a staging test needs its own manifest at that root.
    writeStagingManifest: (stagingDir, files) => {
      writeManifestAt(stagingDir, files);
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

type RefInput = {file: string; text: string | string[]};

const pathsPerLine = ({file, text}: RefInput): string[][] =>
  (Array.isArray(text) ? text : [text]).map((line) =>
    extractPathRefs(file, line).map((ref) => ref.path)
  );

describe('extractPathRefs', () => {
  test.each<RefInput & {equal: string[]; name: string}>([
    {
      equal: ['.gaia/cli/gaia'],
      file: '.gaia/statusline/foo.sh',
      name: 'skips line-leading comments',
      text: '# A reference to .gaia/scripts/check-updates.sh in a comment.\nbash .gaia/cli/gaia\n',
    },
    {
      equal: ['.gaia/cli/gaia', '.gaia/cli/gaia'],
      file: '.claude/hooks/foo.sh',
      name: 'handles bare path tokens in conditionals',
      text: 'if [ -x .gaia/cli/gaia ]; then\n  .gaia/cli/gaia run\nfi\n',
    },
    {
      equal: [],
      file: '.claude/hooks/foo.sh',
      name: 'does not match substrings inside larger paths',
      text: 'echo "not-a-leak/.gaia/cli/foo"\n',
    },
    {
      equal: ['.gaia/cli/gaia'],
      file: '.claude/hooks/foo.sh',
      name: 'trims trailing punctuation',
      text: 'echo .gaia/cli/gaia.\n',
    },
    {
      equal: ['.gaia/cli/gaia', '.claude/hooks/x.sh'],
      file: '.gaia/statusline/foo.sh',
      name: 'extracts multiple occurrences on the same line',
      text: 'cp .gaia/cli/gaia .claude/hooks/x.sh\n',
    },
    {
      // Guards the suppression against over-reach: the rule keys on the
      // halting metacharacter, not on the shape of the token, so a real
      // reference that merely looks like a truncated prefix must still flag.
      equal: ['.claude/agents/code-audit-'],
      file: '.gaia/statusline/foo.sh',
      name: 'still flags a genuine reference whose basename ends in a dash',
      text: 'bash .claude/agents/code-audit-\n',
    },
    {
      // A `*` after a non-empty basename prefix truncates the token to the
      // fragment `.claude/agents/code-audit-`, which names no manifest entry
      // and no shipped directory, so keeping it would report a phantom leak on
      // legitimate prose. The fragment names a family of files, so the question
      // worth asking is whether the directory holding that family ships.
      equal: ['.claude/agents'],
      file: '.claude/hooks/foo.sh',
      name: 'reduces a pattern that truncates mid-basename to its directory',
      text: 'reason="rewrites .claude/agents/code-audit-*.md, which are machinery"\n',
    },
    {
      // Control for the rule above, and the idiom already in the tree
      // (`for f in .claude/hooks/*.sh`): the `*` follows a `/`, so the
      // expansion is already the directory token, and both shapes yield
      // the same kind of token.
      equal: ['.claude/hooks'],
      file: '.gaia/scripts/lint-hook-array-guard.sh',
      name: 'keeps a pattern that starts at a directory boundary',
      text: 'for f in .claude/hooks/*.sh; do :; done\n',
    },
    {
      // `?`, `[`, `{`, and `$` are absent from the path-body character class
      // for the same reason `*` is, so they truncate identically and are
      // reduced identically. Mid-basename `${var}` is the most common of the
      // five in shell.
      equal: ['.claude/agents'],
      file: '.claude/hooks/foo.sh',
      name: 'reduces mid-basename truncation on the other pattern-opening characters',
      text: [
        'ls .claude/agents/code-audit-?.md\n',
        'ls .claude/agents/code-audit-[abc].md\n',
        'ls .claude/agents/code-audit-{frontend,shell}.md\n',
        // eslint-disable-next-line no-template-curly-in-string -- literal shell `${ }` syntax, not JS interpolation
        'agent=".claude/agents/code-audit-${member}.md"\n',
      ],
    },
  ])('$name', (row) => {
    for (const paths of pathsPerLine(row)) {
      expect(paths).toEqual(row.equal);
    }
  });

  test.each<RefInput & {contain: string[]; name: string}>([
    {
      contain: ['.gaia/scripts/check-updates.sh'],
      file: '.gaia/statusline/foo.sh',
      name: 'extracts repo-relative paths from variable assignments',
      text: 'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"\n',
    },
    {
      // The allowlist is exact-token. A real invocation of a file under
      // .github/workflows/ is a distinct, longer token and must still flag,
      // guarding against the allowlist over-suppressing genuine leaks.
      contain: ['.github/workflows/deploy.yml'],
      file: '.gaia/statusline/foo.sh',
      name: 'still flags a genuine file leak under an allowlisted directory',
      text: 'bash .github/workflows/deploy.yml\n',
    },
    {
      // Exact-token allowlisting again: a real invocation of a file beneath
      // the allowlisted directory is a longer token and must still flag.
      contain: ['.claude/shell-snapshots/snapshot-zsh.sh'],
      file: '.gaia/statusline/foo.sh',
      name: 'still flags a genuine file leak under the shell-snapshots directory',
      text: 'bash .claude/shell-snapshots/snapshot-zsh.sh\n',
    },
    {
      // `]` and `}` only ever close a pattern, so the token before one is a
      // complete path. Reducing it to its directory would discard a real
      // reference and silence a genuine leak.
      contain: ['.gaia/scripts/missing.sh'],
      file: '.claude/hooks/foo.sh',
      name: 'does not reduce a token that halts on a pattern-closing character',
      // eslint-disable-next-line no-template-curly-in-string -- literal shell `${ }` syntax, not JS interpolation
      text: 'echo "${paths[.gaia/scripts/missing.sh]}"\n',
    },
  ])('$name', (row) => {
    for (const paths of pathsPerLine(row)) {
      for (const wanted of row.contain) {
        expect(paths).toContain(wanted);
      }
    }
  });

  test.each<RefInput & {contain: string[]; name: string; notContain: string[]}>(
    [
      {
        contain: [],
        // pr-merge-audit-check.sh names `.github/workflows/` as an example
        // in-scope path inside a multi-line `reason="..."` error string. It is
        // descriptive prose shown to the operator, not a runtime invocation, so
        // the scan must not treat it as a runtime-dependency leak.
        file: '.claude/hooks/pr-merge-audit-check.sh',
        name: 'skips prose-allowlisted directory tokens in user-facing strings',
        notContain: ['.github/workflows'],
        text: '                     .github/workflows/), not a wiki/docs/.gaia-only diff\n',
      },
      {
        contain: [],
        // spec-session-lock.sh assigns Claude Code's snapshot-wrapper directory
        // to a regex literal that a `ps` command line is matched against; it is
        // never sourced or executed, so the exact token is allowlisted.
        file: '.gaia/scripts/spec/spec-session-lock.sh',
        name: 'skips the allowlisted shell-snapshots regex-literal token',
        notContain: ['.claude/shell-snapshots'],
        text: "SNAPSHOT_WRAPPER_PATTERN='\\.claude/shell-snapshots/'\n",
      },
      {
        // audit-fix-verify.sh lists the gitignored local settings file among the
        // paths a fixer must not edit. It is compared against a changed-path
        // list, never sourced, and can never have a manifest entry, so the exact
        // token is allowlisted.
        contain: ['.claude/settings.json'],
        file: '.gaia/scripts/audit-fix-verify.sh',
        name: 'skips the allowlisted per-machine settings path in an enforcement-set array',
        notContain: ['.claude/settings.local.json'],
        text: 'ENFORCEMENT_SET=(.claude/settings.json .claude/settings.local.json)\n',
      },
      {
        contain: [],
        // install-react-doctor.sh names the per-machine, gitignored skill
        // directory it writes. It is never sourced or executed, so the exact
        // token is allowlisted.
        file: '.gaia/scripts/install-react-doctor.sh',
        name: 'skips the allowlisted skill directory the React Doctor install script renders into',
        notContain: ['.claude/skills/react-doctor'],
        text: 'skill_directory="$package_directory/.claude/skills/react-doctor"\n',
      },
      {
        contain: [],
        // pr-review-bundle.sh probes the adopter's own pull request template
        // candidates with git ls-files and treats a missing one as absent. They
        // are never sourced or executed, so the exact tokens are allowlisted.
        file: '.gaia/scripts/pr-review-bundle.sh',
        name: 'skips the allowlisted adopter pull request template probes',
        notContain: [
          '.github/pull_request_template.md',
          '.github/PULL_REQUEST_TEMPLATE.md',
        ],
        text: 'git -C "$root" ls-files --error-unmatch .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md\n',
      },
    ]
  )('$name', (row) => {
    for (const paths of pathsPerLine(row)) {
      for (const wanted of row.contain) {
        expect(paths).toContain(wanted);
      }

      for (const unwanted of row.notContain) {
        expect(paths).not.toContain(unwanted);
      }
    }
  });
});

const script = (...body: string[]): string =>
  ['#!/usr/bin/env bash', ...body, ''].join('\n');

const writeManifestWhenGiven = (
  sandbox: Sandbox,
  manifest: ManifestFiles | undefined
): void => {
  if (manifest !== undefined) {
    sandbox.writeManifest(manifest);
  }
};

describe('release runtime-deps CLI', () => {
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

  type CliCase = {
    args?: string[];
    err?: string[];
    exit: number;
    files?: Record<string, string>;
    manifest?: ManifestFiles;
    name: string;
    notOut?: string[];
    out?: string[];
  };

  test.each<CliCase>([
    {
      exit: 0,
      files: {
        '.gaia/statusline/gaia-statusline.sh': script(
          'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
          'if [ -x .gaia/cli/gaia ]; then bash "$CHECK_SCRIPT"; fi'
        ),
      },
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/scripts/check-updates.sh': 'owned',
        '.gaia/statusline/gaia-statusline.sh': 'owned',
      },
      name: 'passes when shipped scripts only reference manifested paths',
      out: ['runtime-dependency leaks: none'],
    },
    {
      // Manifest excludes .gaia/scripts/; that directory is release-excluded.
      // The scanned script itself must ship, or bare mode correctly skips it.
      exit: 1,
      files: {
        '.gaia/statusline/gaia-statusline.sh': script(
          'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
          'bash "$CHECK_SCRIPT"'
        ),
      },
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/statusline/gaia-statusline.sh': 'owned',
      },
      name: 'flags references to release-excluded paths',
      out: [
        '.gaia/scripts/check-updates.sh',
        '.gaia/statusline/gaia-statusline.sh:2',
      ],
    },
    {
      exit: 0,
      files: {
        '.claude/hooks/wiki-session-start.sh': script(
          'cat .gaia/manifest.json',
          'cat .gaia/VERSION',
          'cat wiki/log.md'
        ),
      },
      manifest: {
        '.claude/hooks/wiki-session-start.sh': 'owned',
        '.gaia/cli/gaia': 'owned',
      },
      name: 'allowlists adopter-owned sentinels',
    },
    {
      exit: 0,
      files: {
        '.claude/hooks/wiki-session-start.sh': script(
          'rm -f .gaia/local/cache/shared/update-check.json',
          'STATE_FILE="$PROJECT_ROOT/.gaia/local/setup-state.json"'
        ),
      },
      manifest: {
        '.claude/hooks/wiki-session-start.sh': 'owned',
        '.gaia/cli/gaia': 'owned',
      },
      name: 'allowlists runtime-allocated prefixes (.gaia/local)',
    },
    {
      // Mirrors a shell array glob like `SCAN_GLOB=(.claude/hooks/*.sh)`: the
      // extractor's path-body character class stops at `*`, yielding the bare
      // directory token `.claude/hooks`. That token isn't itself a manifest
      // entry, but files ship beneath it on a real adopter clone, so it must
      // resolve as shipped rather than flag as a leak.
      exit: 0,
      files: {
        '.gaia/scripts/lint-hook-array-guard.sh': script(
          'SCAN_GLOB=(.claude/hooks/*.sh)'
        ),
      },
      manifest: {
        '.claude/hooks/wiki-session-start.sh': 'owned',
        '.gaia/scripts/lint-hook-array-guard.sh': 'owned',
      },
      name: 'resolves a bare directory token as shipped when manifest entries exist beneath it',
      out: ['runtime-dependency leaks: none'],
    },
    {
      // The gate fails closed, so a phantom leak blocks every distribution
      // scenario and `/gaia-release` itself until someone reverse-engineers
      // the extractor. Operator-facing prose naming a family of files by
      // pattern is legitimate and must not cost a release.
      exit: 0,
      files: {
        '.claude/hooks/audit-loop-bound.sh': script(
          'deny "rewrites .claude/agents/code-audit-*.md, which are machinery"'
        ),
      },
      manifest: {
        '.claude/agents/code-audit-frontend.md': 'owned',
        '.claude/hooks/audit-loop-bound.sh': 'owned',
      },
      name: 'passes when a shipped script names a file family by pattern',
      out: ['runtime-dependency leaks: none'],
    },
    {
      // The counterpart to the test above, and the reason a truncated fragment
      // is reduced rather than dropped: a shipped hook sourcing a family of
      // files under a release-excluded directory is a genuine leak. Dropping
      // the fragment would let it publish and fail on every adopter clone.
      exit: 1,
      files: {
        '.claude/hooks/ships.sh': script(
          'for t in .gaia/scripts/tests/run-*.sh; do bash "$t"; done'
        ),
      },
      manifest: {
        '.claude/hooks/ships.sh': 'owned',
        '.gaia/scripts/run-tests.sh': 'owned',
      },
      name: 'still flags a file family sourced from a release-excluded directory',
      out: ['.gaia/scripts/tests'],
    },
    {
      // `.gaia/scripts/tests` is release-excluded end-to-end: zero manifest
      // entries live beneath it, so a bare-directory reference must still
      // flag, guarding against the directory rule over-rescuing a
      // genuinely leaked directory.
      exit: 1,
      files: {
        '.gaia/scripts/run-tests.sh': script(
          'SCAN_GLOB=(.gaia/scripts/tests/*.sh)'
        ),
      },
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/scripts/run-tests.sh': 'owned',
      },
      name: 'still flags a bare directory token as a leak when no manifest entries exist beneath it',
      out: ['.gaia/scripts/tests'],
    },
    {
      // The directory rule must stay scoped to bare directory tokens. A
      // specific file path that sits under a shipped directory but isn't itself
      // a manifest entry is still a genuine leak.
      exit: 1,
      files: {
        '.gaia/statusline/foo.sh': 'bash .claude/hooks/not-a-real-hook.sh\n',
      },
      manifest: {
        '.claude/hooks/wiki-session-start.sh': 'owned',
        '.gaia/statusline/foo.sh': 'owned',
      },
      name: 'does not rescue an unmanifested file merely because its directory ships other files',
      out: ['.claude/hooks/not-a-real-hook.sh'],
    },
    {
      // Guards the fixed-point break in `computeShippedDirs`'s ancestor walk.
      // Manifest keys are repo-relative by construction and drain to `.`, but
      // `loadManifest` reads `Object.keys` off unvalidated JSON, so a corrupt
      // manifest can carry an absolute key. `path.dirname('/')` is `'/'`, so
      // such a key never reaches `.` and the walk must be bounded explicitly.
      // Removing that break turns this into a synchronous infinite loop, which
      // hangs the release gate instead of failing it.
      exit: 0,
      files: {'.gaia/statusline/foo.sh': 'echo hi\n'},
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/statusline/foo.sh': 'owned',
        '/absolute/path/oops.sh': 'owned',
      },
      name: 'terminates on a manifest key that is an absolute path',
    },
    {
      // Recursion-and-leak guard: a maintainer-only path referenced inside a
      // deeply nested composite-action script must still flag, proving the
      // scan scope walks the tree rather than only its top level.
      exit: 1,
      files: {
        '.github/actions/gaia-example-action/lib/render-issue.sh': script(
          'bash .gaia/cli/src/release/scrub.ts'
        ),
      },
      manifest: {
        '.github/actions/gaia-example-action/lib/render-issue.sh': 'owned',
      },
      name: 'flags a release-excluded reference in a nested .github/actions script',
      out: ['.gaia/cli/src/release/scrub.ts'],
    },
    {
      exit: 0,
      manifest: {},
      name: 'exits 0 when there are no shipped script directories',
    },
    {
      err: ['manifest_load_failed'],
      exit: 2,
      files: {'.gaia/statusline/foo.sh': 'bash .gaia/cli/gaia\n'},
      name: 'exits 2 when manifest is missing',
    },
    {
      args: ['--bogus'],
      err: ['unknown flag'],
      exit: 1,
      manifest: {},
      name: 'rejects unknown flags',
    },
    {
      // Bare mode (no --staging) strips `# gaia:maintainer-only:start` / `:end`
      // blocks in-memory, the same blocks the scrub's `**/*.sh` marker-strip
      // transform removes before --staging scans, so a .gaia/cli/src reference
      // inside one is not a leak and bare mode agrees with the authoritative
      // staging run.
      exit: 0,
      files: {
        '.gaia/scripts/resolve-audit-members.sh': script(
          '# gaia:maintainer-only:start',
          'echo .gaia/cli/src',
          '# gaia:maintainer-only:end'
        ),
      },
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/scripts/resolve-audit-members.sh': 'owned',
      },
      name: 'agrees with staging mode: a reference inside a maintainer-only block is not a leak',
      out: ['runtime-dependency leaks: none'],
    },
    {
      // Control for the row above: the marker strip must not disable
      // leak detection wholesale, only the wrapped block.
      exit: 1,
      files: {
        '.gaia/scripts/resolve-audit-members.sh': script('echo .gaia/cli/src'),
      },
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/scripts/resolve-audit-members.sh': 'owned',
      },
      name: 'still flags the same kind of reference outside a maintainer-only block',
      out: ['.gaia/cli/src'],
    },
    {
      exit: 0,
      files: {
        '.gaia/statusline/preferred-base.sh': script(
          '# This file is .gaia/statusline/preferred-base.sh',
          'echo .gaia/statusline/preferred-base.sh'
        ),
      },
      manifest: {'.gaia/statusline/preferred-base.sh': 'owned'},
      name: 'skips self-references',
    },
    {
      // Bare mode walks the repo root, which holds scripts the staging tree
      // never has. A release-excluded script (no manifest entry) naming a
      // maintainer-only workflow in a TRAILING comment would surface as a leak,
      // since `stripCommentSuffix` strips only line-leading `#` by design.
      // Scanning a file that never ships can only produce a phantom, so the
      // scan surface is the manifest.
      exit: 0,
      files: {
        '.gaia/scripts/verify-required-checks.sh': script(
          'REQUIRED_CONTEXTS=(',
          '  "Audit CI Tests"   # .github/workflows/audit-ci-tests.yml',
          ')'
        ),
      },
      manifest: {'.gaia/cli/gaia': 'owned'},
      name: 'bare mode does not scan a release-excluded script',
      out: ['runtime-dependency leaks: none'],
    },
    {
      // A clean bare result covers only what the manifest already answers
      // for, so a shipped script added before its `/distribution-vet` answer
      // lands is skipped rather than cleared. The header has to say so; an
      // unqualified "scanned N script(s)" reads as "all of them" and turns a
      // partial pass into a false all-clear.
      exit: 0,
      files: {'.claude/hooks/ships.sh': 'echo hi\n'},
      manifest: {'.claude/hooks/ships.sh': 'owned'},
      name: 'bare mode names its narrowed scope in the report header',
      out: ['1 manifest-backed script(s)'],
    },
    {
      // Control for the two tests above: narrowing the scan surface must not
      // disable leak detection for the files that DO ship.
      exit: 1,
      files: {'.gaia/statusline/foo.sh': 'bash .gaia/scripts/missing.sh\n'},
      manifest: {'.gaia/statusline/foo.sh': 'owned'},
      name: 'bare mode still flags a leak in a manifest-backed script',
      out: ['.gaia/scripts/missing.sh'],
    },
  ])('$name', ({args, err, exit, files, manifest, notOut, out}) => {
    writeManifestWhenGiven(sandbox, manifest);

    for (const [relativePath, contents] of Object.entries(files ?? {})) {
      sandbox.writeFile(relativePath, contents);
    }

    expect(run(args ?? [], {cwd: sandbox.rootDir})).toBe(exit);

    const stdout = stdio.outputs.join('');

    for (const fragment of out ?? []) {
      expect(stdout).toContain(fragment);
    }

    for (const fragment of notOut ?? []) {
      expect(stdout).not.toContain(fragment);
    }

    for (const fragment of err ?? []) {
      expect(stdio.errors.join('')).toContain(fragment);
    }
  });

  test.each<{
    exit: number;
    name: string;
    notOut?: string[];
    out?: string[];
    staged: string;
  }>([
    {
      exit: 0,
      name: '--staging scans inside the staging dir',
      staged: 'bash .gaia/cli/gaia\n',
    },
    {
      exit: 0,
      name: '--staging with a shipped script referencing .gaia/VERSION-dev exits 0',
      staged: 'cat .gaia/VERSION-dev\n',
    },
    {
      exit: 1,
      name: '--staging with a shipped script referencing .gaia/VERSION-other exits 1',
      staged: 'cat .gaia/VERSION-other\n',
    },
    {
      // Control: staging scans the tarball unfiltered, so its header must stay
      // the unqualified count rather than inherit bare mode's caveat.
      exit: 0,
      name: '--staging does not claim the narrowed scope',
      notOut: ['manifest-backed'],
      out: ['scanned 1 script(s)'],
      staged: 'bash .gaia/cli/gaia\n',
    },
    {
      // Staging is the ground truth for what ships: it scans the extracted
      // tarball unfiltered, so a shipped-but-unmanifested script still gets
      // scanned there and a packaging bug stays visible to the release gate.
      exit: 1,
      name: '--staging scans every script present in the tarball',
      out: ['.gaia/scripts/missing.sh'],
      staged: 'bash .gaia/scripts/missing.sh\n',
    },
  ])('$name', ({exit, notOut, out, staged}) => {
    const stagingDir = path.join(sandbox.rootDir, 'staging');
    sandbox.writeStagingManifest(stagingDir, {'.gaia/cli/gaia': 'owned'});
    mkdirSync(path.join(stagingDir, '.gaia/statusline'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/statusline/foo.sh'),
      staged,
      'utf8'
    );

    expect(run(['--staging', stagingDir], {cwd: sandbox.rootDir})).toBe(exit);

    const stdout = stdio.outputs.join('');

    for (const fragment of out ?? []) {
      expect(stdout).toContain(fragment);
    }

    for (const fragment of notOut ?? []) {
      expect(stdout).not.toContain(fragment);
    }
  });

  test('scans a manifested script under .gaia/scripts/spec and classifies its tokens', () => {
    // The spec-lifecycle scripts live in a subdirectory of `.gaia/scripts`, so
    // the recursive walk must reach them: a token that names a shipped file
    // passes, and the same token naming a missing file flags, exactly as for
    // any other shipped script.
    sandbox.writeManifest({
      '.gaia/scripts/check-updates.sh': 'owned',
      '.gaia/scripts/spec/lint.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/spec/lint.sh',
      '#!/usr/bin/env bash\nbash .gaia/scripts/check-updates.sh\n'
    );

    expect(run([], {cwd: sandbox.rootDir})).toBe(0);

    const cleanOutput = stdio.outputs.join('');
    expect(cleanOutput).toContain('1 manifest-backed script(s)');
    expect(cleanOutput).toContain('runtime-dependency leaks: none');

    sandbox.writeFile(
      '.gaia/scripts/spec/lint.sh',
      '#!/usr/bin/env bash\nbash .gaia/scripts/missing.sh\n'
    );
    stdio.outputs.length = 0;

    expect(run([], {cwd: sandbox.rootDir})).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/scripts/missing.sh');
  });

  test('allowlists the adopter-owned update decision log, and reports it once the sentinel is gone', () => {
    sandbox.writeManifest({
      '.claude/hooks/wiki-session-start.sh': 'owned',
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/wiki-session-start.sh',
      ['#!/usr/bin/env bash', 'cat .gaia/update-decisions.json', ''].join('\n')
    );

    expect(run([], {cwd: sandbox.rootDir})).toBe(0);

    const sentinels = ADOPTER_OWNED_SENTINELS as Set<string>;
    sentinels.delete('.gaia/update-decisions.json');

    try {
      stdio.outputs.length = 0;

      expect(run([], {cwd: sandbox.rootDir})).toBe(1);
      expect(stdio.outputs.join('')).toContain('.gaia/update-decisions.json');
    } finally {
      sentinels.add('.gaia/update-decisions.json');
    }
  });

  test.each<{
    exit: number;
    files?: Record<string, string>;
    leaks: string[];
    manifest: ManifestFiles;
    name: string;
    scannedContains: string[];
  }>([
    {
      exit: 0,
      // Composite-action scripts can live two directories deep
      // (.github/actions/<action>/lib/*.sh); the walk must recurse to reach
      // them. This fixture ships (manifest "owned") and references no
      // maintainer paths, so a clean scan is the expected steady state.
      files: {
        '.github/actions/gaia-example-action/lib/wait-for-ci.sh': script(
          'gh pr checks "$PR_NUMBER"'
        ),
      },
      leaks: [],
      manifest: {
        '.github/actions/gaia-example-action/lib/wait-for-ci.sh': 'owned',
      },
      name: 'scans nested scripts under .github/actions',
      scannedContains: [
        '.github/actions/gaia-example-action/lib/wait-for-ci.sh',
      ],
    },
    {
      exit: 1,
      files: {'.gaia/statusline/foo.sh': 'bash .gaia/scripts/missing.sh\n'},
      leaks: ['.gaia/scripts/missing.sh'],
      manifest: {
        '.gaia/cli/gaia': 'owned',
        '.gaia/statusline/foo.sh': 'owned',
      },
      name: '--json emits structured report',
      scannedContains: ['.gaia/statusline/foo.sh'],
    },
  ])('$name', ({exit, files, leaks, manifest, scannedContains}) => {
    sandbox.writeManifest(manifest);

    for (const [relativePath, contents] of Object.entries(files ?? {})) {
      sandbox.writeFile(relativePath, contents);
    }

    expect(run(['--json'], {cwd: sandbox.rootDir})).toBe(exit);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: readonly {path: string}[];
      scanned_files: readonly string[];
    };
    expect(parsed.leaks.map((leak) => leak.path)).toEqual(leaks);

    for (const scanned of scannedContains) {
      expect(parsed.scanned_files).toContain(scanned);
    }
  });

  test.each<{
    exit: number;
    files?: Record<string, string>;
    leaks: string[];
    manifest: ManifestFiles;
    name: string;
    scannedEquals: string[];
  }>([
    {
      exit: 0,
      // The scan surface itself is the contract: bare mode must agree with the
      // authoritative post-scrub staging run, which only ever sees shipped
      // files. A release-excluded sibling must not inflate the scanned count.
      files: {
        '.claude/hooks/ships.sh': 'echo hi\n',
        '.gaia/scripts/excluded.sh': 'echo hi\n',
      },
      leaks: [],
      manifest: {'.claude/hooks/ships.sh': 'owned'},
      name: 'bare mode reports only manifest-backed scripts as scanned',
      scannedEquals: ['.claude/hooks/ships.sh'],
    },
  ])('$name', ({exit, files, leaks, manifest, scannedEquals}) => {
    sandbox.writeManifest(manifest);

    for (const [relativePath, contents] of Object.entries(files ?? {})) {
      sandbox.writeFile(relativePath, contents);
    }

    expect(run(['--json'], {cwd: sandbox.rootDir})).toBe(exit);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: readonly {path: string}[];
      scanned_files: readonly string[];
    };
    expect(parsed.leaks.map((leak) => leak.path)).toEqual(leaks);

    expect(parsed.scanned_files).toEqual(scannedEquals);
  });

  test('--json discriminates the scan scope in both modes', () => {
    // `scanned_files` means two different things per mode, and a JSON consumer
    // cannot read the prose caveat the human header carries, so the payload
    // has to say which one it is.
    sandbox.writeManifest({
      '.claude/hooks/ships.sh': 'owned',
    });
    sandbox.writeFile('.claude/hooks/ships.sh', 'echo hi\n');

    expect(run(['--json'], {cwd: sandbox.rootDir})).toBe(0);
    const bare = JSON.parse(stdio.outputs.join('')) as {scan_scope: string};
    expect(bare.scan_scope).toBe('manifest-backed');

    stdio.outputs.length = 0;

    const stagingDir = path.join(sandbox.rootDir, 'staging');
    sandbox.writeStagingManifest(stagingDir, {'.gaia/cli/gaia': 'owned'});

    expect(
      run(['--json', '--staging', stagingDir], {cwd: sandbox.rootDir})
    ).toBe(0);
    const staging = JSON.parse(stdio.outputs.join('')) as {scan_scope: string};
    expect(staging.scan_scope).toBe('tarball');
  });
});

describe('SCAN_GLOBS coverage of the committed manifest', () => {
  test('every owned .sh file in the committed manifest sits under a SCAN_GLOBS entry', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const manifestPath = path.join(repoRoot, '.gaia', 'manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    const ownedShFiles = Object.entries(manifest.files)
      .filter(([file, klass]) => klass === 'owned' && file.endsWith('.sh'))
      .map(([file]) => file);

    for (const file of ownedShFiles) {
      const covered = SCAN_GLOBS.some(
        (glob) => file === glob || file.startsWith(`${glob}/`)
      );
      expect(covered, `${file} is not under any SCAN_GLOBS entry`).toBe(true);
    }
  });
});
