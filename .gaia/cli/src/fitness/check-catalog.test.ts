import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {compareBytes} from './markdown.js';
import {ALL_FIXTURES} from './rules/fixtures.js';
import {runFitness} from './test-support.js';

type RuleListing = {
  applies_to: unknown;
  category: unknown;
  detection: unknown;
  inventory_only?: boolean;
  models?: unknown;
  rule_id: string;
  severity: unknown;
};

/** The catalog as published, hard-coded because the document that defines it is not tracked. */
const EXPECTED_RULE_IDS = [
  'authoring.content.time-sensitive',
  'authoring.path.windows-separator',
  'authoring.playbook.max-lines',
  'authoring.reference.depth.one-level',
  'authoring.reference.link.resolves',
  'authoring.reference.orphan',
  'authoring.reference.toc.required',
  'authoring.skill.body.max-lines',
  'authoring.skill.body.toc',
  'authoring.skill.description.first-person',
  'authoring.skill.description.no-when',
  'authoring.skill.description.second-person',
  'authoring.skill.description.too-short',
  'authoring.skill.name.vague',
  'claudemd.budget',
  'claudemd.dead-path',
  'claudemd.imports-resolve',
  'claudemd.missing-root',
  'claudemd.no-absolute-machine-path',
  'claudemd.path-outside-root',
  'frontmatter.name-collision',
  'frontmatter.parse',
  'frontmatter.skill.description.listing-truncation',
  'frontmatter.skill.description.max-length',
  'frontmatter.skill.description.non-empty',
  'frontmatter.skill.description.xml-tag',
  'frontmatter.skill.name.charset',
  'frontmatter.skill.name.max-length',
  'frontmatter.skill.name.present',
  'frontmatter.skill.name.reserved-word',
  'frontmatter.yaml-hazard',
  'hooks.event-name',
  'hooks.path-exists-executable',
  'hooks.rooted-command',
  'memory.dead-path',
  'prompt.description-caps-emphasis',
  'prompt.no-brief-updates',
  'prompt.no-dont-think',
  'prompt.no-explicit-double-check',
  'prompt.no-forced-interim-status',
  'prompt.no-if-in-doubt-tool',
  'prompt.no-reasoning-extraction',
  'prompt.no-think-carefully',
  'prompt.no-tool-discouragement',
  'prompt.xml-tag-balance',
  'rules.dead-path',
  'rules.glob-syntax',
  'rules.no-skill-import',
  'settings.env-secrets',
  'settings.fitness-config.no-reason',
  'settings.fitness-config.parse',
  'settings.fitness-config.stale',
  'settings.local-gitignored',
  'settings.redundant-permissions',
  'settings.valid-json',
  'wiki.dead-paths',
  'wiki.orphans',
];

const listing = async (): Promise<{listing: RuleListing[]; stdout: string}> => {
  const run = await runFitness(['rules', '--json']);

  expect(run.exitCode).toBe(0);

  return {listing: run.json as RuleListing[], stdout: run.stdout};
};

describe('gaia fitness rules', () => {
  test('prints byte-identical JSON on every run', async () => {
    const first = await listing();
    const second = await listing();

    expect(first.stdout.length).toBeGreaterThan(0);
    expect(second.stdout).toBe(first.stdout);
  });

  test('lists exactly the fixture map plus the one inventory-only rule', async () => {
    const {listing: rules} = await listing();
    const graded = rules.filter((rule) => rule.inventory_only !== true);
    const inventoryOnly = rules.filter((rule) => rule.inventory_only === true);

    expect(graded.map((rule) => rule.rule_id).toSorted(compareBytes)).toEqual(
      Object.keys(ALL_FIXTURES).toSorted(compareBytes)
    );
    expect(inventoryOnly.map((rule) => rule.rule_id)).toEqual([
      'memory.dead-path',
    ]);
    expect(rules.map((rule) => rule.rule_id)).toEqual(
      rules.map((rule) => rule.rule_id).toSorted(compareBytes)
    );
    expect(rules.map((rule) => rule.rule_id)).toEqual(EXPECTED_RULE_IDS);
  });

  test('gives every rule its identity fields and every prompt rule its models', async () => {
    const {listing: rules} = await listing();

    expect(rules.length).toBeGreaterThan(0);

    const problems = rules.flatMap((rule) => {
      const category = rule.rule_id.split('.', 1)[0];
      const detection =
        typeof rule.detection === 'string' ? rule.detection : '';
      const hasModels = Array.isArray(rule.models) && rule.models.length > 0;

      return [
        rule.category === category ? [] : [`${rule.rule_id}: category`],
        ['error', 'info', 'warning'].includes(String(rule.severity)) ?
          []
        : [`${rule.rule_id}: severity`],
        Array.isArray(rule.applies_to) ? [] : [`${rule.rule_id}: applies_to`],
        detection !== '' && !detection.includes('\n') ?
          []
        : [`${rule.rule_id}: detection`],
        (category === 'prompt') === hasModels ?
          []
        : [`${rule.rule_id}: models`],
        category !== 'prompt' && rule.models !== undefined ?
          [`${rule.rule_id}: unexpected models`]
        : [],
      ].flat();
    });

    expect(problems).toEqual([]);
  });
});

const FITNESS_DIRECTORY = path.dirname(new URL(import.meta.url).pathname);

const isTestOrSnapshot = (relative: string): boolean =>
  relative.endsWith('.test.ts') || relative.includes('__snapshots__');

/** Every non-test `.ts` file under the fitness directory, as paths relative to it. */
const productionSourceFiles = (): string[] => {
  const collected: string[] = [];

  const walk = (directory: string): void => {
    for (const entry of readdirSync(directory, {withFileTypes: true})) {
      const absolute = path.join(directory, entry.name);
      const relative = path.relative(FITNESS_DIRECTORY, absolute);

      if (entry.isDirectory()) walk(absolute);
      else if (relative.endsWith('.ts') && !isTestOrSnapshot(relative)) {
        collected.push(relative);
      }
    }
  };

  walk(FITNESS_DIRECTORY);

  return collected.toSorted(compareBytes);
};

/** Every string-literal value in a TypeScript source text. */
const stringLiterals = (source: string): string[] => {
  const literals: string[] = [];
  const file = ts.createSourceFile(
    'scan.ts',
    source,
    ts.ScriptTarget.Latest,
    true
  );

  const visit = (node: ts.Node): void => {
    if (
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      ts.isTemplateHead(node) ||
      ts.isTemplateMiddle(node) ||
      ts.isTemplateTail(node)
    ) {
      literals.push(node.text);
    }
    ts.forEachChild(node, visit);
  };

  visit(file);

  return literals;
};

const STATUSLINE_TOKEN = 'gaia-statusline';

/** Literals that equal or start with a forbidden path, or name the statusline. */
const forbiddenLiterals = (
  source: string,
  forbiddenPaths: readonly string[]
): string[] =>
  stringLiterals(source).filter(
    (literal) =>
      literal.includes(STATUSLINE_TOKEN) ||
      forbiddenPaths.some((forbidden) => literal.startsWith(forbidden))
  );

const ownedHarnessPaths = (): string[] => {
  const root = resolveRepoRootFromImportMeta(import.meta.url);
  const manifest = JSON.parse(
    readFileSync(path.join(root, '.gaia/manifest.json'), 'utf8')
  ) as {files: Record<string, unknown>};

  return Object.entries(manifest.files)
    .filter(
      ([relative, ownership]) =>
        ownership === 'owned' &&
        ['.claude/', 'frontend/.claude/', 'wiki/'].some((prefix) =>
          relative.startsWith(prefix)
        )
    )
    .map(([relative]) => relative);
};

describe('the fitness sources', () => {
  test('hold no literal naming a file GAIA ships or the statusline', () => {
    const forbidden = ownedHarnessPaths();
    const sources = productionSourceFiles();

    expect(forbidden.length).toBeGreaterThan(50);
    expect(sources).toEqual(
      expect.arrayContaining([
        'check.ts',
        'rules/hooks.fixtures.ts',
        'test-support.ts',
      ])
    );

    const offenders = sources.flatMap((relative) =>
      forbiddenLiterals(
        readFileSync(path.join(FITNESS_DIRECTORY, relative), 'utf8'),
        forbidden
      ).map((literal) => `${relative}: ${literal}`)
    );

    expect(offenders).toEqual([]);
  });

  test('the scan flags a shipped path, a prefix of one and the statusline token', () => {
    const [shipped] = ownedHarnessPaths();

    expect(shipped).toBeDefined();
    expect(
      forbiddenLiterals(`const a = '${shipped ?? ''}';`, ownedHarnessPaths())
    ).toEqual([shipped]);
    expect(
      forbiddenLiterals(`const a = \`${shipped ?? ''}/more\`;`, [shipped ?? ''])
    ).toHaveLength(1);
    expect(
      forbiddenLiterals(`const a = 'my-gaia-statusline.sh';`, [])
    ).toHaveLength(1);
    expect(
      forbiddenLiterals(
        `const a = '.claude/hooks/example.sh';`,
        ownedHarnessPaths()
      )
    ).toEqual([]);
  });
});
