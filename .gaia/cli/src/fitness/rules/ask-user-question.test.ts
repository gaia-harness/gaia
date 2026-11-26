import {describe, expect, test} from 'vitest';
import type {RuleContext} from '../context.js';
import type {ProjectFile} from '../types.js';
import {classify} from './ask-user-question-sites.js';
import {ASK_USER_QUESTION_RULES} from './ask-user-question.js';

const fileOf = (text: string): ProjectFile =>
  ({path: '.claude/skills/example/SKILL.md', text}) as ProjectFile;

const only = (text: string) => {
  const {sites} = classify(fileOf(text));

  expect(sites).toHaveLength(1);

  return sites[0]!;
};

const recommendationRule = ASK_USER_QUESTION_RULES.find(
  (rule) => rule.ruleId === 'authoring.ask-user-question.recommendation'
)!;

const findingsFor = (text: string): number =>
  recommendationRule.check({files: [fileOf(text)]} as unknown as RuleContext)
    .length;

describe('recommendation rule', () => {
  test('a quoted bare mark beside one named option covers both questions', () => {
    expect(
      findingsFor(
        'Ask with `AskUserQuestion` (header `Ruling`), the suggested reading first, its label ending ` (Recommended)`; then ask (header `Notes`) `Accept the notes (Recommended)` or `Adjust`.'
      )
    ).toBe(0);
  });

  test('a headed site with no marked option fails', () => {
    expect(
      findingsFor('Ask with `AskUserQuestion` (header `Go`): `Yes` or `No`.')
    ).toBe(1);
  });

  test('a headed site with two marked options fails', () => {
    expect(
      findingsFor(
        'Ask with `AskUserQuestion` (header `Go`): `Yes (Recommended)` or `No (Recommended)`.'
      )
    ).toBe(1);
  });

  test('a headed site that says it recommends nothing passes', () => {
    expect(
      findingsFor(
        'Ask with `AskUserQuestion` (header `Go`): `Yes` or `No`; it recommends nothing.'
      )
    ).toBe(0);
  });

  test('an unheaded option block with no marked option fails', () => {
    expect(
      findingsFor('Ask with `AskUserQuestion`, options `Yes` or `No`.')
    ).toBe(1);
  });

  test('an unheaded option block with one marked option passes', () => {
    expect(
      findingsFor(
        'Ask with `AskUserQuestion`, options `Yes (Recommended)` or `No`.'
      )
    ).toBe(0);
  });

  test('a block that only mentions the tool passes', () => {
    expect(
      findingsFor(
        'The hook denies every `AskUserQuestion` while the switch is live.'
      )
    ).toBe(0);
  });
});

describe('AskUserQuestion site grammar', () => {
  test('a headed question with one marked option holds one label', () => {
    const site = only(
      'Ask with `AskUserQuestion` (header `Go`): `Yes (Recommended)` or `No`.'
    );

    expect(site.recommendedLabels.size).toBe(site.headers.length);
  });

  test('a headed question with no marked option holds none', () => {
    const site = only(
      'Ask with `AskUserQuestion` (header `Go`): `Yes` or `No`, options.'
    );

    expect(site.recommendedLabels.size).toBe(0);
  });

  test('a headed question with two marked options holds two labels', () => {
    const site = only(
      'Ask with `AskUserQuestion` (header `Go`): `Yes (Recommended)` or `No (Recommended)`.'
    );

    expect(site.recommendedLabels.size).toBe(2);
  });

  test('one option restated in a lead-in counts once', () => {
    const site = only(
      'Ask with `AskUserQuestion` (header `Go`), `Yes (Recommended)` first:\n\n- `Yes (Recommended)`: proceed.\n- `No`: stop.'
    );

    expect(site.recommendedLabels.size).toBe(1);
  });

  test('a bare mention of the marker names no option', () => {
    const site = only(
      'Ask with `AskUserQuestion` (header `Go`), the first option marked `(Recommended)`.'
    );

    expect(site.recommendedLabels.size).toBe(0);
  });

  test('a marker quoted with its leading space names no option', () => {
    const site = only(
      'Ask with one `AskUserQuestion` call of two questions (header `Group`, header `Data`), each recommended answer first and marked ` (Recommended)`.'
    );

    expect(site.recommendedLabels.size).toBe(0);
    expect(site.hasMarker).toBe(true);
  });

  test('a block that only names the tool is mention-only, not a site', () => {
    const classified = classify(
      fileOf(
        'The hook denies every `AskUserQuestion` while the switch is live.'
      )
    );

    expect(classified.sites).toHaveLength(0);
    expect(classified.mentionOnly).toHaveLength(1);
  });

  test('a block that offers options with no header is counted, not checked', () => {
    const classified = classify(
      fileOf(
        'Ask with `AskUserQuestion`, options `Yes (Recommended)` and `No`.'
      )
    );

    expect(classified.sites).toHaveLength(0);
    expect(classified.unheaded).toHaveLength(1);
    expect(classified.unheaded[0]?.recommendedLabels.size).toBe(1);
  });

  test('a header word at the end of the text ends the scan', () => {
    const classified = classify(
      fileOf('Ask with `AskUserQuestion`, the header')
    );

    expect(classified.sites).toHaveLength(0);
  });

  test('a free-text question names its fallback or not', () => {
    const bare = classify(
      fileOf('Ask for the handle as a plain chat message.')
    );
    const covered = classify(
      fileOf(
        'Ask for the handle as a plain chat message; unattended, keep the default.'
      )
    );

    expect(bare.freeText.map((entry) => entry.hasFallback)).toEqual([false]);
    expect(covered.freeText.map((entry) => entry.hasFallback)).toEqual([true]);
  });
});
