import type {FixtureMap, FixtureProject} from '../types.js';

const REFERENCE = '.claude/skills/example/SKILL.md';
const HEADERS_FILE = '.gaia/autonomy-human-only-headers.json';

const reference = (text: string): FixtureProject => ({
  files: {[REFERENCE]: `# Example\n\n${text}\n`},
  git: true,
});

const withHeaders = (
  headers: readonly string[],
  text: string
): FixtureProject => ({
  files: {
    [HEADERS_FILE]: JSON.stringify({headers}),
    [REFERENCE]: `# Example\n\n${text}\n`,
  },
  git: true,
});

export const ASK_USER_QUESTION_FIXTURES: FixtureMap = {
  'authoring.ask-user-question.free-text-fallback': {
    green: () =>
      reference(
        'Ask for the handle as a plain chat message. Unattended, keep the placeholder and do not ask.'
      ),
    red: () => reference('Ask for the handle as a plain chat message.'),
  },
  'authoring.ask-user-question.human-only-header': {
    green: () =>
      withHeaders(
        ['Fork PR'],
        'Ask with `AskUserQuestion` (header `Fork PR`): `Stop (Recommended)` or `Continue`. This question is human-only.'
      ),
    red: () =>
      withHeaders(
        ['Fork PR'],
        'Ask with `AskUserQuestion` (header `Other header`): `Stop (Recommended)` or `Continue`.'
      ),
  },
  'authoring.ask-user-question.recommendation': {
    green: () =>
      reference(
        'Ask with `AskUserQuestion` (header `Pick one`): `Continue (Recommended)` or `Stop`.'
      ),
    red: () =>
      reference(
        'Ask with `AskUserQuestion` (header `Pick one`): `Continue (Recommended)` or `Stop (Recommended)`.'
      ),
  },
};
