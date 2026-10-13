/**
 * Fixture helpers shared by the record, drift and state-preservation tests:
 * a temp git repository holding a custom setup feature list.
 */
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {projectConfigPath} from '../../schemas/project-config.js';
import {resolveStateFilePath} from '../util/state-file.js';

export type FixtureFeature = {
  admin?: boolean;
  id: string;
  reference?: string;
  required?: boolean;
  scope: 'machine' | 'project';
  standalone?: boolean;
};

export const writeFeatureList = (
  filePath: string,
  features: readonly FixtureFeature[]
): void => {
  mkdirSync(path.dirname(filePath), {recursive: true});
  writeFileSync(
    filePath,
    JSON.stringify({
      description: 'fixture list',
      features: features.map((feature) => ({
        admin: false,
        reference: '.claude/commands/setup-gaia.md',
        required: false,
        standalone: false,
        ...feature,
      })),
      version: 1,
    }),
    'utf8'
  );
};

export const writeStateJson = (root: string, value: unknown): void => {
  const target = resolveStateFilePath(root);
  mkdirSync(path.dirname(target), {recursive: true});
  writeFileSync(target, JSON.stringify(value), 'utf8');
};

export const readStateJson = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(resolveStateFilePath(root), 'utf8')) as Record<
    string,
    unknown
  >;

export const readProjectJson = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(projectConfigPath(root), 'utf8')) as Record<
    string,
    unknown
  >;

export const listPathIn = (root: string): string =>
  path.join(root, '.gaia', 'setup-features.json');
