import {describe, expect, test} from 'vitest';
import {buildRequestHeaders, getParseJson, setPathParams} from '../utils';

const yields =
  (expected: string) =>
  (call: () => string): void => {
    expect(call()).toBe(expected);
  };

const throws =
  (message: string) =>
  (call: () => string): void => {
    expect(call).toThrow(message);
  };

describe('api utils', () => {
  test.each(
    [
      {
        check: yields('api/1/test/foo'),
        name: 'replaces path params',
        params: {id: 1, name: 'foo'},
        path: 'api/:id/test/:name',
      },
      {
        check: yields('api/test'),
        name: 'leaves a path without placeholders',
        params: {id: 1, name: 'foo'},
        path: 'api/test',
      },
      {
        check: yields('api/test'),
        name: 'leaves a path when no params are given',
        params: undefined,
        path: 'api/test',
      },
      ...(
        [
          ['../x', 'items/..%2Fx'],
          ['a?b', 'items/a%3Fb'],
          ['a#b', 'items/a%23b'],
          ['a/b', 'items/a%2Fb'],
          ['../x?y#z/w', 'items/..%2Fx%3Fy%23z%2Fw'],
        ] as const
      ).map(([value, expected]) => ({
        check: yields(expected),
        name: `encodes ${value}`,
        params: {id: value},
        path: 'items/:id',
      })),
      ...['.', '..'].map((value) => ({
        check: throws('Path param cannot be a dot segment'),
        name: `rejects the dot segment ${value}`,
        params: {id: value},
        path: 'items/:id',
      })),
      {
        check: throws('Path param cannot be empty'),
        name: 'rejects an empty segment',
        params: {id: ''},
        path: 'items/:id',
      },
      {
        check: yields('/users/b/items/a'),
        name: 'does not let a key rewrite a longer placeholder it prefixes',
        params: {user: 'a', userId: 'b'},
        path: '/users/:userId/items/:user',
      },
      {
        check: yields('/users/:userId/items/a'),
        name: 'does not let a short key rewrite a longer placeholder it prefixes when only the short key is given',
        params: {user: 'a'},
        path: '/users/:userId/items/:user',
      },
      {
        check: yields('/7/copy/7'),
        name: 'replaces every occurrence of a repeated placeholder',
        params: {id: 7},
        path: '/:id/copy/:id',
      },
      {
        check: yields('items/a.b'),
        name: 'keeps a dot inside a longer segment',
        params: {id: 'a.b'},
        path: 'items/:id',
      },
      {
        check: yields('items/...'),
        name: 'keeps a run of three dots',
        params: {id: '...'},
        path: 'items/:id',
      },
    ].map((row) => [row.name, row] as const)
  )(
    'setPathParams substitutes, encodes and refuses path params: %s',
    (_name, {check, params, path}) => {
      expect.hasAssertions();
      check(() =>
        setPathParams(
          path,
          params as Record<string, number | string> | undefined
        )
      );
    }
  );

  test('the snake_case parseJson delivers a JSON body of false as false', async () => {
    const parseJson = getParseJson(true);
    const context = {
      request: new Request('https://example.test'),
      response: new Response('false'),
    };

    expect(await parseJson?.('false', context)).toBe(false);
  });

  test.each(
    [
      {
        expected: {
          'Accept-Language': 'ja',
          Authorization: 'Bearer abc123',
        },
        headers: undefined,
        language: 'ja',
        name: 'applies per-request token and language',
        token: 'abc123',
      },
      {
        expected: {
          'Accept-Language': null,
          Authorization: null,
          'X-Custom': 'keep',
        },
        headers: {'X-Custom': 'keep'},
        language: undefined,
        name: 'preserves caller headers and omits absent values',
        token: undefined,
      },
    ].map((row) => [row.name, row] as const)
  )(
    'buildRequestHeaders sets token and language and keeps caller headers: %s',
    (_name, {expected, headers: callerHeaders, language, token}) => {
      const headers = buildRequestHeaders(callerHeaders, token, language);

      for (const [headerName, headerValue] of Object.entries(expected)) {
        expect(headers.get(headerName)).toBe(headerValue);
      }
    }
  );
});
