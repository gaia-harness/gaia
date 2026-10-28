import {rmSync} from 'node:fs';
import {
  CSF3_PREVIEW,
  CSF3_STORY,
  git,
  makeHarness,
  makeRepo,
  PLAIN_MAIN,
} from './run-fixture.js';
import type {Behavior} from './run-fixture.js';
import {runMigrateCsf4} from './run.js';
import type {MigrateReport} from './types.js';

const roots: string[] = [];

export const repo = (
  files: Record<string, string>,
  version?: string
): string => {
  const root = makeRepo(files, version);

  roots.push(root);

  return root;
};

export const cleanupRepos = (): void => {
  roots
    .splice(0)
    .forEach((root) => rmSync(root, {force: true, recursive: true}));
};

export const standardFiles = {
  'frontend/.storybook/main.ts': PLAIN_MAIN,
  'frontend/.storybook/preview.ts': CSF3_PREVIEW,
  'frontend/app/a/a.stories.tsx': CSF3_STORY,
  'frontend/app/b/b.stories.tsx': CSF3_STORY,
};

export const execute = (
  root: string,
  flags: {json?: boolean; updateMerge?: boolean} = {},
  behavior: Behavior = {}
): {
  exit: number;
  harness: ReturnType<typeof makeHarness>;
  json: MigrateReport | undefined;
} => {
  const harness = makeHarness(root, behavior);
  const exit = runMigrateCsf4(
    {json: flags.json ?? true, updateMerge: flags.updateMerge ?? false},
    harness.deps
  );
  const text = harness.out.join('');

  return {
    exit,
    harness,
    json:
      text.trim().startsWith('{') ?
        (JSON.parse(text) as MigrateReport)
      : undefined,
  };
};

export const status = (root: string): string =>
  git(root, 'status', '--porcelain');

export const JSON_KEYS = [
  'converted',
  'files',
  'lint',
  'package',
  'refused',
  'restore',
  'typecheck',
  'unexpectedChanges',
  'unknownAddons',
];
