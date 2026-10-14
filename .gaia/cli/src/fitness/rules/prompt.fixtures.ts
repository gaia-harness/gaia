import type {FixtureFactory, FixtureMap, FixtureProject} from '../types.js';

const SKILL_PATH = '.claude/skills/example/SKILL.md';

const skill = (model: string, body: string, description = 'Does a thing.') =>
  `---\nname: example\ndescription: ${description}\nmodel: ${model}\n---\n\n${body}\n`;

const project = (text: string): FixtureProject => ({
  files: {[SKILL_PATH]: text},
  git: true,
});

const pair = (
  model: string,
  redBody: string,
  greenBody: string
): {green: FixtureFactory; red: FixtureFactory} => ({
  green: () => project(skill(model, greenBody)),
  red: () => project(skill(model, redBody)),
});

export const PROMPT_FIXTURES: FixtureMap = {
  'prompt.description-caps-emphasis': {
    green: () =>
      project(skill('opus', 'Review the change.', 'Use when reviewing.')),
    red: () =>
      project(
        skill('opus', 'Review the change.', 'You MUST use this when reviewing.')
      ),
  },
  'prompt.no-brief-updates': pair(
    'fable',
    'Keep progress updates brief.',
    'Write progress updates a reader can act on without the transcript.'
  ),
  'prompt.no-dont-think': pair(
    'sonnet',
    'Answer fast and do not think about it.',
    'Answer from the file contents.'
  ),
  'prompt.no-explicit-double-check': pair(
    'opus',
    'Double-check your answer before replying.',
    'Run the test suite before replying.'
  ),
  'prompt.no-forced-interim-status': pair(
    'sonnet',
    'After every 5 tool calls, give a status update.',
    'Report the outcome when the work is done.'
  ),
  'prompt.no-if-in-doubt-tool': pair(
    'opus',
    'When in doubt, use the search tool.',
    'Search when the answer is not in the file.'
  ),
  'prompt.no-reasoning-extraction': pair(
    'opus',
    'Show your reasoning before the answer.',
    'State the answer first.'
  ),
  'prompt.no-think-carefully': pair(
    'opus',
    'Think carefully about the edge cases.',
    'List the edge cases the change must handle.'
  ),
  'prompt.no-tool-discouragement': pair(
    'sonnet',
    'Only use tools when the user asks.',
    'Use the search tool to locate the file.'
  ),
  'prompt.xml-tag-balance': pair(
    'haiku',
    '<context>\nA.\n</context>\n<context>\nB.',
    '<context>\nA.\n</context>\n<context>\nB.\n</context>'
  ),
};
