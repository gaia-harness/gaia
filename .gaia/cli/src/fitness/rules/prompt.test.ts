import {describe, expect, test} from 'vitest';
import {runCheck} from '../check.js';
import {createScratchProject, expectFixtureParity} from '../test-support.js';
import type {Finding, FixtureProject} from '../types.js';
import {PROMPT_FIXTURES} from './prompt.fixtures.js';
import {PROMPT_RULES} from './prompt.js';

const checkProject = (project: FixtureProject) => {
  const scratch = createScratchProject({git: true, ...project});

  try {
    return runCheck({env: scratch.env, root: scratch.root, scope: 'all'});
  } finally {
    scratch.cleanup();
  }
};

const promptIds = (findings: readonly Finding[], file: string): string[] => {
  const ids = findings
    .filter((finding) => finding.file === file)
    .map((finding) => finding.rule_id)
    .filter((id) => id.startsWith('prompt.'));

  return ids.toSorted((a, b) => a.localeCompare(b));
};

const frontmatter = (model: string | undefined): string => {
  const modelLine = model === undefined ? '' : `model: ${model}\n`;

  return `---\nname: example\ndescription: Does a thing.\n${modelLine}---\n\n`;
};

const UNBALANCED = '<context>\nA.\n</context>\n<context>\nB.\n';

const OPUS_AGENT = '.claude/agents/example-agent.md';
const SONNET_SKILL = '.claude/skills/sonnet-example/SKILL.md';
const UNPINNED_SKILL = '.claude/skills/unpinned-example/SKILL.md';

describe('prompt rules', () => {
  test('every rule has a red fixture that fires it and a green one that does not', () => {
    expectFixtureParity(PROMPT_RULES, PROMPT_FIXTURES);
  });

  test('a rule fires only on a file whose resolved model is in its list', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]: `${frontmatter('opus')}Think carefully.\n\n${UNBALANCED}`,
        [SONNET_SKILL]: `${frontmatter('sonnet')}Think carefully.\n`,
        [UNPINNED_SKILL]: `${frontmatter(undefined)}${UNBALANCED}`,
      },
    });

    expect(promptIds(report.findings, OPUS_AGENT)).toEqual([
      'prompt.no-think-carefully',
      'prompt.xml-tag-balance',
    ]);
    expect(promptIds(report.findings, SONNET_SKILL)).toEqual([]);
    expect(promptIds(report.findings, UNPINNED_SKILL)).toEqual([
      'prompt.xml-tag-balance',
    ]);

    const models = Object.fromEntries(
      report.inventory.map((entry) => [entry.path, entry.model])
    );

    expect(models[OPUS_AGENT]).toBe('opus');
    expect(models[SONNET_SKILL]).toBe('sonnet');
    expect(models[UNPINNED_SKILL]).toBe('unresolved');
  });

  test('the project settings model resolves a file that pins none', () => {
    const report = checkProject({
      files: {[UNPINNED_SKILL]: `${frontmatter(undefined)}Think carefully.\n`},
      settingsJson: {model: 'opus'},
    });

    expect(promptIds(report.findings, UNPINNED_SKILL)).toEqual([
      'prompt.no-think-carefully',
    ]);
  });

  test('an unresolved file runs only the rules that apply to any model', () => {
    const report = checkProject({
      files: {
        [UNPINNED_SKILL]: `${frontmatter(undefined)}Show your reasoning. Do not think. Think carefully.\n`,
      },
    });

    expect(promptIds(report.findings, UNPINNED_SKILL)).toEqual([]);
  });

  test('a haiku file runs only the rules that apply to any model', () => {
    const report = checkProject({
      files: {
        [SONNET_SKILL]: `${frontmatter('haiku')}Think carefully.\n${UNBALANCED}`,
      },
    });

    expect(promptIds(report.findings, SONNET_SKILL)).toEqual([
      'prompt.xml-tag-balance',
    ]);
  });

  test('a quoted negative example does not fire', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]: `${frontmatter('opus')}Avoid writing "think carefully".\nBad example: think hard.\n`,
      },
    });

    expect(promptIds(report.findings, OPUS_AGENT)).toEqual([]);
  });

  test('a phrase inside fenced or inline code does not fire', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]: `${frontmatter('opus')}\`\`\`\nthink carefully\n\`\`\`\n\nUse \`think hard\` here.\n`,
      },
    });

    expect(promptIds(report.findings, OPUS_AGENT)).toEqual([]);
  });

  test('a finding names the line of the match', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]: `${frontmatter('opus')}Intro.\n\nThink step by step.\n`,
      },
    });
    const finding = report.findings.find(
      (entry) => entry.rule_id === 'prompt.no-think-carefully'
    );

    expect(finding?.line).toBe(9);
  });

  test('the avoid-using-tools phrase fires despite holding a negative marker', () => {
    const report = checkProject({
      files: {
        [SONNET_SKILL]: `${frontmatter('sonnet')}Avoid using tools here.\n`,
      },
    });

    expect(promptIds(report.findings, SONNET_SKILL)).toEqual([
      'prompt.no-tool-discouragement',
    ]);
  });

  test('self-closing tags and tags with no closing form are not balance-checked', () => {
    const report = checkProject({
      files: {
        [UNPINNED_SKILL]: `${frontmatter(undefined)}Line<br>\n<hr/>\n<note>a</note>\n`,
      },
    });

    expect(promptIds(report.findings, UNPINNED_SKILL)).toEqual([]);
  });

  test('a stray closing tag is reported on its own line', () => {
    const report = checkProject({
      files: {
        [UNPINNED_SKILL]: `${frontmatter(undefined)}<note>a</note>\n</note>\n`,
      },
    });
    const finding = report.findings.find(
      (entry) => entry.rule_id === 'prompt.xml-tag-balance'
    );

    expect(finding?.line).toBe(7);
  });

  test('caps emphasis is read from the description and when_to_use only', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]:
          '---\nname: example\ndescription: Does a thing.\nwhen_to_use: |\n  Use it.\n  You MUST do so.\nmodel: opus\n---\n\nYou MUST read this.\n',
      },
    });
    const caps = report.findings.filter(
      (entry) => entry.rule_id === 'prompt.description-caps-emphasis'
    );

    expect(caps.map((entry) => entry.line)).toEqual([6]);
  });

  test('the forced-status cadence needs a status verb in the same sentence', () => {
    const report = checkProject({
      files: {
        [OPUS_AGENT]: `${frontmatter('opus')}Pause after 3 steps. Then summarize the result.\n`,
      },
    });

    expect(promptIds(report.findings, OPUS_AGENT)).toEqual([]);
  });
});
