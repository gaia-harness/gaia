/**
 * Strategy: invoke `run` with `--parent` pointing into a temp tree, so the
 * handler renders from the shipped templates directory. We assert
 * on stdout (captured), the produced filesystem contents, and the exit
 * codes.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run} from './component.js';
import {csf4Violations} from './story-shape-fixture.js';

type Sandbox = {
  cleanup: () => void;
  parent: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-component-'));
  const parent = path.join(root, 'app', 'components');
  mkdirSync(parent, {recursive: true});
  writeFrontendRegistry(root);

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    parent,
    root,
  };
};

type StdioCapture = {
  errors: string[];
  outputs: string[];
  restore: () => void;
};

const captureStdio = (): StdioCapture => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

const makeUiTree = (root: string): void => {
  mkdirSync(path.join(root, 'app', 'components', 'ui', 'x'), {
    recursive: true,
  });
};

const makeOtherFolders = (root: string): void => {
  mkdirSync(path.join(root, 'app', 'services'), {recursive: true});
  mkdirSync(path.join(root, 'app', 'pages'), {recursive: true});
};

describe('scaffold component', () => {
  let sandbox: Sandbox;
  let stdio: StdioCapture;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('default invocation produces the component and its story, no test file', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const indexPath = path.join(sandbox.parent, 'foo', 'index.tsx');
    const testPath = path.join(
      sandbox.parent,
      'foo',
      'tests',
      'index.test.tsx'
    );
    const storyPath = path.join(
      sandbox.parent,
      'foo',
      'tests',
      'index.stories.tsx'
    );

    const indexContents = read(indexPath);
    expect(indexContents).not.toMatch(/\bFC\b/);
    expect(indexContents.startsWith('\n')).toBe(false);
    expect(indexContents).toContain('const Foo = () => (');
    expect(indexContents).toContain('<section aria-label="Foo">');
    expect(indexContents).toContain('export default Foo;');
    expect(indexContents).not.toContain('FooProps');

    expect(existsSync(testPath)).toBe(false);

    const storyContents = read(storyPath);
    expect(storyContents).toContain("import Foo from '..';");
    expect(storyContents).toContain("import {expect} from 'storybook/test';");
    expect(storyContents).toContain(
      "import preview from '#.storybook/preview';"
    );
    expect(csf4Violations(storyContents)).toEqual([]);
    expect(storyContents).toContain("title: 'Components/Foo',");
    expect(storyContents).toContain('export const Default = meta.story({');
    expect(storyContents).toContain('render: () => <Foo />,');
    expect(storyContents).toContain('export const Renders = meta.story({');
    expect(storyContents).toContain('Renders.test(');
    expect(storyContents).not.toContain('.play');
    expect(storyContents).toContain("getByRole('region', {name: 'Foo'})");
  });

  describe('component refuses a bad invocation and writes nothing', () => {
    test.each([
      {
        args: ['Bar', '--parent', 'app/components', '--no-story'],
        errorContains: [
          '--no-story is not supported',
          "the story is the component's test",
        ],
        name: '--no-story is refused: exit 1, nothing written, the story named as the test',
      },
      {
        args: ['price_tag', '--parent', 'app/components'],
        errorContains: ['kebab-case', 'PascalCase'],
        name: 'a name in neither accepted form exits 1 and names both forms',
      },
      {
        args: ['Foo', '--parent', 'app/components/missing'],
        errorContains: ['parent dir does not exist'],
        name: 'non-existent parent dir exits 1',
      },
      {
        args: ['Foo', '--parent', 'app/components', '--props', 'oops'],
        errorContains: ['--props entry must be name:type'],
        name: 'malformed --props entry exits 1',
      },
    ])('$name', ({args, errorContains}) => {
      expect(run(args, {cwd: sandbox.root})).toBe(1);

      const errorLine = stdio.errors.join('');

      for (const fragment of errorContains) {
        expect(errorLine).toContain(fragment);
      }
      expect(readdirSync(sandbox.parent)).toEqual([]);
    });
  });

  test('--props renders a typed Props alias and destructured signature', () => {
    const exit = run(
      [
        'Card',
        '--parent',
        'app/components',
        '--props',
        'title:string,count:number',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(path.join(sandbox.parent, 'card', 'index.tsx'));
    expect(indexContents).toContain('type CardProps = {');
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  count: number;');
    expect(indexContents).not.toMatch(/\bFC\b/);
    expect(indexContents.startsWith('\n')).toBe(false);
    expect(indexContents).toContain(
      'const Card = ({title, count}: CardProps) => ('
    );
  });

  test('--props story Default renders a non-degenerate instance with representative prop values', () => {
    const exit = run(
      [
        'Card',
        '--parent',
        'app/components',
        '--props',
        'title:string,count:number',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'card', 'tests', 'index.stories.tsx')
    );
    // Default must carry representative props, not a bare `<Card />`, so the
    // accessibility check renders against a real DOM and can fail.
    expect(storyContents).toContain('export const Default = meta.story({');
    expect(csf4Violations(storyContents)).toEqual([]);
    expect(storyContents).toContain('title="title"');
    expect(storyContents).toContain('count={0}');
    expect(storyContents).not.toContain('<Card />');

    // The tested story renders the same representative instance.
    expect(storyContents).toContain('export const Renders = meta.story({');
    expect(storyContents.match(/title="title"/g)).toHaveLength(2);
    expect(
      existsSync(path.join(sandbox.parent, 'card', 'tests', 'index.test.tsx'))
    ).toBe(false);
  });

  test('the play story carries a starting-point caveat comment', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'foo', 'tests', 'index.stories.tsx')
    );
    // The render check is a starting point, not complete evidence.
    expect(storyContents.toLowerCase()).toContain('starting point');
  });

  test('--json emits a single JSON line matching ScaffoldResult', () => {
    const exit = run(['Foo', '--parent', 'app/components', '--json'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    const out = stdio.outputs.join('');
    const parsed = JSON.parse(out.trim()) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };
    expect(parsed.edited).toEqual([]);
    expect(parsed.written).toHaveLength(2);
    expect(parsed.skipped).toEqual([]);
  });

  describe('component re-run is a no-op or refuses a conflict', () => {
    test.each([
      {
        changeBetween: (): void => undefined,
        code: 0,
        name: 're-running with the same args is a no-op (skipped)',
        secondArgs: ['Foo', '--parent', 'app/components', '--json'],
        stderr: [] as string[],
        stdout: [/"skipped":\["[^"]+","[^"]+"\]/u, /"written":\[\]/u],
      },
      {
        changeBetween: (indexPath: string): void => {
          writeFileSync(
            indexPath,
            `${read(indexPath)}\n// user customization\n`,
            'utf8'
          );
        },
        code: 1,
        name: 're-running with conflicting contents exits 1',
        secondArgs: ['Foo', '--parent', 'app/components'],
        stderr: ['refusing to overwrite'],
        stdout: [] as RegExp[],
      },
    ])('$name', ({changeBetween, code, secondArgs, stderr, stdout}) => {
      expect(
        run(['Foo', '--parent', 'app/components'], {cwd: sandbox.root})
      ).toBe(0);

      changeBetween(path.join(sandbox.parent, 'foo', 'index.tsx'));

      expect(run(secondArgs, {cwd: sandbox.root})).toBe(code);

      for (const pattern of stdout) {
        expect(stdio.outputs.at(-1) ?? '').toMatch(pattern);
      }

      for (const fragment of stderr) {
        expect(stdio.errors.join('')).toContain(fragment);
      }
    });
  });

  test('story title respects nested parent dir', () => {
    mkdirSync(path.join(sandbox.parent, 'form'), {recursive: true});

    const exit = run(['Field', '--parent', 'app/components/form'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'form', 'field', 'tests', 'index.stories.tsx')
    );
    expect(storyContents).toContain("title: 'Components/Form/Field',");
  });

  describe('component naming resolves the folder and export for each name form', () => {
    test.each([
      {
        code: 0,
        contains: {
          'price-tag/index.tsx': [
            'const PriceTag = () => (',
            'export default PriceTag;',
          ],
          'price-tag/tests/index.stories.tsx': [
            "title: 'Components/PriceTag',",
          ],
        },
        input: 'price-tag',
        listing: ['price-tag'],
        name: 'a kebab name exports the PascalCase form into the kebab folder',
        stderr: [] as string[],
      },
      {
        code: 0,
        contains: {'price-badge/index.tsx': ['export default PriceBadge;']},
        input: 'PriceBadge',
        listing: ['price-badge'],
        name: 'a PascalCase name exports as given into the kebab folder',
        stderr: [] as string[],
      },
      {
        code: 0,
        contains: {'html-view/index.tsx': ['export default HTMLView;']},
        input: 'HTMLView',
        listing: ['html-view'],
        name: 'an acronym PascalCase name gets the folder lodash kebabCase gives',
        stderr: [] as string[],
      },
      {
        code: 0,
        contains: {'heading-2/index.tsx': ['export default Heading2;']},
        input: 'Heading2',
        listing: ['heading-2'],
        name: 'a PascalCase name with a digit gets a digit-split folder',
        stderr: [] as string[],
      },
      ...['heading2', 'item2-card', 'h1-title'].map((digitName) => ({
        code: 1,
        contains: {},
        input: digitName,
        listing: [] as string[],
        name: `the digit-bearing kebab name ${digitName} refuses and writes nothing`,
        stderr: ['the folder the linter expects'],
      })),
      {
        code: 1,
        contains: {},
        input: 'heading2',
        listing: [] as string[],
        name: 'the heading2 refusal names the folder the linter expects',
        stderr: [String.raw`must be \"heading-2\"`],
      },
      ...['price_tag', 'Price-Tag', '2fast', 'price-', 'priceTag'].map(
        (invalidName) => ({
          code: 1,
          contains: {},
          input: invalidName,
          listing: [] as string[],
          name: `the invalid name ${invalidName} refuses and writes nothing`,
          stderr: ['PascalCase'],
        })
      ),
    ])('$name', ({code, contains, input, listing, stderr}) => {
      expect(run([input], {cwd: sandbox.root})).toBe(code);

      expect(readdirSync(sandbox.parent)).toEqual(listing);

      for (const [file, fragments] of Object.entries(contains)) {
        for (const fragment of fragments) {
          expect(read(path.join(sandbox.parent, file))).toContain(fragment);
        }
      }

      for (const fragment of stderr) {
        expect(stdio.errors.join('')).toContain(fragment);
      }
    });
  });

  describe('component --parent resolves the target folder and refuses a missing ui parent', () => {
    test.each([
      {
        absent: [] as string[],
        code: 0,
        componentName: 'promo-banner',
        contains: {
          'app/pages/index/promo-banner/index.tsx': [
            'export default PromoBanner;',
          ],
          'app/pages/index/promo-banner/tests/index.stories.tsx': [
            "title: 'Pages/Index/PromoBanner',",
          ],
        },
        listings: {},
        name: 'a pages parent writes under the page folder with a Pages title',
        parent: 'app/pages/index',
        setup: (root: string): void => {
          mkdirSync(path.join(root, 'app', 'pages', 'index'), {
            recursive: true,
          });
        },
        stderr: [] as string[],
      },
      ...['app/components/ui', 'app/components/ui/x', 'app/components/ui/'].map(
        (uiParent) => ({
          absent: [] as string[],
          code: 1,
          componentName: 'probe',
          contains: {},
          listings: {
            'app/components/ui': ['x'],
            'app/components/ui/x': [],
          },
          name: `the ui parent ${uiParent} refuses and creates nothing`,
          parent: uiParent,
          setup: makeUiTree,
          stderr: ['shadcn'],
        })
      ),
      {
        absent: ['app/components/ui'],
        code: 1,
        componentName: 'probe',
        contains: {},
        listings: {},
        name: 'a ui parent that does not exist is not created',
        parent: 'app/components/ui',
        setup: (): void => undefined,
        stderr: [] as string[],
      },
      ...[
        'app/services',
        'app',
        'app/pages',
        'app/components/../services',
        'app/components/../components/ui',
        '../outside',
      ].map((outsideParent) => ({
        absent: [] as string[],
        code: 1,
        componentName: 'probe',
        contains: {},
        listings: {'app/components': []},
        name: `the parent ${outsideParent} outside the allowed folders refuses`,
        parent: outsideParent,
        setup: makeOtherFolders,
        stderr: ['--parent'],
      })),
    ])(
      '$name',
      ({
        absent,
        code,
        componentName,
        contains,
        listings,
        parent,
        setup,
        stderr,
      }) => {
        setup(sandbox.root);

        expect(
          run([componentName, '--parent', parent], {cwd: sandbox.root})
        ).toBe(code);

        for (const fragment of stderr) {
          expect(stdio.errors.join('')).toContain(fragment);
        }

        for (const [file, fragments] of Object.entries(contains)) {
          for (const fragment of fragments) {
            expect(read(path.join(sandbox.root, file))).toContain(fragment);
          }
        }

        for (const [directory, entries] of Object.entries(listings)) {
          expect(readdirSync(path.join(sandbox.root, directory))).toEqual(
            entries
          );
        }

        for (const file of absent) {
          expect(existsSync(path.join(sandbox.root, file))).toBe(false);
        }
      }
    );
  });

  describe('component --props parses each prop type', () => {
    test.each([
      {
        componentName: 'Widget',
        indexContains: [
          'type WidgetProps = {',
          '  meta: Record<string, unknown>;',
          'const Widget = ({meta}: WidgetProps) => (',
        ],
        name: 'comma-bearing Record type scaffolds a single prop with the full type',
        props: 'meta:Record<string, unknown>',
        storyContains: [] as string[],
        storyExcludes: [] as string[],
      },
      {
        componentName: 'Pair',
        indexContains: [
          '  pair: [string, number];',
          'const Pair = ({pair}: PairProps) => (',
        ],
        name: 'comma-bearing tuple type scaffolds a single prop with the full type',
        props: 'pair:[string, number]',
        storyContains: [] as string[],
        storyExcludes: [] as string[],
      },
      {
        componentName: 'Card',
        indexContains: [
          '  title: string;',
          '  meta: Record<string, unknown>;',
          'const Card = ({title, meta}: CardProps) => (',
        ],
        name: 'a plain prop and a comma-bearing prop separate into two props',
        props: 'title:string,meta:Record<string, unknown>',
        storyContains: [] as string[],
        storyExcludes: [] as string[],
      },
      {
        componentName: 'Picker',
        indexContains: [
          '  onSelect: (id: string, ev: Event) => void;',
          'const Picker = ({onSelect}: PickerProps) => (',
        ],
        name: 'multi-arg function prop scaffolds one prop with a callable no-op fallback',
        props: 'onSelect:(id: string, ev: Event) => void',
        // The story attribute must be a CALLABLE no-op cast, so wiring the
        // prop into the render body survives being invoked with arguments.
        storyContains: [
          'onSelect={(() => undefined) as (id: string, ev: Event) => void}',
        ],
        storyExcludes: ['onSelect={{} as'],
      },
      {
        componentName: 'Clicker',
        indexContains: [] as string[],
        name: 'single-arg function prop scaffolds with a callable no-op fallback (not {} as)',
        props: 'onClick:() => void',
        storyContains: ['onClick={(() => undefined) as () => void}'],
        storyExcludes: ['onClick={{} as'],
      },
    ])(
      '$name',
      ({componentName, indexContains, props, storyContains, storyExcludes}) => {
        const exit = run(
          [componentName, '--parent', 'app/components', '--props', props],
          {cwd: sandbox.root}
        );

        expect(exit).toBe(0);

        const folder = path.join(sandbox.parent, componentName.toLowerCase());
        const indexContents = read(path.join(folder, 'index.tsx'));

        for (const fragment of indexContains) {
          expect(indexContents).toContain(fragment);
        }

        const storyContents = read(
          path.join(folder, 'tests', 'index.stories.tsx')
        );

        for (const fragment of storyContains) {
          expect(storyContents).toContain(fragment);
        }

        for (const fragment of storyExcludes) {
          expect(storyContents).not.toContain(fragment);
        }
      }
    );
  });
});
