/**
 * Text splicing at AST positions. Every repair edits the source this way
 * rather than re-printing the tree, so comments and formatting outside the
 * edited spans survive byte for byte.
 */
import type {
  Expression,
  ImportDeclaration,
  ImportSpecifier,
  Node,
  NodeArray,
  ObjectLiteralElementLike,
  ObjectLiteralExpression,
  VariableDeclaration,
} from 'typescript';
import {unwrapExpression} from './ast.js';
import type {Ts} from './ast.js';

/** One replacement of `source.slice(start, end)` by `text`. */
export type TextEdit = {end: number; start: number; text: string};

/**
 * `source` with every edit applied. Edits must not overlap; inserts at the
 * same position land in the order they were given.
 */
export const applyEdits = (
  source: string,
  edits: readonly TextEdit[]
): string => {
  const ordered = edits
    .map((edit, index) => ({edit, index}))
    .toSorted((a, b) => b.edit.start - a.edit.start || b.index - a.index);
  let result = source;
  let floor = Number.POSITIVE_INFINITY;

  for (const {edit} of ordered) {
    if (edit.end > floor) {
      throw new Error(`overlapping edits at ${String(edit.start)}`);
    }
    result = result.slice(0, edit.start) + edit.text + result.slice(edit.end);
    floor = edit.start;
  }

  return result;
};

const lineStart = (source: string, position: number): number =>
  source.lastIndexOf('\n', position - 1) + 1;

/** The whitespace that opens the line holding `position`. */
export const indentAt = (source: string, position: number): string =>
  /^[\t ]*/u.exec(source.slice(lineStart(source, position)))?.[0] ?? '';

/** Where the leading comments attached to `node` begin, or its own start. */
export const startWithComments = (ts: Ts, source: string, node: Node): number =>
  ts.getLeadingCommentRanges(source, node.pos)?.[0]?.pos ?? node.getStart();

const isBlankBetween = (source: string, start: number, end: number): boolean =>
  source.slice(start, end).trim() === '';

/**
 * Removes a whole top-level statement with its leading comments and line
 * ending, plus one of the blank lines around it, so no double gap remains.
 */
export const removeStatementEdit = (
  ts: Ts,
  source: string,
  statement: Node
): TextEdit => {
  let start = lineStart(source, startWithComments(ts, source, statement));
  const newline = source.indexOf('\n', statement.end);
  const end = newline === -1 ? source.length : newline + 1;

  if (
    source[start - 1] === '\n' &&
    source[start - 2] === '\n' &&
    (end >= source.length || source[end] === '\n')
  ) {
    start -= 1;
  }

  return {end, start, text: ''};
};

/**
 * Removes element `index` of a comma-separated list (object properties or
 * array elements): its own lines when it sits on lines of its own, else the
 * element and one adjoining comma.
 */
export const removeListElementEdit = (
  ts: Ts,
  source: string,
  {elements, index}: {elements: NodeArray<Node>; index: number}
): TextEdit => {
  const element = elements[index];

  if (!element) throw new Error(`no list element at ${String(index)}`);
  const commentStart = startWithComments(ts, source, element);
  const ownLineStart = lineStart(source, commentStart);
  let afterElement = element.end;

  if (source.slice(afterElement).trimStart().startsWith(',')) {
    afterElement = source.indexOf(',', afterElement) + 1;
  }
  const newline = source.indexOf('\n', afterElement);

  if (
    isBlankBetween(source, ownLineStart, commentStart) &&
    newline !== -1 &&
    isBlankBetween(source, afterElement, newline)
  ) {
    return {end: newline + 1, start: ownLineStart, text: ''};
  }
  const next = elements[index + 1];

  if (next) return {end: next.getStart(), start: element.getStart(), text: ''};
  const previous = elements[index - 1];

  return previous ?
      {end: element.end, start: previous.end, text: ''}
    : {end: element.end, start: element.getStart(), text: ''};
};

/** Adds properties at the end of an object literal, matching its layout. */
export const insertPropertiesEdit = (
  source: string,
  literal: ObjectLiteralExpression,
  propertyTexts: readonly string[]
): TextEdit[] => {
  if (propertyTexts.length === 0) return [];
  const {end, properties} = literal;
  const last = properties.at(-1);
  const closeBrace = end - 1;

  if (!last) {
    return [
      {
        end: closeBrace,
        start: literal.getStart() + 1,
        text: propertyTexts.join(', '),
      },
    ];
  }
  const multiline = source.slice(literal.getStart(), end).includes('\n');

  if (!multiline) {
    const joined = propertyTexts.join(', ');

    return properties.hasTrailingComma ?
        [{end: closeBrace, start: closeBrace, text: ` ${joined}`}]
      : [{end: last.end, start: last.end, text: `, ${joined}`}];
  }
  const indent = indentAt(source, last.getStart());

  if (properties.hasTrailingComma) {
    const comma = source.indexOf(',', last.end) + 1;

    return [
      {
        end: comma,
        start: comma,
        text: propertyTexts.map((text) => `\n${indent}${text},`).join(''),
      },
    ];
  }

  return [
    {
      end: last.end,
      start: last.end,
      text: propertyTexts.map((text) => `,\n${indent}${text}`).join(''),
    },
  ];
};

/** The static name of an object literal property, when it has one. */
export const propertyName = (
  ts: Ts,
  property: ObjectLiteralElementLike
): string | undefined => {
  const {name} = property;

  if (!name) return undefined;
  if (ts.isIdentifier(name) || ts.isStringLiteral(name)) return name.text;

  return undefined;
};

/** The property of `literal` named `name`. */
export const findProperty = (
  ts: Ts,
  literal: ObjectLiteralExpression,
  name: string
): ObjectLiteralElementLike | undefined =>
  literal.properties.find((property) => propertyName(ts, property) === name);

/** The object literal under parentheses, `satisfies` or `as`, if any. */
export const asObjectLiteral = (
  ts: Ts,
  expression: Expression | undefined
): ObjectLiteralExpression | undefined => {
  const value = expression && unwrapExpression(ts, expression);

  return value && ts.isObjectLiteralExpression(value) ? value : undefined;
};

/** The object literal a property assignment holds, if `property` is one. */
export const objectValueOf = (
  ts: Ts,
  property: ObjectLiteralElementLike | undefined
): ObjectLiteralExpression | undefined =>
  property && ts.isPropertyAssignment(property) ?
    asObjectLiteral(ts, property.initializer)
  : undefined;

/** Drops a declaration's `: Type` annotation. */
export const dropTypeAnnotation = (
  declaration: VariableDeclaration
): TextEdit[] =>
  declaration.type ?
    [{end: declaration.type.end, start: declaration.name.end, text: ''}]
  : [];

/**
 * Edits that deep-merge the properties of `incoming` into `existing`: a key
 * both hold with object-literal values on both sides merges recursively, any
 * other shared key takes the incoming property, and a new key is appended.
 */
export const deepMergeEdits = (
  ts: Ts,
  source: string,
  {
    existing,
    incoming,
  }: {existing: ObjectLiteralExpression; incoming: ObjectLiteralExpression}
): TextEdit[] => {
  const edits: TextEdit[] = [];
  const appended: string[] = [];

  for (const property of incoming.properties) {
    const text = source.slice(property.getStart(), property.end);
    const name = propertyName(ts, property);
    const current =
      name === undefined ? undefined : findProperty(ts, existing, name);

    const currentValue = objectValueOf(ts, current);
    const incomingValue = objectValueOf(ts, property);

    if (!current) {
      appended.push(text);
    } else if (currentValue && incomingValue) {
      edits.push(
        ...deepMergeEdits(ts, source, {
          existing: currentValue,
          incoming: incomingValue,
        })
      );
    } else {
      edits.push({end: current.end, start: current.getStart(), text});
    }
  }

  return [...edits, ...insertPropertiesEdit(source, existing, appended)];
};

/**
 * Edits removing the specifiers `remove` selects from an import, or the whole
 * import when nothing would be left of it.
 */
export const removeImportSpecifiersEdits = (
  ts: Ts,
  source: string,
  {
    declaration,
    remove,
  }: {
    declaration: ImportDeclaration;
    remove: (element: ImportSpecifier) => boolean;
  }
): TextEdit[] => {
  const clause = declaration.importClause;
  const bindings = clause?.namedBindings;

  if (!clause || !bindings || !ts.isNamedImports(bindings)) return [];
  const kept = bindings.elements.filter((element) => !remove(element));

  if (kept.length === bindings.elements.length) return [];

  if (kept.length === 0 && !clause.name) {
    return [removeStatementEdit(ts, source, declaration)];
  }

  return [
    {
      end: bindings.end,
      start: bindings.getStart(),
      text: `{${kept.map((element) => element.getText()).join(', ')}}`,
    },
  ];
};
