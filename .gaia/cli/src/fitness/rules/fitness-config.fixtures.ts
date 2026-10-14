import {FITNESS_CONFIG_PATH} from '../config.js';
import type {FixtureFactory, FixtureMap, FixtureProject} from '../types.js';

const SUPPRESSED_PATH = '.claude/rules/example.md';

const projectWithConfig = (config: string): FixtureProject => ({
  files: {
    [FITNESS_CONFIG_PATH]: config,
    [SUPPRESSED_PATH]: '# Example rule\n',
  },
  git: true,
});

const configText = (ignore: unknown, version: unknown = 1): string =>
  JSON.stringify({ignore, version}, null, 2);

const validEntry = {
  path: SUPPRESSED_PATH,
  reason: 'kept on purpose',
  rule_id: 'settings.fitness-config.parse',
};

const green: FixtureFactory = () => projectWithConfig(configText([validEntry]));

export const FITNESS_CONFIG_FIXTURES: FixtureMap = {
  'settings.fitness-config.no-reason': {
    green,
    red: () => projectWithConfig(configText([{...validEntry, reason: ''}])),
  },
  'settings.fitness-config.parse': {
    green,
    red: () => projectWithConfig('{ not json'),
  },
  'settings.fitness-config.stale': {
    green,
    red: () =>
      projectWithConfig(
        configText([{...validEntry, path: '.claude/rules/missing.md'}])
      ),
  },
};
