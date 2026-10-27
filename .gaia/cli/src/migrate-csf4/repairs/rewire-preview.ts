/**
 * Rewires an adopter's original CSF3 preview (`const preview: Preview = {...}`)
 * into `export default definePreview({...})`. The codemod's own preview is
 * discarded because it wires every community addon wrong: msw through a
 * namespace import with its CSF3 loader kept, i18next without the explicit
 * `definePreviewAddon<AddonTypes>`, and the manager-only dark-mode addon as a
 * preview addon.
 */
import type {
  Expression,
  ImportDeclaration,
  ObjectLiteralExpression,
  SourceFile,
  Statement,
} from 'typescript';
import {
  countIdentifiers,
  findDeclaration,
  findExportDefault,
  importDeclarations,
  moduleSpecifier,
  parseSource,
  unwrapExpression,
} from './ast.js';
import type {Ts} from './ast.js';
import {
  addonImportLines,
  addonsPropertyText,
  DARK_MODE,
  detectAddonWiring,
  MSW,
  packageName,
  unknownAddonSpecifiers,
} from './preview-addons.js';
import {
  applyEdits,
  asObjectLiteral,
  findProperty,
  indentAt,
  insertPropertiesEdit,
  removeImportSpecifiersEdits,
  removeListElementEdit,
  removeStatementEdit,
} from './text-edits.js';
import type {TextEdit} from './text-edits.js';

type PreviewConfig = {
  exportStatement: Statement;
  literal: ObjectLiteralExpression;
  wrapped: Statement;
};

/** The CSF3 preview object and the statements that bind and export it. */
const findPreviewConfig = (
  ts: Ts,
  file: SourceFile
): PreviewConfig | undefined => {
  const exportStatement = findExportDefault(ts, file);

  if (!exportStatement) return undefined;
  const {expression} = exportStatement;

  if (!ts.isIdentifier(expression)) {
    const literal = asObjectLiteral(ts, expression);

    return literal ?
        {exportStatement, literal, wrapped: exportStatement}
      : undefined;
  }
  const bound = findDeclaration(ts, file, expression.text);
  const literal = asObjectLiteral(ts, bound?.declaration.initializer);

  return bound && literal ?
      {exportStatement, literal, wrapped: bound.statement}
    : undefined;
};

const definesPreview = (ts: Ts, file: SourceFile): boolean => {
  const exportDefault = findExportDefault(ts, file);
  const value = exportDefault && unwrapExpression(ts, exportDefault.expression);

  return (
    value !== undefined &&
    ts.isCallExpression(value) &&
    ts.isIdentifier(value.expression) &&
    value.expression.text === 'definePreview'
  );
};

const importedNames = (ts: Ts, declaration: ImportDeclaration): string[] => {
  const clause = declaration.importClause;
  const bindings = clause?.namedBindings;
  const named =
    bindings && ts.isNamedImports(bindings) ?
      bindings.elements.map((element) => element.name.text)
    : [];

  return [...(clause?.name ? [clause.name.text] : []), ...named];
};

/** The local names `mswLoader` is imported under. */
const mswLoaderNames = (
  ts: Ts,
  imports: readonly ImportDeclaration[]
): Set<string> =>
  new Set(
    imports
      .filter(
        (declaration) => packageName(moduleSpecifier(ts, declaration)) === MSW
      )
      .flatMap((declaration) => {
        const bindings = declaration.importClause?.namedBindings;

        return bindings && ts.isNamedImports(bindings) ?
            bindings.elements
              .filter(
                (element) =>
                  (element.propertyName ?? element.name).text === 'mswLoader'
              )
              .map((element) => element.name.text)
          : [];
      })
  );

/** Edits dropping every `mswLoader` entry, or the whole `loaders` it empties. */
const mswLoaderEdits = (
  ts: Ts,
  source: string,
  {
    literal,
    loaderNames,
  }: {literal: ObjectLiteralExpression; loaderNames: ReadonlySet<string>}
): TextEdit[] => {
  const loaders = findProperty(ts, literal, 'loaders');

  if (!loaders || !ts.isPropertyAssignment(loaders)) return [];

  const isMswLoader = (node: Expression): boolean => {
    const callee = ts.isCallExpression(node) ? node.expression : node;

    return ts.isIdentifier(callee) && loaderNames.has(callee.text);
  };
  const value = loaders.initializer;
  const removeLoaders = [
    removeListElementEdit(ts, source, {
      elements: literal.properties,
      index: literal.properties.indexOf(loaders),
    }),
  ];

  if (!ts.isArrayLiteralExpression(value)) {
    return isMswLoader(value) ? removeLoaders : [];
  }
  const indexes = value.elements.flatMap((element, index) =>
    isMswLoader(element) ? [index] : []
  );

  if (indexes.length === value.elements.length) return removeLoaders;

  return indexes.map((index) =>
    removeListElementEdit(ts, source, {elements: value.elements, index})
  );
};

/** Edits replacing the `Preview` type import with the CSF Next imports. */
const importEdits = (
  ts: Ts,
  source: string,
  {
    previewTypeImport,
    wiringImports,
  }: {previewTypeImport: ImportDeclaration; wiringImports: string}
): TextEdit[] => {
  const withoutPreview = removeImportSpecifiersEdits(ts, source, {
    declaration: previewTypeImport,
    remove: (element) => element.name.text === 'Preview',
  });
  const importGone =
    withoutPreview.length === 1 && withoutPreview[0]?.text === '';
  const start = previewTypeImport.getStart();

  return importGone ?
      [{end: previewTypeImport.end, start, text: wiringImports}]
    : [{end: start, start, text: `${wiringImports}\n`}, ...withoutPreview];
};

/** Edits removing a dark-mode import nothing else in the preview uses. */
const darkModeImportEdits = (
  ts: Ts,
  source: string,
  {file, imports}: {file: SourceFile; imports: readonly ImportDeclaration[]}
): TextEdit[] =>
  imports
    .filter(
      (declaration) =>
        DARK_MODE.includes(packageName(moduleSpecifier(ts, declaration))) &&
        importedNames(ts, declaration).every(
          (name) => countIdentifiers(ts, file, name) === 1
        )
    )
    .map((declaration) => removeStatementEdit(ts, source, declaration));

/** Edits wrapping the config object in `export default definePreview(...)`. */
const wrapEdits = (
  ts: Ts,
  source: string,
  {exportStatement, literal, wrapped}: PreviewConfig
): TextEdit[] => [
  {
    end: literal.getStart(),
    start: wrapped.getStart(),
    text: 'export default definePreview(',
  },
  {end: wrapped.end, start: literal.end, text: ');'},
  ...(wrapped === exportStatement ?
    []
  : [removeStatementEdit(ts, source, exportStatement)]),
];

const findPreviewTypeImport = (
  ts: Ts,
  imports: readonly ImportDeclaration[]
): ImportDeclaration | undefined =>
  imports.find((declaration) => {
    const bindings = declaration.importClause?.namedBindings;

    return (
      bindings !== undefined &&
      ts.isNamedImports(bindings) &&
      bindings.elements.some((element) => element.name.text === 'Preview')
    );
  });

/**
 * Rewires a CSF3 `Preview` object to `definePreview`, wiring the addons the
 * preview shows or `mainAddons` (main's addon specifiers) lists; a
 * `definePreview` preview is returned unchanged.
 */
export const rewirePreview = (
  ts: Ts,
  source: string,
  mainAddons: readonly string[] = []
): {changed: boolean; source: string; unknownAddons: readonly string[]} => {
  const unchanged = {changed: false, source, unknownAddons: []};
  const file = parseSource(ts, source, 'preview.ts');
  const config = findPreviewConfig(ts, file);
  const imports = importDeclarations(ts, file);
  const previewTypeImport = findPreviewTypeImport(ts, imports);

  if (definesPreview(ts, file) || !config || !previewTypeImport) {
    return unchanged;
  }
  const specifiers = imports.map((declaration) =>
    moduleSpecifier(ts, declaration)
  );
  const wiring = detectAddonWiring(ts, {
    config: config.literal,
    mainAddons,
    specifiers,
  });
  const wiringImports = addonImportLines(wiring, {
    framework: moduleSpecifier(ts, previewTypeImport),
    quote: source[previewTypeImport.moduleSpecifier.getStart()] ?? "'",
  });
  const loaderNames = mswLoaderNames(ts, imports);
  const firstProperty = config.literal.properties[0];
  const addons = addonsPropertyText(
    wiring,
    indentAt(source, firstProperty?.getStart() ?? config.literal.getStart())
  );
  const otherImports = imports.filter(
    (declaration) => declaration !== previewTypeImport
  );
  const edits = [
    ...importEdits(ts, source, {previewTypeImport, wiringImports}),
    ...otherImports
      .filter(
        (declaration) => packageName(moduleSpecifier(ts, declaration)) === MSW
      )
      .flatMap((declaration) =>
        removeImportSpecifiersEdits(ts, source, {
          declaration,
          remove: (element) => loaderNames.has(element.name.text),
        })
      ),
    ...darkModeImportEdits(ts, source, {file, imports: otherImports}),
    ...mswLoaderEdits(ts, source, {literal: config.literal, loaderNames}),
    ...(addons ? insertPropertiesEdit(source, config.literal, [addons]) : []),
    ...wrapEdits(ts, source, config),
  ];

  return {
    changed: true,
    source: applyEdits(source, edits),
    unknownAddons: unknownAddonSpecifiers([...specifiers, ...mainAddons]),
  };
};
