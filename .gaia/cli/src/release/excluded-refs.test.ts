import {describe, expect, test} from 'vitest';
import {
  compileExcludedRefMatcher,
  deriveExcludedRefTokens,
} from './excluded-refs.js';
import type {ExcludedRefInputs} from './excluded-refs.js';

const TRACKED = [
  '.claude/agents/code-audit-maintainer-node.md',
  '.claude/commands/gaia-release.md',
  '.claude/skills/release-notes/SKILL.md',
  '.gaia/cli/gaia-maintainer',
  '.gaia/cli/src/wiki/chain.ts',
  '.gaia/cli/src/wiki/index.ts',
  '.gaia/cli/test-fixtures/usage.jsonl',
  '.gaia/scripts/lint-hook-jq-availability.sh',
  '.gaia/tests/run-all.sh',
  '.github/CODEOWNERS',
  '.github/workflows/release.yml',
  'README.md',
];

const baseInputs = (
  overrides: Partial<ExcludedRefInputs> = {}
): ExcludedRefInputs => ({
  excludeLines: [
    '.claude/agents/code-audit-maintainer-node.md',
    '.claude/commands/gaia-release.md',
    '.claude/skills/release-notes',
    '.gaia/cli/gaia-maintainer',
    '.gaia/cli/src',
    '.gaia/cli/test-fixtures',
    '.gaia/scripts/lint-hook-jq-availability.sh',
    '.gaia/tests',
    '.github/CODEOWNERS',
    '.github/workflows/release.yml',
    '.gaia/local',
    'README.md',
  ],
  isExecutable: (relativePath) => relativePath === '.gaia/cli/gaia-maintainer',
  optOut: [],
  shippedBasenames: new Set(['index.ts', 'SKILL.md']),
  tracked: TRACKED,
  ...overrides,
});

describe('deriveExcludedRefTokens', () => {
  type Tokens = ReturnType<typeof deriveExcludedRefTokens>;

  // `expected` is a partial match on the derived tokens; `absent` lists values
  // a field must not carry.
  test.each<{
    absent: Partial<Record<keyof Tokens, string[]>>;
    expected: Record<string, unknown>;
    name: string;
    overrides?: Partial<ExcludedRefInputs>;
  }>([
    {
      // Untracked local state, a root governance file, and a workflow the
      // excluded-workflow-ref check owns.
      absent: {
        paths: ['.gaia/local', 'README.md', '.github/workflows/release.yml'],
      },
      expected: {
        paths: expect.arrayContaining([
          '.gaia/cli/src',
          '.gaia/tests',
          '.gaia/scripts/lint-hook-jq-availability.sh',
        ]),
      },
      name: 'keeps tracked excluded paths and drops untracked, root-level, and workflow entries',
    },
    {
      absent: {},
      expected: {commands: ['gaia-release', 'release-notes']},
      name: 'derives slash commands from excluded commands and skills',
    },
    {
      absent: {},
      expected: {agents: ['code-audit-maintainer-node']},
      name: 'derives agent names from excluded agent files',
    },
    {
      // A shipped file shares it, and a data fixture adopters also generate.
      absent: {basenames: ['index.ts', 'usage.jsonl']},
      expected: {
        basenames: expect.arrayContaining([
          'chain.ts',
          'gaia-maintainer',
          'lint-hook-jq-availability.sh',
          'run-all.sh',
        ]),
      },
      name: 'derives basenames only for unshared code files and executables',
    },
    {
      absent: {paths: ['.github/CODEOWNERS']},
      expected: {unusedOptOut: ['.github/no-such-path']},
      name: 'subtracts opt-out tokens by exact equality and reports the unused ones',
      overrides: {optOut: ['.github/CODEOWNERS', '.github/no-such-path']},
    },
  ])('$name', ({absent, expected, overrides}) => {
    const tokens = deriveExcludedRefTokens(baseInputs(overrides));

    expect(tokens).toMatchObject(expected);

    for (const [field, values] of Object.entries(absent)) {
      for (const value of values) {
        expect(tokens[field as keyof Tokens]).not.toContain(value);
      }
    }
  });
});

describe('compileExcludedRefMatcher', () => {
  const matcher = compileExcludedRefMatcher(
    deriveExcludedRefTokens(baseInputs())
  );
  const emptyMatcher = compileExcludedRefMatcher(
    deriveExcludedRefTokens(baseInputs({excludeLines: []}))
  );
  const BASENAME_LINE =
    'the record comes from `chain.ts` and `gaia-maintainer`';

  test.each<{
    expected: string[];
    line: string;
    markdown: boolean;
    matches?: typeof matcher;
    name: string;
  }>([
    {
      expected: ['.gaia/tests'],
      line: 'see `.gaia/tests/run-all.sh` for it',
      markdown: false,
      name: 'flags a path prefix',
    },
    {
      expected: ['.gaia/tests'],
      line: 'find .gaia/tests -name x',
      markdown: false,
      name: 'flags a bare directory',
    },
    {
      expected: ['.gaia/cli/src'],
      line: 'run ./.gaia/cli/src/x.ts',
      markdown: false,
      name: 'flags a dot-slash path',
    },
    {
      expected: ['/gaia-release'],
      line: 'Before `/gaia-release` runs',
      markdown: false,
      name: 'flags a slash command',
    },
    {
      expected: ['code-audit-maintainer-node'],
      line: 'spawn code-audit-maintainer-node now',
      markdown: false,
      name: 'flags an agent name',
    },
    {
      expected: ['.gaia/scripts/lint-hook-jq-availability.sh'],
      line: 'the `.gaia/scripts/lint-hook-jq-availability.sh` lint',
      markdown: false,
      name: 'flags an excluded file path',
    },
    {
      expected: [],
      line: '.gaia/testsuite/foo.sh',
      markdown: true,
      name: 'does not flag a longer path sharing the prefix',
    },
    {
      expected: [],
      line: 'vendor/.gaia/tests/x',
      markdown: true,
      name: 'does not flag a path nested under another tree',
    },
    {
      expected: [],
      line: '.claude/skills/x/gaia-release-notes',
      markdown: true,
      name: 'does not flag a command inside a path',
    },
    {
      expected: [],
      line: 'github.com/org/gaia-release',
      markdown: true,
      name: 'does not flag a command as a URL segment',
    },
    {
      expected: [],
      line: 'run /gaia-releases',
      markdown: true,
      name: 'does not flag a longer command',
    },
    {
      expected: ['chain.ts', 'gaia-maintainer'],
      line: BASENAME_LINE,
      markdown: true,
      name: 'matches basenames in Markdown only',
    },
    {
      expected: [],
      line: BASENAME_LINE,
      markdown: false,
      name: 'matches basenames in Markdown only (code files stay silent)',
    },
    {
      expected: ['.gaia/scripts/lint-hook-jq-availability.sh'],
      line: 'see .gaia/scripts/lint-hook-jq-availability.sh',
      markdown: true,
      name: 'reports a full path once, not again as its basename',
    },
    {
      expected: [],
      line: '.gaia/tests and /gaia-release',
      markdown: true,
      matches: emptyMatcher,
      name: 'matches nothing when nothing is derived',
    },
  ])('$name', ({expected, line, markdown, matches = matcher}) => {
    expect(matches(line, {markdown})).toEqual(expected);
  });
});
