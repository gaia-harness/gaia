import {afterEach, expect, test, vi} from 'vitest';
import {DEFAULT_API_URL} from './default-api-url';
import {url} from './mocks/url';

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

test.each([
  {
    apiUrl: undefined,
    apiUrlState: 'unset',
    browserWindow: undefined,
    expected: `${DEFAULT_API_URL}/things`,
    runtime: 'Node',
  },
  {
    apiUrl: '',
    apiUrlState: 'empty',
    browserWindow: undefined,
    expected: `${DEFAULT_API_URL}/things`,
    runtime: 'Node',
  },
  {
    apiUrl: undefined,
    apiUrlState: 'unset',
    browserWindow: {},
    expected: '/things',
    runtime: 'a browser',
  },
])(
  'a handler URL built in $runtime with API_URL $apiUrlState is $expected',
  ({apiUrl, browserWindow, expected}) => {
    vi.stubEnv('API_URL', apiUrl);
    vi.stubGlobal('window', browserWindow);

    expect(url('things')).toBe(expected);
  }
);
