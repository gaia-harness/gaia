import {afterEach, expect, test, vi} from 'vitest';
import {DEFAULT_API_URL} from './default-api-url';
import {url} from './mocks/url';

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

test.each([
  {
    browserWindow: undefined,
    expected: `${DEFAULT_API_URL}/things`,
    runtime: 'Node',
  },
  {browserWindow: {}, expected: '/things', runtime: 'a browser'},
])(
  'a handler URL built in $runtime with no API_URL is $expected',
  ({browserWindow, expected}) => {
    vi.stubEnv('API_URL', undefined);
    vi.stubGlobal('window', browserWindow);

    expect(url('things')).toBe(expected);
  }
);
