import {describe, expect, test} from 'vitest';
import {buildRequestHeaders, getParseJson, setPathParams} from '../utils';

describe('api utils', () => {
  test('setPathParams should replace path params', () => {
    expect(setPathParams('api/:id/test/:name', {id: 1, name: 'foo'})).toBe(
      'api/1/test/foo'
    );

    expect(setPathParams('api/test', {id: 1, name: 'foo'})).toBe('api/test');

    expect(setPathParams('api/test')).toBe('api/test');
  });

  test.each([
    ['../x', 'items/..%2Fx'],
    ['a?b', 'items/a%3Fb'],
    ['a#b', 'items/a%23b'],
    ['a/b', 'items/a%2Fb'],
    ['../x?y#z/w', 'items/..%2Fx%3Fy%23z%2Fw'],
  ])('setPathParams encodes %s', (value, expected) => {
    expect(setPathParams('items/:id', {id: value})).toBe(expected);
  });

  test.each(['.', '..'])(
    'setPathParams rejects the dot segment %s',
    (value) => {
      expect(() => setPathParams('items/:id', {id: value})).toThrow(
        'Path param cannot be a dot segment'
      );
    }
  );

  test('setPathParams rejects an empty segment', () => {
    expect(() => setPathParams('items/:id', {id: ''})).toThrow(
      'Path param cannot be empty'
    );
  });

  test('setPathParams does not let a key rewrite a longer placeholder it prefixes', () => {
    expect(
      setPathParams('/users/:userId/items/:user', {user: 'a', userId: 'b'})
    ).toBe('/users/b/items/a');
    expect(setPathParams('/users/:userId/items/:user', {user: 'a'})).toBe(
      '/users/:userId/items/a'
    );
  });

  test('setPathParams replaces every occurrence of a repeated placeholder', () => {
    expect(setPathParams('/:id/copy/:id', {id: 7})).toBe('/7/copy/7');
  });

  test('setPathParams keeps a dot inside a longer segment', () => {
    expect(setPathParams('items/:id', {id: 'a.b'})).toBe('items/a.b');
    expect(setPathParams('items/:id', {id: '...'})).toBe('items/...');
  });

  test('the snake_case parseJson delivers a JSON body of false as false', async () => {
    const parseJson = getParseJson(true);
    const context = {
      request: new Request('https://example.test'),
      response: new Response('false'),
    };

    expect(await parseJson?.('false', context)).toBe(false);
  });

  test('buildRequestHeaders applies per-request token and language', () => {
    const headers = buildRequestHeaders(undefined, 'abc123', 'ja');

    expect(headers.get('Authorization')).toBe('Bearer abc123');
    expect(headers.get('Accept-Language')).toBe('ja');
  });

  test('buildRequestHeaders preserves caller headers and omits absent values', () => {
    const headers = buildRequestHeaders({'X-Custom': 'keep'});

    expect(headers.get('X-Custom')).toBe('keep');
    expect(headers.get('Authorization')).toBeNull();
    expect(headers.get('Accept-Language')).toBeNull();
  });
});
