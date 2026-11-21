import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {existsSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  loadTemplate,
  renderTemplate,
  scaffoldTemplatesDirectory,
  substituteVars,
} from './template.js';
import type {TemplateVars} from './template.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const setupSandbox = (): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-template-'));

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const writeTemplateFile = (dir: string, name: string, body: string): string => {
  const filePath = path.join(dir, name);
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

describe('renderTemplate', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  describe('renderTemplate substitutes variables and sections', () => {
    test.each([
      {
        body: 'export const {{name}} = "{{value}}";',
        name: 'substitutes scalar variables',
        renders: [
          [{name: 'foo', value: 'bar'}, 'export const foo = "bar";'],
        ] as [TemplateVars, string][],
      },
      {
        body: 'a{{#flag}}-x-{{/flag}}b',
        name: 'omits boolean section when flag is false / missing',
        renders: [
          [{flag: false}, 'ab'],
          [{}, 'ab'],
        ] as [TemplateVars, string][],
      },
      {
        body: 'a{{#flag}}-x-{{/flag}}b',
        name: 'includes boolean section when flag is true',
        renders: [[{flag: true}, 'a-x-b']] as [TemplateVars, string][],
      },
      {
        body: '[{{#each items}}<{{this}}>{{/each}}]',
        name: 'iterates each blocks with {{this}}',
        renders: [[{items: ['a', 'b', 'c']}, '[<a><b><c>]']] as [
          TemplateVars,
          string,
        ][],
      },
      {
        body: 'pre{{#each items}}X{{/each}}post',
        name: 'each block iterating empty array yields no body',
        renders: [[{items: []}, 'prepost']] as [TemplateVars, string][],
      },
      {
        body: '{{#story}}story for {{name}}{{/story}}',
        name: 'substitutes inside a true section body',
        renders: [[{name: 'Foo', story: true}, 'story for Foo']] as [
          TemplateVars,
          string,
        ][],
      },
      {
        body: 'a-{{absent}}-b',
        name: 'missing scalar renders as empty string',
        renders: [[{}, 'a--b']] as [TemplateVars, string][],
      },
      {
        body: 'flag={{flag}}',
        name: 'boolean scalar is stringified as true/false',
        renders: [
          [{flag: true}, 'flag=true'],
          [{flag: false}, 'flag=false'],
        ] as [TemplateVars, string][],
      },
      {
        body: 'tags={{tags}}',
        name: 'array scalar substitution joins with commas',
        renders: [[{tags: ['a', 'b']}, 'tags=a,b']] as [TemplateVars, string][],
      },
      {
        body: '',
        name: 'renders to empty when template is empty',
        renders: [[{}, '']] as [TemplateVars, string][],
      },
    ])('$name', ({body, renders}) => {
      const filePath = writeTemplateFile(sandbox.dir, 'case.tpl', body);

      for (const [vars, expected] of renders) {
        expect(renderTemplate(filePath, vars)).toBe(expected);
      }
    });
  });
});

describe('scaffoldTemplatesDirectory', () => {
  test.each(['component', 'hook', 'route', 'service', 'data-layer'])(
    'contains the %s templates',
    (family) => {
      expect(existsSync(path.join(scaffoldTemplatesDirectory(), family))).toBe(
        true
      );
    }
  );
});

describe('loadTemplate', () => {
  test('throws when the template file does not exist', () => {
    expect(() => loadTemplate('does-not-exist.tpl')).toThrow(/ENOENT/);
  });
});

describe('substituteVars', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('produces the same output as renderTemplate for the same body', () => {
    const body = '{{#flag}}hi {{name}}{{/flag}}';
    const filePath = writeTemplateFile(sandbox.dir, 'parity.tpl', body);
    const vars = {flag: true, name: 'world'};

    expect(substituteVars(body, vars)).toBe(renderTemplate(filePath, vars));
  });

  // These strings intentionally contain literal `${{ ... }}` GitHub Actions
  // expression text (VAR_PATTERN's negative lookbehind on `$` is what's under
  // test): no-template-curly-in-string only checks quoted-string literals for
  // an accidentally-unescaped template placeholder, which isn't the case
  // here.
  // eslint-disable-next-line no-template-curly-in-string -- the test name quotes a GitHub Actions expression
  test('leaves GitHub Actions ${{ secrets.X }} expressions unchanged', () => {
    const out = substituteVars(
      // eslint-disable-next-line no-template-curly-in-string -- a GitHub Actions expression, not JS interpolation
      'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}',
      {}
    );

    // eslint-disable-next-line no-template-curly-in-string -- a GitHub Actions expression, not JS interpolation
    expect(out).toBe('GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}');
  });
});
