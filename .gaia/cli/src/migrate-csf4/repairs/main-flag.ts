/**
 * Turns on `features.experimentalTestSyntax` in an adopter's original
 * `.storybook/main`, which is what lets a CSF4 story carry `.test()` calls.
 * Never touches `experimentalDocgenServer` or any other feature.
 */
import type {ObjectLiteralExpression, SourceFile} from 'typescript';
import {
  findDeclaration,
  findExportDefault,
  parseSource,
  unwrapExpression,
} from './ast.js';
import type {Ts} from './ast.js';
import {
  applyEdits,
  asObjectLiteral,
  findProperty,
  insertPropertiesEdit,
  objectValueOf,
} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

const FLAG = 'experimentalTestSyntax';

/**
 * The config object of each main shape: a const bound and exported, a
 * directly exported object, or `export default defineMain({...})`.
 */
export const findMainConfig = (
  ts: Ts,
  file: SourceFile
): ObjectLiteralExpression | undefined => {
  const exportDefault = findExportDefault(ts, file);

  if (!exportDefault) return undefined;
  const value = unwrapExpression(ts, exportDefault.expression);

  if (ts.isIdentifier(value)) {
    return asObjectLiteral(
      ts,
      findDeclaration(ts, file, value.text)?.declaration.initializer
    );
  }

  if (
    ts.isCallExpression(value) &&
    ts.isIdentifier(value.expression) &&
    value.expression.text === 'defineMain'
  ) {
    return asObjectLiteral(ts, value.arguments[0]);
  }

  return asObjectLiteral(ts, value);
};

/** Sets `features.experimentalTestSyntax: true`; any other main shape is returned unchanged. */
export const setTestSyntaxFlag = (
  ts: Ts,
  mainSource: string
): {changed: boolean; source: string} => {
  const unchanged = {changed: false, source: mainSource};
  const config = findMainConfig(ts, parseSource(ts, mainSource, 'main.ts'));

  if (!config) return unchanged;
  const features = findProperty(ts, config, 'features');
  let edits: TextEdit[];

  if (features) {
    const literal = objectValueOf(ts, features);

    if (!literal) return unchanged;
    const flag = findProperty(ts, literal, FLAG);

    if (!flag) {
      edits = insertPropertiesEdit(mainSource, literal, [`${FLAG}: true`]);
    } else if (
      ts.isPropertyAssignment(flag) &&
      flag.initializer.kind === ts.SyntaxKind.FalseKeyword
    ) {
      edits = [
        {
          end: flag.initializer.end,
          start: flag.initializer.getStart(),
          text: 'true',
        },
      ];
    } else {
      return unchanged;
    }
  } else {
    edits = insertPropertiesEdit(mainSource, config, [
      `features: {${FLAG}: true}`,
    ]);
  }

  return {changed: true, source: applyEdits(mainSource, edits)};
};
