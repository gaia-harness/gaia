/**
 * Inlines each factory-built story export (`export const X = makeStory('x')`)
 * into a direct `meta.story({...})` call under the same export name, so its
 * story id is unchanged. Storybook's CSF indexer registers only exports it
 * reads as story calls: a factory-call export is never indexed, so a
 * `.test()` attached to it would dereference nothing.
 */
import type {
  CallExpression,
  Expression,
  Identifier,
  Node,
  ObjectLiteralExpression,
  SourceFile,
  VariableDeclaration,
} from 'typescript';
import {
  countIdentifiers,
  exportedDeclarations,
  factoryCallOf,
  findMetaBinding,
  findPreviewImport,
  parseSource,
  topLevelFunctions,
  unwrapExpression,
} from './ast.js';
import type {StoryFactory, Ts} from './ast.js';
import {
  applyEdits,
  dropTypeAnnotation,
  removeStatementEdit,
} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

/** An argument that needs no parentheses wherever it is substituted. */
const SIMPLE_ARGUMENT = /^(?:[\w$.]+|'[^'\\]*'|"[^"\\]*"|`[^`\\$]*`)$/u;

type Binding = {node: Expression | undefined; text: string};

type Bindings = ReadonlyMap<string, Binding>;

/** The object literal a factory returns, unwrapping a `meta.story(...)` wrapper. */
const returnedObject = (
  ts: Ts,
  factory: StoryFactory
): ObjectLiteralExpression | undefined => {
  const {body} = factory.node;

  if (!body) return undefined;
  const statements = ts.isBlock(body) ? body.statements : [];
  const [only] = statements;
  const blockReturn =
    only && statements.length === 1 && ts.isReturnStatement(only) ?
      only.expression
    : undefined;
  const returned = ts.isBlock(body) ? blockReturn : body;

  if (!returned) return undefined;
  const value = unwrapExpression(ts, returned);
  const [storyArgument] = ts.isCallExpression(value) ? value.arguments : [];
  const isStoryCall =
    ts.isCallExpression(value) &&
    ts.isPropertyAccessExpression(value.expression) &&
    value.expression.name.text === 'story' &&
    value.arguments.length === 1;
  const object =
    isStoryCall && storyArgument ? unwrapExpression(ts, storyArgument) : value;

  return ts.isObjectLiteralExpression(object) ? object : undefined;
};

const escapeTemplateText = (text: string): string =>
  text.replaceAll('\\', '\\\\').replaceAll('`', '\\`').replaceAll('${', '\\${');

/** Whether `node` names a property, member or declaration rather than a value. */
const isNamePosition = (ts: Ts, node: Identifier): boolean => {
  const {parent} = node;

  return (
    (ts.isPropertyAccessExpression(parent) ||
      ts.isPropertyAssignment(parent) ||
      ts.isMethodDeclaration(parent) ||
      ts.isJsxAttribute(parent) ||
      ts.isParameter(parent) ||
      ts.isVariableDeclaration(parent) ||
      ts.isBindingElement(parent)) &&
    parent.name === node
  );
};

/** The edit replacing one parameter reference, relative to `offset`. */
const referenceEdit = (
  ts: Ts,
  node: Identifier,
  {binding, offset}: {binding: Binding; offset: number}
): TextEdit | undefined => {
  const {parent} = node;
  const start = node.getStart() - offset;
  const end = node.end - offset;
  const argument = binding.node;

  if (ts.isShorthandPropertyAssignment(parent)) {
    return {end, start, text: `${node.text}: ${binding.text}`};
  }

  if (
    ts.isTemplateSpan(parent) &&
    argument &&
    (ts.isStringLiteral(argument) ||
      ts.isNoSubstitutionTemplateLiteral(argument))
  ) {
    const template = parent.parent;
    const index = template.templateSpans.indexOf(parent);
    const previous =
      index === 0 ? template.head : template.templateSpans[index - 1]?.literal;

    // `${` closes the text before the span and `}` opens the text after it,
    // so the replaced range runs from the one to the other.
    return previous ?
        {
          end: parent.literal.getStart() + 1 - offset,
          start: previous.end - 2 - offset,
          text: escapeTemplateText(argument.text),
        }
      : undefined;
  }
  const text =
    SIMPLE_ARGUMENT.test(binding.text) ? binding.text : `(${binding.text})`;

  return {end, start, text};
};

/** `scope` without the names a function's own parameters shadow. */
const unshadowed = (ts: Ts, node: Node, scope: Bindings): Bindings => {
  if (!ts.isFunctionLike(node)) return scope;
  const shadowed = new Set(
    node.parameters.flatMap((parameter) =>
      ts.isIdentifier(parameter.name) ? [parameter.name.text] : []
    )
  );

  return [...scope.keys()].some((name) => shadowed.has(name)) ?
      new Map([...scope].filter(([name]) => !shadowed.has(name)))
    : scope;
};

/** `literal`'s text with each parameter reference replaced by its argument. */
const substitute = (
  ts: Ts,
  source: string,
  {bindings, literal}: {bindings: Bindings; literal: ObjectLiteralExpression}
): string => {
  const edits: TextEdit[] = [];
  const offset = literal.getStart();

  const visit = (node: Node, scope: Bindings): void => {
    const inner = unshadowed(ts, node, scope);
    const binding = ts.isIdentifier(node) ? inner.get(node.text) : undefined;

    if (binding && ts.isIdentifier(node) && !isNamePosition(ts, node)) {
      const edit = referenceEdit(ts, node, {binding, offset});

      if (edit) edits.push(edit);
    }
    ts.forEachChild(node, (child) => {
      visit(child, inner);
    });
  };

  visit(literal, bindings);

  return applyEdits(source.slice(offset, literal.end), edits);
};

const metaNameOf = (ts: Ts, file: SourceFile): string => {
  const previewImport = findPreviewImport(ts, file);

  return (
    (previewImport && findMetaBinding(ts, file, previewImport.name)?.name) ??
    'meta'
  );
};

/** Each parameter of the factory bound to its call argument or default. */
const bindArguments = (
  source: string,
  {call, factory}: {call: CallExpression; factory: StoryFactory}
): Bindings =>
  new Map(
    factory.node.parameters.map((parameter, index) => {
      const argument = call.arguments[index] ?? parameter.initializer;
      const text =
        argument ?
          source.slice(argument.getStart(), argument.end)
        : 'undefined';

      return [parameter.name.getText(), {node: argument, text}] as const;
    })
  );

/** The edits inlining one factory-built export, or undefined when it cannot be. */
const inlineEdits = (
  ts: Ts,
  source: string,
  {
    declaration,
    functions,
    metaName,
  }: {
    declaration: VariableDeclaration;
    functions: Map<string, StoryFactory>;
    metaName: string;
  }
): undefined | {edits: TextEdit[]; factory: StoryFactory} => {
  const {initializer} = declaration;
  const built = factoryCallOf(ts, initializer, functions);

  if (!built || !initializer) return undefined;
  const {call, factory} = built;
  const literal = returnedObject(ts, factory);
  const plainCall =
    factory.node.parameters.every(
      (parameter) =>
        ts.isIdentifier(parameter.name) && !parameter.dotDotDotToken
    ) && !call.arguments.some((argument) => ts.isSpreadElement(argument));

  if (!literal || !plainCall) return undefined;
  const objectText = substitute(ts, source, {
    bindings: bindArguments(source, built),
    literal,
  });

  return {
    edits: [
      ...dropTypeAnnotation(declaration),
      {
        end: initializer.end,
        start: initializer.getStart(),
        text: `${metaName}.story(${objectText})`,
      },
    ],
    factory,
  };
};

/** Inlines the named factory-built exports; names each inline and each it could not. */
export const inlineFactoryExports = (
  ts: Ts,
  source: string,
  {exportNames, filePath}: {exportNames: readonly string[]; filePath: string}
): {notes: string[]; source: string} => {
  const file = parseSource(ts, source, filePath);
  const functions = topLevelFunctions(ts, file);
  const metaName = metaNameOf(ts, file);
  const notes: string[] = [];
  const edits: TextEdit[] = [];
  const used = new Set<string>();
  const targets = exportedDeclarations(ts, file).filter(
    ({declaration, name}) =>
      exportNames.includes(name) &&
      factoryCallOf(ts, declaration.initializer, functions)
  );

  for (const {declaration, name} of targets) {
    const inlined = inlineEdits(ts, source, {declaration, functions, metaName});

    if (inlined) {
      edits.push(...inlined.edits);
      used.add(inlined.factory.name);
      notes.push(
        `inlined the factory-built story ${name} into a direct meta.story()`
      );
    } else {
      notes.push(
        `could not inline the factory-built story ${name}: its factory is not a plain object factory`
      );
    }
  }
  const inlinedSource = applyEdits(source, edits);
  const after = parseSource(ts, inlinedSource, filePath);
  const removals = [...topLevelFunctions(ts, after).values()]
    .filter(
      (factory) =>
        used.has(factory.name) &&
        countIdentifiers(ts, after, factory.name) === 1
    )
    .map((factory) =>
      removeStatementEdit(ts, inlinedSource, factory.statement)
    );

  return {notes, source: applyEdits(inlinedSource, removals)};
};
