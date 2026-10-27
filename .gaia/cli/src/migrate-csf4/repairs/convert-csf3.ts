/**
 * Whole-file CSF3 to CSF4 conversion for a story file the codemod skipped as
 * an unsupported format (a factory-built story set): the meta object becomes
 * `preview.meta(...)`, each story object or render function `meta.story(...)`.
 * Factory-built exports are left to the inlining pass that runs after it.
 */
import type {SourceFile} from 'typescript';
import {
  countIdentifiers,
  exportedDeclarations,
  findDeclaration,
  findExportDefault,
  importDeclarations,
  moduleSpecifier,
  parseSource,
  PREVIEW_SPECIFIER,
  unwrapExpression,
} from './ast.js';
import type {Ts} from './ast.js';
import {extractLeadingComment} from './leading-comment.js';
import {
  applyEdits,
  dropTypeAnnotation,
  removeImportSpecifiersEdits,
  removeStatementEdit,
} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

const PREVIEW_NAME = 'preview';

/** Storybook's CSF3 type names, removed once nothing references them. */
const CSF3_TYPE_NAMES = new Set([
  'ComponentMeta',
  'ComponentStory',
  'ComponentStoryFn',
  'ComponentStoryObj',
  'Meta',
  'Story',
  'StoryFn',
  'StoryObj',
]);

const metaEdits = (
  ts: Ts,
  source: string,
  file: SourceFile
): undefined | {edits: TextEdit[]; metaName: string} => {
  const exportDefault = findExportDefault(ts, file);

  if (!exportDefault) return undefined;
  const exportStart = exportDefault.getStart();
  const exportEnd = exportDefault.end;
  const {expression} = exportDefault;

  if (!ts.isIdentifier(expression)) {
    const literal = unwrapExpression(ts, expression);

    if (!ts.isObjectLiteralExpression(literal)) return undefined;
    const literalText = source.slice(literal.getStart(), literal.end);

    return {
      edits: [
        {
          end: exportEnd,
          start: exportStart,
          text: `const meta = ${PREVIEW_NAME}.meta(${literalText});`,
        },
      ],
      metaName: 'meta',
    };
  }
  const meta = findDeclaration(ts, file, expression.text)?.declaration;
  const initializer = meta?.initializer;
  const literal = initializer && unwrapExpression(ts, initializer);

  if (!meta || !literal || !ts.isObjectLiteralExpression(literal)) {
    return undefined;
  }
  const literalText = source.slice(literal.getStart(), literal.end);

  return {
    edits: [
      ...dropTypeAnnotation(meta),
      {
        end: initializer.end,
        start: initializer.getStart(),
        text: `${PREVIEW_NAME}.meta(${literalText})`,
      },
      removeStatementEdit(ts, source, exportDefault),
    ],
    metaName: expression.text,
  };
};

const storyEdits = (
  ts: Ts,
  source: string,
  {file, metaName}: {file: SourceFile; metaName: string}
): TextEdit[] =>
  exportedDeclarations(ts, file).flatMap(({declaration}) => {
    const {initializer} = declaration;
    const value = initializer && unwrapExpression(ts, initializer);

    if (
      !value ||
      !(
        ts.isObjectLiteralExpression(value) ||
        ts.isArrowFunction(value) ||
        ts.isFunctionExpression(value)
      )
    ) {
      return [];
    }
    const valueText = source.slice(value.getStart(), value.end);

    return [
      ...dropTypeAnnotation(declaration),
      {
        end: initializer.end,
        start: initializer.getStart(),
        text: `${metaName}.story(${valueText})`,
      },
    ];
  });

const previewImportEdit = (
  ts: Ts,
  source: string,
  file: SourceFile
): TextEdit => {
  const [firstImport] = importDeclarations(ts, file);
  const position =
    firstImport ?
      firstImport.getStart()
    : (() => {
        const leading = extractLeadingComment(source);

        return leading ?
            source.indexOf(leading.comment) +
              leading.comment.length +
              leading.gap.length
          : 0;
      })();

  return {
    end: position,
    start: position,
    text: `import ${PREVIEW_NAME} from '${PREVIEW_SPECIFIER}';\n${firstImport ? '' : '\n'}`,
  };
};

/** Converts a CSF3 story file; undefined when its meta is not a plain object. */
export const convertCsf3StoryFile = (
  ts: Ts,
  source: string,
  filePath: string
): string | undefined => {
  const file = parseSource(ts, source, filePath);
  const meta = metaEdits(ts, source, file);

  if (!meta) return undefined;

  return applyEdits(source, [
    previewImportEdit(ts, source, file),
    ...meta.edits,
    ...storyEdits(ts, source, {file, metaName: meta.metaName}),
  ]);
};

/**
 * Removes Storybook's CSF3 type imports and the type aliases built on them
 * once nothing in the file references them.
 */
export const removeUnusedCsf3Types = (
  ts: Ts,
  source: string,
  filePath: string
): string => {
  const file = parseSource(ts, source, filePath);
  const withoutAliases = applyEdits(
    source,
    file.statements
      .filter(
        (statement) =>
          ts.isTypeAliasDeclaration(statement) &&
          [...CSF3_TYPE_NAMES].some(
            (name) => countIdentifiers(ts, statement.type, name) > 0
          ) &&
          countIdentifiers(ts, file, statement.name.text) === 1
      )
      .map((statement) => removeStatementEdit(ts, source, statement))
  );
  const reparsed = parseSource(ts, withoutAliases, filePath);
  const importEdits = importDeclarations(ts, reparsed)
    .filter((declaration) =>
      moduleSpecifier(ts, declaration).startsWith('@storybook/')
    )
    .flatMap((declaration) =>
      removeImportSpecifiersEdits(ts, withoutAliases, {
        declaration,
        remove: (element) =>
          CSF3_TYPE_NAMES.has(element.name.text) &&
          countIdentifiers(ts, reparsed, element.name.text) === 1,
      })
    );

  return applyEdits(withoutAliases, importEdits);
};
