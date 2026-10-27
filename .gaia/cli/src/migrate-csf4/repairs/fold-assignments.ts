/**
 * Folds top-level `Story.<key> =` and `Story.input.<key> =` assignments into
 * the story's `meta.story(...)` argument. The codemod leaves them on
 * render-function stories, where the file then fails to import and every
 * test in it silently drops out of the run.
 */
import type {
  BinaryExpression,
  CallExpression,
  ExpressionStatement,
  SourceFile,
} from 'typescript';
import {exportedDeclarations, parseSource, unwrapExpression} from './ast.js';
import type {Ts} from './ast.js';
import {
  applyEdits,
  asObjectLiteral,
  deepMergeEdits,
  findProperty,
  insertPropertiesEdit,
  objectValueOf,
  removeStatementEdit,
  startWithComments,
} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

/** Keys CSF3 spelled differently from the `meta.story({...})` input. */
const RENAMED_KEYS: Readonly<Record<string, string>> = {storyName: 'name'};

type StoryAssignment = {
  call: CallExpression;
  key: string;
  statement: ExpressionStatement;
  story: string;
  value: BinaryExpression['right'];
};

const storyCalls = (ts: Ts, file: SourceFile): Map<string, CallExpression> => {
  const calls = new Map<string, CallExpression>();

  for (const {declaration, name} of exportedDeclarations(ts, file)) {
    const value =
      declaration.initializer && unwrapExpression(ts, declaration.initializer);

    if (
      value &&
      ts.isCallExpression(value) &&
      ts.isPropertyAccessExpression(value.expression) &&
      value.expression.name.text === 'story'
    ) {
      calls.set(name, value);
    }
  }

  return calls;
};

const storyAssignments = (
  ts: Ts,
  file: SourceFile,
  calls: Map<string, CallExpression>
): StoryAssignment[] =>
  file.statements.flatMap((statement) => {
    if (!ts.isExpressionStatement(statement)) return [];
    const {expression} = statement;

    if (
      !ts.isBinaryExpression(expression) ||
      expression.operatorToken.kind !== ts.SyntaxKind.EqualsToken ||
      !ts.isPropertyAccessExpression(expression.left)
    ) {
      return [];
    }
    const target = expression.left.expression;
    const key = expression.left.name.text;
    const story =
      ts.isIdentifier(target) ? target.text
      : (
        ts.isPropertyAccessExpression(target) &&
        target.name.text === 'input' &&
        ts.isIdentifier(target.expression)
      ) ?
        target.expression.text
      : undefined;

    const call = story === undefined ? undefined : calls.get(story);

    if (story === undefined || !call) return [];
    if (ts.isIdentifier(target) && key === 'input') return [];

    return [
      {
        call,
        key: RENAMED_KEYS[key] ?? key,
        statement,
        story,
        value: expression.right,
      },
    ];
  });

/** The edits that move one assignment's value into its story call. */
const foldEdits = (
  ts: Ts,
  source: string,
  {call, key, statement, value}: StoryAssignment
): TextEdit[] | undefined => {
  const valueText = source.slice(value.getStart(), value.end);
  const comments = source
    .slice(startWithComments(ts, source, statement), statement.getStart())
    .trimEnd();
  const commentLines = comments ? `${comments}\n` : '';
  const propertyText = `${commentLines}${key}: ${valueText}`;
  const [argument] = call.arguments;

  if (!argument) {
    return [
      {
        end: call.arguments.end,
        start: call.arguments.pos,
        text: `{${propertyText}}`,
      },
    ];
  }
  const literal = asObjectLiteral(ts, argument);

  if (literal) {
    const current = findProperty(ts, literal, key);
    const incoming = asObjectLiteral(ts, value);

    if (!current) return insertPropertiesEdit(source, literal, [propertyText]);
    const currentValue = objectValueOf(ts, current);

    if (currentValue && incoming)
      return deepMergeEdits(ts, source, {
        existing: currentValue,
        incoming,
      });

    return [{end: current.end, start: current.getStart(), text: propertyText}];
  }
  const render = unwrapExpression(ts, argument);

  if (ts.isArrowFunction(render) || ts.isFunctionExpression(render)) {
    const renderText = source.slice(argument.getStart(), argument.end);

    return [
      {
        end: argument.end,
        start: argument.getStart(),
        text: `{\n  render: ${renderText},\n  ${propertyText},\n}`,
      },
    ];
  }

  return undefined;
};

/** Folds every story assignment it can; names each fold and each it could not. */
export const foldStoryAssignments = (
  ts: Ts,
  source: string,
  filePath: string
): {notes: string[]; source: string} => {
  const notes: string[] = [];
  let current = source;
  let skipped = 0;

  for (;;) {
    const file = parseSource(ts, current, filePath);
    const assignment = storyAssignments(ts, file, storyCalls(ts, file))[
      skipped
    ];

    if (!assignment) break;
    const edits = foldEdits(ts, current, assignment);

    if (edits) {
      current = applyEdits(current, [
        ...edits,
        removeStatementEdit(ts, current, assignment.statement),
      ]);
      notes.push(
        `folded ${assignment.story}.${assignment.key} into its meta.story()`
      );
    } else {
      notes.push(
        `left ${assignment.story}.${assignment.key} = in place: its story argument is not an object or a render function`
      );
      skipped += 1;
    }
  }

  return {notes, source: current};
};
