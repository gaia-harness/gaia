import {afterEach, describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {createScratchProject} from '../test-support.js';
import type {Finding, FixtureProject} from '../types.js';
import {
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

const skillBodyProject = (count: number): FixtureProject => ({
  files: {[SKILL]: skillFile(linesWithContents(count))},
});

const playbookProject = (count: number): FixtureProject => ({
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

const withDescription = (description: string): FixtureProject => ({
  files: {[SKILL]: skillFile('Body.\n', {description})},
});

const withBody = (body: string): FixtureProject => ({
  files: {[SKILL]: skillFile(body)},
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

  test.each([
    [
      'accepts a playbook, a sub-reference it links and that sub-reference sibling',
      routed({
        [`${REFS}/example/a.md`]: 'Then [b](b.md).\n',
        [`${REFS}/example/b.md`]: 'Done.\n',
        [PLAYBOOK]: 'Start with [a](example/a.md).\n',
      }),
    ],
    [
      'accepts a command, a routed playbook and a directory of sub-references',
      routed({
        [`${REFS}/example/a.md`]: 'First.\n',
        [`${REFS}/example/b.md`]: 'Second.\n',
        [PLAYBOOK]: [
          'Read [a](example/a.md) now.',
          'Read [b](example/b.md) now.',
          '',
        ].join('\n'),
      }),
    ],
    [
      'a file both an entry and a sub-reference link counts as one level down',
      {
        files: {
          [`${REFS}/a.md`]: 'See [shared](shared/s.md).\n',
          [`${REFS}/shared/s.md`]: 'Shared.\n',
          [SKILL]: skillFile(
            'See [a](references/a.md) and [s](references/shared/s.md).\n'
          ),
        },
      },
    ],
  ])('reference depth: %s', (_name, project) => {
    expect(idsOf(project)).toEqual([]);
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
});

describe('line limits', () => {
  test.each([
    [
      'a command body of 510 lines yields exactly one body limit finding',
      {
        files: {
          '.claude/commands/example.md': commandFile(linesWithContents(510)),
        },
      },
      ['authoring.skill.body.max-lines'],
    ],
    ['a 499 line body passes', skillBodyProject(499), []],
    [
      'a 500 line body fails',
      skillBodyProject(500),
      ['authoring.skill.body.max-lines'],
    ],
    ['a 499 line playbook passes', playbookProject(499), []],
    [
      'a 500 line playbook fails',
      playbookProject(500),
      ['authoring.playbook.max-lines'],
    ],
    [
      'frontmatter lines do not count toward the body',
      skillBodyProject(499),
      [],
    ],
  ])('%s', (_name, project, expected) => {
    expect(idsOf(project)).toEqual(expected);
  });
});

describe('contents line', () => {
  test.each([
    ['a 100 line reference without one passes', filler(100), []],
    [
      'a 101 line reference without one fails',
      filler(101),
      ['authoring.reference.toc.required'],
    ],
    [
      'a Contents line inside a code fence does not count',
      `\`\`\`text\nContents: fenced\n\`\`\`\n${filler(101)}`,
      ['authoring.reference.toc.required'],
    ],
    ['a Contents heading counts', `## Contents\n${filler(120)}`, []],
    [
      'a table of contents line counts',
      `Table of Contents below\n${filler(120)}`,
      [],
    ],
    [
      'a Contents line past the first 30 non-blank lines does not count',
      `${filler(40)}Contents: late\n${filler(70)}`,
      ['authoring.reference.toc.required'],
    ],
  ])('%s', (_name, reference, expected) => {
    expect(idsOf(withRef(reference))).toEqual(expected);
  });
});

describe('each authoring defect yields exactly its own warning', () => {
  test.each([
    [
      'a first-person description',
      withDescription('Helps me review code whenever a review is asked.'),
      'authoring.skill.description.first-person',
    ],
    [
      'a 520 line skill body',
      skillBodyProject(520),
      'authoring.skill.body.max-lines',
    ],
    [
      'a 140 line reference with no Contents line',
      {
        files: {
          [`${REFS}/ref.md`]: filler(140),
          [SKILL]: skillFile('See [ref](references/ref.md).\n'),
        },
      },
      'authoring.reference.toc.required',
    ],
    [
      'a reference linked only from another reference',
      {
        files: {
          [`${REFS}/a.md`]: 'Next, [z](deep/z.md).\n',
          [`${REFS}/deep/z.md`]: 'Too deep.\n',
          [SKILL]: skillFile('See [a](references/a.md).\n'),
        },
      },
      'authoring.reference.depth.one-level',
    ],
    [
      'a backslash path',
      withBody('Open docs\\guide.md first.\n'),
      'authoring.path.windows-separator',
    ],
    [
      'a 510 line playbook',
      playbookProject(510),
      'authoring.playbook.max-lines',
    ],
  ])('%s', (_name, project, ruleId) => {
    expectOnly(project, ruleId);
  });
});

const commandWithInvocation = (invocation: boolean): FixtureProject => ({
  files: {
    '.claude/commands/example.md': `---\ndescription: Reviews pull request diffs for security defects.\ndisable-model-invocation: ${invocation}\n---\nBody.\n`,
  },
});

describe('description rules', () => {
  const FIRST_PERSON = ['authoring.skill.description.first-person'];

  test.each([
    [
      'quoted spans are not matched as person words',
      withDescription(
        'Reviews code when asked to "show me the diff" or `my-flag`.'
      ),
      [],
    ],
    [
      'I is case sensitive and whole word: a capital I flags',
      withDescription('Reviews code when asked, I think.'),
      FIRST_PERSON,
    ],
    [
      'I is case sensitive and whole word: a lowercase i in i/o does not',
      withDescription('Reviews item i/o paths when asked to.'),
      [],
    ],
    [
      'a contraction apostrophe does not open a quoted span',
      withDescription("Reviews code when it's asked, and we agree."),
      FIRST_PERSON,
    ],
    [
      'a command without a description is not judged',
      {files: {'.claude/commands/example.md': 'Do the thing.\n'}},
      [],
    ],
    [
      'when_to_use satisfies the trigger rule',
      {
        files: {
          [SKILL]:
            '---\nname: example\ndescription: Reviews pull request diffs for security defects.\nwhen_to_use: Whenever a diff lands.\n---\nBody.\n',
        },
      },
      [],
    ],
    [
      'disable-model-invocation: true needs no trigger',
      commandWithInvocation(true),
      [],
    ],
    [
      'disable-model-invocation: false needs a trigger',
      commandWithInvocation(false),
      ['authoring.skill.description.no-when'],
    ],
  ])('%s', (_name, project, expected) => {
    expect(idsOf(project)).toEqual(expected);
  });
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

  test.each([
    [
      'a command repo-relative path that is missing is flagged',
      {
        files: {
          '.claude/commands/example.md': commandFile(
            'Run `.claude/scripts/gone.sh` first.\n'
          ),
        },
      },
      ['authoring.reference.link.resolves'],
    ],
    [
      'urls, anchors and fenced examples are not links',
      withBody(
        'See [site](https://example.com/a.md) and [here](#top).\n```md\n[x](nope.md)\n```\n'
      ),
      [],
    ],
  ])('%s', (_name, project, expected) => {
    expect(idsOf(project)).toEqual(expected);
  });
});

describe('path and time rules', () => {
  const WINDOWS = ['authoring.path.windows-separator'];
  const TIME_SENSITIVE = ['authoring.content.time-sensitive'];

  test.each([
    [
      'a backslash path inside a powershell fence is allowed',
      withBody('```powershell\nGet-Item docs\\guide.md\n```\n'),
      [],
    ],
    [
      'a backslash path inside a bash fence is flagged',
      withBody('```bash\ncat docs\\guide.md\n```\n'),
      WINDOWS,
    ],
    [
      'a regex escape is not a path',
      withBody('Match `name\\.md` files.\n'),
      [],
    ],
    [
      'a dated phrase inside a legacy section is allowed',
      withBody('## Legacy notes\nUse this until 2024 only.\n## Current\nOk.\n'),
      [],
    ],
    [
      'a dated phrase inside a details block is allowed',
      withBody('<details>\nBefore March 2025 this differed.\n</details>\n'),
      [],
    ],
    [
      'a dated phrase after a legacy section ends is flagged',
      withBody('## Legacy notes\nOld.\n## Current\nUse this as of 2026.\n'),
      TIME_SENSITIVE,
    ],
  ])('%s', (_name, project, expected) => {
    expect(idsOf(project)).toEqual(expected);
  });
});
