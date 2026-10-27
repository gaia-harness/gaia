/**
 * Parsing and node lookups shared by the repairs. The TypeScript module is
 * always the caller's (the adopter package's own `typescript`), never imported
 * here at runtime, so the CLI bundle never carries a compiler.
 */
import type {
  ArrowFunction,
  CallExpression,
  ExportAssignment,
  Expression,
  FunctionDeclaration,
  FunctionExpression,
  ImportDeclaration,
  Node,
  SourceFile,
  Statement,
  SyntaxKind,
  VariableDeclaration,
  VariableStatement,
} from 'typescript';

/** The TypeScript compiler module the repairs parse with. */
// eslint-disable-next-line @typescript-eslint/consistent-type-imports -- a namespace type import of this export= module adds a synthetic `default` the caller's own `typescript` value lacks
export type Ts = typeof import('typescript');

/** Parses `source` as a module, choosing JSX support from the extension. */
export const parseSource = (
  ts: Ts,
  source: string,
  filePath: string
): SourceFile => {
  const scriptKind =
    /\.[cm]?ts$/u.test(filePath) ? ts.ScriptKind.TS
    : /\.[cm]?js$/u.test(filePath) ? ts.ScriptKind.JS
    : filePath.endsWith('.jsx') ? ts.ScriptKind.JSX
    : ts.ScriptKind.TSX;

  return ts.createSourceFile(
    filePath,
    source,
    ts.ScriptTarget.Latest,
    true,
    scriptKind
  );
};

/** `expression` without wrapping parentheses, `satisfies` or `as`. */
export const unwrapExpression = (
  ts: Ts,
  expression: Expression
): Expression => {
  let current = expression;

  while (
    ts.isParenthesizedExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isAsExpression(current)
  ) {
    current = current.expression;
  }

  return current;
};

/** The module specifier of an import declaration, as written. */
export const moduleSpecifier = (
  ts: Ts,
  declaration: ImportDeclaration
): string =>
  ts.isStringLiteral(declaration.moduleSpecifier) ?
    declaration.moduleSpecifier.text
  : '';

/** The import declarations at the top level of `file`. */
export const importDeclarations = (
  ts: Ts,
  file: SourceFile
): ImportDeclaration[] =>
  file.statements.filter((statement) => ts.isImportDeclaration(statement));

const RELATIVE_PREVIEW =
  /^\.\.?\/(?:.*\/)?\.storybook\/preview(?:\.(?:ts|tsx|js|jsx|mjs|mts))?$/u;

/** The stable preview specifier story files import. */
export const PREVIEW_SPECIFIER = '#.storybook/preview';

/** Whether `specifier` names the Storybook preview (stable or relative form). */
const isPreviewSpecifier = (specifier: string): boolean =>
  specifier === PREVIEW_SPECIFIER || RELATIVE_PREVIEW.test(specifier);

/** Whether `specifier` is a relative path to the Storybook preview. */
export const isRelativePreviewSpecifier = (specifier: string): boolean =>
  RELATIVE_PREVIEW.test(specifier);

/** The default import of the preview, when the file has one. */
export const findPreviewImport = (
  ts: Ts,
  file: SourceFile
): undefined | {declaration: ImportDeclaration; name: string} => {
  for (const declaration of importDeclarations(ts, file)) {
    const name = declaration.importClause?.name?.text;

    if (name && isPreviewSpecifier(moduleSpecifier(ts, declaration))) {
      return {declaration, name};
    }
  }

  return undefined;
};

/** Each declaration of every top-level `const`/`let`/`var` statement. */
const topLevelDeclarations = (
  ts: Ts,
  file: SourceFile
): {declaration: VariableDeclaration; statement: VariableStatement}[] =>
  file.statements
    .filter((statement) => ts.isVariableStatement(statement))
    .flatMap((statement) =>
      statement.declarationList.declarations.map((declaration) => ({
        declaration,
        statement,
      }))
    );

const hasModifier = (ts: Ts, node: Statement, kind: SyntaxKind): boolean =>
  (ts.canHaveModifiers(node) ? ts.getModifiers(node) : undefined)?.some(
    (modifier) => modifier.kind === kind
  ) ?? false;

/** The named `export const` declarations of `file`. */
export const exportedDeclarations = (
  ts: Ts,
  file: SourceFile
): {
  declaration: VariableDeclaration;
  name: string;
  statement: VariableStatement;
}[] =>
  topLevelDeclarations(ts, file).flatMap(({declaration, statement}) =>
    (
      ts.isIdentifier(declaration.name) &&
      hasModifier(ts, statement, ts.SyntaxKind.ExportKeyword)
    ) ?
      [{declaration, name: declaration.name.text, statement}]
    : []
  );

/** The `export default <expression>;` statement, when the file has one. */
export const findExportDefault = (
  ts: Ts,
  file: SourceFile
): ExportAssignment | undefined =>
  file.statements.find(
    (statement): statement is ExportAssignment =>
      ts.isExportAssignment(statement) && !statement.isExportEquals
  );

/** The top-level declaration that binds `name`. */
export const findDeclaration = (
  ts: Ts,
  file: SourceFile,
  name: string
):
  | undefined
  | {declaration: VariableDeclaration; statement: VariableStatement} =>
  topLevelDeclarations(ts, file).find(
    ({declaration}) =>
      ts.isIdentifier(declaration.name) && declaration.name.text === name
  );

/** Whether the file has a default export in any spelling. */
export const hasDefaultExport = (ts: Ts, file: SourceFile): boolean =>
  file.statements.some(
    (statement) =>
      (ts.isExportAssignment(statement) && !statement.isExportEquals) ||
      (hasModifier(ts, statement, ts.SyntaxKind.ExportKeyword) &&
        hasModifier(ts, statement, ts.SyntaxKind.DefaultKeyword)) ||
      (ts.isExportDeclaration(statement) &&
        statement.exportClause !== undefined &&
        ts.isNamedExports(statement.exportClause) &&
        statement.exportClause.elements.some(
          (element) => element.name.text === 'default'
        ))
  );

/**
 * The binding initialized from `<preview>.meta(` or
 * `<preview>.type<…>().meta(`, with that call.
 */
export const findMetaBinding = (
  ts: Ts,
  file: SourceFile,
  previewName: string
): undefined | {call: CallExpression; name: string} => {
  const isPreviewTarget = (target: Expression): boolean =>
    (ts.isIdentifier(target) && target.text === previewName) ||
    (ts.isCallExpression(target) &&
      ts.isPropertyAccessExpression(target.expression) &&
      target.expression.name.text === 'type' &&
      ts.isIdentifier(target.expression.expression) &&
      target.expression.expression.text === previewName);

  for (const {declaration} of topLevelDeclarations(ts, file)) {
    const call =
      declaration.initializer && unwrapExpression(ts, declaration.initializer);

    if (
      call &&
      ts.isIdentifier(declaration.name) &&
      ts.isCallExpression(call) &&
      ts.isPropertyAccessExpression(call.expression) &&
      call.expression.name.text === 'meta' &&
      isPreviewTarget(call.expression.expression)
    ) {
      return {call, name: declaration.name.text};
    }
  }

  return undefined;
};

/** A same-file function a story export can be built from. */
export type StoryFactory = {
  name: string;
  node: ArrowFunction | FunctionDeclaration | FunctionExpression;
  statement: Statement;
};

/** Every top-level function binding of `file`, by name. */
export const topLevelFunctions = (
  ts: Ts,
  file: SourceFile
): Map<string, StoryFactory> => {
  const functions = new Map<string, StoryFactory>();

  for (const statement of file.statements) {
    if (
      ts.isFunctionDeclaration(statement) &&
      statement.name &&
      statement.body
    ) {
      functions.set(statement.name.text, {
        name: statement.name.text,
        node: statement,
        statement,
      });
    }
  }

  for (const {declaration, statement} of topLevelDeclarations(ts, file)) {
    const value =
      declaration.initializer && unwrapExpression(ts, declaration.initializer);

    if (
      value &&
      ts.isIdentifier(declaration.name) &&
      (ts.isArrowFunction(value) || ts.isFunctionExpression(value))
    ) {
      functions.set(declaration.name.text, {
        name: declaration.name.text,
        node: value,
        statement,
      });
    }
  }

  return functions;
};

/** The same-file factory an exported initializer calls, if it calls one. */
export const factoryCallOf = (
  ts: Ts,
  initializer: Expression | undefined,
  functions: Map<string, StoryFactory>
): undefined | {call: CallExpression; factory: StoryFactory} => {
  if (!initializer) return undefined;
  const call = unwrapExpression(ts, initializer);

  if (!ts.isCallExpression(call) || !ts.isIdentifier(call.expression))
    return undefined;
  const factory = functions.get(call.expression.text);

  return factory ? {call, factory} : undefined;
};

/** How many identifiers named `name` appear in `root`, declarations included. */
export const countIdentifiers = (ts: Ts, root: Node, name: string): number => {
  let count = 0;

  const visit = (node: Node): void => {
    if (ts.isIdentifier(node) && node.text === name) count += 1;
    ts.forEachChild(node, visit);
  };

  visit(root);

  return count;
};
