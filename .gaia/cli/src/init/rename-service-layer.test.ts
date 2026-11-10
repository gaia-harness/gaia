import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveLayer} from '../scaffold/layer.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {rewriteServiceSpecifiers} from './rename-service-layer.js';
import {run} from './rename.js';

const LAYER_API = `import {create} from '../api';

export const api = create();
`;

const ITEMS_REQUESTS = `import {api} from '../api';
import {ITEMS_URLS} from '~/services/gaia/items/urls';
`;

const ROUTE = `import {getItems} from '~/services/gaia/items';
import {api} from '../services/gaia/api';
import {other} from '~/services/gaia-extra/thing';
`;

const MOCK = `import {ITEMS_URLS} from "~/services/gaia/items/urls";
// app/services/gaia/ is the layer this mock serves.
const servicePath = 'app/services/gaia/items';
`;

let root: string;

const at = (...segments: string[]): string => path.join(root, ...segments);

const write = (relative: string, content: string): void => {
  mkdirSync(path.dirname(at(relative)), {recursive: true});
  writeFileSync(at(relative), content, 'utf8');
};

const read = (relative: string): string => readFileSync(at(relative), 'utf8');

const rename = (kebab: string): number =>
  run(['--title', 'Repair Desk', '--kebab', kebab], {cwd: root});

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'gaia-init-rename-services-'));
  writeFrontendRegistry(root);
  write('package.json', `${JSON.stringify({name: 'gaia'}, null, 2)}\n`);
  write('CLAUDE.md', '# GAIA React\n');
  write('app/services/api/index.ts', 'export const create = () => ({});\n');
  write('app/services/gaia/api.ts', LAYER_API);
  write('app/services/gaia/items/requests.ts', ITEMS_REQUESTS);
  write('app/routes/items.tsx', ROUTE);
  write('test/mocks/items/get.ts', MOCK);
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  rmSync(root, {force: true, recursive: true});
  vi.restoreAllMocks();
});

describe('init rename: the sample service layer', () => {
  test('moves services/gaia/ to the slug and rewrites every specifier naming it', () => {
    expect(rename('repair-desk')).toBe(0);

    expect(existsSync(at('app/services/gaia'))).toBe(false);
    expect(read('app/services/repair-desk/api.ts')).toBe(LAYER_API);
    expect(read('app/services/repair-desk/items/requests.ts')).toBe(
      ITEMS_REQUESTS.replace('services/gaia/', 'services/repair-desk/')
    );
    expect(read('app/routes/items.tsx')).toBe(
      `import {getItems} from '~/services/repair-desk/items';
import {api} from '../services/repair-desk/api';
import {other} from '~/services/gaia-extra/thing';
`
    );
    expect(read('test/mocks/items/get.ts')).toBe(
      `import {ITEMS_URLS} from "~/services/repair-desk/items/urls";
// app/services/gaia/ is the layer this mock serves.
const servicePath = 'app/services/repair-desk/items';
`
    );
  });

  test('/new-service resolves the renamed folder as the domain layer', () => {
    expect(rename('repair-desk')).toBe(0);

    expect(resolveLayer(root, undefined)).toEqual({layer: 'repair-desk'});
  });

  test('a replay with the same slug changes nothing', () => {
    expect(rename('repair-desk')).toBe(0);
    const route = read('app/routes/items.tsx');

    expect(rename('repair-desk')).toBe(0);

    expect(read('app/routes/items.tsx')).toBe(route);
    expect(existsSync(at('app/services/repair-desk/api.ts'))).toBe(true);
  });

  test('a run that rewrote the specifiers but never moved the folder finishes the move', () => {
    write(
      'app/routes/items.tsx',
      rewriteServiceSpecifiers(ROUTE, 'gaia', 'repair-desk')
    );

    expect(rename('repair-desk')).toBe(0);

    expect(existsSync(at('app/services/gaia'))).toBe(false);
    expect(read('app/services/repair-desk/api.ts')).toBe(LAYER_API);
  });

  test('re-running with a new slug moves the layer from the slug the last run recorded', () => {
    expect(rename('repair-desk')).toBe(0);

    expect(rename('fix-it')).toBe(0);

    expect(existsSync(at('app/services/repair-desk'))).toBe(false);
    expect(read('app/services/fix-it/api.ts')).toBe(LAYER_API);
    expect(read('app/routes/items.tsx')).toContain("'~/services/fix-it/items'");
  });

  test('a rename after finalize deleted init-state still moves the layer', () => {
    expect(rename('repair-desk')).toBe(0);
    rmSync(at('.gaia/init-state.json'), {force: true});

    expect(rename('fix-it')).toBe(0);

    expect(existsSync(at('app/services/repair-desk'))).toBe(false);
    expect(read('app/services/fix-it/api.ts')).toBe(LAYER_API);
    expect(read('app/routes/items.tsx')).toContain("'~/services/fix-it/items'");
  });

  test('the slug "gaia" leaves the layer where it is', () => {
    expect(rename('gaia')).toBe(0);

    expect(read('app/services/gaia/api.ts')).toBe(LAYER_API);
    expect(read('app/routes/items.tsx')).toBe(ROUTE);
  });

  test('a project without services/gaia/ renames cleanly and creates no layer', () => {
    rmSync(at('app/services/gaia'), {force: true, recursive: true});

    expect(rename('repair-desk')).toBe(0);

    expect(existsSync(at('app/services/repair-desk'))).toBe(false);
    expect(read('app/routes/items.tsx')).toBe(ROUTE);
  });

  test('a slug folder beside services/gaia/ is refused before anything is written', () => {
    write('app/services/repair-desk/api.ts', LAYER_API);

    expect(rename('repair-desk')).toBe(1);

    expect(JSON.parse(read('package.json'))).toEqual({name: 'gaia'});
    expect(read('app/routes/items.tsx')).toBe(ROUTE);
    expect(existsSync(at('app/services/gaia/api.ts'))).toBe(true);
  });
});
