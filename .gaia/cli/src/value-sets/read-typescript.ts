import type {
  CallExpression,
  CommentRange,
  Node,
  SourceFile,
  VariableDeclaration,
} from 'typescript';
import type {Ts} from '../util/load-typescript.js';
import {isMarkerText} from './markers.js';
import type {
  FileReading,
  MarkerComment,
  StrayMarker,
  ValueSet,
} from './types.js';

export type TypescriptReading =
  {ok: false; syntaxErrorLine: number} | {ok: true; reading: FileReading};

/** A set before its line and markers are known: `nameNode` fixes the line. */
type Draft = {name: null | string; nameNode: Node; values: string[]};

type FoundComment = MarkerComment & {isOwnLine: boolean};

/** `parseDiagnostics` is on the parsed file but not in the public typings. */
type SourceFileWithDiagnostics = {
  parseDiagnostics?: readonly {start?: number}[];
};

const LINE_COMMENT_LEADER_LENGTH = 2;

const stringValue = (ts: Ts, node: Node): string | undefined =>
  ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) ?
    node.text
  : undefined;

const isWrapper = (ts: Ts, node: Node): node is Node & {expression: Node} =>
  ts.isParenthesizedExpression(node) ||
  ts.isAsExpression(node) ||
  ts.isSatisfiesExpression(node) ||
  ts.isTypeAssertionExpression(node) ||
  ts.isNonNullExpression(node);

const unwrap = (ts: Ts, node: Node): Node => {
  let current = node;

  while (isWrapper(ts, current)) {
    current = current.expression;
  }

  return current;
};

/** The values of an array literal whose every element is a string literal. */
const stringArrayValues = (ts: Ts, node: Node): string[] | undefined => {
  const array = unwrap(ts, node);

  if (!ts.isArrayLiteralExpression(array)) {
    return undefined;
  }

  const values = array.elements.map((element) => stringValue(ts, element));

  return values.every((value) => value !== undefined) ? values : undefined;
};

/** True for a call whose callee is exactly `<object>.<member>`, such as `Object.freeze`. */
const isQualifiedCall = (
  ts: Ts,
  node: Node,
  qualifiedNames: readonly string[]
): node is CallExpression =>
  ts.isCallExpression(node) &&
  ts.isPropertyAccessExpression(node.expression) &&
  ts.isIdentifier(node.expression.expression) &&
  qualifiedNames.includes(
    `${node.expression.expression.text}.${node.expression.name.text}`
  );

const isConstDeclaration = (ts: Ts, node: Node): node is VariableDeclaration =>
  ts.isVariableDeclaration(node) &&
  ts.isVariableDeclarationList(node.parent) &&
  // eslint-disable-next-line no-bitwise -- NodeFlags is a bit set
  (node.parent.flags & ts.NodeFlags.Const) !== 0;

const isSameNode = (first: Node | undefined, second: Node): boolean =>
  first === second;

const readConstArray = (ts: Ts, node: Node): Draft | undefined => {
  if (
    !isConstDeclaration(ts, node) ||
    !ts.isIdentifier(node.name) ||
    !node.initializer
  ) {
    return undefined;
  }

  const initializer = unwrap(ts, node.initializer);
  const frozenArgument =
    (
      isQualifiedCall(ts, initializer, ['Object.freeze']) &&
      initializer.arguments.length === 1
    ) ?
      initializer.arguments[0]
    : undefined;
  const values = stringArrayValues(ts, frozenArgument ?? initializer);

  return values ?
      {name: node.name.text, nameNode: node.name, values}
    : undefined;
};

const readLiteralUnion = (ts: Ts, node: Node): Draft | undefined => {
  if (!ts.isTypeAliasDeclaration(node) || !ts.isUnionTypeNode(node.type)) {
    return undefined;
  }

  const values = node.type.types.map((member) =>
    ts.isLiteralTypeNode(member) ? stringValue(ts, member.literal) : undefined
  );

  return values.every((value) => value !== undefined) ?
      {name: node.name.text, nameNode: node.name, values}
    : undefined;
};

/** The `const` a `z.enum(...)` call initializes, directly or through chained calls. */
const zodBindingOf = (ts: Ts, call: Node): undefined | VariableDeclaration => {
  let top: Node = call;
  let climbing = true;

  while (climbing) {
    const {parent} = top;
    const isChainedCall =
      ts.isPropertyAccessExpression(parent) &&
      isSameNode(parent.expression, top) &&
      ts.isCallExpression(parent.parent) &&
      isSameNode(parent.parent.expression, parent);

    if (isChainedCall) {
      top = parent.parent;
    } else if (isWrapper(ts, parent) && isSameNode(parent.expression, top)) {
      top = parent;
    } else {
      climbing = false;
    }
  }

  const declaration = top.parent;

  return (
      isConstDeclaration(ts, declaration) &&
        isSameNode(declaration.initializer, top)
    ) ?
      declaration
    : undefined;
};

const readZodEnum = (ts: Ts, node: Node): Draft | undefined => {
  if (!isQualifiedCall(ts, node, ['z.enum', 'z.literal'])) {
    return undefined;
  }

  const [argument] = node.arguments;
  const values = argument ? stringArrayValues(ts, argument) : undefined;

  if (!values) {
    return undefined;
  }

  const binding = zodBindingOf(ts, node);

  return binding && ts.isIdentifier(binding.name) ?
      {name: binding.name.text, nameNode: binding.name, values}
    : {name: null, nameNode: node, values};
};

const collectSets = (
  ts: Ts,
  sourceFile: SourceFile,
  path: string
): Omit<ValueSet, 'markers'>[] => {
  const sets: Omit<ValueSet, 'markers'>[] = [];

  const visit = (node: Node): void => {
    const draft =
      readConstArray(ts, node) ??
      readLiteralUnion(ts, node) ??
      readZodEnum(ts, node);

    if (draft) {
      sets.push({
        language: 'typescript',
        line:
          sourceFile.getLineAndCharacterOfPosition(
            draft.nameNode.getStart(sourceFile)
          ).line + 1,
        name: draft.name,
        origin: 'declaration',
        path,
        values: draft.values,
      });
    }

    ts.forEachChild(node, visit);
  };

  visit(sourceFile);

  return sets;
};

/** Every marker-text `//` comment, found through token trivia so a `//` inside a string or template is never one. */
const collectMarkerComments = (
  ts: Ts,
  sourceFile: SourceFile,
  text: string
): FoundComment[] => {
  const byPosition = new Map<number, FoundComment>();

  const record = (ranges: CommentRange[] | undefined): void => {
    const lineComments = (ranges ?? []).filter(
      (range) =>
        range.kind === ts.SyntaxKind.SingleLineCommentTrivia &&
        !byPosition.has(range.pos)
    );

    for (const range of lineComments) {
      const {line} = sourceFile.getLineAndCharacterOfPosition(range.pos);
      const lineStart = sourceFile.getPositionOfLineAndCharacter(line, 0);

      byPosition.set(range.pos, {
        isOwnLine: text.slice(lineStart, range.pos).trim() === '',
        line: line + 1,
        text: text
          .slice(range.pos + LINE_COMMENT_LEADER_LENGTH, range.end)
          .trim(),
      });
    }
  };

  const visit = (node: Node): void => {
    record(ts.getLeadingCommentRanges(text, node.pos));
    record(ts.getTrailingCommentRanges(text, node.pos));

    for (const child of node.getChildren(sourceFile)) {
      visit(child);
    }
  };

  visit(sourceFile);

  return [...byPosition.values()]
    .filter((comment) => isMarkerText(comment.text))
    .toSorted((first, second) => first.line - second.line);
};

/** Parses one file with `ts.createSourceFile` only, and reads its literal value sets. */
export const readTypescriptFile = (
  ts: Ts,
  path: string,
  text: string
): TypescriptReading => {
  const sourceFile = ts.createSourceFile(
    path,
    text,
    ts.ScriptTarget.Latest,
    true,
    path.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS
  );

  const [firstDiagnostic] =
    (sourceFile as SourceFile & SourceFileWithDiagnostics).parseDiagnostics ??
    [];

  if (firstDiagnostic) {
    return {
      ok: false,
      syntaxErrorLine:
        sourceFile.getLineAndCharacterOfPosition(firstDiagnostic.start ?? 0)
          .line + 1,
    };
  }

  const comments = collectMarkerComments(ts, sourceFile, text);
  const attached = new Set<FoundComment>();

  const sets: ValueSet[] = collectSets(ts, sourceFile, path).map((set) => {
    const markers = comments.filter(
      (comment) =>
        comment.line === set.line ||
        (comment.isOwnLine && comment.line === set.line - 1)
    );

    for (const marker of markers) {
      attached.add(marker);
    }

    return {
      ...set,
      markers: markers.map(({line, text: body}) => ({line, text: body})),
    };
  });

  const strayMarkers: StrayMarker[] = comments
    .filter((comment) => !attached.has(comment))
    .map(({line, text: body}) => ({line, path, text: body}));

  return {ok: true, reading: {sets, strayMarkers}};
};
