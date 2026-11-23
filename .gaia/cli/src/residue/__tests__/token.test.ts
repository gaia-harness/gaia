import {describe, expect, test} from 'vitest';
import {decodeToken, encodeToken, TOKEN_PATTERN} from '../token.js';

const forgeToken = (decodedForm: string): string =>
  Buffer.from(decodedForm, 'utf8').toString('base64url');

describe('token encode and decode round-trip', () => {
  test.each([
    {
      coordinate: {line: 42, path: 'app/services/foo.ts', pr_number: 1234},
      title: 'round-trips a plain coordinate through encode and decode',
    },
    {
      coordinate: {
        line: 7,
        path: "app/services/danger; rm -rf ' file.ts",
        pr_number: 9,
      },
      title:
        'a path carrying a space, a semicolon, and a single quote still produces a token inside the pattern and round-trips',
    },
  ])('$title', ({coordinate}) => {
    const token = encodeToken(coordinate);

    expect(TOKEN_PATTERN.test(token)).toBe(true);
    expect(decodeToken(token)).toEqual({ok: true, value: coordinate});
  });
});

describe('token decode refuses each bad token', () => {
  test.each([
    {
      insidePattern: false,
      title: 'refuses a token outside the character set',
      token: 'not a token',
    },
    {
      insidePattern: true,
      title: 'refuses a well-formed token whose decoded path is a traversal',
      token: forgeToken('9:../../etc/passwd:1'),
    },
    {
      insidePattern: true,
      title: 'refuses a token that does not decode to a three-field shape',
      token: forgeToken('not-three-fields'),
    },
  ])('$title', ({insidePattern, token}) => {
    // A forged row is only a real test of the decoder when its token gets
    // past the character-set check.
    expect(TOKEN_PATTERN.test(token)).toBe(insidePattern);

    expect(decodeToken(token).ok).toBe(false);
  });
});
