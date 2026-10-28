/**
 * The addons an adopter's original `.storybook/main` lists, which is where an
 * addon with no sign in the preview (the links addon) is declared.
 */
import type {Expression} from 'typescript';
import {parseSource, unwrapExpression} from './ast.js';
import type {Ts} from './ast.js';
import {findMainConfig} from './main-flag.js';
import {asObjectLiteral, findProperty} from './text-edits.js';

/**
 * A string entry, the `name` of an `{name, options}` entry, or the argument of
 * a one-argument path wrapper such as `getAbsolutePath('...')`. Any other
 * entry is computed at runtime and cannot be read statically.
 */
const entryName = (ts: Ts, entry: Expression): string | undefined => {
  const value = unwrapExpression(ts, entry);

  if (ts.isStringLiteralLike(value)) return value.text;

  if (ts.isCallExpression(value)) {
    const [argument] = value.arguments;

    return argument ? entryName(ts, argument) : undefined;
  }
  const literal = asObjectLiteral(ts, value);
  const name = literal && findProperty(ts, literal, 'name');

  return name && ts.isPropertyAssignment(name) ?
      entryName(ts, name.initializer)
    : undefined;
};

/** The addon specifiers main's `addons` array lists; none when it has no literal array. */
export const mainAddonSpecifiers = (ts: Ts, mainSource: string): string[] => {
  const config = findMainConfig(ts, parseSource(ts, mainSource, 'main.ts'));
  const addons = config && findProperty(ts, config, 'addons');

  if (!addons || !ts.isPropertyAssignment(addons)) return [];
  const list = unwrapExpression(ts, addons.initializer);

  return ts.isArrayLiteralExpression(list) ?
      list.elements.flatMap((element) => {
        const name = entryName(ts, element);

        return name === undefined ? [] : [name];
      })
    : [];
};
