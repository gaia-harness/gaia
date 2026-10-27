/**
 * What the codemod loses, read from the CSF3 original before it runs: the
 * opening comment, the meta's custom args type, and the factory-built exports
 * it skips.
 */
import type {Expression, SourceFile, TypeNode} from 'typescript';
import {
  exportedDeclarations,
  factoryCallOf,
  findDeclaration,
  findExportDefault,
  parseSource,
  topLevelFunctions,
} from './ast.js';
import type {Ts} from './ast.js';
import {extractLeadingComment} from './leading-comment.js';

/** Facts about a CSF3 original that its codemod output no longer carries. */
export type PreCodemodFacts = {
  factoryExports: readonly string[];
  leadingComment: string | undefined;
  metaArgsType: string | undefined;
};

/** The X of a `Meta<X>` type, unless X is `typeof <Component>`. */
const customArgsType = (
  ts: Ts,
  type: TypeNode | undefined
): string | undefined => {
  if (!type || !ts.isTypeReferenceNode(type)) return undefined;
  const name =
    ts.isIdentifier(type.typeName) ?
      type.typeName.text
    : type.typeName.right.text;

  if (name !== 'Meta') return undefined;
  const [argument] = type.typeArguments ?? [];

  if (!argument || ts.isTypeQueryNode(argument)) return undefined;

  return argument.getText();
};

const argsTypeOfExpression = (
  ts: Ts,
  expression: Expression
): string | undefined => {
  let current = expression;

  while (
    ts.isParenthesizedExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isAsExpression(current)
  ) {
    if (!ts.isParenthesizedExpression(current)) {
      const found = customArgsType(ts, current.type);

      if (found) return found;
    }
    current = current.expression;
  }

  return undefined;
};

const metaArgsTypeOf = (ts: Ts, file: SourceFile): string | undefined => {
  const exportDefault = findExportDefault(ts, file);

  if (!exportDefault) return undefined;
  const {expression} = exportDefault;

  if (!ts.isIdentifier(expression)) return argsTypeOfExpression(ts, expression);
  const meta = findDeclaration(ts, file, expression.text)?.declaration;

  if (!meta) return undefined;

  return (
    customArgsType(ts, meta.type) ??
    (meta.initializer ? argsTypeOfExpression(ts, meta.initializer) : undefined)
  );
};

/** Reads the facts the codemod would lose from a CSF3 original. */
export const capturePreCodemodFacts = (
  ts: Ts,
  source: string,
  filePath: string
): PreCodemodFacts => {
  const file = parseSource(ts, source, filePath);
  const functions = topLevelFunctions(ts, file);

  return {
    factoryExports: exportedDeclarations(ts, file)
      .filter(({declaration}) =>
        factoryCallOf(ts, declaration.initializer, functions)
      )
      .map(({name}) => name),
    leadingComment: extractLeadingComment(source)?.comment,
    metaArgsType: metaArgsTypeOf(ts, file),
  };
};
