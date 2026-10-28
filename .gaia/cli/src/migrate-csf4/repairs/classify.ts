/**
 * The story-file format predicate every reader shares (the red-ledger
 * extractor, quick-classify and the migration command apply the same clauses
 * in the same order), decided from the source text alone and never by
 * resolving a path on disk.
 */
import type {Node, SourceFile} from 'typescript';
import {
  exportedDeclarations,
  findMetaBinding,
  findPreviewImport,
  hasDefaultExport,
  parseSource,
  unwrapExpression,
} from './ast.js';
import type {Ts} from './ast.js';

/** The format a story file is written in. */
export type StoryFormat = 'csf2' | 'csf3' | 'csf4' | 'unknown';

const callsStoriesOf = (ts: Ts, file: SourceFile): boolean => {
  let found = false;

  const visit = (node: Node): void => {
    if (found) return;

    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'storiesOf'
    ) {
      found = true;

      return;
    }
    ts.forEachChild(node, visit);
  };

  visit(file);

  return found;
};

const exportsATemplateBind = (ts: Ts, file: SourceFile): boolean =>
  exportedDeclarations(ts, file).some(({declaration}) => {
    if (!declaration.initializer) return false;
    const value = unwrapExpression(ts, declaration.initializer);

    return (
      ts.isCallExpression(value) &&
      ts.isPropertyAccessExpression(value.expression) &&
      value.expression.name.text === 'bind' &&
      ts.isIdentifier(value.expression.expression)
    );
  });

const exportsAnObjectLiteral = (ts: Ts, file: SourceFile): boolean =>
  exportedDeclarations(ts, file).some(
    ({declaration}) =>
      declaration.initializer !== undefined &&
      ts.isObjectLiteralExpression(
        unwrapExpression(ts, declaration.initializer)
      )
  );

const isCsf4 = (ts: Ts, file: SourceFile): boolean => {
  if (hasDefaultExport(ts, file)) return false;
  const previewImport = findPreviewImport(ts, file);

  if (!previewImport) return false;
  if (!findMetaBinding(ts, file, previewImport.name)) return false;

  return !exportsAnObjectLiteral(ts, file);
};

/** Classifies a story file as CSF2, CSF3, CSF4 or unknown. */
export const classifyStoryFile = (
  ts: Ts,
  source: string,
  filePath: string
): StoryFormat => {
  const file = parseSource(ts, source, filePath);

  if (callsStoriesOf(ts, file) || exportsATemplateBind(ts, file)) return 'csf2';
  if (isCsf4(ts, file)) return 'csf4';
  if (hasDefaultExport(ts, file)) return 'csf3';

  return 'unknown';
};
