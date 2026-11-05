import {describe, expect, test} from 'vitest';
// Runs in the node project.
import {readFileSync} from 'node:fs';
import path from 'node:path';

const stylesDirectory = path.resolve(import.meta.dirname, '../app/styles');
const tokenCss = readFileSync(path.join(stylesDirectory, 'theme.css'), 'utf-8');

const buildBlockPattern = (selector: string): RegExp =>
  new RegExp(String.raw`(?:^|\n)${selector}\s*\{([^}]*)\}`);

const parseBlock = (selector: string): Map<string, string> => {
  const body = (
    buildBlockPattern(selector).exec(tokenCss)?.[1] ?? ''
  ).replaceAll(/\/\*[^*]*\*\//g, '');
  const declarations = new Map<string, string>();

  for (const declaration of body.split(';')) {
    const separator = declaration.indexOf(':');

    if (declaration.trimStart().startsWith('--') && separator !== -1) {
      declarations.set(
        declaration.slice(0, separator).trim(),
        declaration.slice(separator + 1).trim()
      );
    }
  }

  return declarations;
};

const rootTokens = parseBlock(':root');
const darkTokens = parseBlock(String.raw`\.dark`);

// Percentage lightness and `deg` hue, the form the stylelint config enforces.
const stylelintOklch =
  /^oklch\(\d+(?:\.\d+)?% \d+(?:\.\d+)? \d+(?:\.\d+)?deg(?: \/ \d+(?:\.\d+)?%)?\)$/;

const requiredTokens = [
  '--accent',
  '--accent-foreground',
  '--background',
  '--border',
  '--card',
  '--card-foreground',
  '--chart-1',
  '--chart-2',
  '--chart-3',
  '--chart-4',
  '--chart-5',
  '--destructive',
  '--foreground',
  '--input',
  '--muted',
  '--muted-foreground',
  '--popover',
  '--popover-foreground',
  '--primary',
  '--primary-foreground',
  '--ring',
  '--secondary',
  '--secondary-foreground',
  '--sidebar',
  '--sidebar-accent',
  '--sidebar-accent-foreground',
  '--sidebar-border',
  '--sidebar-foreground',
  '--sidebar-primary',
  '--sidebar-primary-foreground',
  '--sidebar-ring',
];

const findBadTokens = (
  tokens: Map<string, string>,
  expected: string[]
): string[] =>
  expected.flatMap((name) => {
    const value = tokens.get(name);

    if (value === undefined) return [`${name}: missing`];

    return stylelintOklch.test(value) ? [] : [`${name}: ${value}`];
  });

describe('theme tokens', () => {
  test(':root defines every required token in stylelint oklch form, plus --radius', () => {
    expect(findBadTokens(rootTokens, requiredTokens)).toEqual([]);
    expect(rootTokens.has('--radius')).toBe(true);
  });

  test('.dark defines every required token in stylelint oklch form', () => {
    expect(findBadTokens(darkTokens, requiredTokens)).toEqual([]);
  });
});
