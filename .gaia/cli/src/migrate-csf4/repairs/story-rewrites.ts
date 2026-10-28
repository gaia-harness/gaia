/**
 * Two narrow story-file rewrites: the stable preview import in place of the
 * codemod's deep relative one, and the meta's custom args type the codemod
 * drops (without it, stories whose args exceed the component's props fail
 * typecheck).
 */
import {
  findMetaBinding,
  findPreviewImport,
  importDeclarations,
  isRelativePreviewSpecifier,
  moduleSpecifier,
  parseSource,
  PREVIEW_SPECIFIER,
} from './ast.js';
import type {Ts} from './ast.js';
import {applyEdits} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

/** Replaces each relative preview import specifier with `#.storybook/preview`. */
export const stabilizePreviewImport = (
  ts: Ts,
  source: string,
  filePath: string
): {changed: boolean; source: string} => {
  const file = parseSource(ts, source, filePath);
  const edits: TextEdit[] = importDeclarations(ts, file)
    .filter((declaration) =>
      isRelativePreviewSpecifier(moduleSpecifier(ts, declaration))
    )
    .map(({moduleSpecifier: specifier}) => {
      const quote = source[specifier.getStart()] ?? "'";

      return {
        end: specifier.end,
        start: specifier.getStart(),
        text: `${quote}${PREVIEW_SPECIFIER}${quote}`,
      };
    });

  return {changed: edits.length > 0, source: applyEdits(source, edits)};
};

/** Rewrites `preview.meta(` to `preview.type<{args: X}>().meta(`. */
export const restoreMetaArgsType = (
  ts: Ts,
  source: string,
  {argsType, filePath}: {argsType: string; filePath: string}
): {changed: boolean; source: string} => {
  const file = parseSource(ts, source, filePath);
  const previewImport = findPreviewImport(ts, file);
  const meta = previewImport && findMetaBinding(ts, file, previewImport.name);

  if (
    !previewImport ||
    !meta ||
    !ts.isPropertyAccessExpression(meta.call.expression)
  ) {
    return {changed: false, source};
  }
  const target = meta.call.expression.expression;

  if (!ts.isIdentifier(target)) return {changed: false, source};

  return {
    changed: true,
    source: applyEdits(source, [
      {
        end: target.end,
        start: target.end,
        text: `.type<{args: ${argsType}}>()`,
      },
    ]),
  };
};
