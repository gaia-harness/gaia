import type {FixtureFactory, FixtureMap, FixtureProject} from '../types.js';

const SKILL_PATH = '.claude/skills/example/SKILL.md';
const COMMAND_PATH = '.claude/commands/example.md';

const PLAIN_DESCRIPTION = 'Does an example thing when the user asks for one.';

/** A frontmatter block from raw lines, followed by a short body. */
export const documentOf = (...lines: readonly string[]): string =>
  `---\n${lines.join('\n')}\n---\n\n# Example\n`;

const projectOf = (files: Record<string, string>): FixtureProject => ({
  files,
  git: true,
});

const skillWith = (...lines: readonly string[]): FixtureProject =>
  projectOf({[SKILL_PATH]: documentOf(...lines)});

const validSkill: FixtureFactory = () =>
  skillWith('name: example', `description: ${PLAIN_DESCRIPTION}`);

export const FRONTMATTER_FIXTURES: FixtureMap = {
  'frontmatter.name-collision': {
    green: () =>
      projectOf({
        '.claude/skills/first/SKILL.md': documentOf(
          'name: first',
          `description: ${PLAIN_DESCRIPTION}`
        ),
        '.claude/skills/second/SKILL.md': documentOf(
          'name: second',
          `description: ${PLAIN_DESCRIPTION}`
        ),
      }),
    red: () =>
      projectOf({
        '.claude/skills/first/SKILL.md': documentOf(
          'name: shared',
          `description: ${PLAIN_DESCRIPTION}`
        ),
        '.claude/skills/second/SKILL.md': documentOf(
          'name: shared',
          `description: ${PLAIN_DESCRIPTION}`
        ),
      }),
  },
  'frontmatter.parse': {
    green: validSkill,
    red: () => projectOf({[SKILL_PATH]: '# No frontmatter here\n'}),
  },
  'frontmatter.skill.description.listing-truncation': {
    green: () => skillWith('name: example', `description: ${'a'.repeat(1000)}`),
    red: () =>
      projectOf({
        [SKILL_PATH]: documentOf(
          'name: example',
          `description: ${'a'.repeat(1000)}`,
          `when_to_use: ${'b'.repeat(600)}`
        ),
      }),
  },
  'frontmatter.skill.description.max-length': {
    green: () => skillWith('name: example', `description: ${'a'.repeat(1024)}`),
    red: () => skillWith('name: example', `description: ${'a'.repeat(1025)}`),
  },
  'frontmatter.skill.description.non-empty': {
    green: validSkill,
    red: () => skillWith('name: example', 'description:'),
  },
  'frontmatter.skill.description.xml-tag': {
    green: () =>
      skillWith('name: example', 'description: Wraps `<example>` in code.'),
    red: () =>
      skillWith(
        'name: example',
        'description: Wraps <example>text</example> and more.'
      ),
  },
  'frontmatter.skill.name.charset': {
    green: validSkill,
    red: () =>
      skillWith('name: Example_Name', `description: ${PLAIN_DESCRIPTION}`),
  },
  'frontmatter.skill.name.max-length': {
    green: () =>
      skillWith(`name: ${'a'.repeat(64)}`, `description: ${PLAIN_DESCRIPTION}`),
    red: () =>
      skillWith(`name: ${'a'.repeat(65)}`, `description: ${PLAIN_DESCRIPTION}`),
  },
  'frontmatter.skill.name.present': {
    green: validSkill,
    red: () => skillWith(`description: ${PLAIN_DESCRIPTION}`),
  },
  'frontmatter.skill.name.reserved-word': {
    green: validSkill,
    red: () =>
      skillWith('name: claude-example', `description: ${PLAIN_DESCRIPTION}`),
  },
  'frontmatter.yaml-hazard': {
    green: () =>
      projectOf({
        [COMMAND_PATH]: documentOf('description: "Use when: asked"'),
      }),
    red: () =>
      projectOf({
        [COMMAND_PATH]: documentOf('description: Use when: asked'),
      }),
  },
};
