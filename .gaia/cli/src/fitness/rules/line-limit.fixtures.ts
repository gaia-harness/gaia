import type {FixtureMap, FixtureProject} from '../types.js';
import {filler} from './authoring.fixtures.js';
import {CEILINGS_PATH, MAINTAINER_MARKER_PATH} from './line-limit.js';

export const SCRIPT_PATH = '.gaia/scripts/example.sh';

export const ceilingsText = (ceilings: Record<string, unknown>): string =>
  `${JSON.stringify({ceilings, version: 1}, null, 2)}\n`;

/** A maintainer-repo project: the marker, the given files and, when passed, the ceilings file. */
export const maintainerProject = (
  files: Record<string, string>,
  ceilings?: Record<string, unknown>
): FixtureProject => ({
  files: {
    [MAINTAINER_MARKER_PATH]: '# Harness triage threshold\n',
    ...(ceilings === undefined ?
      {}
    : {[CEILINGS_PATH]: ceilingsText(ceilings)}),
    ...files,
  },
});

export const LINE_LIMIT_FIXTURES: FixtureMap = {
  'authoring.harness.ceiling-stale': {
    green: () =>
      maintainerProject({[SCRIPT_PATH]: filler(401)}, {[SCRIPT_PATH]: 401}),
    red: () =>
      maintainerProject({[SCRIPT_PATH]: filler(10)}, {[SCRIPT_PATH]: 401}),
  },
  'authoring.harness.max-lines': {
    green: () => maintainerProject({[SCRIPT_PATH]: filler(400)}, {}),
    red: () => maintainerProject({[SCRIPT_PATH]: filler(401)}, {}),
  },
};
