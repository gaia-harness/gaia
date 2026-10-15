import {afterEach, describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {
  createScratchProject,
  expectFixtureParity,
  FIXTURE_PARITY_TIMEOUT_MS,
} from '../test-support.js';
import type {Finding, FixtureProject} from '../types.js';
import {
  AUTHORING_FIXTURES,
  commandFile,
  filler,
  linesWithContents,
  skillFile,
} from './authoring.fixtures.js';
import {AUTHORING_RULES} from './authoring.js';

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const findingsOf = (project: FixtureProject): readonly Finding[] => {
  const scratch = createScratchProject(project);

  cleanups.push(scratch.cleanup);

  return runCheck({
    catalog: AUTHORING_RULES,
    env: scratch.env,
    root: scratch.root,
    scope: 'all',
  }).findings;
};

const idsOf = (project: FixtureProject): string[] =>
  findingsOf(project).map((finding) => finding.rule_id);

const SKILL = '.claude/skills/example/SKILL.md';
const REFS = '.claude/skills/example/references';

const idsOfSkillBody = (count: number): string[] =>
  idsOf({files: {[SKILL]: skillFile(linesWithContents(count))}});

const idsOfPlaybook = (count: number): string[] =>
  idsOf({
    files: {
      '.claude/commands/example.md': commandFile(
        `Read \`${REFS}/big.md\` and follow it.\n`
      ),
      [`${REFS}/big.md`]: linesWithContents(count),
    },
  });

const withRef = (reference: string): FixtureProject => ({
  files: {
    [`${REFS}/ref.md`]: reference,
    [SKILL]: skillFile('See [ref](references/ref.md).\n'),
  },
});

const expectOnly = (project: FixtureProject, ruleId: string): void => {
  const findings = findingsOf(project);

  expect(findings.map((finding) => finding.rule_id)).toEqual([ruleId]);
  expect(findings[0]?.severity).toBe('warning');
};

const idsForDescription = (description: string): string[] =>
  idsOf({files: {[SKILL]: skillFile('Body.\n', {description})}});

describe('authoring rules', () => {
  test(
    'every rule has a red fixture that fires it and a green fixture that does not',
    () => {
      expectFixtureParity(AUTHORING_RULES, AUTHORING_FIXTURES);
    },
    FIXTURE_PARITY_TIMEOUT_MS
  );

  test('every id starts with the authoring category', () => {
    for (const rule of AUTHORING_RULES) {
      expect(rule.ruleId.startsWith('authoring.')).toBe(true);
      expect(rule.category).toBe('authoring');
    }
  });
});

describe('reference depth', () => {
  const COMMAND = '.claude/commands/example.md';
  const PLAYBOOK = `${REFS}/example.md`;

  const routed = (files: Record<string, string>): FixtureProject => ({
    files: {
      [COMMAND]: commandFile(`Read \`${PLAYBOOK}\` and follow it.\n`),
      ...files,
    },
  });

  test('accepts a playbook, a sub-reference it links and that sub-reference sibling', () => {
    const ids = idsOf(
      routed({
        [`${REFS}/example/a.md`]: 'Then [b](b.md).\n',
        [`${REFS}/example/b.md`]: 'Done.\n',
        [PLAYBOOK]: 'Start with [a](example/a.md).\n',
      })
    );

    expect(ids).toEqual([]);
  });

  test('flags a file reachable only through a sub-reference, on the linking line', () => {
    const findings = findingsOf(
      routed({
        [`${REFS}/example/a.md`]: 'Intro.\n\nThen [z](../other/z.md).\n',
        [`${REFS}/other/z.md`]: 'Deep.\n',
        [PLAYBOOK]: 'Start with [a](example/a.md).\n',
      })
    ).filter((finding) => finding.rule_id.endsWith('depth.one-level'));

    expect(findings).toHaveLength(1);
    expect(findings[0]).toMatchObject({
      file: `${REFS}/example/a.md`,
      line: 3,
      severity: 'warning',
    });
  });

  test('accepts a command, a routed playbook and a directory of sub-references', () => {
    const ids = idsOf(
      routed({
        [`${REFS}/example/a.md`]: 'First.\n',
        [`${REFS}/example/b.md`]: 'Second.\n',
        [PLAYBOOK]: [
          'Read [a](example/a.md) now.',
          'Read [b](example/b.md) now.',
          '',
        ].join('\n'),
      })
    );

    expect(ids).toEqual([]);
  });

  test('a file both an entry and a sub-reference link counts as one level down', () => {
    const ids = idsOf({
      files: {
        [`${REFS}/a.md`]: 'See [shared](shared/s.md).\n',
        [`${REFS}/shared/s.md`]: 'Shared.\n',
        [SKILL]: skillFile(
          'See [a](references/a.md) and [s](references/shared/s.md).\n'
        ),
      },
    });

    expect(ids).toEqual([]);
  });
});

describe('line limits', () => {
  test('a command body of 510 lines yields exactly one body limit finding', () => {
    const findings = findingsOf({
      files: {
        '.claude/commands/example.md': commandFile(linesWithContents(510)),
      },
    });

    expect(findings.map((finding) => finding.rule_id)).toEqual([
      'authoring.skill.body.max-lines',
    ]);
  });

  test('a 499 line body passes and a 500 line body fails', () => {
    expect(idsOfSkillBody(499)).toEqual([]);
    expect(idsOfSkillBody(500)).toEqual(['authoring.skill.body.max-lines']);
  });

  test('a 499 line playbook passes and a 500 line playbook fails', () => {
    expect(idsOfPlaybook(499)).toEqual([]);
    expect(idsOfPlaybook(500)).toEqual(['authoring.playbook.max-lines']);
  });

  test('frontmatter lines do not count toward the body', () => {
    const ids = idsOf({files: {[SKILL]: skillFile(linesWithContents(499))}});

    expect(ids).toEqual([]);
  });
});

describe('contents line', () => {
  test('a 100 line reference without one passes and 101 lines fails', () => {
    expect(idsOf(withRef(filler(100)))).toEqual([]);
    expect(idsOf(withRef(filler(101)))).toEqual([
      'authoring.reference.toc.required',
    ]);
  });

  test('a Contents line inside a code fence does not count', () => {
    const fenced = `\`\`\`text\nContents: fenced\n\`\`\`\n${filler(101)}`;

    expect(idsOf(withRef(fenced))).toEqual([
      'authoring.reference.toc.required',
    ]);
  });

  test('a Contents heading and a table of contents line both count', () => {
    expect(idsOf(withRef(`## Contents\n${filler(120)}`))).toEqual([]);
    expect(idsOf(withRef(`Table of Contents below\n${filler(120)}`))).toEqual(
      []
    );
  });

  test('a Contents line past the first 30 non-blank lines does not count', () => {
    expect(
      idsOf(withRef(`${filler(40)}Contents: late\n${filler(70)}`))
    ).toEqual(['authoring.reference.toc.required']);
  });
});

describe('each authoring defect yields exactly its own warning', () => {
  test('a first-person description', () => {
    expectOnly(
      {
        files: {
          [SKILL]: skillFile('Body.\n', {
            description: 'Helps me review code whenever a review is asked.',
          }),
        },
      },
      'authoring.skill.description.first-person'
    );
  });

  test('a 520 line skill body', () => {
    expectOnly(
      {files: {[SKILL]: skillFile(linesWithContents(520))}},
      'authoring.skill.body.max-lines'
    );
  });

  test('a 140 line reference with no Contents line', () => {
    expectOnly(
      {
        files: {
          [`${REFS}/ref.md`]: filler(140),
          [SKILL]: skillFile('See [ref](references/ref.md).\n'),
        },
      },
      'authoring.reference.toc.required'
    );
  });

  test('a reference linked only from another reference', () => {
    expectOnly(
      {
        files: {
          [`${REFS}/a.md`]: 'Next, [z](deep/z.md).\n',
          [`${REFS}/deep/z.md`]: 'Too deep.\n',
          [SKILL]: skillFile('See [a](references/a.md).\n'),
        },
      },
      'authoring.reference.depth.one-level'
    );
  });

  test('a backslash path', () => {
    expectOnly(
      {files: {[SKILL]: skillFile('Open docs\\guide.md first.\n')}},
      'authoring.path.windows-separator'
    );
  });

  test('a 510 line playbook', () => {
    expectOnly(
      {
        files: {
          '.claude/commands/example.md': commandFile(
            `Read \`${REFS}/big.md\` and follow it.\n`
          ),
          [`${REFS}/big.md`]: linesWithContents(510),
        },
      },
      'authoring.playbook.max-lines'
    );
  });
});

describe('description rules', () => {
  test('quoted spans are not matched as person words', () => {
    expect(
      idsForDescription(
        'Reviews code when asked to "show me the diff" or `my-flag`.'
      )
    ).toEqual([]);
  });

  test('I is case sensitive and whole word', () => {
    expect(idsForDescription('Reviews code when asked, I think.')).toEqual([
      'authoring.skill.description.first-person',
    ]);
    expect(idsForDescription('Reviews item i/o paths when asked to.')).toEqual(
      []
    );
  });

  test('a contraction apostrophe does not open a quoted span', () => {
    expect(
      idsForDescription("Reviews code when it's asked, and we agree.")
    ).toEqual(['authoring.skill.description.first-person']);
  });

  test('a command without a description is not judged', () => {
    expect(
      idsOf({files: {'.claude/commands/example.md': 'Do the thing.\n'}})
    ).toEqual([]);
  });

  test('when_to_use satisfies the trigger rule', () => {
    const ids = idsOf({
      files: {
        [SKILL]:
          '---\nname: example\ndescription: Reviews pull request diffs for security defects.\nwhen_to_use: Whenever a diff lands.\n---\nBody.\n',
      },
    });

    expect(ids).toEqual([]);
  });

  test.each([
    {expected: [], invocation: true},
    {expected: ['authoring.skill.description.no-when'], invocation: false},
  ])(
    'disable-model-invocation: $invocation decides whether a command needs a trigger',
    ({expected, invocation}) => {
      const ids = idsOf({
        files: {
          '.claude/commands/example.md': `---\ndescription: Reviews pull request diffs for security defects.\ndisable-model-invocation: ${invocation}\n---\nBody.\n`,
        },
      });

      expect(ids).toEqual(expected);
    }
  );
});

describe('orphan references', () => {
  test('scripts, assets and eval subtrees are not orphans', () => {
    const ids = idsOf({
      files: {
        '.claude/skills/example/assets/note.md': 'Asset.\n',
        '.claude/skills/example/eval-set/case.md': 'Case.\n',
        '.claude/skills/example/scripts/readme.md': 'Script.\n',
        [SKILL]: skillFile('Body.\n'),
      },
    });

    expect(ids).toEqual([]);
  });
});

describe('link resolution', () => {
  test('a backticked skill-relative path that is missing is flagged on its line', () => {
    const findings = findingsOf({
      files: {
        '.claude/skills/example/references/data.json': '{}\n',
        [SKILL]: skillFile('Intro.\nRead `references/gone.md`.\n'),
      },
    });

    expect(findings).toHaveLength(1);
    expect(findings[0]).toMatchObject({
      line: 6,
      rule_id: 'authoring.reference.link.resolves',
    });
  });

  test('a command repo-relative path that is missing is flagged', () => {
    const ids = idsOf({
      files: {
        '.claude/commands/example.md': commandFile(
          'Run `.claude/scripts/gone.sh` first.\n'
        ),
      },
    });

    expect(ids).toEqual(['authoring.reference.link.resolves']);
  });

  test('urls, anchors and fenced examples are not links', () => {
    const ids = idsOf({
      files: {
        [SKILL]: skillFile(
          'See [site](https://example.com/a.md) and [here](#top).\n```md\n[x](nope.md)\n```\n'
        ),
      },
    });

    expect(ids).toEqual([]);
  });
});

describe('path and time rules', () => {
  test('a backslash path inside a powershell fence is allowed', () => {
    const body = '```powershell\nGet-Item docs\\guide.md\n```\n';

    expect(idsOf({files: {[SKILL]: skillFile(body)}})).toEqual([]);
  });

  test('a backslash path inside a bash fence is flagged', () => {
    const body = '```bash\ncat docs\\guide.md\n```\n';

    expect(idsOf({files: {[SKILL]: skillFile(body)}})).toEqual([
      'authoring.path.windows-separator',
    ]);
  });

  test('a regex escape is not a path', () => {
    expect(
      idsOf({files: {[SKILL]: skillFile('Match `name\\.md` files.\n')}})
    ).toEqual([]);
  });

  test('a dated phrase inside a legacy section or details block is allowed', () => {
    const legacy =
      '## Legacy notes\nUse this until 2024 only.\n## Current\nOk.\n';
    const details = '<details>\nBefore March 2025 this differed.\n</details>\n';

    expect(idsOf({files: {[SKILL]: skillFile(legacy)}})).toEqual([]);
    expect(idsOf({files: {[SKILL]: skillFile(details)}})).toEqual([]);
  });

  test('a dated phrase after a legacy section ends is flagged', () => {
    const body = '## Legacy notes\nOld.\n## Current\nUse this as of 2026.\n';

    expect(idsOf({files: {[SKILL]: skillFile(body)}})).toEqual([
      'authoring.content.time-sensitive',
    ]);
  });
});
