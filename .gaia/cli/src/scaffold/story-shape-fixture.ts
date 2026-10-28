/**
 * Test helper: parses generated story text with `typescript` and reports where
 * it departs from the CSF Next shape the scaffolds promise. A story is a
 * visual state, a behavior is a `.test()` on it, and a `play` only drives the
 * UI, so no `expect(` sits inside one.
 */
import ts from 'typescript';
import {classifyStoryFile} from '../migrate-csf4/repairs/classify.js';

const OLD_FORMAT_TYPES = new Set(['Meta', 'StoryFn', 'StoryObj']);

const parse = (source: string): ts.SourceFile =>
  ts.createSourceFile(
    'generated.stories.tsx',
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  );

const walk = (node: ts.Node, visit: (child: ts.Node) => void): void => {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
};

const isCallTo = (node: ts.Node, methodName: string): boolean =>
  ts.isCallExpression(node) &&
  ts.isPropertyAccessExpression(node.expression) &&
  node.expression.name.text === methodName;

const hasModifier = (node: ts.Node, kind: ts.SyntaxKind): boolean =>
  (ts.canHaveModifiers(node) ? ts.getModifiers(node) : undefined)?.some(
    (modifier) => modifier.kind === kind
  ) ?? false;

const nonFactoryExports = (file: ts.SourceFile): string[] => {
  const names: string[] = [];

  for (const statement of file.statements) {
    if (
      ts.isVariableStatement(statement) &&
      hasModifier(statement, ts.SyntaxKind.ExportKeyword)
    ) {
      for (const declaration of statement.declarationList.declarations) {
        const {initializer} = declaration;
        const isFactory =
          initializer !== undefined &&
          (isCallTo(initializer, 'story') || isCallTo(initializer, 'extend'));

        if (!isFactory) names.push(declaration.name.getText(file));
      }
    }
  }

  return names;
};

const oldFormatReferences = (file: ts.SourceFile): string[] => {
  const found: string[] = [];

  walk(file, (node) => {
    if (
      ts.isTypeReferenceNode(node) &&
      ts.isIdentifier(node.typeName) &&
      OLD_FORMAT_TYPES.has(node.typeName.text)
    ) {
      found.push(node.typeName.text);
    }

    if (ts.isSatisfiesExpression(node)) found.push('satisfies');
  });

  return found;
};

/** The `play` properties and methods of every story and meta in the file. */
const playBodies = (file: ts.SourceFile): ts.Node[] => {
  const bodies: ts.Node[] = [];

  walk(file, (node) => {
    if (
      (ts.isPropertyAssignment(node) || ts.isMethodDeclaration(node)) &&
      ts.isIdentifier(node.name) &&
      node.name.text === 'play'
    ) {
      bodies.push(ts.isPropertyAssignment(node) ? node.initializer : node);
    }
  });

  return bodies;
};

/** Source text of every `expect(` call that sits inside a `play`. */
export const expectsInsidePlays = (source: string): string[] => {
  const file = parse(source);
  const found: string[] = [];

  for (const body of playBodies(file)) {
    walk(body, (node) => {
      if (
        ts.isCallExpression(node) &&
        ts.isIdentifier(node.expression) &&
        node.expression.text === 'expect'
      ) {
        found.push(node.getText(file));
      }
    });
  }

  return found;
};

/** How many `.test(` calls the file makes. */
export const countTestCalls = (source: string): number => {
  let count = 0;

  walk(parse(source), (node) => {
    if (isCallTo(node, 'test')) count += 1;
  });

  return count;
};

/** Every way the text departs from the CSF Next story shape; empty when it holds. */
export const csf4Violations = (source: string): string[] => {
  const file = parse(source);

  const format = classifyStoryFile(ts, source, 'generated.stories.tsx');

  return [
    ...(format === 'csf4' ? [] : [`not csf4: classified ${format}`]),
    ...nonFactoryExports(file).map(
      (name) => `export ${name} is not a story( or extend( call`
    ),
    ...oldFormatReferences(file).map(
      (reference) => `old-format reference: ${reference}`
    ),
    ...expectsInsidePlays(source).map(
      (text) => `expect inside a play: ${text}`
    ),
    ...(countTestCalls(source) === 0 ? ['no .test( call'] : []),
  ];
};
