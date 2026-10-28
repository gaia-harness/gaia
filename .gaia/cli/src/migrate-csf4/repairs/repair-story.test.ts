import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {createRequire} from 'node:module';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {readMigrationFixture, repoRoot} from './repairs-fixture.js';
import {
  capturePreCodemodFacts,
  classifyStoryFile,
  repairStoryFile,
} from './index.js';

const FILE = 'app/components/x/tests/index.stories.tsx';

const ASSIGNMENT = /^(\w+)(?:\.input)?\.(\w+) =/gmu;

const RELATIVE_PREVIEW_IMPORT = /from '\.\.?\/[^']*\.storybook\/preview'/u;

const repair = (codemodOutput: string, original: string) =>
  repairStoryFile(
    ts,
    codemodOutput,
    original,
    capturePreCodemodFacts(ts, original, FILE),
    FILE
  );

/** The property names of `export const <name> = meta.story({...})`. */
const storyKeys = (source: string, name: string): string[] | undefined => {
  const file = ts.createSourceFile(
    FILE,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  );

  const call = file.statements
    .filter((statement) => ts.isVariableStatement(statement))
    .flatMap((statement) => [...statement.declarationList.declarations])
    .find(
      (declaration) =>
        ts.isIdentifier(declaration.name) && declaration.name.text === name
    )?.initializer;

  if (
    !call ||
    !ts.isCallExpression(call) ||
    !ts.isPropertyAccessExpression(call.expression) ||
    call.expression.name.text !== 'story'
  ) {
    return undefined;
  }
  const [argument] = call.arguments;

  if (!argument || !ts.isObjectLiteralExpression(argument)) return [];

  return argument.properties.map((property) =>
    property.name && ts.isIdentifier(property.name) ? property.name.text : ''
  );
};

type LoadCsf = (
  code: string,
  options: {fileName: string; makeTitle: (title?: string) => string}
) => {parse: () => {_stories: Record<string, unknown>}};

/**
 * Storybook's own CSF indexer from the frontend package, or undefined where
 * the frontend's dependencies are not installed (the CLI-only CI install).
 */
const loadStorybookIndexer = async (): Promise<LoadCsf | undefined> => {
  try {
    const require = createRequire(path.join(repoRoot, 'frontend/package.json'));
    const modulePath = require.resolve('storybook/internal/csf-tools');
    const csfTools = (await import(pathToFileURL(modulePath).href)) as {
      loadCsf: LoadCsf;
    };

    return csfTools.loadCsf;
  } catch {
    return undefined;
  }
};

const storybookIndexer = await loadStorybookIndexer();

describe.each([
  'error-stack.stories.tsx',
  'composed-form.stories.tsx',
  'index-page.stories.tsx',
])('repairStoryFile on the codemod output of %s', (name) => {
  const original = readMigrationFixture(`${name}.csf3`);
  const codemodOutput = readMigrationFixture(`${name}.codemod`);
  const assignments = [...codemodOutput.matchAll(ASSIGNMENT)].map(
    ([, story, key]) => ({key: key ?? '', story: story ?? ''})
  );

  test('the fixture carries the silent-failure assignments', () => {
    expect(assignments.length).toBeGreaterThan(0);
  });

  test('folds every story assignment into its meta.story({...})', () => {
    const {notes, source} = repair(codemodOutput, original);

    expect(source).not.toMatch(ASSIGNMENT);

    for (const {key, story} of assignments) {
      expect(storyKeys(source, story)).toEqual(
        expect.arrayContaining(['render', key])
      );
    }
    expect(notes.length).toBeGreaterThan(0);
  });

  test('imports the preview through #.storybook/preview', () => {
    const {source} = repair(codemodOutput, original);

    expect(source).toContain(`import preview from '#.storybook/preview';`);
    expect(codemodOutput).toMatch(RELATIVE_PREVIEW_IMPORT);
    expect(source).not.toMatch(RELATIVE_PREVIEW_IMPORT);
    expect(classifyStoryFile(ts, source, FILE)).toBe('csf4');
  });

  test('feeding its own output back in changes nothing', () => {
    const {source} = repair(codemodOutput, original);
    const again = repair(source, original);

    expect(again.source).toBe(source);
    expect(again.notes).toEqual([]);
  });
});

describe('repairStoryFile', () => {
  test('restores custom args typing through preview.type<{args: X}>()', () => {
    const {source} = repair(
      readMigrationFixture('composed-form.stories.tsx.codemod'),
      readMigrationFixture('composed-form.stories.tsx.csf3')
    );

    expect(source).toContain(
      'const meta = preview.type<{args: StoryArgs}>().meta({'
    );
  });

  test('restores a leading comment the codemod dropped', () => {
    const original = `// Each story renders the page at one viewport.

import type {Meta, StoryFn} from '@storybook/react-vite';
import Page from '..';

const meta: Meta = {component: Page};

export default meta;

export const Default: StoryFn = () => <Page />;
`;
    const codemodOutput = `import preview from '../../../.storybook/preview';
import Page from '..';

const meta = preview.meta({component: Page});

export const Default = meta.story(() => <Page />);
`;

    const {source} = repair(codemodOutput, original);

    expect(
      source.startsWith(
        `// Each story renders the page at one viewport.\n\nimport preview from '#.storybook/preview';`
      )
    ).toBe(true);
    expect(repair(source, original).source).toBe(source);
  });

  test('deep-merges an assignment into a key the story already holds', () => {
    const original = `import type {Meta, StoryObj} from '@storybook/react-vite';

const meta: Meta = {title: 'X'};

export default meta;

export const Mobile: StoryObj = {parameters: {chromatic: {delay: 100}}};
`;
    const codemodOutput = `import preview from '#.storybook/preview';

const meta = preview.meta({title: 'X'});

export const Mobile = meta.story({parameters: {chromatic: {delay: 100}}});

Mobile.input.parameters = {chromatic: {modes: {mobile: {viewport: 375}}}, layout: 'centered'};
`;

    const {source} = repair(codemodOutput, original);

    expect(source).toBe(`import preview from '#.storybook/preview';

const meta = preview.meta({title: 'X'});

export const Mobile = meta.story({parameters: {chromatic: {delay: 100, modes: {mobile: {viewport: 375}}}, layout: 'centered'}});
`);
  });
});

describe('repairStoryFile on a factory-built story set the codemod skipped', () => {
  const original = readMigrationFixture('toast.stories.tsx.csf3');
  const facts = capturePreCodemodFacts(ts, original, FILE);
  const {notes, source} = repairStoryFile(ts, original, original, facts, FILE);

  test('converts the file to CSF4', () => {
    expect(classifyStoryFile(ts, source, FILE)).toBe('csf4');
    expect(source).toContain(`import preview from '#.storybook/preview';`);
    expect(source).toContain('const meta = preview.meta({');
    expect(source).not.toContain('export default');
    expect(source).not.toContain('StoryObj');
    expect(notes.length).toBeGreaterThan(0);
  });

  test('inlines each factory-built export into a direct meta.story({...})', () => {
    for (const name of facts.factoryExports) {
      expect(source).toMatch(
        new RegExp(String.raw`export const ${name} = meta\.story\(\{`, 'u')
      );
      expect(storyKeys(source, name)).toEqual(['play']);
    }
    expect(source).not.toContain('createTypeStory');
    expect(source).toContain(
      "toast.add({title: `error toast`, type: 'error'});"
    );
    expect(source).toContain(
      'await expectToast(canvasElement, `warning toast`);'
    );
  });

  test('keeps every story export under its own name', () => {
    for (const name of [
      'Default',
      'WithAction',
      'Loading',
      ...facts.factoryExports,
    ]) {
      expect(storyKeys(source, name)).toBeDefined();
    }
  });

  test.skipIf(storybookIndexer === undefined)(
    "Storybook's CSF indexer registers every export of the inlined file",
    () => {
      const indexed = storybookIndexer?.(source, {
        fileName: FILE,
        makeTitle: (title) => title ?? 'Untitled',
      }).parse();

      // eslint-disable-next-line no-underscore-dangle -- the indexer's own field name
      expect(Object.keys(indexed?._stories ?? {})).toEqual([
        'Default',
        'WithAction',
        'Loading',
        'ErrorType',
        'Info',
        'Success',
        'Warning',
      ]);
    }
  );

  test.skipIf(storybookIndexer === undefined)(
    'the same indexer drops an export a factory call still builds',
    () => {
      const factoryBuilt = source
        .replace(
          'export const Warning = meta.story({',
          'const warningStory = () =>\n  meta.story({'
        )
        .concat('\nexport const Warning = warningStory();\n');
      const indexed = storybookIndexer?.(factoryBuilt, {
        fileName: FILE,
        makeTitle: (title) => title ?? 'Untitled',
      }).parse();

      // eslint-disable-next-line no-underscore-dangle -- the indexer's own field name
      expect(Object.keys(indexed?._stories ?? {})).not.toContain('Warning');
    }
  );

  test('feeding its own output back in changes nothing', () => {
    const again = repairStoryFile(ts, source, original, facts, FILE);

    expect(again.source).toBe(source);
    expect(again.notes).toEqual([]);
  });
});

describe('repairStoryFile inlining a block-bodied factory with a default', () => {
  const original = `import type {Meta, StoryObj} from '@storybook/react-vite';
import Badge from '..';

const meta = {component: Badge} satisfies Meta<typeof Badge>;

export default meta;

type Story = StoryObj<typeof meta>;

function badgeStory(tone: string, label = 'New'): Story {
  return {args: {label, tone}};
}

export const Info: Story = badgeStory('info');

export const Warning: Story = badgeStory('warning', 'Careful');
`;
  const facts = capturePreCodemodFacts(ts, original, FILE);
  const {source} = repairStoryFile(ts, original, original, facts, FILE);

  test('substitutes each argument, the default included', () => {
    expect(facts.factoryExports).toEqual(['Info', 'Warning']);
    expect(source).toContain(
      `export const Info = meta.story({args: {label: 'New', tone: 'info'}});`
    );
    expect(source).toContain(
      `export const Warning = meta.story({args: {label: 'Careful', tone: 'warning'}});`
    );
    expect(source).not.toContain('badgeStory');
    expect(source).not.toContain('type Story');
    expect(classifyStoryFile(ts, source, FILE)).toBe('csf4');
  });
});
