/**
 * Pins the title handling of the RED-ledger signal helper
 * (`.gaia/scripts/red-ledger/extract-test-signals.mjs`): a dynamic-title
 * `test`, or anything under a dynamic-title `describe`, has no source title
 * vitest preserves verbatim at runtime, so the helper emits nothing for it
 * rather than an identity the RED ledger could never match. A test under a
 * `.each`/`.for` table, at test or describe level, is named by its template
 * plus a row pattern.
 */
import {describe, expect, test} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const SIGNAL_HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/red-ledger/extract-test-signals.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The GAIA: CLI Tests workflow installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd script resolves
// typescript whether or not the repo root is installed.
const CLI_NODE_MODULES = path.join(REPO_ROOT, '.gaia/cli/node_modules');
const HELPER_ENV = {...process.env, NODE_PATH: CLI_NODE_MODULES};

const TEST_FILE_REL = 'apps/web/app/generated/tests/index.test.ts';

type ExtractedSignal = {
  fullName: string;
  kind: string;
  rowPattern?: string;
  signal: string;
};

const runOnSource = (source: string): ExtractedSignal[] =>
  execFileSync('node', [SIGNAL_HELPER, TEST_FILE_REL, '--stdin'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  })
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as ExtractedSignal);

/**
 * A test under a `.each`/`.for` table is one test owing one RED: the helper
 * names it by its declared template and adds a `rowPattern` that matches every
 * fullName vitest can expand a row into, so the capture hook can file a
 * failing row's RED under the template.
 */
const rowEntry = (source: string): ExtractedSignal => {
  const lines = runOnSource(source);
  expect(lines).toHaveLength(1);
  const [entry] = lines;

  if (entry?.rowPattern === undefined) {
    throw new Error('expected a rowPattern entry');
  }

  return entry;
};

const matchesRow = (entry: ExtractedSignal, rowName: string) =>
  new RegExp(entry.rowPattern ?? '(?!)').test(rowName);

describe('extract-test-signals test-level .each/.for rows', () => {
  test.for([
    {
      call: "test.each([{from: '/en', to: '/'}])",
      row: '301s /en to /',
      template: '301s $from to $to',
    },
    {
      call: "test.each([['a', 'b']])",
      row: 'converts a to b',
      template: 'converts %s to %s',
    },
    {call: 'it.each([{n: 1}])', row: 'handles 1', template: 'handles $n'},
    {
      call: "test.for([{from: '/en', to: '/'}])",
      row: '301s /en to /',
      template: '301s $from to $to',
    },
    {
      call: "test.for([{user: {name: 'ann'}}])",
      row: 'signs in as ann (row 1)',
      template: 'signs in as $user.name (row %$)',
    },
  ])(
    '$call names the test $template and matches its row',
    ({call, row, template}) => {
      const entry = rowEntry(`
      ${call}('${template}', (value) => {
        expect(value).toBeTruthy();
      });
    `);

      expect(entry.fullName).toBe(template);
      expect(entry.kind).toBe('runtime');
      expect(matchesRow(entry, row)).toBe(true);
      expect(matchesRow(entry, `other ${row}`)).toBe(false);
    }
  );

  test('a tagged-template test.each is one entry whose pattern matches its rows', () => {
    const entry = rowEntry(`
      test.each\`
        a    | b
        \${1} | \${2}
      \`('sums $a and $b', ({a, b}) => {
        expect(a + b).toBeGreaterThan(0);
      });
    `);

    expect(entry.fullName).toBe('sums $a and $b');
    expect(matchesRow(entry, 'sums 1 and 2')).toBe(true);
  });

  test('the describe prefix and regex metacharacters in the title are matched literally', () => {
    const entry = rowEntry(`
      describe('form body', () => {
        test.for([{field: 'email'}])('rejects (blank) $field + more', ({field}) => {
          expect(field).toBeTruthy();
        });
      });
    `);

    expect(entry.fullName).toBe('form body rejects (blank) $field + more');
    expect(matchesRow(entry, 'form body rejects (blank) email + more')).toBe(
      true
    );
    expect(matchesRow(entry, 'form body rejects blank email + more')).toBe(
      false
    );
    expect(matchesRow(entry, 'rejects (blank) email + more')).toBe(false);
  });

  test('a substitution-free title is matched verbatim', () => {
    const entry = rowEntry(`
      test.each([1, 2])('fixed title', (n) => {
        expect(n).toBeGreaterThan(0);
      });
    `);

    expect(entry.fullName).toBe('fixed title');
    expect(matchesRow(entry, 'fixed title')).toBe(true);
    expect(matchesRow(entry, 'fixed title 2')).toBe(false);
  });

  test('a title that is only tokens emits nothing: its pattern would match any sibling', () => {
    const lines = runOnSource(`
      describe('sign in', () => {
        test.for([{name: 'ann'}])('$name', ({name}) => {
          expect(name).toBeTruthy();
        });
      });
    `);

    expect(lines).toEqual([]);
  });
});

const describeTableSource = (group: string) => `
  describe.each([{group: '${group}'}])('group $group', ({group}) => {
    test('does the static thing', () => {
      expect(group).toBeTruthy();
    });
  });
`;

describe('extract-test-signals describe-level .each/.for rows', () => {
  test.for([
    {call: "describe.each([{group: 'a'}])", template: 'group $group'},
    {call: "describe.for([{group: 'a'}])", template: 'group $group'},
    {call: "describe.each([['a']])", template: '%s group'},
  ])(
    '$call names a nested test by its template and matches its row',
    ({call, template}) => {
      const entry = rowEntry(`
      ${call}('${template}', (group) => {
        test('does the static thing', () => {
          expect(group).toBeTruthy();
        });
      });
    `);
      const row = `${template.replace(/\$group|%s/, 'a')} does the static thing`;

      expect(entry.fullName).toBe(`${template} does the static thing`);
      expect(matchesRow(entry, row)).toBe(true);
      expect(matchesRow(entry, `${row} later`)).toBe(false);
    }
  );

  test('a tagged-template describe.each names a nested test by its template', () => {
    const entry = rowEntry(`
      describe.each\`
        group
        \${'a'}
      \`('group $group', ({group}) => {
        test('does the static thing', () => {
          expect(group).toBeTruthy();
        });
      });
    `);

    expect(entry.fullName).toBe('group $group does the static thing');
    expect(matchesRow(entry, 'group a does the static thing')).toBe(true);
  });

  test('every title on the path joins the pattern, however deep the tables nest', () => {
    const entry = rowEntry(`
      describe('form', () => {
        describe.each([{group: 'a'}])('group $group', () => {
          describe('inner', () => {
            test.each([1])('counts %s', (count) => {
              expect(count).toBe(1);
            });
          });
        });
      });
    `);

    expect(entry.fullName).toBe('form group $group inner counts %s');
    expect(matchesRow(entry, 'form group a inner counts 1')).toBe(true);
    expect(matchesRow(entry, 'form group a counts 1')).toBe(false);
  });

  test('editing the describe table changes the nested test signal', () => {
    expect(rowEntry(describeTableSource('a')).signal).not.toBe(
      rowEntry(describeTableSource('b')).signal
    );
  });

  test('a test under a describe table with no literal text past the first token emits nothing', () => {
    const lines = runOnSource(`
      describe.each([{group: 'a'}])('$group', () => {
        test.each([1])('%s', (count) => {
          expect(count).toBe(1);
        });
      });
    `);

    expect(lines).toEqual([]);
  });

  test('a plain static test still emits a signal (regression guard)', () => {
    const lines = runOnSource(`
      test('adds numbers', () => {
        expect(1 + 1).toBe(2);
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('adds numbers');
    expect(lines[0]?.kind).toBe('runtime');
  });
});

/**
 * Pins the dynamic-title describe carve-out: a describe whose title is a
 * template literal with a substitution is computed at runtime, so the declared
 * source title is never the prefix vitest records, and no row pattern can
 * stand in for it. `titleOf` returns null for it; this suite pins that the
 * null makes the whole subtree unmatchable, so descendants never emit under a
 * silently shortened prefix.
 */
describe('extract-test-signals dynamic-title describe handling', () => {
  test('a template-literal-titled describe emits no signal for a nested static test', () => {
    const lines = runOnSource(`
      const x = 1;
      describe(\`group \${x}\`, () => {
        test('does the thing', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toEqual([]);
  });

  test('a nested dynamic-title describe suppresses only its own subtree', () => {
    const lines = runOnSource(`
      const x = 1;
      describe('outer', () => {
        test('static sibling', () => {
          expect(1).toBe(1);
        });
        describe(\`inner \${x}\`, () => {
          test('nested', () => {
            expect(1).toBe(1);
          });
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer static sibling');
  });

  test('a static describe with a static test still emits fullName (regression guard)', () => {
    const lines = runOnSource(`
      describe('outer', () => {
        test('inner', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer inner');
  });

  test('a dynamic-title test inside a static describe suppresses only itself (regression guard)', () => {
    const lines = runOnSource(`
      const x = 1;
      describe('outer', () => {
        test(\`dynamic \${x}\`, () => {
          expect(1).toBe(1);
        });
        test('static sibling', () => {
          expect(1).toBe(1);
        });
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]?.fullName).toBe('outer static sibling');
  });
});

/**
 * Story mode: a `*.stories.tsx` path is read as a CSF4 story file. A story
 * with `.test()` calls is a describe block of a `base story` test plus one test
 * per call; a story with an effective play and no tests is one test. The
 * helper names each the way Storybook's Vitest run does, refuses (exit 7,
 * empty stdout) any shape it cannot resolve, and refuses an older story format
 * (exit 8) with the migration command: a silent empty result would let the
 * worthiness gate pass the file unjudged.
 */
const STORY_FILE_REL = 'apps/web/app/generated/tests/index.stories.tsx';

const runStory = (source: string) => {
  const result = spawnSync('node', [SIGNAL_HELPER, STORY_FILE_REL, '--stdin'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  });

  return {
    lines: result.stdout
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as ExtractedSignal),
    status: result.status,
    stderr: result.stderr,
    stdout: result.stdout,
  };
};

const storyLines = (source: string): ExtractedSignal[] => {
  const result = runStory(source);

  expect(result.stderr).toBe('');
  expect(result.status).toBe(0);

  return result.lines;
};

const namesOf = (lines: ExtractedSignal[]) =>
  lines.map((line) => line.fullName);

const signalOf = (lines: ExtractedSignal[], fullName: string) =>
  lines.find((line) => line.fullName === fullName)?.signal;

const PREVIEW_IMPORT = `import preview from '#.storybook/preview';`;

const META = `
  ${PREVIEW_IMPORT}
  const meta = preview.meta({component: Widget, args: {size: 'small'}, title: 'Widget'});
`;

describe('extract-test-signals story mode: names', () => {
  test('a story with a play emits one runtime line named by start-casing the export', () => {
    const lines = storyLines(`${META}
      export const LongStoryName = meta.story({
        play: async () => {
          await drive();
        },
      });
    `);

    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({
      fullName: 'Long Story Name',
      kind: 'runtime',
    });
    expect(lines[0]?.signal).toMatch(/^sha256:[0-9a-f]{64}$/);
  });

  test('a digit in the export name is split the way Storybook splits it', () => {
    const lines = storyLines(`${META}
      export const Step2Done = meta.story({play: async () => drive()});
    `);

    expect(namesOf(lines)).toEqual(['Step 2 Done']);
  });

  test('a string-literal name in the story argument overrides the export name', () => {
    const lines = storyLines(`${META}
      export const Renamed = meta.story({name: 'Custom', play: async () => drive()});
    `);

    expect(namesOf(lines)).toEqual(['Custom']);
  });

  test('a story with tests emits base story then each test, joined by three spaces', () => {
    const lines = storyLines(`${META}
      export const Default = meta.story({play: async () => drive()});
      Default.test('shows the label', async () => check());
      Default.test('hides the hint', async () => check());
    `);

    expect(namesOf(lines)).toEqual([
      'Default   base story',
      'Default   shows the label',
      'Default   hides the hint',
    ]);
  });

  test('a render-only story with a test still emits its base story', () => {
    const lines = storyLines(`${META}
      export const Plain = meta.story({args: {size: 'large'}});
      Plain.test('renders large', async () => check());
    `);

    expect(namesOf(lines)).toEqual([
      'Plain   base story',
      'Plain   renders large',
    ]);
  });

  test('a test with an overrides argument is named by its first argument', () => {
    const lines = storyLines(`${META}
      export const Plain = meta.story({});
      Plain.test('with overrides', {parameters: {a11y: {test: 'off'}}}, async () => check());
    `);

    expect(namesOf(lines)).toEqual([
      'Plain   base story',
      'Plain   with overrides',
    ]);
  });

  test('a render-only story without tests emits nothing', () => {
    expect(
      storyLines(`${META}
        export const Default = meta.story({args: {size: 'large'}});
        export const Rendered = meta.story(() => <Widget />);
        export const Bare = meta.story();
      `)
    ).toEqual([]);
  });

  test('an extend story is named by its own export, never by the source name', () => {
    const lines = storyLines(`${META}
      export const Source = meta.story({name: 'Source Display', play: async () => drive()});
      export const Variant = Source.extend({args: {size: 'large'}});
      export const Relabeled = Source.extend({name: 'Own Label'});
    `);

    expect(namesOf(lines)).toEqual(['Source Display', 'Variant', 'Own Label']);
  });

  test('tests on an extend story are named under the extend story', () => {
    const lines = storyLines(`${META}
      export const Source = meta.story({});
      export const Variant = Source.extend({args: {size: 'large'}});
      Variant.test('is large', async () => check());
    `);

    expect(namesOf(lines)).toEqual([
      'Variant   base story',
      'Variant   is large',
    ]);
  });
});

describe('extract-test-signals story mode: effective play', () => {
  test('a meta play makes every story without its own play a test', () => {
    const lines = storyLines(`${PREVIEW_IMPORT}
      const meta = preview.meta({component: Widget, play: async () => drive(), title: 'Widget'});
      export const Plain = meta.story({});
      export const Rendered = meta.story(() => <Widget />);
    `);

    expect(namesOf(lines)).toEqual(['Plain', 'Rendered']);
  });

  test('an extend story without its own play inherits the source play', () => {
    const lines = storyLines(`${META}
      const Hidden = meta.story({play: async () => drive()});
      export const Variant = Hidden.extend({args: {size: 'large'}});
    `);

    expect(namesOf(lines)).toEqual(['Variant']);
  });

  test('an extend play set to undefined overrides the source play and falls through to the meta, here absent', () => {
    expect(
      storyLines(`${META}
        const Hidden = meta.story({play: async () => drive()});
        export const Cleared = Hidden.extend({play: undefined});
      `)
    ).toEqual([]);
  });

  test('a play shared by a same-file identifier emits every story that uses it', () => {
    const lines = storyLines(`${META}
      const sharedPlay = async () => {
        await drive();
      };
      export const First = meta.story({play: sharedPlay});
      export const Second = meta.story({play: sharedPlay});
    `);

    expect(namesOf(lines)).toEqual(['First', 'Second']);
  });

  test('a relative .storybook/preview import is read as CSF4', () => {
    const lines = storyLines(`
      import preview from '../../.storybook/preview';
      const meta = preview.meta({component: Widget, title: 'Widget'});
      export const Typed = meta.story({play: async () => drive()});
    `);

    expect(namesOf(lines)).toEqual(['Typed']);
  });

  test('a typed meta through preview.type<…>().meta is read as CSF4', () => {
    const lines = storyLines(`${PREVIEW_IMPORT}
      const meta = preview.type<{args: {size: string}}>().meta({component: Widget, title: 'Widget'});
      export const Typed = meta.story({play: async () => drive()});
    `);

    expect(namesOf(lines)).toEqual(['Typed']);
  });

  test('a play body that calls imported helpers is not refused', () => {
    const lines = storyLines(`import {expectToast} from './expect-toast';
      ${META}
      export const Toasted = meta.story({play: async ({canvasElement}) => expectToast(canvasElement, 'Saved')});
    `);

    expect(namesOf(lines)).toEqual(['Toasted']);
  });
});

describe('extract-test-signals story mode: test tags', () => {
  test('a story tagged !test emits nothing, its tests included', () => {
    const lines = storyLines(`${META}
      export const Kept = meta.story({play: async () => drive()});
      export const Dropped = meta.story({play: async () => drive(), tags: ['!test']});
      Dropped.test('never runs', async () => check());
    `);

    expect(namesOf(lines)).toEqual(['Kept']);
  });

  test('a meta tagged !test suppresses every story that does not re-add test', () => {
    const lines = storyLines(`${PREVIEW_IMPORT}
      const meta = preview.meta({component: Widget, tags: ['!test'], title: 'Widget'});
      export const Suppressed = meta.story({play: async () => drive()});
      export const Restored = meta.story({play: async () => drive(), tags: ['test']});
    `);

    expect(namesOf(lines)).toEqual(['Restored']);
  });
});

const rotationSource = ({
  metaArgs = "{size: 'small'}",
  playBody = 'await drive();',
  siblingArgs = "{size: 'large'}",
  testBody = 'await check();',
} = {}) => `
  ${PREVIEW_IMPORT}
  const meta = preview.meta({component: Widget, args: ${metaArgs}, title: 'Widget'});
  export const Default = meta.story({
    play: async () => {
      ${playBody}
    },
  });
  Default.test('first', async () => {
    ${testBody}
  });
  Default.test('second', async () => check());
  export const Variant = Default.extend({args: {size: 'medium'}});
  export const Sibling = meta.story({args: ${siblingArgs}, play: async () => drive()});
`;

const ROTATION_NAMES = [
  'Default   base story',
  'Default   first',
  'Default   second',
  'Variant',
  'Sibling',
];

describe('extract-test-signals story mode: signal rotation', () => {
  test("editing a story's play rotates its base story, every test and the extend story inheriting it, and no sibling", () => {
    const base = storyLines(rotationSource());
    const edited = storyLines(
      rotationSource({playBody: 'await drive(); await again();'})
    );

    expect(namesOf(edited)).toEqual(ROTATION_NAMES);

    for (const name of ROTATION_NAMES.slice(0, 4)) {
      expect(signalOf(edited, name)).not.toBe(signalOf(base, name));
    }
    expect(signalOf(edited, 'Sibling')).toBe(signalOf(base, 'Sibling'));
  });

  test("editing one test's body rotates that test only", () => {
    const base = storyLines(rotationSource());
    const edited = storyLines(
      rotationSource({testBody: 'await check(); await again();'})
    );

    expect(signalOf(edited, 'Default   first')).not.toBe(
      signalOf(base, 'Default   first')
    );

    for (const name of ROTATION_NAMES.filter(
      (entry) => entry !== 'Default   first'
    )) {
      expect(signalOf(edited, name)).toBe(signalOf(base, name));
    }
  });

  test('editing a sibling story rotates nothing of another story', () => {
    const base = storyLines(rotationSource());
    const edited = storyLines(rotationSource({siblingArgs: "{size: 'huge'}"}));

    expect(signalOf(edited, 'Sibling')).not.toBe(signalOf(base, 'Sibling'));

    for (const name of ROTATION_NAMES.slice(0, 4)) {
      expect(signalOf(edited, name)).toBe(signalOf(base, name));
    }
  });

  test("editing the meta's args rotates every entry in the file", () => {
    const base = storyLines(rotationSource());
    const edited = storyLines(rotationSource({metaArgs: "{size: 'tiny'}"}));

    for (const name of ROTATION_NAMES) {
      expect(signalOf(edited, name)).not.toBe(signalOf(base, name));
    }
  });

  test('reformatting whitespace or rewording a comment rotates no signal', () => {
    const reworded = storyLines(
      rotationSource({
        metaArgs: "{size:\n        'small'}",
        playBody: '// a reworded comment\n\n      await   drive();',
      })
    );
    const original = storyLines(
      rotationSource({playBody: '// the first comment\n      await drive();'})
    );

    const identity = (lines: typeof original) =>
      lines.map(({fullName, kind, signal}) => ({fullName, kind, signal}));

    expect(identity(reworded)).toEqual(identity(original));
    expect(namesOf(original)).toEqual(ROTATION_NAMES);
  });
});

const OLD_FORMAT_LINE = `extract-test-signals: ${STORY_FILE_REL} is an old-format story file; migrate it with: .gaia/cli/gaia migrate-csf4\n`;

describe('extract-test-signals story mode: old formats', () => {
  test('a CSF3 file exits 8 with the migration line and no stdout', () => {
    const result = runStory(`
      const meta = {component: Widget, title: 'Widget'};
      export default meta;
      export const Default = {play: async () => drive()};
    `);

    expect(result.status).toBe(8);
    expect(result.stdout).toBe('');
    expect(result.stderr).toBe(OLD_FORMAT_LINE);
  });

  test('a CSF2 Template.bind file exits 8 with the migration line', () => {
    const result = runStory(`
      export default {component: Widget, title: 'Widget'};
      const Template = (args) => <Widget {...args} />;
      export const Default = Template.bind({});
    `);

    expect(result.status).toBe(8);
    expect(result.stdout).toBe('');
    expect(result.stderr).toBe(OLD_FORMAT_LINE);
  });

  test('a storiesOf file exits 8 even with a preview meta beside it', () => {
    const result = runStory(`${META}
      storiesOf('Widget', module).add('default', () => <Widget />);
    `);

    expect(result.status).toBe(8);
    expect(result.stderr).toBe(OLD_FORMAT_LINE);
  });
});

const expectRefusal = (source: string, exportName: string, reason: RegExp) => {
  const result = runStory(source);

  expect(result.status).toBe(7);
  expect(result.stdout).toBe('');
  expect(
    result.stderr.startsWith(
      `extract-test-signals: unsupported story shape in ${STORY_FILE_REL}: ${exportName}: `
    )
  ).toBe(true);
  expect(result.stderr.split('\n')).toHaveLength(2);
  expect(result.stderr).toMatch(reason);
};

describe('extract-test-signals story mode: refusal', () => {
  test('a file that is neither CSF4 nor an older format is refused, not sent to migration', () => {
    expectRefusal(
      `${META}
      export const Leftover = {args: {size: 'large'}};
    `,
      'default',
      /not a CSF4 story file/
    );
  });

  test('a file with no preview import is refused as unknown', () => {
    expectRefusal(
      `import preview from './somewhere/else';
      const meta = preview.meta({component: Widget, title: 'Widget'});
      export const Default = meta.story({});
    `,
      'default',
      /not a CSF4 story file/
    );
  });

  test('a play bound to an imported identifier is refused', () => {
    expectRefusal(
      `import {sharedPlay} from './plays';
      ${META}
      export const Default = meta.story({play: sharedPlay});
    `,
      'Default',
      /imported identifier sharedPlay/
    );
  });

  test('a play bound to a mutable binding is refused', () => {
    expectRefusal(
      `${META}
      let sharedPlay = async () => drive();
      export const Default = meta.story({play: sharedPlay});
    `,
      'Default',
      /not a const or function declaration/
    );
  });

  test('an imported play inherited through extend is refused on the extend story', () => {
    expectRefusal(
      `import {sharedPlay} from './plays';
      ${META}
      const Hidden = meta.story({play: sharedPlay});
      export const Variant = Hidden.extend({});
    `,
      'Variant',
      /imported identifier sharedPlay/
    );
  });

  test('a .test() call whose name is not a string literal is refused', () => {
    expectRefusal(
      `${META}
      export const Default = meta.story({});
      const label = 'dynamic';
      Default.test(\`\${label} name\`, async () => check());
    `,
      'Default',
      /string literal/
    );
  });

  test('a .test() on a story that is not exported is refused', () => {
    expectRefusal(
      `${META}
      const Hidden = meta.story({});
      Hidden.test('runs', async () => check());
    `,
      'Hidden',
      /not an exported story/
    );
  });

  test('an assignment to a story after its declaration is refused', () => {
    expectRefusal(
      `${META}
      export const Default = meta.story({});
      Default.play = async () => drive();
    `,
      'Default',
      /assign/
    );
  });

  test('an extend cycle is refused', () => {
    expectRefusal(
      `${META}
      export const First = Second.extend({});
      export const Second = First.extend({});
    `,
      'First',
      /cycle/
    );
  });

  test('a meta excludeStories is refused before any story', () => {
    expectRefusal(
      `${PREVIEW_IMPORT}
      const meta = preview.meta({component: Widget, excludeStories: /.*Data$/, title: 'Widget'});
      export const Primary = meta.story({play: async () => drive()});
    `,
      'default',
      /excludeStories/
    );
  });

  test('an export clause is refused', () => {
    expectRefusal(
      `${META}
      const Hidden = meta.story({play: async () => drive()});
      export {Hidden as Shown};
    `,
      'Shown',
      /`export \{…\}` clause/
    );
  });

  test('non-literal story tags are refused', () => {
    expectRefusal(
      `${META}
      export const Tagged = meta.story({play: async () => drive(), tags: makeTags()});
    `,
      'Tagged',
      /tags/
    );
  });
});
