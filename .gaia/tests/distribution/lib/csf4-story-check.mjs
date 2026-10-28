// Structural checks over migrated story files, using the staged tree's own
// TypeScript. Usage: node csf4-story-check.mjs <frontend dir> <check> <file>...
// Checks: shape (CSF4 form), msw (handlers moved into beforeEach).
// Prints one problem per line and exits 1 when any check fails.
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import path from 'node:path';

const [frontendDirectory, check, ...files] = process.argv.slice(2);
const ts = createRequire(path.join(frontendDirectory, 'package.json'))(
  'typescript'
);
const problems = [];

const parse = (file) =>
  ts.createSourceFile(
    file,
    readFileSync(path.join(frontendDirectory, file), 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  );

const isExported = (statement) =>
  statement.modifiers?.some(
    (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword
  ) ?? false;

const calleeProperty = (call) =>
  ts.isCallExpression(call) && ts.isPropertyAccessExpression(call.expression) ?
    call.expression
  : undefined;

// `preview.meta(` or `preview.type<...>().meta(`
const isPreviewMeta = (initializer) => {
  const access = initializer && calleeProperty(initializer);

  if (access?.name.text !== 'meta') return false;
  const owner = access.expression;

  if (ts.isIdentifier(owner)) return owner.text === 'preview';
  const typeAccess = calleeProperty(owner);

  return (
    typeAccess?.name.text === 'type' &&
    ts.isIdentifier(typeAccess.expression) &&
    typeAccess.expression.text === 'preview'
  );
};

const namedDeclarations = (source) =>
  source.statements
    .filter(ts.isVariableStatement)
    .flatMap((statement) =>
      statement.declarationList.declarations.map((declaration) => ({
        declaration,
        exported: isExported(statement),
      }))
    );

const checkShape = (file) => {
  const source = parse(file);
  const metaNames = new Set(
    namedDeclarations(source)
      .filter(({declaration}) => isPreviewMeta(declaration.initializer))
      .map(({declaration}) => declaration.name.text)
  );
  const storyNames = new Set();

  if (!/from '#\.storybook\/preview'/u.test(source.text)) {
    problems.push(`${file}: does not import #.storybook/preview`);
  }
  if (metaNames.size === 0) {
    problems.push(`${file}: no binding from preview.meta(`);
  }
  if (source.statements.some(ts.isExportAssignment)) {
    problems.push(`${file}: still has an export default`);
  }

  namedDeclarations(source)
    .filter(({exported}) => exported)
    .forEach(({declaration}) => {
      const access = declaration.initializer && calleeProperty(declaration.initializer);
      const owner = access && ts.isIdentifier(access.expression) ? access.expression.text : '';
      const viaMeta = access?.name.text === 'story' && metaNames.has(owner);
      const viaExtend = access?.name.text === 'extend' && storyNames.has(owner);

      if (viaMeta || viaExtend) {
        storyNames.add(declaration.name.text);
      } else {
        problems.push(
          `${file}: export ${declaration.name.getText()} is not a meta.story( or .extend( call`
        );
      }
    });

  source.statements.filter(ts.isExpressionStatement).forEach((statement) => {
    const expression = statement.expression;

    let root = ts.isBinaryExpression(expression) ? expression.left : undefined;

    while (root && ts.isPropertyAccessExpression(root)) root = root.expression;
    if (
      ts.isBinaryExpression(expression) &&
      expression.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      root &&
      ts.isIdentifier(root) &&
      storyNames.has(root.text)
    ) {
      problems.push(`${file}: top-level assignment ${expression.left.getText()}`);
    }
  });
};

const hasProperty = (node, name) =>
  node.properties.some((property) => property.name?.getText() === name);

const checkMsw = (file) => {
  const source = parse(file);
  let mswParameters = false;
  let installed = false;

  const visit = (node) => {
    if (ts.isPropertyAssignment(node) && node.name.getText() === 'msw') {
      mswParameters = true;
    }
    if (
      ts.isCallExpression(node) &&
      ts.isObjectLiteralExpression(node.arguments[0] ?? node) &&
      hasProperty(node.arguments[0], 'beforeEach')
    ) {
      installed = true;
    }
    ts.forEachChild(node, visit);
  };

  visit(source);
  if (mswParameters) problems.push(`${file}: parameters.msw remains`);
  if (!installed) problems.push(`${file}: no story has a beforeEach`);
};

const checks = {msw: checkMsw, shape: checkShape};

files.forEach((file) => checks[check](file));
problems.forEach((problem) => console.log(problem));
process.exit(problems.length > 0 ? 1 : 0);
