import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {memoryKey} from './inventory.js';
import type {InventoryReport} from './inventory.js';
import {INVENTORY_ONLY_RULES} from './rules/index.js';
import {runFitness} from './test-support.js';

type Sandbox = {
  home: string;
  project: string;
  scratch: string;
};

let sandbox: Sandbox;

const write = (absolute: string, text: string): void => {
  mkdirSync(path.dirname(absolute), {recursive: true});
  writeFileSync(absolute, text);
};

const memoryDirectoryFor = (home: string, root: string): string =>
  path.join(home, '.claude', 'projects', memoryKey(root), 'memory');

const populate = (home: string, project: string): void => {
  const memory = memoryDirectoryFor(home, project);

  write(path.join(memory, 'MEMORY.md'), 'one two three\n');
  write(path.join(memory, 'fact.md'), 'a fact\n');
  write(path.join(memory, 'notes.txt'), 'not markdown\n');
  write(
    path.join(home, '.claude/agent-memory/helper/note.md'),
    'helper note\n'
  );
  write(
    path.join(project, '.claude/agent-memory/reviewer/note.md'),
    'reviewer note\n'
  );
  write(path.join(project, '.claude/rules/quality-gate.md'), 'gate\n');
  write(path.join(project, '.claude/rules/house.md'), 'mine\n');
  write(path.join(project, 'wiki/index.md'), 'index\n');
  write(path.join(project, 'wiki/concepts/Page.md'), 'page\n');
  write(path.join(project, 'CLAUDE.md'), 'root\n');
  write(path.join(project, 'apps/web/CLAUDE.md'), 'nested\n');
};

const inventoryOf = async (
  root: string,
  home: string
): Promise<InventoryReport> => {
  const result = await runFitness(['inventory', '--json', '--root', root], {
    env: {HOME: home},
  });

  expect(result.exitCode).toBe(0);

  return result.json as InventoryReport;
};

const counts = (report: InventoryReport): Record<string, number> =>
  Object.fromEntries(
    Object.entries(report.stores).map(([name, store]) => [name, store.count])
  );

beforeEach(() => {
  const scratch = mkdtempSync(path.join(tmpdir(), 'gaia-inventory-'));
  const project = path.join(scratch, 'project');
  const home = path.join(scratch, 'home');

  mkdirSync(project, {recursive: true});
  mkdirSync(home, {recursive: true});
  sandbox = {home, project, scratch};
});

afterEach(() => {
  rmSync(sandbox.scratch, {force: true, recursive: true});
});

describe('gaia fitness inventory', () => {
  test('one count per store, markdown files only', async () => {
    populate(sandbox.home, sandbox.project);

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(counts(report)).toEqual({
      claude_md: 2,
      memory: 2,
      project_agent_memory: 1,
      rules: 2,
      user_agent_memory: 1,
      wiki: 2,
    });
    expect(Object.keys(report.stores)).toEqual([
      'memory',
      'user_agent_memory',
      'project_agent_memory',
      'rules',
      'wiki',
      'claude_md',
    ]);
  });

  test('a new memory entry changes the memory count', async () => {
    populate(sandbox.home, sandbox.project);

    const before = await inventoryOf(sandbox.project, sandbox.home);

    write(
      path.join(memoryDirectoryFor(sandbox.home, sandbox.project), 'new.md'),
      'fresh\n'
    );

    const after = await inventoryOf(sandbox.project, sandbox.home);

    expect(after.stores.memory.count).toBe(before.stores.memory.count + 1);
  });

  test('an absent store counts zero rather than failing', async () => {
    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(Object.values(counts(report))).toEqual([0, 0, 0, 0, 0, 0]);
    expect(report.findings).toEqual([]);
  });

  test.each<[string, (home: string, root: string) => string, number]>([
    [
      'a root with a dot and a plus reads the memory directory keyed with every non-alphanumeric as a dash',
      (home, root) => memoryDirectoryFor(home, root),
      1,
    ],
    [
      'a memory directory keyed by slashes only is not read for a dotted root',
      (home, root) =>
        path.join(
          home,
          '.claude',
          'projects',
          root.replaceAll('/', '-'),
          'memory'
        ),
      0,
    ],
  ])('%s', async (_name, directoryFor, expectedCount) => {
    const oddRoot = path.join(sandbox.scratch, 'odd.root+x');

    mkdirSync(oddRoot, {recursive: true});
    write(
      path.join(directoryFor(sandbox.home, oddRoot), 'MEMORY.md'),
      'kept\n'
    );

    const report = await inventoryOf(oddRoot, sandbox.home);

    expect(report.stores.memory.count).toBe(expectedCount);
  });

  test('count equals the listed files for every store, with words, lines and an epoch mtime', async () => {
    populate(sandbox.home, sandbox.project);

    const report = await inventoryOf(sandbox.project, sandbox.home);

    for (const store of Object.values(report.stores)) {
      expect(store.files).toHaveLength(store.count);
    }

    const memoryEntry = report.stores.memory.files.find(
      (file) => file.path === '<memory>/MEMORY.md'
    );

    expect(memoryEntry).toMatchObject({lines: 1, words: 3});
    expect(Number.isInteger(memoryEntry?.mtime)).toBe(true);
    expect(memoryEntry?.mtime).toBeGreaterThan(1_000_000_000);
  });

  test('files are sorted by path and carry symbolic roots, never an absolute path', async () => {
    populate(sandbox.home, sandbox.project);
    write(path.join(sandbox.project, 'deep/er/er/CLAUDE.md'), 'depth four\n');

    const report = await inventoryOf(sandbox.project, sandbox.home);
    const listed = Object.values(report.stores).flatMap((store) =>
      store.files.map((file) => file.path)
    );

    expect(report.stores.memory.files.map((file) => file.path)).toEqual([
      '<memory>/MEMORY.md',
      '<memory>/fact.md',
    ]);
    expect(report.stores.user_agent_memory.files[0]?.path).toBe(
      '<agent-memory>/helper/note.md'
    );
    expect(report.stores.claude_md.files.map((file) => file.path)).toEqual([
      'CLAUDE.md',
      'apps/web/CLAUDE.md',
    ]);
    expect(listed).not.toContain('deep/er/er/CLAUDE.md');

    const text = JSON.stringify(report);

    expect(text).not.toContain(sandbox.scratch);
    expect(text).not.toContain(realpathSync(sandbox.scratch));
  });

  test('a CLAUDE.md under node_modules or a linked worktree is not listed', async () => {
    write(path.join(sandbox.project, 'CLAUDE.md'), 'root\n');
    write(path.join(sandbox.project, 'node_modules/CLAUDE.md'), 'vendored\n');
    write(
      path.join(sandbox.project, '.claude/worktrees/CLAUDE.md'),
      'worktree\n'
    );

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(report.stores.claude_md.files.map((file) => file.path)).toEqual([
      'CLAUDE.md',
    ]);
  });

  test('a symbolic link out of a store is not followed', async () => {
    const outside = path.join(sandbox.scratch, 'outside');

    write(path.join(outside, 'secret.md'), 'elsewhere\n');
    mkdirSync(path.join(sandbox.project, '.claude/rules'), {recursive: true});
    symlinkSync(outside, path.join(sandbox.project, '.claude/rules/linked'));
    symlinkSync(
      path.join(outside, 'secret.md'),
      path.join(sandbox.project, '.claude/rules/secret.md')
    );
    write(path.join(sandbox.project, '.claude/rules/real.md'), 'real\n');

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(report.stores.rules.files.map((file) => file.path)).toEqual([
      '.claude/rules/real.md',
    ]);
  });

  test.each<[string, (scratch: string) => string[], number]>([
    [
      'a root that is not a directory exits 3',
      (scratch) => ['inventory', '--root', path.join(scratch, 'missing')],
      3,
    ],
    ['an unknown flag exits 2', () => ['inventory', '--bogus'], 2],
  ])('%s', async (_name, argumentsFor, exitCode) => {
    const result = await runFitness(argumentsFor(sandbox.scratch), {
      env: {HOME: sandbox.home},
    });

    expect(result.exitCode).toBe(exitCode);
    expect(result.stdout).toBe('');
  });
});

describe('memory.dead-path', () => {
  const descriptor = INVENTORY_ONLY_RULES.find(
    (rule) => rule.ruleId === 'memory.dead-path'
  );

  test('a memory file naming a missing repo path yields one finding carrying the descriptor id and severity', async () => {
    write(
      path.join(memoryDirectoryFor(sandbox.home, sandbox.project), 'MEMORY.md'),
      'Intro\nSee `scripts/gone.sh` for the helper.\n'
    );

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(report.findings).toHaveLength(1);
    expect(report.findings[0]).toMatchObject({
      category: 'memory',
      file: '<memory>/MEMORY.md',
      line: 2,
      rule_id: descriptor?.ruleId,
      severity: descriptor?.severity,
    });
    expect(report.findings[0]?.message).toContain('scripts/gone.sh');
  });

  test.each<[string, () => void]>([
    [
      'an existing path yields no finding',
      () => {
        write(path.join(sandbox.project, 'scripts/here.sh'), '#!/bin/sh\n');
        write(
          path.join(
            memoryDirectoryFor(sandbox.home, sandbox.project),
            'MEMORY.md'
          ),
          'See `scripts/here.sh` and [the script](scripts/here.sh#top).\n'
        );
      },
    ],
    [
      'urls, placeholders, absolute paths and fenced code are not repo paths',
      () => {
        write(
          path.join(
            memoryDirectoryFor(sandbox.home, sandbox.project),
            'MEMORY.md'
          ),
          [
            'A `https://example.com/a/b.html` link, `scripts/<name>.sh`, `src/*.ts`,',
            'and `/etc/hosts.conf` plus `~/notes/a.md`.',
            '```',
            '`scripts/in-fence.sh`',
            '```',
            '',
          ].join('\n')
        );
      },
    ],
    [
      'only the memory store is scanned for dead paths',
      () => {
        write(
          path.join(sandbox.project, '.claude/rules/house.md'),
          'See `scripts/gone.sh`.\n'
        );
      },
    ],
  ])('%s', async (_name, arrange) => {
    arrange();

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(report.findings).toEqual([]);
  });

  test('a link target and a line-suffixed path are checked', async () => {
    write(
      path.join(memoryDirectoryFor(sandbox.home, sandbox.project), 'MEMORY.md'),
      'See [doc](docs/gone.md) and `app/gone.ts:12`.\n'
    );

    const report = await inventoryOf(sandbox.project, sandbox.home);

    expect(report.findings.map((finding) => finding.message)).toEqual([
      expect.stringContaining('app/gone.ts'),
      expect.stringContaining('docs/gone.md'),
    ]);
  });

  test('a credential in a message is redacted', async () => {
    const token = `ghp_${'a1B2c3D4e5'.repeat(4)}`;

    write(
      path.join(memoryDirectoryFor(sandbox.home, sandbox.project), 'MEMORY.md'),
      `See \`scripts/${token}.sh\`.\n`
    );

    const result = await runFitness(['inventory', '--root', sandbox.project], {
      env: {HOME: sandbox.home},
    });

    expect(result.stdout).not.toContain(token);
    expect(result.stdout).toContain('[redacted]');
  });
});
