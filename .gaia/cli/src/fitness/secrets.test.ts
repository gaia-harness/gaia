import {describe, expect, test} from 'vitest';
import {redact, redactDeep, SECRET_KEY_PATTERN} from './secrets.js';

// Built at run time so no credential-shaped literal is ever committed.
const buildCredential = (): string =>
  `${[
    'sk',
    'ant',
    Array.from({length: 4}, (_, index) => `Zq${index}Xw`).join(''),
  ].join('-')}Lm9PrT3vBn7KcY2d`;

describe('redact', () => {
  test('replaces a credential-shaped value and leaves no 8-character piece of it', () => {
    const value = buildCredential();
    const output = redact(`token: ${value} end`);

    expect(output).toBe('token: [redacted] end');

    for (let start = 0; start + 8 <= value.length; start += 1) {
      expect(output).not.toContain(value.slice(start, start + 8));
    }
  });

  test('replaces every match, not just the first', () => {
    const value = buildCredential();

    expect(redact(`${value} and ${value}`)).toBe('[redacted] and [redacted]');
  });

  test('leaves ordinary text alone', () => {
    expect(redact('a normal sentence about skills')).toBe(
      'a normal sentence about skills'
    );
  });
});

describe('redactDeep', () => {
  test('redacts strings nested in arrays and objects', () => {
    const value = buildCredential();

    expect(
      redactDeep({count: 3, list: [`x ${value}`], nested: {text: value}})
    ).toEqual({count: 3, list: ['x [redacted]'], nested: {text: '[redacted]'}});
  });
});

describe('SECRET_KEY_PATTERN', () => {
  test.each(['API_KEY', 'DB_PASSWORD', 'GITHUB_TOKEN', 'client_secret'])(
    'matches %s',
    (key) => {
      expect(SECRET_KEY_PATTERN.test(key)).toBe(true);
    }
  );

  test.each(['PATH', 'HOME', 'NODE_ENV'])('does not match %s', (key) => {
    expect(SECRET_KEY_PATTERN.test(key)).toBe(false);
  });
});
