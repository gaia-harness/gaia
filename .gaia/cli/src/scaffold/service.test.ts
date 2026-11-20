/**
 * vitest coverage for `gaia scaffold service`.
 *
 * Each test runs the handler against a sandbox repo seeded to mirror the real
 * shape (`app/services/gaia/`, `test/mocks/database.ts` with the empty
 * default-export). We assert on file presence, file contents, and the
 * idempotence contract.
 */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
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
import {EXIT_CODES} from '../exit.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run} from './service.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const seedDatabase = (root: string): string => {
  const databaseDirectory = path.join(root, 'test', 'mocks');
  mkdirSync(databaseDirectory, {recursive: true});
  const databasePath = path.join(databaseDirectory, 'database.ts');
  writeFileSync(
    databasePath,
    [
      '// Barrel for `@msw/data` collections.',
      '',
      'export const resetTestData = async (): Promise<void> => {};',
      '',
      'export default {} as Record<string, never>;',
      '',
    ].join('\n'),
    'utf8'
  );

  return databasePath;
};

const setupSandbox = ({withDatabase}: {withDatabase: boolean}): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-service-'));
  writeFrontendRegistry(dir);
  mkdirSync(path.join(dir, 'app', 'services', 'gaia'), {recursive: true});

  if (withDatabase) seedDatabase(dir);

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

const itemsDir = (root: string): string =>
  path.join(root, 'app', 'services', 'gaia', 'items');

const scaffoldGetPost = (root: string): number =>
  run(
    [
      'items',
      '--endpoints',
      'get,post',
      '--schema',
      'id:string,displayName:string',
    ],
    {cwd: root}
  );

const installQuery = (root: string): void => {
  writeFileSync(
    path.join(root, 'package.json'),
    JSON.stringify({dependencies: {'@tanstack/react-query': '5.104.1'}}),
    'utf8'
  );
};

const captureStderr = (action: () => number): {code: number; err: string} => {
  let err = '';
  const originalWrite = process.stderr.write.bind(process.stderr);

  (process.stderr as any).write = (chunk: string | Uint8Array): boolean => {
    err +=
      typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');

    return true;
  };

  try {
    return {code: action(), err};
  } finally {
    process.stderr.write = originalWrite;
  }
};

type ServiceCase = {
  absent?: string[];
  args: string[];
  code?: number;
  contains?: Record<string, string[]>;
  excludes?: Record<string, string[]>;
  exists?: string[];
  name: string;
  notMatches?: Record<string, RegExp[]>;
  setup?: (root: string) => void;
  stderr?: string[];
  unchanged?: string[];
};

const serviceFile = (name: string, file: string): string =>
  `app/services/gaia/${name}/${file}`;

const mockFile = (name: string, file: string): string =>
  `test/mocks/${name}/${file}`;

const makeAcme = (root: string): void => {
  mkdirSync(path.join(root, 'app', 'services', 'acme'), {recursive: true});
};

const DATABASE_FILE = 'test/mocks/database.ts';

const ITEMS_ARGS = [
  'items',
  '--endpoints',
  'get,post,put,delete',
  '--schema',
  'id:string,displayName:string',
];

const GET_POST_ARGS = [
  'items',
  '--endpoints',
  'get,post',
  '--schema',
  'id:string,displayName:string',
];

const seedDatabaseBody =
  (body: string) =>
  (root: string): void => {
    writeFileSync(path.join(root, DATABASE_FILE), body, 'utf8');
  };

const expectServiceCase = (root: string, row: ServiceCase): void => {
  row.setup?.(root);
  const before = (row.unchanged ?? []).map((file) =>
    read(path.join(root, file))
  );

  const {code, err} = captureStderr(() => run(row.args, {cwd: root}));

  expect(code).toBe(row.code ?? EXIT_CODES.OK);

  for (const fragment of row.stderr ?? []) {
    expect(err).toContain(fragment);
  }

  for (const file of row.exists ?? []) {
    expect(existsSync(path.join(root, file))).toBe(true);
  }

  for (const file of row.absent ?? []) {
    expect(existsSync(path.join(root, file))).toBe(false);
  }

  for (const [file, fragments] of Object.entries(row.contains ?? {})) {
    for (const fragment of fragments) {
      expect(read(path.join(root, file))).toContain(fragment);
    }
  }

  for (const [file, fragments] of Object.entries(row.excludes ?? {})) {
    for (const fragment of fragments) {
      expect(read(path.join(root, file))).not.toContain(fragment);
    }
  }

  for (const [file, patterns] of Object.entries(row.notMatches ?? {})) {
    for (const pattern of patterns) {
      expect(read(path.join(root, file))).not.toMatch(pattern);
    }
  }

  expect(
    (row.unchanged ?? []).map((file) => read(path.join(root, file)))
  ).toEqual(before);
};

describe('gaia scaffold service', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox({withDatabase: true});
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('re-run is idempotent: files unchanged, no duplicate barrel inserts', () => {
    const args = [
      'projects',
      '--endpoints',
      'get,post',
      '--schema',
      'id:string,title:string',
      '--mocks',
    ];
    expect(run(args, {cwd: sandbox.dir})).toBe(EXIT_CODES.OK);
    const databaseAfterFirst = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    const parsersAfterFirst = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );

    expect(run(args, {cwd: sandbox.dir})).toBe(EXIT_CODES.OK);
    const databaseAfterSecond = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    const parsersAfterSecond = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );

    expect(databaseAfterSecond).toBe(databaseAfterFirst);
    expect(parsersAfterSecond).toBe(parsersAfterFirst);
    // No duplicate import lines.
    const importMatches =
      databaseAfterSecond.match(/import \{projects, resetProjects\}/gu) ?? [];
    expect(importMatches).toHaveLength(1);
  });

  test('--json emits a single ScaffoldResult JSON line', () => {
    let captured = '';
    const originalWrite = process.stdout.write.bind(process.stdout);

    (process.stdout as any).write = (chunk: string | Uint8Array): boolean => {
      captured +=
        typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');

      return true;
    };

    try {
      const code = run(
        ['projects', '--endpoints', 'get', '--schema', 'id:string', '--json'],
        {cwd: sandbox.dir}
      );
      expect(code).toBe(EXIT_CODES.OK);
    } finally {
      process.stdout.write = originalWrite;
    }

    const lines = captured.trim().split('\n');
    const lastLine = lines.at(-1) ?? '';
    const parsed = JSON.parse(lastLine) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };
    expect(parsed.written.length).toBeGreaterThan(0);
    expect(Array.isArray(parsed.edited)).toBe(true);
    expect(Array.isArray(parsed.skipped)).toBe(true);
  });

  test('POST and PUT mocks parse the body with the server schema and answer 400 naming the issues', () => {
    run(
      [
        'projects',
        '--endpoints',
        'post,put',
        '--schema',
        'id:string,title:string',
        '--mocks',
      ],
      {cwd: sandbox.dir}
    );
    const mockDirectory = path.join(sandbox.dir, 'test', 'mocks', 'projects');
    const post = read(path.join(mockDirectory, 'post.ts'));
    const put = read(path.join(mockDirectory, 'put.ts'));

    expect(post).toContain('serverProjectSchema.safeParse(');
    expect(put).toMatch(/serverProjectSchema\s*\.partial\(\)\s*\.safeParse\(/u);

    for (const handler of [post, put]) {
      expect(handler).toContain("error: 'Invalid project'");
      expect(handler).toContain('issues: parsed.error.issues');
      expect(handler).toContain('{status: 400}');
      expect(handler).not.toMatch(/ as (Partial<)?ServerProject/u);
    }
  });

  test('multi-word kebab name derives correct identifiers', () => {
    run(['user-settings', '--endpoints', 'get', '--schema', 'id:string'], {
      cwd: sandbox.dir,
    });
    const urls = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'user-settings',
        'urls.ts'
      )
    );
    expect(urls).toContain('USER_SETTINGS_URLS');
    expect(urls).toContain("userSettings: 'user-settings'");
    expect(urls).toContain("userSettingsId: 'user-settings/:id'");

    const types = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'user-settings',
        'types.ts'
      )
    );
    expect(types).toContain('UserSetting');
    expect(types).toContain('UserSettings');
  });

  describe('service emits the right files for each endpoint and mock choice', () => {
    test.each<ServiceCase>([
      {
        absent: [
          mockFile('projects', 'put.ts'),
          mockFile('projects', 'delete.ts'),
        ],
        args: [
          'projects',
          '--endpoints',
          'get,post',
          '--schema',
          'id:string,title:string',
          '--mocks',
        ],
        contains: {
          [DATABASE_FILE]: [
            "import {projects, resetProjects} from './projects/data';",
            'resetProjects()',
            'export default {projects};',
          ],
        },
        exists: [
          ...['parsers', 'types', 'requests', 'urls', 'index'].map((file) =>
            serviceFile('projects', `${file}.ts`)
          ),
          ...['data', 'get', 'post', 'index'].map((file) =>
            mockFile('projects', `${file}.ts`)
          ),
        ],
        name: 'emits 5 service files plus 4 mock files for projects with --mocks (get,post)',
      },
      {
        absent: ['post', 'put', 'delete'].map((file) =>
          mockFile('things', `${file}.ts`)
        ),
        args: [
          'things',
          '--endpoints',
          'get',
          '--schema',
          'id:string,name:string',
          '--mocks',
        ],
        contains: {
          [mockFile('things', 'index.ts')]: [
            "import get from './get';",
            'const handlers = [...get];',
          ],
          [serviceFile('things', 'requests.ts')]: [
            'getAllThings',
            'getThingById',
          ],
          [serviceFile('things', 'urls.ts')]: [
            "things: 'things'",
            "thingsId: 'things/:id'",
          ],
        },
        excludes: {
          [mockFile('things', 'index.ts')]: [
            "import post from './post';",
            "import put from './put';",
            "import del from './delete';",
          ],
          [serviceFile('things', 'requests.ts')]: [
            'createThing',
            'updateThing',
            'deleteThing',
          ],
        },
        exists: [mockFile('things', 'get.ts')],
        name: '--endpoints "get" emits only the get request and the get mock',
      },
      {
        absent: [mockFile('projects', '')],
        args: ['projects', '--endpoints', 'get', '--schema', 'id:string'],
        exists: [
          serviceFile('projects', 'parsers.ts'),
          serviceFile('projects', 'index.ts'),
        ],
        name: 'without --mocks: only 5 service files; no mock dir; database untouched',
        unchanged: [DATABASE_FILE],
      },
      {
        args: [
          'projects',
          '--endpoints',
          'get,post,put,delete',
          '--schema',
          'id:string,title:string',
          '--mocks',
        ],
        contains: {
          [mockFile('projects', 'index.ts')]: [
            "import del from './delete';",
            "import get from './get';",
            "import post from './post';",
            "import put from './put';",
            'const handlers = [...get, post, put, del];',
          ],
          [serviceFile('projects', 'requests.ts')]: [
            'getAllProjects',
            'createProject',
            'updateProject',
            'deleteProject',
          ],
        },
        name: 'full CRUD emits all four request functions and full mock barrel',
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service schema types render to zod and mock data', () => {
    test.each<ServiceCase>([
      {
        args: [
          'projects',
          '--endpoints',
          'get',
          '--schema',
          'id:string,status:enum(active,archived)',
        ],
        contains: {
          [serviceFile('projects', 'parsers.ts')]: [
            "status: z.literal(['active', 'archived'])",
          ],
          // The TS type is derived via z.infer, so the union is implicit; what
          // this verifies is that the type alias points at the schema.
          [serviceFile('projects', 'types.ts')]: [
            'z.infer<typeof projectSchema>',
          ],
        },
        name: '--schema with enum produces z.literal + TS union',
      },
      {
        args: [
          'projects',
          '--endpoints',
          'get',
          '--schema',
          'id:string,description:string?',
        ],
        contains: {
          [serviceFile('projects', 'parsers.ts')]: [
            'description: z.string().nullish()',
          ],
        },
        name: 'optional types append .nullish()',
      },
      {
        args: [
          'projects',
          '--endpoints',
          'get',
          '--schema',
          'id:string,createdAt:datetime',
          '--mocks',
        ],
        contains: {
          [mockFile('projects', 'data.ts')]: ['createdAt: z.iso.datetime()'],
        },
        name: 'mock data schema keeps camelCase field names by default',
      },
      {
        args: [
          'projects',
          '--endpoints',
          'get',
          '--schema',
          'id:string,createdAt:datetime',
          '--mocks',
        ],
        contains: {
          [mockFile('projects', 'data.ts')]: ['created_at: z.iso.datetime()'],
        },
        name: 'a snake_case layer converts camelCase field names in mock data schema',
        setup: (root) => {
          writeFileSync(
            path.join(root, 'app', 'services', 'gaia', 'api.ts'),
            'export const api = create({isSnakeCaseEnabled: true});\n'
          );
        },
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service registers mocks in the database barrel', () => {
    const mangoArgs = [
      'mangoes',
      '--endpoints',
      'get',
      '--schema',
      'id:string',
      '--mocks',
    ];

    test.each<ServiceCase>([
      {
        args: mangoArgs,
        contains: {
          // Pre-seeded with two collections, then `mango` goes between apples
          // and zebras.
          [DATABASE_FILE]: [
            [
              "import {apples, resetApples} from './apples/data';",
              "import {mangoes, resetMangoes} from './mangoes/data';",
              "import {zebras, resetZebras} from './zebras/data';",
            ].join('\n'),
            'Promise.all([resetApples(), resetMangoes(), resetZebras()])',
            'export default {apples, mangoes, zebras}',
          ],
        },
        name: 'database.ts collection insert is alphabetical',
        setup: seedDatabaseBody(
          [
            "import {apples, resetApples} from './apples/data';",
            "import {zebras, resetZebras} from './zebras/data';",
            '',
            'export const resetTestData = async (): Promise<void> => {',
            '  await Promise.all([resetApples(), resetZebras()]);',
            '};',
            '',
            'export default {apples, zebras};',
            '',
          ].join('\n')
        ),
      },
      {
        // A barrel whose `resetTestData` lost its `Promise.all([...])` region:
        // the import insert applies but the reset-call insert can no longer
        // match. The diff-safety net must reject this instead of writing a
        // half-applied barrel, and since the barrel edit is planned before
        // anything is written, no service or mock files are left behind.
        absent: [serviceFile('mangoes', ''), mockFile('mangoes', '')],
        args: mangoArgs,
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        excludes: {[DATABASE_FILE]: ['mangoes']},
        name: 'fails loudly when the database barrel is missing the Promise.all region',
        setup: seedDatabaseBody(
          [
            "import {apples, resetApples} from './apples/data';",
            '',
            'export const resetTestData = async (): Promise<void> => {',
            '  // resetting disabled',
            '};',
            '',
            'export default {apples};',
            '',
          ].join('\n')
        ),
      },
      {
        args: [...ITEMS_ARGS, '--mocks'],
        contains: {
          [DATABASE_FILE]: [
            'export const resetTestData = async (): Promise<void> => {\n  await Promise.all([resetItems()]);\n};',
            'export default {items};',
          ],
        },
        name: 'stock empty barrel gains a Promise.all with the new reset call',
      },
      {
        args: mangoArgs,
        contains: {
          [DATABASE_FILE]: [
            'await Promise.all([resetApples(), resetMangoes()]);',
            'export default {apples, mangoes};',
          ],
        },
        excludes: {[DATABASE_FILE]: ['await resetApples();']},
        name: 'hand-registered sequential resets fold into one Promise.all',
        setup: seedDatabaseBody(
          [
            "import {apples, resetApples} from './apples/data';",
            '',
            'export const resetTestData = async (): Promise<void> => {',
            '  await resetApples();',
            '};',
            '',
            'export default {apples};',
            '',
          ].join('\n')
        ),
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service rejects each bad argument', () => {
    test.each<ServiceCase>([
      {
        args: ['BadName', '--endpoints', 'get', '--schema', 'id:string'],
        name: 'rejects non-kebab name',
      },
      {
        args: ['projects', '--schema', 'id:string'],
        name: 'rejects missing --endpoints',
      },
      {
        args: ['projects', '--endpoints', 'get'],
        name: 'rejects missing --schema',
      },
      {
        args: ['projects', '--endpoints', 'get,patch', '--schema', 'id:string'],
        name: 'rejects unknown endpoint token',
      },
      {
        args: ['projects', '--endpoints', 'get', '--schema', 'id:bigint'],
        name: 'rejects unknown schema type',
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, {
        ...row,
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
      });
    });
  });

  describe('service resolves the domain-layer folder', () => {
    const projectArgs = [
      'projects',
      '--endpoints',
      'get',
      '--schema',
      'id:string',
    ];

    test.each<ServiceCase>([
      {
        absent: ['app/services/gaia'],
        args: [...projectArgs, '--mocks'],
        contains: {
          [mockFile('projects', 'get.ts')]: [
            "from '~/services/acme/projects/urls'",
          ],
        },
        exists: ['app/services/acme/projects/urls.ts'],
        name: 'writes into a renamed domain-layer folder and points mocks at it',
        setup: (root) => {
          const servicesDir = path.join(root, 'app', 'services');
          rmSync(path.join(servicesDir, 'gaia'), {
            force: true,
            recursive: true,
          });
          mkdirSync(path.join(servicesDir, 'acme'), {recursive: true});
          mkdirSync(path.join(servicesDir, 'api'), {recursive: true});
        },
      },
      {
        absent: ['app/services/gaia/projects', 'app/services/acme/projects'],
        args: projectArgs,
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: 'refuses to guess when several domain-layer folders exist',
        setup: makeAcme,
      },
      {
        args: [...projectArgs, '--layer', 'acme'],
        exists: ['app/services/acme/projects/urls.ts'],
        name: '--layer picks the folder when several exist',
        setup: makeAcme,
      },
      {
        absent: ['app/services/notes/projects'],
        args: [...projectArgs, '--layer', 'notes'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: 'rejects a --layer that names a file, not a folder',
        setup: (root) => {
          writeFileSync(path.join(root, 'app', 'services', 'notes'), '');
        },
      },
      {
        args: [...projectArgs, '--layer', '../escape'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: 'rejects a --layer that is not one folder name',
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service request and mock contract', () => {
    test.each<ServiceCase>([
      {
        args: ITEMS_ARGS,
        contains: {
          [serviceFile('items', 'requests.ts')]: [
            "import {api, envelope} from '../api';",
            'envelope(itemsSchema)',
            'envelope(itemSchema)',
            'json: input',
            'signal',
            'export const updateItem = async (\n  id: string,\n  input: ItemInput,',
            'export const deleteItem = async (\n  id: string,\n  signal?: AbortSignal\n): Promise<void> =>',
          ],
        },
        excludes: {[serviceFile('items', 'requests.ts')]: ['FormData']},
        name: 'requests.ts validates through envelope, sends JSON, and threads signal',
        notMatches: {
          [serviceFile('items', 'requests.ts')]: [
            /\.parse\(/u,
            /api</u,
            / as /u,
          ],
        },
      },
      {
        args: ['items', '--endpoints', 'delete', '--schema', 'id:string'],
        contains: {
          [serviceFile('items', 'requests.ts')]: [
            "import {api} from '../api';",
          ],
        },
        excludes: {
          [serviceFile('items', 'requests.ts')]: ['envelope', './parsers'],
        },
        name: 'a delete-only service imports no unused envelope or parsers',
      },
      {
        args: ITEMS_ARGS,
        contains: {
          [serviceFile('items', 'parsers.ts')]: [
            'itemInputSchema = itemSchema.omit({id: true});',
          ],
          [serviceFile('items', 'types.ts')]: ['export type ItemInput'],
        },
        name: 'input schema omits id when the schema has one',
      },
      {
        args: [
          'items',
          '--endpoints',
          'post',
          '--schema',
          'displayName:string',
        ],
        contains: {
          [serviceFile('items', 'parsers.ts')]: [
            'itemInputSchema = itemSchema;',
          ],
        },
        name: 'input schema is the entity schema when there is no id',
      },
      {
        args: ITEMS_ARGS,
        contains: {
          [serviceFile('items', 'parsers.ts')]: [
            'z.object({\n  id: z.string(),\n  displayName: z.string(),\n});',
          ],
        },
        name: 'parsers.ts keeps one field per line as "  <name>: <zod>,"',
      },
      {
        args: [...ITEMS_ARGS, '--mocks'],
        contains: {
          [mockFile('items', 'post.ts')]: [
            'request.json()',
            'crypto.randomUUID()',
          ],
          [mockFile('items', 'put.ts')]: ['request.json()'],
        },
        excludes: {
          [mockFile('items', 'post.ts')]: ['formData'],
          [mockFile('items', 'put.ts')]: ['formData'],
        },
        name: 'mock post and put read the JSON body, not form data',
      },
      {
        // `@msw/data`'s `delete`, `deleteMany`, and `findMany` are
        // synchronous, so awaiting them fails `await-thenable` in the
        // adopter's lint, as do a sequential await loop and a redundant
        // `undefined` argument.
        args: [...ITEMS_ARGS, '--mocks'],
        contains: {
          [mockFile('items', 'data.ts')]: [
            'items.clear();',
            'await Promise.all(seed.map(async (record) => items.create(record)));',
          ],
          [mockFile('items', 'delete.ts')]: ['const data = items.delete('],
          [mockFile('items', 'get.ts')]: ['items.findMany()'],
        },
        excludes: {[mockFile('items', 'delete.ts')]: ['async']},
        name: 'mock data, get, and delete call the collection the way its types allow',
        notMatches: {
          [mockFile('items', 'data.ts')]: [/for \(|await items\.delete/u],
        },
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service writes queries.ts only when Query and a get endpoint exist', () => {
    const queriesFile = serviceFile('items', 'queries.ts');
    const serviceFiles = [
      'parsers.ts',
      'types.ts',
      'requests.ts',
      'urls.ts',
      'index.ts',
    ].map((file) => serviceFile('items', file));

    test.each<ServiceCase>([
      {
        args: GET_POST_ARGS,
        contains: {
          [queriesFile]: [
            'export const itemKeys',
            'all: ITEMS_ROOT_KEY',
            'detail: (id: string)',
            'queryFn: async ({signal}) => getItemById(id, signal)',
            'queryFn: async ({signal}) => getAllItems(signal)',
            // Every exported factory names its return type, which
            // `explicit-module-boundary-types` requires under app/services/**.
            'export const itemsQuery = (): ReturnType<typeof listOptions> =>',
            'export const itemQuery = (id: string): ReturnType<typeof detailOptions> =>',
          ],
        },
        excludes: {[serviceFile('items', 'index.ts')]: ['queries']},
        name: 'writes queries.ts when Query is installed',
        setup: installQuery,
      },
      {
        absent: [queriesFile],
        args: GET_POST_ARGS,
        name: 'writes no queries.ts without the dependency',
      },
      {
        absent: [queriesFile],
        args: ['items', '--endpoints', 'post', '--schema', 'id:string'],
        name: 'writes no queries.ts when the service has no get endpoint',
        setup: installQuery,
      },
      {
        args: ['items', '--queries-only'],
        exists: [queriesFile],
        name: '--queries-only writes only queries.ts and leaves the rest byte-identical',
        setup: (root) => {
          scaffoldGetPost(root);
          installQuery(root);
        },
        unchanged: serviceFiles,
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });

  describe('service --queries-only refuses an unusable state', () => {
    const queriesFile = serviceFile('items', 'queries.ts');

    test.each<ServiceCase>([
      {
        absent: [queriesFile],
        args: ['items', '--queries-only'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: '--queries-only refuses without Query and names the install command',
        setup: scaffoldGetPost,
        stderr: ['init configure-data-layer --query true'],
      },
      {
        absent: ['app/services/gaia/items'],
        args: ['items', '--queries-only'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: '--queries-only refuses a missing service folder',
        setup: installQuery,
      },
      {
        absent: [queriesFile],
        args: ['items', '--queries-only'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: '--queries-only refuses when requests.ts lacks the by-id getter',
        setup: (root) => {
          scaffoldGetPost(root);
          writeFileSync(
            path.join(itemsDir(root), 'requests.ts'),
            'export const getAllItems = async () => [];\n',
            'utf8'
          );
          installQuery(root);
        },
        stderr: ['getItemById'],
      },
      {
        absent: [queriesFile],
        args: ['items', '--queries-only', '--endpoints', 'get'],
        code: EXIT_CODES.UNKNOWN_SUBCOMMAND,
        name: '--queries-only refuses --endpoints and --schema',
        setup: (root) => {
          scaffoldGetPost(root);
          installQuery(root);
        },
      },
    ])('$name', (row) => {
      expectServiceCase(sandbox.dir, row);
    });
  });
});
