/**
 * Reader for the shipped setup feature list.
 *
 * Takes an explicit file path and never calls `process.cwd()`, matching the
 * labels registry reader; each `run` handler resolves its own default root.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {SetupFeaturesSchema} from '../../schemas/setup-features.js';
import type {SetupFeatures} from '../../schemas/setup-features.js';
import {summarizeZodError} from '../../schemas/zod-error.js';

export const setupFeaturesPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'setup-features.json');

/** Reads and validates a setup feature list; throws naming the file on failure. */
export const readSetupFeatures = (filePath: string): SetupFeatures => {
  let text: string;

  try {
    text = readFileSync(filePath, 'utf8');
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(`${filePath}: unreadable: ${detail}`);
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(text);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(`${filePath}: invalid JSON: ${detail}`);
  }

  const result = SetupFeaturesSchema.safeParse(parsed);

  if (!result.success) {
    throw new Error(summarizeZodError(filePath, result.error));
  }

  return result.data;
};
