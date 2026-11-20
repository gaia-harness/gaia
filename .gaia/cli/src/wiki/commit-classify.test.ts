import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {COMMIT_TYPES} from '../util/conventional-commit.js';
import {execGaiaGit} from '../util/git-env.js';
import {
  autoMaintenanceSpawns,
  detachedSpawns,
  MAINTENANCE_GATE_DEFAULTS,
  MAINTENANCE_GATES,
} from '../util/git-maintenance.js';
import {
  NON_ASCII_STEM,
  QUOTEPATH_PIN_ARGS,
} from '../util/non-ascii-path-fixture.js';
import {committedFrontendDescriptor} from '../util/package-fixture.js';
import {run} from './commit-classify.js';
import type {CommitClassification} from './commit-classify.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  initialSha: string;
  root: string;
};

/**
 * What the sandbox actually looked like when a git command failed in it.
 *
 * `git commit` reports a broken object store as a bare
 * `fatal: could not parse HEAD` and nothing else, so a failure that only
 * appears under CI load leaves no evidence unless the fixture reads the
 * repository back itself. Every probe is best-effort: this runs on a repo
 * already known to be unhappy, so a probe that also fails records its own
 * error rather than replacing the original one.
 */
const describeSandbox = (root: string): string => {
  const probe = (args: string[]): string => {
    try {
      return execGaiaGit(args, root).replaceAll('\n', ' ');
    } catch (error) {
      // Keep the whole message, collapsed to this row's single line. Node puts
      // the failed command on the first line and git's own explanation on the
      // lines after it, so taking only the first line reports that `fsck`
      // failed while discarding the one thing that says why.
      return `<${(error instanceof Error ? error.message : String(error)).replaceAll('\n', ' ').trim()}>`;
    }
  };

  return [
    `  HEAD ref: ${probe(['rev-parse', '--symbolic-full-name', 'HEAD'])}`,
    `  HEAD sha: ${probe(['rev-parse', 'HEAD'])}`,
    `  objects:  ${probe(['count-objects', '-v'])}`,
    `  fsck:     ${probe(['fsck', '--no-progress', '--connectivity-only'])}`,
  ].join('\n');
};

/**
 * Run one git command against the sandbox.
 *
 * Routes through `execGaiaGit` rather than a bare `execFileSync('git', ...)`,
 * for the reason its docblock gives: an ambient `GIT_DIR`, `GIT_WORK_TREE`, or
 * `GIT_COMMON_DIR` overrides repository discovery for every git subprocess no
 * matter what `cwd` says, and a sandbox that inherits one silently commits
 * into whatever repository the variable names instead of into itself.
 */
const sandboxGit = (root: string, args: string[]): string => {
  try {
    return execGaiaGit(args, root);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(
      `sandbox git ${args.join(' ')} failed in ${root}\n${detail}\n${describeSandbox(root)}`
    );
  }
};

/**
 * Every git config a repository this fixture creates needs, identity included.
 *
 * The maintenance entries are the load-bearing ones. Every `git commit`
 * otherwise spawns a detached `git maintenance run --auto --quiet --detach`,
 * so a 25-commit scenario leaves background git processes running against a
 * sandbox that `afterEach` deletes out from under them, and one that repacks
 * while the next `git commit` is running leaves the repository holding several
 * packfiles and a HEAD whose commit object that commit can no longer parse.
 *
 * One key alone will not do it, because the spelling that gates this moved
 * when `git maintenance` replaced `git gc --auto`, and the git the fixture
 * runs under is whatever the machine or the CI runner supplies:
 *
 * - `maintenance.auto=false` is the documented gate on the spawn, and it covers
 *   the whole task set, including the `loose-objects` and `incremental-repack`
 *   tasks, which are the ones that pack.
 * - `gc.auto=0` is the gate for git predating that task set, which reaches the
 *   repository through `git gc --auto` instead. On git 2.55 it also suppresses
 *   the modern spawn on its own, so what failed in CI is not established to be
 *   this key being the weaker one; what is established is that a single key was
 *   not enough on the git that ran there.
 * - `gc.autoDetach=false` and `maintenance.autoDetach=false` are the fallback
 *   for both: a run that starts anyway finishes before the command that
 *   triggered it returns, so it can neither outlive the test nor race the next
 *   `git commit`. Both spellings are here for the control repository below
 *   rather than for the sandbox, which needs neither once the gates hold.
 *   Neither is a gate, so the control inherits both, and the control is the one
 *   repository that deliberately leaves maintenance switched on. Modern git
 *   resolves `maintenance.autoDetach` ahead of `gc.autoDetach`, so dropping it
 *   as redundant would let a global `maintenance.autoDetach = true` detach the
 *   control's run and leave it working in a directory `rmSync` is about to
 *   delete, which is the orphan this whole list exists to prevent.
 *
 * Measured on git 2.55, over the whole list rather than per entry: one spawned
 * maintenance run per commit with none of these set, zero with them. The test
 * at the bottom of this file is what keeps that true, and it clears
 * `GIT_CONFIG_COUNT` so that what it measures is this list.
 *
 * A second mechanism covers the same hazard for the whole run,
 * `util/git-maintenance-env.ts`, which puts the four maintenance keys in the
 * environment so every other file building a sandbox gets them without opting
 * in. This list is not redundant under it: it is what this fixture's own
 * hermeticity rests on, and it is the thing the test at the bottom measures.
 */
const SANDBOX_GIT_CONFIG: [string, string][] = [
  ['user.email', 'test@example.com'],
  ['user.name', 'Test'],
  ['commit.gpgsign', 'false'],
  ['gc.auto', '0'],
  ['maintenance.auto', 'false'],
  ['gc.autoDetach', 'false'],
  ['maintenance.autoDetach', 'false'],
];

/** Initialize one repository this fixture owns, suppression included. */
const initSandboxRepo = (root: string, omit?: ReadonlySet<string>): void => {
  sandboxGit(root, ['init', '-q', '-b', 'main']);

  for (const [key, value] of SANDBOX_GIT_CONFIG) {
    if (!omit?.has(key)) {
      sandboxGit(root, ['config', key, value]);
    }
  }
};

/**
 * `transitionalLayout` pins the app at the repo root with a literal registry
 * and descriptor in the baseline commit; without it the sandbox has no
 * registry and commits the committed descriptor under `apps/web/`, so the
 * built-in default (the app under `apps/web/`) applies.
 */
const setupSandbox = (transitionalLayout = true): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-'));
  initSandboxRepo(root);

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    sandboxGit(root, ['add', '-A']);
    sandboxGit(root, ['commit', '-q', '-m', message]);

    return sandboxGit(root, ['rev-parse', 'HEAD']);
  };

  // Initial baseline commit.
  const baseline: Record<string, string> = {'README.md': '# repo\n'};

  if (transitionalLayout) {
    baseline['.gaia/packages.json'] = JSON.stringify([
      {name: 'web', path: '.'},
    ]);
    baseline['gaia.package.json'] = JSON.stringify(
      committedFrontendDescriptor()
    );
  } else {
    baseline['apps/web/gaia.package.json'] = JSON.stringify(
      committedFrontendDescriptor()
    );
  }
  const initialSha = commit('initial commit', baseline);

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    initialSha,
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

const classify = (sandbox: Sandbox): CommitClassification => {
  let out = '';
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out += typeof chunk === 'string' ? chunk : String(chunk);

      return true;
    });
  const exit = run(['--since', sandbox.initialSha, '--json'], {
    cwd: sandbox.root,
  });
  stdoutSpy.mockRestore();
  expect(exit).toBe(0);

  return JSON.parse(out.trim()) as CommitClassification;
};

const withConfig = (wikiClassify: unknown): string =>
  `${JSON.stringify({gaia: {wikiClassify}, name: 'sandbox'}, null, 2)}\n`;

const commitManyTo = (
  sandbox: Sandbox,
  count: number,
  subject: string,
  file: string
): void => {
  for (let index = 0; index < count; index += 1) {
    sandbox.commit(`${subject} ${index}`, {[file]: `body ${index}\n`});
  }
};

describe('wiki commit-classify', () => {
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

  test.each(
    Array.of<{
      files: Record<string, string>;
      name: string;
      reasonParts: string[];
      subject: string;
      suggestion: 'SKIP' | 'WORTHY';
    }>(
      {
        files: {'package.json': '{"version": "1.0.1"}\n'},
        name: 'chore(deps): bumps without architecture body → SKIP',
        reasonParts: ['chore(deps)'],
        subject: 'chore(deps): bump foo from 1.0.0 to 1.0.1',
        suggestion: 'SKIP',
      },
      {
        files: {'package.json': '{"version": "2.0.0"}\n'},
        name: 'chore(deps): with BREAKING CHANGE body → WORTHY',
        reasonParts: [],
        subject:
          'chore(deps): swap axios for ofetch\n\nBREAKING CHANGE: server-side fetch surface changed',
        suggestion: 'WORTHY',
      },
      {
        files: {'app/foo.ts': 'export const x = 1;\n'},
        name: 'feat: touching app/** non-test → WORTHY',
        reasonParts: ['source-bearing'],
        subject: 'feat: add new module',
        suggestion: 'WORTHY',
      },
      {
        files: {
          'app/components/button/index.tsx':
            'export const Button = () => null;\n',
        },
        name: 'feat: only inventory paths without decision keywords → SKIP',
        reasonParts: ['inventory'],
        subject: 'feat: add Button variant',
        suggestion: 'SKIP',
      },
      {
        files: {'app/foo.test.ts': 'test ...\n'},
        name: 'test: prefix → SKIP',
        reasonParts: [],
        subject: 'test: add coverage',
        suggestion: 'SKIP',
      },
      {
        files: {'docs/decisions/zod.md': '# zod\n'},
        name: 'docs(decision): → WORTHY',
        reasonParts: ['ADR'],
        subject: 'docs(decision): adopt zod',
        suggestion: 'WORTHY',
      },
      {
        files: {'README.md': '# repo updated\n'},
        name: 'Merge pull request → SKIP',
        reasonParts: [],
        subject: 'Merge pull request #42 from feature/foo',
        suggestion: 'SKIP',
      },
      {
        files: {'CHANGELOG.md': '# 1.0.0\n'},
        name: 'chore(release): → SKIP',
        reasonParts: [],
        subject: 'chore(release): 1.0.0',
        suggestion: 'SKIP',
      },
      {
        files: {'app/middleware/foo.ts': 'export const foo = () => null;\n'},
        name: 'touching app/middleware → WORTHY (flows-relevant)',
        reasonParts: ['flows'],
        subject: 'feat: middleware tweak',
        suggestion: 'WORTHY',
      },
      {
        files: {'wiki/concepts/Foo.md': '# Foo\n'},
        name: 'touching wiki/concepts/ → WORTHY',
        reasonParts: ['wiki-heavy'],
        subject: 'chore: rewrite concept',
        suggestion: 'WORTHY',
      },
      {
        files: {'app/api.ts': 'export const api = null;\n'},
        name: 'feat(scope)!: → WORTHY (breaking)',
        reasonParts: ['breaking'],
        subject: 'feat(api)!: drop the legacy endpoint',
        suggestion: 'WORTHY',
      },
      // Once every rule matches breaking-agnostically, the `!` no longer breaks a
      // prefix match by accident, so a breaking subject on a SKIP-rule type would
      // be silently skipped unless rule 2 claims it first.
      ...[
        'chore(cli)!: drop the legacy flag',
        'refactor(components)!: rename the exported prop',
        'fix(hooks)!: change the return shape',
      ].map((subject) => ({
        files: {'app/components/Thing/index.tsx': 'export {};\n'},
        name: `${subject} → WORTHY (breaking beats every SKIP rule)`,
        reasonParts: ['breaking'],
        subject,
        suggestion: 'WORTHY' as const,
      })),
      // Rule 1 is deliberately "SKIP regardless", ahead of the breaking signal:
      // both its categories are mechanical, so a `!` on them is either
      // meaningless (formatting cannot break a contract) or still just plumbing.
      ...['style!: reformat everything', 'chore(release)!: 2.0.0'].map(
        (subject) => ({
          files: {'app/foo.ts': 'export const x = 1;\n'},
          name: `${subject} → SKIP (rule 1 outranks the breaking marker)`,
          reasonParts: [],
          subject,
          suggestion: 'SKIP' as const,
        })
      ),
      // Deliberately outside wiki/{decisions,concepts,...}, so rule 3 cannot
      // rescue it and the ADR rule is the only thing standing between this
      // commit and rule 8's `docs: prose-only` SKIP.
      ...['docs(decision): adopt zod', 'docs(decisions): adopt zod'].map(
        (subject) => ({
          files: {'.claude/rules/zod.md': '# zod\n'},
          name: `${subject} → WORTHY (ADR signal outside a wiki-heavy path)`,
          reasonParts: ['ADR'],
          subject,
          suggestion: 'WORTHY' as const,
        })
      ),
      {
        files: {'app/foo.ts': 'export const x = 1;\n'},
        name: 'debt: touching app/** non-test → WORTHY',
        reasonParts: ['source-bearing'],
        subject: 'debt(cli): remove the dead telemetry write',
        suggestion: 'WORTHY',
      },
      {
        files: {'app/foo.test.ts': 'test ...\n'},
        name: 'debt: tests-only → SKIP',
        reasonParts: ['tests-only'],
        subject: 'debt(shell-lint): drop the redundant case',
        suggestion: 'SKIP',
      },
      {
        files: {'.github/workflows/release.yml': 'on: push\n'},
        name: 'ci: without an architecture body → SKIP',
        reasonParts: ['ci'],
        subject: 'ci(release): add the distribution gate',
        suggestion: 'SKIP',
      },
      {
        files: {'.github/workflows/tests.yml': 'on: push\n'},
        name: 'ci: with an architecture body → WORTHY',
        reasonParts: [],
        subject:
          'ci(gaia): run the bats gate under bash 5\n\nRecords the decision to pin the CI shell.',
        suggestion: 'WORTHY',
      },
      {
        files: {'dist/gaia': 'binary\n'},
        name: 'build: without an architecture body → SKIP',
        reasonParts: ['build'],
        subject: 'build(cli): rebundle the gaia binary',
        suggestion: 'SKIP',
      },
      {
        files: {'app/gate.ts': 'export const gate = null;\n'},
        name: 'a non-conforming subject still defers to human review',
        reasonParts: ['no matching prefix'],
        subject: 'Harden the Code Audit Team merge gate (#793)',
        suggestion: 'WORTHY',
      }
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {files, reasonParts, subject, suggestion}) => {
    sandbox.commit(subject, files);

    const json = classify(sandbox);
    expect(json.commits).toHaveLength(1);
    expect(json.commits[0]?.suggestion).toBe(suggestion);

    for (const part of reasonParts) {
      expect(json.commits[0]?.suggestion_reason).toContain(part);
    }
  });

  describe('paths git rewrites on the way out', () => {
    beforeEach(() => {
      sandboxGit(sandbox.root, [...QUOTEPATH_PIN_ARGS]);
    });

    test('a commit whose only wiki page is non-ASCII still reads as wiki-heavy', () => {
      sandbox.commit('chore: rewrite concept', {
        [`wiki/concepts/${NON_ASCII_STEM}.md`]: '# concept\n',
      });

      const json = classify(sandbox);
      expect(json.commits[0]?.suggestion).toBe('WORTHY');
      expect(json.commits[0]?.suggestion_reason).toContain('wiki-heavy');
    });
  });

  // This repo writes scoped subjects (`fix(hooks):`) essentially exclusively.
  // A rule table that only matches the unscoped form is unreachable in
  // practice: every commit falls through to the fail-open default and the
  // first-pass filter stops filtering. Parity is the property that catches it.
  describe('scoped subjects reach the same decision as unscoped', () => {
    const parityCases = [
      {path: 'app/foo.ts', type: 'feat'},
      {path: 'app/foo.ts', type: 'fix'},
      {path: 'app/foo.ts', type: 'refactor'},
      {path: 'app/foo.ts', type: 'debt'},
      {path: 'app/foo.ts', type: 'style'},
      {path: 'app/foo.test.ts', type: 'test'},
      {path: 'docs/guide.md', type: 'docs'},
      {path: 'tooling/thing.cfg', type: 'chore'},
    ];

    test.each(parityCases)(
      '$type: and $type(scope): agree',
      ({path: filePath, type}) => {
        sandbox.commit(`${type}: unscoped subject`, {[filePath]: 'unscoped\n'});
        sandbox.commit(`${type}(scope): scoped subject`, {
          [filePath]: 'scoped\n',
        });

        const {commits} = classify(sandbox);
        expect(commits).toHaveLength(2);
        expect(commits[1]?.suggestion).toBe(commits[0]?.suggestion);
        expect(commits[1]?.suggestion_reason).toBe(
          commits[0]?.suggestion_reason
        );
      }
    );
  });

  test('exits 1 when --since missing', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--since');
  });

  test('returns empty list when no commits exist after the baseline', () => {
    const json = classify(sandbox);
    expect(json.commits).toEqual([]);
  });

  test('without --json, prints a tabular summary', () => {
    sandbox.commit('feat: real feature', {'app/foo.ts': 'x\n'});
    const exit = run(['--since', sandbox.initialSha], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Classified');
    expect(stdio.outputs.join('')).toContain('WORTHY');
  });

  // Every declared type must reach a DISCRIMINATING rule. A type in steady
  // use with no rule written for it (`debt` was exactly this) is invisible:
  // it lands on a fail-open default, gets promoted to WORTHY, and nothing
  // reports the gap.
  //
  // Asserted via `health.deferred` rather than by substring-matching a reason
  // string, so rewording a reason cannot silently disarm the guard. The
  // fixture sits under a source-bearing path on purpose: with a neutral path
  // the five path-discriminated types pass by landing on rule 7's deferred
  // tail, which is the very outcome this is supposed to reject.
  describe('declared commit-type vocabulary', () => {
    test.each([...COMMIT_TYPES])(
      '%s: reaches a discriminating rule',
      (type) => {
        sandbox.commit(`${type}(scope): a subject`, {
          'app/thing.ts': `export const x = '${type}';\n`,
        });

        const {health} = classify(sandbox);
        expect(health.evaluated).toBe(1);
        expect(health.deferred).toBe(0);
      }
    );

    test('an undeclared type still falls open to rule 9', () => {
      sandbox.commit('spike(scope): try a thing', {
        'app/thing.ts': 'export const x = 1;\n',
      });

      const {commits, health} = classify(sandbox);
      expect(commits[0]?.suggestion).toBe('WORTHY');
      expect(commits[0]?.suggestion_reason).toContain('no matching prefix');
      expect(health.deferred).toBe(1);
    });
  });

  // Rules 6/7 used to hardcode `app/**`. A repo whose source lives elsewhere
  // matched none of the three discriminating branches, so every source commit
  // fell to rule 7's tail with a plausible-looking reason.
  describe('configurable path vocabulary', () => {
    test.each(
      Array.of<{
        files: Record<string, string>;
        name: string;
        packageJson: string;
        reasonPart: string;
        subject: string;
        suggestion: 'SKIP' | 'WORTHY';
      }>(
        {
          files: {'cli/src/parse.ts': 'export const x = 1;\n'},
          name: 'a configured source path is recognized outside app/**',
          packageJson: withConfig({sourcePaths: ['cli/src/']}),
          reasonPart: 'source-bearing',
          subject: 'fix(cli): repair the parser',
          suggestion: 'WORTHY',
        },
        {
          files: {'suite/guard.bats': '@test "guard" { true; }\n'},
          name: 'a configured test path counts as tests-only',
          packageJson: withConfig({testPaths: ['suite/']}),
          reasonPart: 'tests-only',
          subject: 'fix(hooks): tighten the guard case',
          suggestion: 'SKIP',
        },
        {
          files: {'lib/widgets/Thing.ts': 'export const Thing = null;\n'},
          name: 'a configured inventory path skips without decision keywords',
          packageJson: withConfig({inventoryPaths: ['lib/widgets/']}),
          reasonPart: 'inventory',
          subject: 'feat(widgets): add a variant',
          suggestion: 'SKIP',
        },
        // Adopters get today's behavior with no config, and a malformed config
        // must degrade to it rather than fail a sync: this is a cheap pre-filter
        // ahead of an expensive read, not a correctness gate.
        ...[
          ['absent gaia key', '{"name": "sandbox"}\n'],
          ['malformed JSON', '{not json\n'],
          [
            'wrong value type',
            '{"gaia": {"wikiClassify": {"sourcePaths": 7}}}\n',
          ],
        ].map(([label, packageJson]) => ({
          files: {'app/foo.ts': 'export const x = 1;\n'},
          name: `${label} falls back to the app/** defaults`,
          packageJson: packageJson ?? '',
          reasonPart: 'source-bearing',
          subject: 'feat: add a module',
          suggestion: 'WORTHY' as const,
        }))
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {files, packageJson, reasonPart, subject, suggestion}) => {
      sandbox.commit('chore: configure', {'package.json': packageJson});
      sandbox.commit(subject, files);

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion).toBe(suggestion);
      expect(commits[1]?.suggestion_reason).toContain(reasonPart);
    });

    // An empty `sourcePaths` matches no file at all, so every source commit
    // would land on rule 7's fail-open tail: the exact inertness this module
    // exists to prevent, reachable through the config surface and invisible
    // below the health signal's minimum sample. It must be rejected loudly
    // rather than accepted as "match nothing".
    test('an empty sourcePaths is rejected, not honored as match-nothing', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({sourcePaths: []}),
      });
      sandbox.commit('fix(cli): repair the parser', {
        'app/foo.ts': 'export const x = 1;\n',
      });

      const {commits, health} = classify(sandbox);
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
      expect(health.deferred).toBe(0);
      expect(stdio.errors.join('')).toContain('malformed gaia.wikiClassify');
    });

    // The other two lists have legitimate empty forms: `testPaths: []` is the
    // shipped default, and `inventoryPaths: []` turns the inventory skip off.
    test('an empty inventoryPaths is honored, disabling the inventory skip', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({inventoryPaths: []}),
      });
      sandbox.commit('feat: add Button variant', {
        'app/components/button/index.tsx': 'export const Button = null;\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
      expect(stdio.errors.join('')).toBe('');
    });
  });

  // The health signal, not any individual commit, is what reports that the
  // rule table has gone inert. Both fail-open defaults count: rule 9, and
  // rule 7's tail, which emits a specific-sounding reason and would otherwise
  // hide a path vocabulary that matches nothing.
  describe('health signal', () => {
    test.each(
      Array.of<{
        batches: [count: number, subject: string, file: string][];
        health: Partial<CommitClassification['health']>;
        name: string;
      }>(
        {
          batches: [[4, 'Not a conventional subject', 'tooling/thing.cfg']],
          // Below HEALTH_MIN_SAMPLE, so a bad rate alone never fires.
          health: {deferral_rate: 1, deferred: 4, evaluated: 4, inert: false},
          name: 'counts rule-9 fallthrough as deferred, without calling it inert',
        },
        {
          batches: [[4, 'docs: prose', 'notes/thing.md']],
          health: {deferral_rate: 0, deferred: 0},
          name: 'a discriminating rule is not deferral',
        },
        // WORTHY rate is reported alongside deferral so configuring the path
        // vocabulary cannot quietly turn "I could not tell" into "definitely
        // read this" while the deep-read cost stays exactly the same.
        {
          batches: [[4, 'feat: add a module', 'app/foo.ts']],
          health: {deferred: 0, worthy_rate: 1},
          name: 'worthy_rate stays visible when deferral is zero',
        },
        {
          batches: [
            [11, 'fix(cli): repair the thing', 'tooling/thing.cfg'],
            [11, 'docs: prose', 'notes/thing.md'],
          ],
          health: {deferred: 11, evaluated: 22, inert: true},
          name: 'a ~50% deferral rate fires, the rate the path failure produced',
        },
        {
          batches: [],
          health: {
            deferral_rate: 0,
            evaluated: 0,
            inert: false,
            worthy_rate: 0,
          },
          name: 'an empty range reports zeroed rates rather than NaN',
        }
      ).map((row) => [row.name, row] as const)
    )('%s', (_name, {batches, health: expectedHealth}) => {
      for (const [count, subject, file] of batches) {
        commitManyTo(sandbox, count, subject, file);
      }

      const {health} = classify(sandbox);
      expect(health).toMatchObject(expectedHealth);
    });

    test("counts rule 7's tail as deferred despite its specific reason", () => {
      commitManyTo(
        sandbox,
        4,
        'fix(cli): repair the thing',
        'tooling/thing.cfg'
      );

      const {commits, health} = classify(sandbox);
      expect(commits[0]?.suggestion_reason).toContain('defer to human review');
      expect(health.deferred).toBe(4);
    });

    test('a large sample over the threshold reports inert and warns', () => {
      commitManyTo(
        sandbox,
        25,
        'Not a conventional subject',
        'tooling/thing.cfg'
      );

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(25);
      expect(health.inert).toBe(true);
      expect(stdio.errors.join('')).toContain('fail-open default');
    });

    test('a large healthy sample reports neither inert nor a warning', () => {
      commitManyTo(sandbox, 25, 'docs: prose', 'notes/thing.md');

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(25);
      expect(health.inert).toBe(false);
      expect(stdio.errors.join('')).toBe('');
    });
  });

  // Without a propagated failure, git breaking is indistinguishable from the
  // genuinely empty range the test directly above covers: both answer "there
  // is nothing to review" with exit 0, so anything downstream of the sync
  // stage of `/gaia-wiki` that trusts a zero count reads a transient git
  // failure as a clean, up-to-date wiki.
  test('a failing git log reports git_failed, not an empty range', () => {
    // Well-formed but absent from the sandbox, so `git log <sha>..HEAD` exits
    // non-zero rather than resolving. Nothing validates `--since` ahead of the
    // call, which is what lets a bad revision reach `commitDetails` at all.
    const absentSha = 'deadbeef'.repeat(5);

    const exit = run(['--since', absentSha, '--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);

    const payload = JSON.parse(stdio.errors.join('').trim()) as {
      code: string;
      subcommand: string;
    };
    expect(payload.code).toBe('git_failed');
    expect(payload.subcommand).toBe('wiki commit-classify');
    // No classification on stdout: a zeroed payload here is the wrong answer
    // this test exists to keep out.
    expect(stdio.outputs.join('')).toBe('');
  });
});

/**
 * The fixture's own hermeticity. Every scenario above takes it on faith that
 * the repository it commits into is the one `setupSandbox` created; nothing
 * asserted it, and a bare `execFileSync('git', ...)` hands that assumption to
 * whatever `GIT_DIR` the ambient environment happens to be carrying.
 */
describe('commit-classify sandbox fixture', () => {
  test('commits into its own repository under an ambient GIT_DIR', () => {
    const decoy = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-decoy-'));
    initSandboxRepo(decoy);
    execGaiaGit(
      ['commit', '-q', '--allow-empty', '-m', 'decoy baseline'],
      decoy
    );
    const decoyHeadBefore = execGaiaGit(['rev-parse', 'HEAD'], decoy);
    vi.stubEnv('GIT_DIR', path.join(decoy, '.git'));

    let sandbox: Sandbox | undefined;

    try {
      sandbox = setupSandbox();
      const sha = sandbox.commit('docs: prose 0', {'notes/thing.md': 'body\n'});

      expect(execGaiaGit(['rev-parse', 'HEAD'], sandbox.root)).toBe(sha);
      expect(execGaiaGit(['rev-parse', 'HEAD'], decoy)).toBe(decoyHeadBefore);
    } finally {
      vi.unstubAllEnvs();
      sandbox?.cleanup();
      rmSync(decoy, {force: true, recursive: true});
    }
  });

  // A bare "no maintenance was spawned" assertion passes just as well when the
  // trace recorded nothing at all, which is how a guard against a background
  // process goes vacuous without anyone noticing. The control repository, which
  // sets everything the sandbox sets except the two suppression gates, proves in
  // the same run that git still spawns maintenance on commit and that the trace
  // captures it.
  test('the sandbox config suppresses maintenance a bare repo spawns', () => {
    const traceRoot = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-classify-trace-')
    );
    const controlRoot = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-classify-control-')
    );
    let sandbox: Sandbox | undefined;

    try {
      // Opt out of the run-wide suppression (`util/git-maintenance-env.ts`) for
      // the whole test, so what runs here is this file's own config list and
      // nothing else. An environment entry outranks repo-local config the way
      // `git -c` does, so without this the control below would inherit the
      // gates it exists to leave off and report a fixture that spawns nothing,
      // which is the vacuous green this test was written to prevent.
      vi.stubEnv('GIT_CONFIG_COUNT', '0');

      // Everything the sandbox sets except the gates, which are then written
      // back at git's own defaults so the control's ungated state is its own
      // rather than inherited from the machine's global config. `gc.autoDetach`
      // is not a gate and so stays, which keeps the control's own maintenance
      // run a foreground child; without it this test would leak the very
      // orphaned background process it exists to keep out of the suite.
      initSandboxRepo(controlRoot, MAINTENANCE_GATES);

      for (const [key, value] of MAINTENANCE_GATE_DEFAULTS) {
        sandboxGit(controlRoot, ['config', key, value]);
      }

      const controlTrace = path.join(traceRoot, 'control.json');
      vi.stubEnv('GIT_TRACE2_EVENT', controlTrace);
      execGaiaGit(
        ['commit', '-q', '--allow-empty', '-m', 'control baseline'],
        controlRoot
      );

      const controlSpawns = autoMaintenanceSpawns(controlTrace);
      expect(controlSpawns.length).toBeGreaterThan(0);
      // The control's own run must stay in the foreground, or the `finally`
      // below deletes `controlRoot` out from under a live background git. A
      // count alone cannot see that: the parent records the child either way,
      // so this test would pass green while leaking the orphan the whole
      // fixture exists to prevent. Asserted as an absence to stay portable,
      // git predating the task set spawns `git gc --auto`, which carries no
      // detach flag at all and passes, while modern git catches a
      // `maintenance.autoDetach` that a later edit dropped as redundant.
      expect(detachedSpawns(controlSpawns)).toEqual([]);

      const sandboxTrace = path.join(traceRoot, 'sandbox.json');
      vi.stubEnv('GIT_TRACE2_EVENT', sandboxTrace);
      sandbox = setupSandbox();
      commitManyTo(sandbox, 4, 'docs: prose', 'notes/thing.md');

      expect(autoMaintenanceSpawns(sandboxTrace)).toEqual([]);
    } finally {
      vi.unstubAllEnvs();
      sandbox?.cleanup();
      rmSync(controlRoot, {force: true, recursive: true});
      rmSync(traceRoot, {force: true, recursive: true});
    }
  });
});

describe('wiki commit-classify under the built-in frontend package', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox(false);
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test.each(
    Array.of<{
      contents: string;
      file: string;
      name: string;
      reasonPart: string;
      subject: string;
      suggestion: 'SKIP' | 'WORTHY';
    }>(
      {
        contents: 'export const x = 1;\n',
        file: 'apps/web/app/foo.ts',
        name: 'a apps/web/app source commit is source-bearing',
        reasonPart: 'source-bearing',
        subject: 'feat: add a module',
        suggestion: 'WORTHY',
      },
      {
        contents: 'export const X = null;\n',
        file: 'apps/web/app/components/X/index.tsx',
        name: 'apps/web/app/components is inventory and skips',
        reasonPart: 'inventory',
        subject: 'feat: add Button variant',
        suggestion: 'SKIP',
      },
      {
        contents: 'export default [];\n',
        file: 'apps/web/app/routes.ts',
        name: 'apps/web/app/routes.ts is flows-relevant',
        reasonPart: 'flows-relevant',
        subject: 'chore: touch routes',
        suggestion: 'WORTHY',
      }
    ).map((row) => [row.name, row] as const)
  )('%s', (_name, {contents, file, reasonPart, subject, suggestion}) => {
    sandbox.commit(subject, {[file]: contents});

    const {commits} = classify(sandbox);
    expect(commits[0]?.suggestion).toBe(suggestion);
    expect(commits[0]?.suggestion_reason).toContain(reasonPart);
  });

  test('a root app/ path is not inventory and not source-bearing', () => {
    sandbox.commit('feat: add Button variant', {
      'app/components/X/index.tsx': 'export const X = null;\n',
    });

    const {commits} = classify(sandbox);
    expect(commits[0]?.suggestion_reason).not.toContain('inventory');
    expect(commits[0]?.suggestion_reason).not.toContain('source-bearing');
  });

  test('a present gaia.wikiClassify wins whole over the descriptor', () => {
    sandbox.commit('chore: configure', {
      'package.json': withConfig({sourcePaths: ['cli/src/']}),
    });
    sandbox.commit('fix(cli): repair the parser', {
      'cli/src/parse.ts': 'export const x = 1;\n',
    });
    sandbox.commit('fix: repair the app', {
      'apps/web/app/foo.ts': 'export const x = 1;\n',
    });

    const {commits} = classify(sandbox);
    expect(commits[1]?.suggestion_reason).toContain('source-bearing');
    expect(commits[2]?.suggestion_reason).not.toContain('source-bearing');
  });

  // The defaults come from the descriptor, so one that cannot load must stop
  // the command rather than classify against a guessed layout.
  test('a malformed registry refuses with the gaia-packages message', () => {
    sandbox.commit('chore: break the registry', {
      '.gaia/packages.json': '{not json',
    });
    const exit = run(['--since', sandbox.initialSha, '--json'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(stdio.errors.join('')).toContain('gaia-packages:');
    expect(stdio.outputs.join('')).toBe('');
  });
});
