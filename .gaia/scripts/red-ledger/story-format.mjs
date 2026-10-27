// The story-file format predicate every story reader shares: the RED-ledger
// extractor parses `csf4`, sends `csf2` and `csf3` to the migration command
// (exit 8) and refuses `unknown` (exit 7). The migration command's
// classifyStoryFile and quick-classify's line patterns implement the same
// clauses in the same order, so no file is told to migrate by one reader and
// left alone by another. Decided from the source text alone: `--stdin` input
// has no file on disk whose imports could be resolved.
//
//   1. csf2     the file calls `storiesOf(`, or a named export is initialized
//               from `<identifier>.bind(` (`Template.bind({})`).
//   2. csf4     all four hold: (a) no `export default`; (b) a default import
//               whose specifier is `#.storybook/preview`, or a relative
//               specifier (`./`, `../`) whose last two segments are
//               `.storybook/preview`, optionally with a .ts, .tsx, .js, .jsx,
//               .mjs or .mts extension; (c) a binding initialized from
//               `<that import>.meta(` or `<that import>.type<…>().meta(`;
//               (d) no named export initialized from an object literal, bare
//               or under `satisfies` / `as`.
//   3. csf3     the file has an `export default`.
//   4. unknown  anything else.

const PREVIEW_EXTENSION = /\.(?:ts|tsx|js|jsx|mjs|mts)$/;

function isPreviewSpecifier(specifier) {
  if (specifier === '#.storybook/preview') {
    return true;
  }
  if (!specifier.startsWith('./') && !specifier.startsWith('../')) {
    return false;
  }
  const segments = specifier.replace(PREVIEW_EXTENSION, '').split('/');
  return segments.length >= 2 && segments.at(-2) === '.storybook' && segments.at(-1) === 'preview';
}

const unwrapTypeOperators = (ts, expression) => {
  let current = expression;
  while (
    current &&
    (ts.isParenthesizedExpression(current) || ts.isAsExpression(current) || ts.isSatisfiesExpression(current))
  ) {
    current = current.expression;
  }
  return current;
};

export const hasModifier = (ts, node, kind) =>
  (ts.canHaveModifiers?.(node) ? ts.getModifiers(node) : node.modifiers)?.some(
    (modifier) => modifier.kind === kind,
  ) ?? false;

// True when `call` is `<preview>.meta(…)` or `<preview>.type<…>().meta(…)` for
// one of the preview import names.
export function isPreviewMetaCall(ts, call, previewNames) {
  if (!call || !ts.isCallExpression(call) || !ts.isPropertyAccessExpression(call.expression)) {
    return false;
  }
  if (call.expression.name.text !== 'meta') {
    return false;
  }
  const receiver = call.expression.expression;
  if (ts.isIdentifier(receiver)) {
    return previewNames.has(receiver.text);
  }
  return (
    ts.isCallExpression(receiver) &&
    Boolean(receiver.typeArguments?.length) &&
    ts.isPropertyAccessExpression(receiver.expression) &&
    receiver.expression.name.text === 'type' &&
    ts.isIdentifier(receiver.expression.expression) &&
    previewNames.has(receiver.expression.expression.text)
  );
}

// The default-import names whose specifier is the Storybook preview.
function previewImportNames(ts, sourceFile) {
  const names = new Set();
  for (const statement of sourceFile.statements) {
    if (
      ts.isImportDeclaration(statement) &&
      !statement.importClause?.isTypeOnly &&
      statement.importClause?.name &&
      ts.isStringLiteral(statement.moduleSpecifier) &&
      isPreviewSpecifier(statement.moduleSpecifier.text)
    ) {
      names.add(statement.importClause.name.text);
    }
  }
  return names;
}

function callsStoriesOf(ts, node) {
  if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'storiesOf') {
    return true;
  }
  return ts.forEachChild(node, (child) => callsStoriesOf(ts, child) || undefined) ?? false;
}

export function classifyStoryFormat(ts, sourceFile) {
  const previewNames = previewImportNames(ts, sourceFile);
  let hasDefaultExport = false;
  let bindsFromBind = false;
  let exportsObjectLiteral = false;
  let bindsPreviewMeta = false;

  for (const statement of sourceFile.statements) {
    if (ts.isExportAssignment(statement)) {
      hasDefaultExport ||= !statement.isExportEquals;
    } else if (
      (ts.isFunctionDeclaration(statement) || ts.isClassDeclaration(statement)) &&
      hasModifier(ts, statement, ts.SyntaxKind.ExportKeyword) &&
      hasModifier(ts, statement, ts.SyntaxKind.DefaultKeyword)
    ) {
      hasDefaultExport = true;
    } else if (ts.isExportDeclaration(statement) && statement.exportClause && ts.isNamedExports(statement.exportClause)) {
      hasDefaultExport ||= statement.exportClause.elements.some((element) => element.name.text === 'default');
    } else if (ts.isVariableStatement(statement)) {
      const exported = hasModifier(ts, statement, ts.SyntaxKind.ExportKeyword);
      for (const declaration of statement.declarationList.declarations) {
        const init = unwrapTypeOperators(ts, declaration.initializer);
        if (isPreviewMetaCall(ts, init, previewNames)) {
          bindsPreviewMeta = true;
        }
        if (!exported || !init) {
          continue;
        }
        if (ts.isObjectLiteralExpression(init)) {
          exportsObjectLiteral = true;
        } else if (
          ts.isCallExpression(init) &&
          ts.isPropertyAccessExpression(init.expression) &&
          init.expression.name.text === 'bind' &&
          ts.isIdentifier(init.expression.expression)
        ) {
          bindsFromBind = true;
        }
      }
    }
  }

  if (bindsFromBind || callsStoriesOf(ts, sourceFile)) {
    return {format: 'csf2', previewNames};
  }
  if (!hasDefaultExport && previewNames.size > 0 && bindsPreviewMeta && !exportsObjectLiteral) {
    return {format: 'csf4', previewNames};
  }
  if (hasDefaultExport) {
    return {format: 'csf3', previewNames};
  }
  return {format: 'unknown', previewNames};
}
