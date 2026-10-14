import {afterEach, describe, expect, test} from 'vitest';
import {createHash} from 'node:crypto';
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {applyProposal} from './apply.js';
import type {ApplyResult} from './apply.js';
import {runCheck} from './check.js';
import {createScratchProject, runFitness} from './test-support.js';
import type {ScratchProject} from './test-support.js';
import type {FixtureProject, RuleDefinition} from './types.js';

const MARKER = 'REMOVE-THIS-MARKER';
const FIXED = 'fixed content\n';
const MARKED = `# Notes\n${MARKER}\n`;

const sha256 = (text: string): string =>
  createHash('sha256').update(text).digest('hex');

/** A claudemd warning that fires on a marker string, standing in for a real rule. */
const markerRule = (onCheck?: () => void): RuleDefinition => ({
  appliesTo: ['claudemd'],
  category: 'claudemd',
  check: (context) => {
    const findings = context
      .filesOfKind('claudemd')
      .filter((file) => file.text.includes(MARKER))
      .map((file) => ({
        file: file.path,
        line: 2,
        message: 'The marker is present.',
        remediation: 'Remove the marker.',
      }));

    onCheck?.();

    return findings;
  },
  detection: 'A CLAUDE.md that contains the marker string.',
  ruleId: 'claudemd.example-marker',
  severity: 'warning',
});

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const scratchDirectory = (): string => {
  const directory = mkdtempSync(path.join(tmpdir(), 'gaia-apply-'));

  cleanups.push(() => {
    rmSync(directory, {force: true, recursive: true});
  });

  return directory;
};

const project = (input: FixtureProject): ScratchProject => {
  const scratch = createScratchProject(input);

  cleanups.push(scratch.cleanup);

  return scratch;
};

const proposalFile = (text: string = FIXED): string => {
  const file = path.join(scratchDirectory(), 'proposal.md');

  writeFileSync(file, text);

  return file;
};

const readText = (root: string, relative: string): string =>
  readFileSync(path.join(root, relative), 'utf8');

type Applied = ApplyResult & {reason?: string};

const apply = (
  scratch: ScratchProject,
  options: {
    base?: string;
    catalog?: readonly RuleDefinition[];
    proposal?: string;
    symlinkCheck?: () => string | undefined;
    target?: string;
  } = {}
): Applied =>
  applyProposal({
    baseSha256: options.base ?? sha256(MARKED),
    catalog: options.catalog ?? [markerRule()],
    env: scratch.env,
    proposalPath: options.proposal ?? proposalFile(),
    root: scratch.root,
    symlinkCheck: options.symlinkCheck,
    target: options.target ?? 'CLAUDE.md',
  });

/**
 * A classifier that calls every path `adopter` the first time (the check) and
 * answers differently the second time (apply's own re-classification).
 */
const driftingClassifier = (second: 'exit-failure' | 'third-party'): string => {
  const directory = scratchDirectory();
  const stub = path.join(directory, 'classifier.sh');
  const afterFirst = second === 'exit-failure' ? 'exit 3' : 'klass=third-party';

  writeFileSync(
    stub,
    [
      '#!/usr/bin/env bash',
      `counter="${directory}/count"`,
      'count=$(cat "$counter" 2>/dev/null || echo 0)',
      'count=$((count + 1))',
      'echo "$count" > "$counter"',
      'klass=adopter',
      `if [ "$count" -gt 1 ]; then ${afterFirst}; fi`,
      'shift 3',
      String.raw`for candidate in "$@"; do printf "%s\t%s\n" "$klass" "$candidate"; done`,
      '',
    ].join('\n')
  );

  return stub;
};

/**
 * The repo classifier fails closed on a path that runs through a symlinked
 * directory, which would refuse before the symlink check is reached; this one
 * answers `adopter` so the symlink check is the guard under test.
 */
const alwaysAdopterClassifier = (): string => {
  const stub = path.join(scratchDirectory(), 'classifier.sh');

  writeFileSync(
    stub,
    [
      '#!/usr/bin/env bash',
      'shift 3',
      String.raw`for candidate in "$@"; do printf "adopter\t%s\n" "$candidate"; done`,
      '',
    ].join('\n')
  );

  return stub;
};

const gitProject = (files: Record<string, string>): FixtureProject => ({
  classifier: 'repo',
  files,
  git: true,
});

describe('gaia fitness apply usage', () => {
  test.each([
    ['no flags', []],
    ['no --target', ['--proposal', 'p', '--base-sha256', 'absent']],
    ['no --proposal', ['--target', 'CLAUDE.md', '--base-sha256', 'absent']],
    ['no --base-sha256', ['--target', 'CLAUDE.md', '--proposal', 'p']],
    ['an unknown flag', ['--bogus', 'x']],
    [
      'an absolute target',
      ['--target', '/etc/passwd', '--proposal', 'p', '--base-sha256', 'absent'],
    ],
    [
      'a target that climbs out of the root',
      ['--target', '../x.md', '--proposal', 'p', '--base-sha256', 'absent'],
    ],
    [
      'a malformed digest',
      ['--target', 'CLAUDE.md', '--proposal', 'p', '--base-sha256', 'ABC'],
    ],
  ])('exits 2 for %s', async (_name, argv) => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));
    const run = await runFitness(['apply', '--root', scratch.root, ...argv], {
      env: scratch.env,
    });

    expect(run.exitCode).toBe(2);
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });
});

describe('gaia fitness apply refusals', () => {
  test('refuses a target that is in no fixable finding, through the router', async () => {
    const scratch = project(gitProject({'notes.md': MARKED}));
    const run = await runFitness(
      [
        'apply',
        '--root',
        scratch.root,
        '--target',
        'notes.md',
        '--proposal',
        proposalFile(),
        '--base-sha256',
        sha256(MARKED),
      ],
      {env: scratch.env}
    );

    expect(run.exitCode).toBe(1);
    expect(run.stderr).toContain('refuse: target is not in the fixable set');
    expect(readText(scratch.root, 'notes.md')).toBe(MARKED);
  });

  test('refuses a target whose finding is already clean', () => {
    const scratch = project(gitProject({'CLAUDE.md': '# Notes\n'}));
    const result = apply(scratch, {base: sha256('# Notes\n')});

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'target is not in the fixable set',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe('# Notes\n');
  });

  test('refuses a GAIA-shipped target', () => {
    const scratch = project({
      ...gitProject({'CLAUDE.md': MARKED}),
      manifest: {files: {'CLAUDE.md': 'owned'}},
    });
    const result = apply(scratch);

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'target is not in the fixable set',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });

  test('refuses a target under a vendor pin', () => {
    const scratch = project({
      ...gitProject({'vendored/CLAUDE.md': MARKED}),
      vendorPins: {example: 'vendored'},
    });
    const result = apply(scratch, {target: 'vendored/CLAUDE.md'});

    expect(result.kind).toBe('refused');
    expect(readText(scratch.root, 'vendored/CLAUDE.md')).toBe(MARKED);
  });

  test('refuses when ownership has drifted away from adopter since the check', () => {
    const scratch = project({
      ...gitProject({'CLAUDE.md': MARKED}),
      classifier: driftingClassifier('third-party'),
    });
    const result = apply(scratch);

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'target ownership is third-party, not adopter',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });

  test('refuses when the classifier fails on the re-classification', () => {
    const scratch = project({
      ...gitProject({'CLAUDE.md': MARKED}),
      classifier: driftingClassifier('exit-failure'),
    });
    const result = apply(scratch);

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'target ownership is unknown, not adopter',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });

  test('refuses a stale base digest', () => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));
    const result = apply(scratch, {base: sha256('something else\n')});

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'file changed since the diff was shown',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });

  test('refuses an absent base digest for a file that exists', () => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));
    const result = apply(scratch, {base: 'absent'});

    expect(result).toMatchObject({
      kind: 'refused',
      reason: 'file changed since the diff was shown',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });
});

/** A tracked directory the check reads, swapped for a symlink to an outside folder before the write. */
const directorySwappedForEscape = (): {
  outside: string;
  result: (symlinkCheck?: () => string | undefined) => Applied;
  scratch: ScratchProject;
} => {
  const scratch = project({
    ...gitProject({'docs/CLAUDE.md': MARKED}),
    classifier: alwaysAdopterClassifier(),
  });
  const outside = scratchDirectory();

  writeFileSync(path.join(outside, 'CLAUDE.md'), MARKED);

  const swap = (): void => {
    rmSync(path.join(scratch.root, 'docs'), {force: true, recursive: true});
    symlinkSync(outside, path.join(scratch.root, 'docs'));
  };

  return {
    outside,
    result: (symlinkCheck) =>
      apply(scratch, {
        catalog: [markerRule(swap)],
        symlinkCheck,
        target: 'docs/CLAUDE.md',
      }),
    scratch,
  };
};

/** A tracked CLAUDE.md that is a symlink into a vendored tree. */
const fileLinkedIntoVendorTree = (): {
  result: (symlinkCheck?: () => string | undefined) => Applied;
  scratch: ScratchProject;
} => {
  const scratch = project({
    ...gitProject({'CLAUDE.md': MARKED, 'vendored/CLAUDE.md': MARKED}),
    vendorPins: {example: 'vendored'},
  });

  rmSync(path.join(scratch.root, 'CLAUDE.md'));
  symlinkSync(
    path.join('vendored', 'CLAUDE.md'),
    path.join(scratch.root, 'CLAUDE.md')
  );

  return {
    result: (symlinkCheck) => apply(scratch, {symlinkCheck}),
    scratch,
  };
};

const passingSymlinkCheck = (): undefined => undefined;

describe('gaia fitness apply symlink refusals', () => {
  test('refuses a target reached through a symlinked directory that leaves the root', () => {
    const {outside, result} = directorySwappedForEscape();

    expect(result()).toMatchObject({
      kind: 'refused',
      reason: 'target passes through a symlink that leaves the project root',
    });
    expect(readFileSync(path.join(outside, 'CLAUDE.md'), 'utf8')).toBe(MARKED);
  });

  test('refuses a target whose symlink points into a vendored tree', () => {
    const {result, scratch} = fileLinkedIntoVendorTree();

    expect(result()).toMatchObject({
      kind: 'refused',
      reason: 'target resolves into a vendored tree',
    });
    expect(readText(scratch.root, 'vendored/CLAUDE.md')).toBe(MARKED);
  });

  test('both symlink refusals depend on the symlink check', () => {
    const escaping = directorySwappedForEscape().result(passingSymlinkCheck);
    const vendored = fileLinkedIntoVendorTree().result(passingSymlinkCheck);

    expect(escaping.kind).not.toBe('refused');
    expect(vendored.kind).not.toBe('refused');
  });
});

describe('gaia fitness apply could-not-run', () => {
  test('exits 3 when the proposal cannot be read', () => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));
    const result = apply(scratch, {
      proposal: path.join(scratchDirectory(), 'missing.md'),
    });

    expect(result.kind).toBe('could-not-run');
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(MARKED);
  });

  test('exits 3 through the router when the root is not a directory', async () => {
    const run = await runFitness([
      'apply',
      '--root',
      path.join(scratchDirectory(), 'no-such-root'),
      '--target',
      'CLAUDE.md',
      '--proposal',
      proposalFile(),
      '--base-sha256',
      'absent',
    ]);

    expect(run.exitCode).toBe(3);
  });
});

describe('gaia fitness apply writes', () => {
  test('writes a fixable adopter target and a re-run no longer reports it', () => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));
    const catalog = [markerRule()];
    const before = runCheck({
      catalog,
      env: scratch.env,
      root: scratch.root,
      scope: 'adopter',
    });

    expect(
      before.inventory.find((file) => file.path === 'CLAUDE.md')?.ownership
    ).toBe('adopter');
    expect(before.findings.map((finding) => finding.fixable)).toEqual([true]);

    expect(apply(scratch, {catalog})).toEqual({
      kind: 'applied',
      target: 'CLAUDE.md',
    });
    expect(readText(scratch.root, 'CLAUDE.md')).toBe(FIXED);

    const after = runCheck({
      catalog,
      env: scratch.env,
      root: scratch.root,
      scope: 'adopter',
    });

    expect(after.findings).toEqual([]);
  });

  test('keeps the file mode of the target it replaces', () => {
    const scratch = project(gitProject({'CLAUDE.md': MARKED}));

    chmodSync(path.join(scratch.root, 'CLAUDE.md'), 0o755);
    expect(apply(scratch).kind).toBe('applied');
    expect(statSync(path.join(scratch.root, 'CLAUDE.md')).mode % 0o1000).toBe(
      0o755
    );
  });
});
