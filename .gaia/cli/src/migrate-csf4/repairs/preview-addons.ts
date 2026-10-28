/**
 * Which addons a CSF3 preview wires, and the CSF Next text that wires them.
 * Each addon is wired only when the project shows it (main lists it, or the
 * preview imports the addon package or has the parameter the addon reads), so
 * a project that removed an addon never gets it back.
 */
import type {ObjectLiteralExpression} from 'typescript';
import type {Ts} from './ast.js';
import {findProperty, objectValueOf} from './text-edits.js';

export const MSW = 'msw-storybook-addon';
const I18NEXT = 'storybook-react-i18next';
const A11Y = '@storybook/addon-a11y';
const LINKS = '@storybook/addon-links';
const DOCS = '@storybook/addon-docs';

/**
 * Addons with no `/preview` entry, so the csf-factories codemod's main-to-preview
 * sync skips them and the preview needs nothing for them.
 */
const NO_PREVIEW_ENTRY = ['@storybook/addon-vitest'];

/** The i18next addon's preview annotations; its package root exports none. */
const I18NEXT_PREVIEW = `${I18NEXT}/preview`;

/** The dark-mode addon is manager-only: it stays in main and never enters the preview. */
export const DARK_MODE = [
  '@vueless/storybook-dark-mode',
  'storybook-dark-mode',
];

const KNOWN_ADDONS = new Set([
  A11Y,
  DOCS,
  I18NEXT,
  LINKS,
  MSW,
  ...DARK_MODE,
  ...NO_PREVIEW_ENTRY,
]);
const ADDON_PACKAGE = /(?:^|[/-])addon(?:[/-]|$)|(?:^|\/)storybook-/u;

/** The package a module specifier resolves into. */
export const packageName = (specifier: string): string => {
  const parts = specifier.split('/');

  return specifier.startsWith('@') ?
      parts.slice(0, 2).join('/')
    : (parts[0] ?? specifier);
};

/** The addons a preview wires. */
export type AddonWiring = {
  a11y: boolean;
  docs: boolean;
  i18next: boolean;
  links: boolean;
  msw: boolean;
};

/** Reads the wiring from main's addons and the preview's imports and config object. */
export const detectAddonWiring = (
  ts: Ts,
  {
    config,
    mainAddons,
    specifiers,
  }: {
    config: ObjectLiteralExpression;
    mainAddons: readonly string[];
    specifiers: readonly string[];
  }
): AddonWiring => {
  const property = findProperty(ts, config, 'parameters');
  const parameters = objectValueOf(ts, property);
  const hasParameter = (name: string): boolean =>
    parameters !== undefined &&
    findProperty(ts, parameters, name) !== undefined;
  const imported = (name: string): boolean =>
    [...specifiers, ...mainAddons].some(
      (specifier) => packageName(specifier) === name
    );

  return {
    a11y: imported(A11Y) || hasParameter('a11y'),
    docs: imported(DOCS),
    i18next: imported(I18NEXT) || hasParameter('i18n'),
    links: imported(LINKS),
    msw: imported(MSW),
  };
};

/** Imported or main-listed addon packages this rewiring does not know how to wire. */
export const unknownAddonSpecifiers = (
  specifiers: readonly string[]
): string[] => [
  ...new Set(
    specifiers.filter(
      (specifier) =>
        !specifier.startsWith('.') &&
        ADDON_PACKAGE.test(packageName(specifier)) &&
        !KNOWN_ADDONS.has(packageName(specifier))
    )
  ),
];

/** The import lines the rewired preview needs, in the quote style of the original. */
export const addonImportLines = (
  wiring: AddonWiring,
  {framework, quote}: {framework: string; quote: string}
): string => {
  const quoted = (text: string): string => quote + text + quote;
  const csfInternal = quoted('storybook/internal/csf');

  return [
    ...(wiring.a11y ? [`import addonA11y from ${quoted(A11Y)};`] : []),
    ...(wiring.docs ? [`import addonDocs from ${quoted(DOCS)};`] : []),
    ...(wiring.links ? [`import addonLinks from ${quoted(LINKS)};`] : []),
    `import {definePreview} from ${quoted(framework)};`,
    ...(wiring.msw ? [`import addonMsw from ${quoted(MSW)};`] : []),
    ...(wiring.i18next ?
      [
        `import storybookReactI18next from ${quoted(I18NEXT_PREVIEW)};`,
        '// Storybook internal import: it can change in any upgrade.',
        `import type {AddonTypes} from ${csfInternal};`,
        `import {definePreviewAddon} from ${csfInternal};`,
      ]
    : []),
  ].join('\n');
};

/**
 * The `addons` property text, or undefined when nothing is wired. The
 * explicit `<AddonTypes>` is load-bearing: without it the whole preview infers
 * `ReactPreview<never>`, so the lint rule that would strip it is disabled on
 * that line.
 */
export const addonsPropertyText = (
  wiring: AddonWiring,
  indent: string
): string | undefined => {
  const entryIndent = `${indent}  `;
  const disable =
    '// eslint-disable-next-line @typescript-eslint/no-unnecessary-type-arguments -- the explicit argument is the documented CSF Next wiring';
  const entries = [
    ...(wiring.a11y ? ['addonA11y(),'] : []),
    ...(wiring.docs ? ['addonDocs(),'] : []),
    ...(wiring.links ? ['addonLinks(),'] : []),
    ...(wiring.i18next ?
      [disable, 'definePreviewAddon<AddonTypes>(storybookReactI18next),']
    : []),
    ...(wiring.msw ? ['addonMsw(),'] : []),
  ];

  if (entries.length === 0) return undefined;
  const lines = entries.map((entry) => entryIndent + entry).join('\n');

  return `addons: [\n${lines}\n${indent}]`;
};
