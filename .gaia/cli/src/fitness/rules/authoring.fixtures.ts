import type {FixtureMap, FixtureProject} from '../types.js';

const GOOD_DESCRIPTION =
  'Reviews pull request diffs for security defects. Use when the user asks for a security review.';

const SKILL_PATH = '.claude/skills/example/SKILL.md';
const REFERENCES = '.claude/skills/example/references';

/** `count` filler lines, each ending in a newline. */
export const filler = (count: number, prefix = 'line'): string =>
  Array.from({length: count}, (_, index) => `${prefix} ${index}\n`).join('');

/** A text of exactly `count` lines whose first line is a Contents line. */
export const linesWithContents = (count: number): string =>
  `Contents: body\n${filler(count - 1)}`;

export const skillFile = (
  body: string,
  options: {description?: string; name?: string} = {}
): string =>
  `---\nname: ${options.name ?? 'example'}\ndescription: ${options.description ?? GOOD_DESCRIPTION}\n---\n${body}`;

export const commandFile = (body: string, description?: string): string =>
  `---\ndescription: ${description ?? 'Runs the example workflow when the user asks for it.'}\n---\n${body}`;

const project = (files: Record<string, string>): FixtureProject => ({files});

const skillProject = (
  body: string,
  options: {description?: string; name?: string} = {}
): FixtureProject => project({[SKILL_PATH]: skillFile(body, options)});

const withReference = (skillBody: string, reference: string): FixtureProject =>
  project({
    [`${REFERENCES}/ref.md`]: reference,
    [SKILL_PATH]: skillFile(skillBody),
  });

const playbookProject = (playbook: string): FixtureProject =>
  project({
    '.claude/commands/example.md': commandFile(
      `Read \`${REFERENCES}/big.md\` and follow it.\n`
    ),
    [`${REFERENCES}/big.md`]: playbook,
  });

const LINKS_REF = 'See [the reference](references/ref.md) for detail.\n';

export const AUTHORING_FIXTURES: FixtureMap = {
  'authoring.content.time-sensitive': {
    green: () => skillProject('Use the current release.\n'),
    red: () => skillProject('Use the old flag before August 2026 only.\n'),
  },
  'authoring.path.windows-separator': {
    green: () => skillProject('Open docs/guide.md first.\n'),
    red: () => skillProject('Open docs\\guide.md first.\n'),
  },
  'authoring.playbook.max-lines': {
    green: () => playbookProject(linesWithContents(499)),
    red: () => playbookProject(linesWithContents(500)),
  },
  'authoring.reference.depth.one-level': {
    green: () =>
      project({
        [`${REFERENCES}/a.md`]: 'Next, [b](b.md).\n',
        [`${REFERENCES}/b.md`]: 'Leaf.\n',
        [SKILL_PATH]: skillFile('See [a](references/a.md).\n'),
      }),
    red: () =>
      project({
        [`${REFERENCES}/a.md`]: 'Next, [z](deep/z.md).\n',
        [`${REFERENCES}/deep/z.md`]: 'Too deep.\n',
        [SKILL_PATH]: skillFile('See [a](references/a.md).\n'),
      }),
  },
  'authoring.reference.link.resolves': {
    green: () => withReference(LINKS_REF, 'Detail.\n'),
    red: () =>
      skillProject('See [the reference](references/missing.md) for detail.\n'),
  },
  'authoring.reference.orphan': {
    green: () => withReference(LINKS_REF, 'Detail.\n'),
    red: () => withReference('No links here.\n', 'Detail.\n'),
  },
  'authoring.reference.toc.required': {
    green: () => withReference(LINKS_REF, filler(100)),
    red: () => withReference(LINKS_REF, filler(101)),
  },
  'authoring.skill.body.max-lines': {
    green: () => skillProject(linesWithContents(499)),
    red: () => skillProject(linesWithContents(500)),
  },
  'authoring.skill.body.toc': {
    green: () => skillProject(linesWithContents(101)),
    red: () => skillProject(filler(101)),
  },
  'authoring.skill.description.first-person': {
    green: () =>
      skillProject('Body.\n', {
        description: 'Reviews code for defects whenever a review is asked.',
      }),
    red: () =>
      skillProject('Body.\n', {
        description: 'Helps me review code whenever a review is asked.',
      }),
  },
  'authoring.skill.description.no-when': {
    green: () => skillProject('Body.\n'),
    red: () =>
      skillProject('Body.\n', {
        description:
          'Reviews pull request diffs for security defects and style.',
      }),
  },
  'authoring.skill.description.second-person': {
    green: () => skillProject('Body.\n'),
    red: () =>
      skillProject('Body.\n', {
        description: 'Reviews code for defects when you ask for a review.',
      }),
  },
  'authoring.skill.description.too-short': {
    green: () => skillProject('Body.\n'),
    red: () => skillProject('Body.\n', {description: 'Reviews code'}),
  },
  'authoring.skill.name.vague': {
    green: () => skillProject('Body.\n'),
    red: () => skillProject('Body.\n', {name: 'helper'}),
  },
};
