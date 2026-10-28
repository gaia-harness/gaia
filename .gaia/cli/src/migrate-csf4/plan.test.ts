import ts from 'typescript';
import {afterEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {computeWritePlan} from './plan.js';
import * as repairs from './repairs/index.js';
import type {Repairs} from './repairs/index.js';
import {readMigrationFixture} from './repairs/repairs-fixture.js';
import {fakeRepairs, writeTree} from './run-fixture.js';

const MAIN = `import type {StorybookConfig} from '@storybook/react-vite';

const config: StorybookConfig = {
  addons: ['@storybook/addon-a11y', '@storybook/addon-links', 'msw-storybook-addon'],
  stories: ['../app/**/*.stories.tsx'],
};

export default config;
`;

const packageDirs: string[] = [];

const makePackage = (files: Record<string, string>): string => {
  const packageDir = mkdtempSync(path.join(tmpdir(), 'migrate-csf4-plan-'));

  packageDirs.push(packageDir);
  writeTree(packageDir, files);

  return packageDir;
};

afterEach(() => {
  packageDirs
    .splice(0)
    .forEach((packageDir) =>
      rmSync(packageDir, {force: true, recursive: true})
    );
});

const previewEdit = (packageDir: string, planRepairs: Repairs) =>
  computeWritePlan({
    csf3Stories: [],
    packageDir,
    repairs: planRepairs,
    ts,
  }).configEdits.find((edit) => edit.relative === '.storybook/preview.ts');

describe('computeWritePlan', () => {
  test('wires the addons main lists into the rewired preview', () => {
    const packageDir = makePackage({
      '.storybook/main.ts': MAIN,
      '.storybook/preview.ts': readMigrationFixture('preview.ts.csf3'),
    });

    const edit = previewEdit(packageDir, repairs);

    expect(edit?.text).toContain(
      "import addonLinks from '@storybook/addon-links';"
    );
    expect(edit?.text).toContain('    addonA11y(),\n    addonLinks(),\n');
  });

  test('passes no main addons when the package has no main', () => {
    const received: (readonly string[] | undefined)[] = [];
    const packageDir = makePackage({
      '.storybook/preview.ts': 'const preview = {};\nexport default preview;\n',
    });

    previewEdit(packageDir, {
      ...fakeRepairs,
      rewirePreview: (_ts, source, mainAddons) => {
        received.push(mainAddons);

        return {changed: false, source, unknownAddons: []};
      },
    });

    expect(received).toEqual([[]]);
  });
});
