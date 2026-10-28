/**
 * Test support for the repair suites: the repository root, the committed
 * migration fixtures, and a file from the checkout.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';

export const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

/** A file under `.gaia/cli/test-fixtures/migrate-csf4/`. */
export const readMigrationFixture = (name: string): string =>
  readFileSync(
    path.join(repoRoot, '.gaia/cli/test-fixtures/migrate-csf4', name),
    'utf8'
  );

/** A file of the checkout, by repo-relative path. */
export const readCheckoutFile = (relativePath: string): string =>
  readFileSync(path.join(repoRoot, relativePath), 'utf8');
