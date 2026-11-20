import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveLayer} from './layer.js';

describe('resolveLayer', () => {
  let packageDir: string;

  beforeEach(() => {
    packageDir = mkdtempSync(path.join(tmpdir(), 'gaia-layer-'));
  });

  afterEach(() => {
    rmSync(packageDir, {force: true, recursive: true});
  });

  const makeServiceFolders = (...names: string[]): void => {
    for (const name of names) {
      mkdirSync(path.join(packageDir, 'app', 'services', name), {
        recursive: true,
      });
    }
  };

  test('picks the single folder other than api', () => {
    makeServiceFolders('api', 'acme');

    expect(resolveLayer(packageDir, undefined)).toEqual({layer: 'acme'});
  });

  test('returns the requested folder when it exists', () => {
    makeServiceFolders('api', 'acme', 'billing');

    expect(resolveLayer(packageDir, 'billing')).toEqual({layer: 'billing'});
  });

  describe('resolveLayer errors name the candidates', () => {
    const noneFound =
      'cannot pick the domain-layer folder under app/services/ (found: none); pass --layer <folder>';

    test.each([
      {
        error: '--layer folder not found: app/services/billing/',
        folders: ['api', 'acme'],
        name: 'errors when the requested folder is missing',
        requested: 'billing',
      },
      {
        error: noneFound,
        folders: ['api'],
        name: 'errors naming none when there is no candidate',
        requested: undefined,
      },
      {
        error: noneFound,
        folders: [],
        name: 'errors naming none when app/services is missing',
        requested: undefined,
      },
      {
        error:
          'cannot pick the domain-layer folder under app/services/ (found: acme, billing); pass --layer <folder>',
        folders: ['api', 'billing', 'acme'],
        name: 'errors naming every candidate when there are several',
        requested: undefined,
      },
    ])('$name', ({error, folders, requested}) => {
      makeServiceFolders(...folders);

      expect(resolveLayer(packageDir, requested)).toEqual({error});
    });
  });
});
