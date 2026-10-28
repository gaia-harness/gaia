// Story mode for extract-test-signals.mjs: per-test (fullName, signal) pairs
// from a CSF4 `*.stories.tsx` / `*.stories.ts` file (`preview.meta`,
// `meta.story`, `.extend`, `.test()`), whose stories @storybook/addon-vitest
// runs as Vitest tests. CSF4 only: ./story-format.mjs decides the format, an
// older format throws OldStoryFormat (the caller exits 8 and names the
// migration command) and an unknown one refuses.
//
// Entries, in export source order, for each exported story whose tags keep it
// a test (Storybook's combineTags over "test", "dev", the meta `tags`, then the
// story's own static `tags`: those in its own `meta.story({…})` or
// `.extend({…})` argument, never a source story's):
//   - a story carrying any `.test()`: `<Story Name>   base story`, then
//     `<Story Name>   <test name>` per call in source order;
//   - a story with an effective play and no tests: `<Story Name>`;
//   - a render-only story with no tests: nothing.
// Read from Storybook 10.6.3's vitest transform: a story with tests becomes a
// describe titled with the story name plus two trailing spaces, so the
// reporter's fullName joins with three spaces, and its own render/play is the
// test `base story`. Only a top-level `Story.test('<string literal>', …)`
// statement is indexed as a test.
//
// <Story Name>: storyNameFromExport(exportName), overridden by a string-literal
// `name` in the story's own call argument. An `.extend` story is named by its
// own export, overridden only by a `name` in its own extend argument: the
// static parse reads the extending call's argument, while `extend` copies the
// source's whole input, `name` included, into the runtime story only.
//
// Effective play, as Storybook 10.6.3's `defineStory` composes it: the story
// argument's `play`; for `.extend`, the source story's input play when the
// extend argument sets no `play` key (`{...source.input, ...input}`, so a
// `play: undefined` overrides it); then the meta's play.
//
// signal: "sha256:" + hex sha256 of these regions, each normalized and
// comment-free exactly as a test signal is, joined by "\n", for every entry
// of a story (its base story, each test, or its plain entry):
//   1. the story's declaration statement;
//   2. the resolved play (the function node, or the same-file declaration an
//      identifier resolves to; for an inherited play, the source's), or empty;
//   3. the meta's declaration statement;
//   4. for a test entry only, that `.test(…)` call statement.
// So an edit to a story's play rotates its base story, every attached test and
// every `.extend` story inheriting it; an edit to one test rotates that test;
// an edit to a sibling story rotates nothing of this one.
//
// Refusal (StoryShapeRefusal, the first offending export in source order; the
// meta and the file report as `default`): a play bound to an import or a
// mutable binding, a play the extractor cannot read, an `export {…}` clause or
// `export *`, a `.test()` whose name is not a string literal or whose story is
// not an exported story declared before it, a top-level assignment to a story
// or the meta, an `.extend` of something other than a same-file story, a cycle,
// meta spreads, `includeStories` / `excludeStories`, and non-literal `tags`.
// A play body calling imported helpers is normal and never refused.

import {createHash} from 'node:crypto';
import {classifyStoryFormat, hasModifier, isPreviewMetaCall} from './story-format.mjs';

// A story file the extractor will not read: the driver prints
// `extract-test-signals: <describe(path)>` and exits with exitCode, the code
// its callers branch on (7 refuse the shape, 8 send the file to migration).
export class StoryFileRefusal extends Error {
  constructor(exitCode, reason) {
    super(reason);
    this.exitCode = exitCode;
    this.reason = reason;
  }
}

export class StoryShapeRefusal extends StoryFileRefusal {
  constructor(exportName, reason) {
    super(7, reason);
    this.exportName = exportName;
  }

  describe(filePath) {
    return `unsupported story shape in ${filePath}: ${this.exportName}: ${this.reason}`;
  }
}

export class OldStoryFormat extends StoryFileRefusal {
  constructor(format) {
    super(8, `a ${format} story file`);
  }

  describe(filePath) {
    return `${filePath} is an old-format story file; migrate it with: .gaia/cli/gaia migrate-csf4`;
  }
}

// Mirrors storybook 10.6.3 `toStartCaseStr` (src/csf/toStartCaseStr.ts), which
// its `storyNameFromExport` (src/csf/export-story.ts) returns unchanged. Copied
// rather than imported: this script resolves only `typescript` from the repo
// root and must not depend on frontend's node_modules.
export function storyNameFromExport(key) {
  return key
    .replace(/_/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\./g, ' ')
    .replace(/([^\n])([A-Z])([a-z])/g, (_match, a, b, c) => `${a} ${b}${c}`)
    .replace(/([a-z])([A-Z])/g, (_match, a, b) => `${a} ${b}`)
    .replace(/([a-z])([0-9])/gi, (_match, a, b) => `${a} ${b}`)
    .replace(/([0-9])([a-z])/gi, (_match, a, b) => `${a} ${b}`)
    .replace(/(\s|^)(\w)/g, (_match, a, b) => `${a}${b.toUpperCase()}`)
    .replace(/ +/g, ' ')
    .trim();
}

// Mirrors storybook 10.6.3 `combineTags` (src/csf/csf-utils.ts): later tags
// win, and a `!tag` deletes an earlier `tag`.
function combineTags(...tags) {
  const result = new Set();
  for (const tag of tags) {
    if (tag.startsWith('!')) {
      result.delete(tag.slice(1));
    } else {
      result.add(tag);
    }
  }
  return result;
}

// A play key that is present but literally `undefined`.
const UNDEFINED_PLAY = Object.freeze({undefinedPlay: true});
const isRealPlay = (play) => Boolean(play) && play !== UNDEFINED_PLAY;

export function extractStorySignals({ts, sourceFile, textWithoutComments, normalize}) {
  const {format, previewNames} = classifyStoryFormat(ts, sourceFile);
  if (format === 'csf2' || format === 'csf3') {
    throw new OldStoryFormat(format);
  }
  if (format !== 'csf4') {
    throw new StoryShapeRefusal('default', 'the file is not a CSF4 story file (a `#.storybook/preview` meta with factory stories) nor an older format the migration converts');
  }

  const unwrap = (expression) => {
    let current = expression;
    while (
      current &&
      (ts.isParenthesizedExpression(current) ||
        ts.isAsExpression(current) ||
        ts.isSatisfiesExpression(current) ||
        ts.isNonNullExpression(current) ||
        ts.isTypeAssertionExpression(current))
    ) {
      current = current.expression;
    }
    return current;
  };
  const position = (node) => node.getStart(sourceFile);
  const regionText = (node) => normalize(textWithoutComments(node.getStart(sourceFile), node.getEnd()));
  const refuser = (exportName) => (reason) => {
    throw new StoryShapeRefusal(exportName, reason);
  };
  const refuseMeta = refuser('default');

  // Top-level bindings: name -> {kind, statement, node, init}.
  const bindings = new Map();
  // Exported variable names, in source order.
  const exportNames = [];
  // Top-level `Name.prop = value` targets: name -> first statement.
  const assignedNames = new Map();
  // Top-level `Name.test(…)` statements, in source order.
  const testStatements = [];

  for (const statement of sourceFile.statements) {
    if (ts.isImportDeclaration(statement)) {
      const clause = statement.importClause;
      const named = clause?.namedBindings;
      const names = [clause?.name, ...(named && ts.isNamespaceImport(named) ? [named.name] : (named?.elements ?? []).map((element) => element.name))];
      for (const name of names.filter(Boolean)) {
        bindings.set(name.text, {kind: 'import', statement});
      }
    } else if (ts.isImportEqualsDeclaration(statement)) {
      bindings.set(statement.name.text, {kind: 'import', statement});
    } else if (ts.isVariableStatement(statement)) {
      if (hasModifier(ts, statement, ts.SyntaxKind.DeclareKeyword)) {
        continue;
      }
      const flags = statement.declarationList.flags;
      const kind = flags & ts.NodeFlags.Const ? 'const' : flags & ts.NodeFlags.Let ? 'let' : 'var';
      const exported = hasModifier(ts, statement, ts.SyntaxKind.ExportKeyword);
      for (const declaration of statement.declarationList.declarations) {
        if (!ts.isIdentifier(declaration.name)) {
          if (exported) {
            refuser('<destructured>')('a destructured export has no story name the extractor can read');
          }
          continue;
        }
        const name = declaration.name.text;
        bindings.set(name, {kind, statement, node: declaration, init: declaration.initializer});
        if (exported && name !== '__namedExportsOrder') {
          exportNames.push(name);
        }
      }
    } else if (ts.isFunctionDeclaration(statement) && statement.name) {
      bindings.set(statement.name.text, {kind: 'function', statement, node: statement});
    } else if (ts.isClassDeclaration(statement) && statement.name) {
      bindings.set(statement.name.text, {kind: 'class', statement});
    } else if (ts.isExportDeclaration(statement) && !statement.isTypeOnly) {
      const clause = statement.exportClause;
      if (!clause) {
        refuser('*')('an `export * from` re-export hides which stories the file exports');
      }
      if (ts.isNamespaceExport(clause)) {
        refuser(clause.name.text)('a namespace re-export is not a story the extractor can read');
      }
      const element = clause.elements.find((candidate) => !candidate.isTypeOnly);
      if (element) {
        refuser(element.name.text)('an `export {…}` clause is not a story declaration the extractor can read');
      }
    } else if (ts.isExpressionStatement(statement)) {
      const expression = statement.expression;
      if (
        ts.isBinaryExpression(expression) &&
        expression.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isPropertyAccessExpression(expression.left) &&
        ts.isIdentifier(expression.left.expression)
      ) {
        const name = expression.left.expression.text;
        if (!assignedNames.has(name)) {
          assignedNames.set(name, statement);
        }
      } else if (
        ts.isCallExpression(expression) &&
        ts.isPropertyAccessExpression(expression.expression) &&
        ts.isIdentifier(expression.expression.expression) &&
        expression.expression.name.text === 'test'
      ) {
        testStatements.push({owner: expression.expression.expression.text, statement, call: expression});
      }
    }
  }

  const propertyName = (member, refuse) => {
    const name = member.name;
    if (!name) {
      return null;
    }
    if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNoSubstitutionTemplateLiteral(name) || ts.isNumericLiteral(name)) {
      return name.text;
    }
    refuse('an object member has a computed key the extractor cannot read');
    return null;
  };
  const memberValue = (member) => {
    if (ts.isPropertyAssignment(member)) {
      return member.initializer;
    }
    return ts.isShorthandPropertyAssignment(member) ? member.name : member;
  };

  const parseTags = (node, refuse) => {
    let value = unwrap(node);
    if (value && ts.isIdentifier(value)) {
      const binding = bindings.get(value.text);
      value = binding?.kind === 'const' ? unwrap(binding.init) : null;
    }
    if (!value || !ts.isArrayLiteralExpression(value) || !value.elements.every((element) => ts.isStringLiteral(element))) {
      refuse('tags is not an array of string literals');
    }
    return value.elements.map((element) => element.text);
  };

  // ---- meta ---------------------------------------------------------------

  const metaNames = [...bindings].filter(([, binding]) => isPreviewMetaCall(ts, unwrap(binding.init), previewNames));
  if (metaNames.length !== 1) {
    refuseMeta('the file binds more than one preview meta');
  }
  const [metaBindingName, metaBinding] = metaNames[0];
  if (metaBinding.kind !== 'const') {
    refuseMeta('the meta is a mutable binding');
  }
  if (assignedNames.has(metaBindingName)) {
    refuseMeta('the meta is assigned to after its declaration');
  }
  const metaObject = unwrap(unwrap(metaBinding.init).arguments[0]);
  if (!metaObject || !ts.isObjectLiteralExpression(metaObject)) {
    refuseMeta('the meta argument is not an object literal');
  }
  let metaTagsNode = null;
  let metaPlayMember = null;
  for (const member of metaObject.properties) {
    if (ts.isSpreadAssignment(member)) {
      refuseMeta('the meta spreads another object, which can carry play or tags');
    }
    const name = propertyName(member, refuseMeta);
    if (name === 'includeStories' || name === 'excludeStories') {
      refuseMeta(`the meta sets ${name}, which decides story exports at runtime`);
    }
    if ((name === 'play' || name === 'tags') && (ts.isGetAccessorDeclaration(member) || ts.isSetAccessorDeclaration(member))) {
      refuseMeta(`the meta defines ${name} through an accessor`);
    }
    if (name === 'play') {
      metaPlayMember = member;
    } else if (name === 'tags') {
      metaTagsNode = memberValue(member);
    }
  }
  const metaTags = metaTagsNode ? parseTags(metaTagsNode, refuseMeta) : [];
  const metaRegion = regionText(metaBinding.statement);

  // ---- stories ------------------------------------------------------------

  // A story binding's factory call: {method: 'story' | 'extend', source, argument}.
  const storyCall = (name) => {
    const binding = bindings.get(name);
    const init = binding?.init ? unwrap(binding.init) : null;
    if (!init || !ts.isCallExpression(init) || !ts.isPropertyAccessExpression(init.expression)) {
      return null;
    }
    const method = init.expression.name.text;
    if (method !== 'story' && method !== 'extend') {
      return null;
    }
    return {binding, method, receiver: unwrap(init.expression.expression), argument: init.arguments[0] ? unwrap(init.arguments[0]) : null};
  };

  function withVisit(key, context, run) {
    if (context.visiting.has(key)) {
      context.refuse(`a play or extend cycle runs through ${key}`);
    }
    context.visiting.add(key);
    try {
      return run();
    } finally {
      context.visiting.delete(key);
    }
  }

  // A resolved play is null (no play key), UNDEFINED_PLAY, or {nodes: [...]}.
  function resolvePlayValue(expression, context) {
    const value = unwrap(expression);
    if (ts.isArrowFunction(value) || ts.isFunctionExpression(value) || ts.isMethodDeclaration(value)) {
      return {nodes: [value]};
    }
    if (ts.isIdentifier(value)) {
      const binding = bindings.get(value.text);
      if (!binding) {
        if (value.text === 'undefined') {
          return UNDEFINED_PLAY;
        }
        context.refuse(`play is bound to ${value.text}, which has no same-file top-level declaration`);
      }
      if (binding.kind === 'import') {
        context.refuse(`play is bound to the imported identifier ${value.text}`);
      }
      if (binding.kind === 'function') {
        return {nodes: [binding.node]};
      }
      if (binding.kind !== 'const' || !binding.init) {
        context.refuse(`play is bound to ${value.text}, which is not a const or function declaration`);
      }
      return withVisit(`identifier ${value.text}`, context, () => resolvePlayValue(binding.init, context));
    }
    if (ts.isPropertyAccessExpression(value) && ts.isIdentifier(value.expression) && value.name.text === 'play' && storyCall(value.expression.text)) {
      // A story's `play` getter: its input play, else the meta's.
      return effectivePlay(value.expression.text, context) ?? UNDEFINED_PLAY;
    }
    context.refuse('play is not a function, a same-file identifier, or a story play reference the extractor can read');
    return null;
  }

  // The play an object literal carries once its members have applied.
  function objectPlay(objectNode, context) {
    let state = null;
    for (const member of objectNode.properties) {
      if (ts.isSpreadAssignment(member)) {
        let spread = unwrap(member.expression);
        if (ts.isIdentifier(spread)) {
          const binding = bindings.get(spread.text);
          spread = binding?.kind === 'const' ? unwrap(binding.init) : null;
        }
        if (!spread || !ts.isObjectLiteralExpression(spread)) {
          context.refuse('the story spreads something other than a same-file object literal');
        }
        state = objectPlay(spread, context) ?? state;
        continue;
      }
      if (propertyName(member, context.refuse) !== 'play') {
        continue;
      }
      if (ts.isGetAccessorDeclaration(member) || ts.isSetAccessorDeclaration(member)) {
        context.refuse('play is defined through an accessor');
      }
      state = resolvePlayValue(memberValue(member), context);
    }
    return state;
  }

  // The play in a story's composed input: its own argument's, else (extend
  // only, when the argument has no play key) the source story's input play.
  function inputPlay(name, context) {
    return withVisit(`story ${name}`, context, () => {
      const call = storyCall(name);
      const argument = call.argument;
      let own = null;
      if (argument && ts.isObjectLiteralExpression(argument)) {
        own = objectPlay(argument, context);
      } else if (call.method === 'extend' || (argument && !ts.isArrowFunction(argument) && !ts.isFunctionExpression(argument))) {
        context.refuse(`the .${call.method}(…) argument is not an object literal${call.method === 'story' ? ' or a render function' : ''}`);
      }
      if (own !== null || call.method === 'story') {
        return own;
      }
      return inputPlay(call.receiver.text, context);
    });
  }

  function metaPlay(context) {
    return metaPlayMember ? resolvePlayValue(memberValue(metaPlayMember), context) : null;
  }

  function effectivePlay(name, context) {
    const own = inputPlay(name, context);
    if (isRealPlay(own)) {
      return own;
    }
    const fromMeta = metaPlay(context);
    return isRealPlay(fromMeta) ? fromMeta : null;
  }

  // Every story binding's receiver must be the meta (`.story`) or a same-file
  // story (`.extend`), and no story may be mutated after its declaration.
  for (const [name] of bindings) {
    const call = storyCall(name);
    if (!call) {
      continue;
    }
    const refuse = refuser(name);
    if (!ts.isIdentifier(call.receiver)) {
      refuse(`the .${call.method}(…) receiver is not an identifier the extractor can read`);
    }
    if (call.method === 'story' && call.receiver.text !== metaBindingName) {
      refuse(`.story(…) is called on ${call.receiver.text}, which is not the file's meta`);
    }
    if (call.method === 'extend' && !storyCall(call.receiver.text)) {
      refuse(`.extend(…) is called on ${call.receiver.text}, which is not a same-file story`);
    }
    if (call.binding.kind !== 'const') {
      refuse('the story is a mutable binding');
    }
    if (assignedNames.has(name)) {
      refuse('the story is assigned to after its declaration, which its factory input never sees');
    }
  }

  const testsByStory = new Map();
  for (const test of testStatements) {
    const refuse = refuser(test.owner);
    const binding = bindings.get(test.owner);
    if (!storyCall(test.owner) || !exportNames.includes(test.owner)) {
      refuse(`a .test(…) is called on ${test.owner}, which is not an exported story`);
    }
    if (position(test.statement) < position(binding.statement)) {
      refuse('a .test(…) call precedes its story declaration');
    }
    const [title] = test.call.arguments;
    if (test.call.arguments.length < 2 || !ts.isStringLiteral(title)) {
      refuse('a .test(…) call whose name is not a string literal is not indexed as a test');
    }
    if (!testsByStory.has(test.owner)) {
      testsByStory.set(test.owner, []);
    }
    testsByStory.get(test.owner).push({name: title.text, statement: test.statement});
  }

  const lines = [];
  const emit = (fullName, regions) => {
    const hex = createHash('sha256').update(regions.join('\n'), 'utf8').digest('hex');
    lines.push(JSON.stringify({fullName, signal: `sha256:${hex}`, kind: 'runtime'}));
  };

  for (const exportName of exportNames) {
    const call = storyCall(exportName);
    if (!call) {
      continue;
    }
    const refuse = refuser(exportName);
    let storyName = storyNameFromExport(exportName);
    let storyTagsNode = null;
    if (call.argument && ts.isObjectLiteralExpression(call.argument)) {
      for (const member of call.argument.properties) {
        if (!ts.isPropertyAssignment(member) || !ts.isIdentifier(member.name)) {
          continue;
        }
        if (member.name.text === 'name' && ts.isStringLiteral(member.initializer)) {
          storyName = member.initializer.text;
        } else if (member.name.text === 'tags') {
          storyTagsNode = member.initializer;
        }
      }
    }
    const storyTags = storyTagsNode ? parseTags(storyTagsNode, refuse) : [];
    if (!combineTags('test', 'dev', ...metaTags, ...storyTags).has('test')) {
      continue;
    }
    const play = effectivePlay(exportName, {refuse, visiting: new Set()});
    const baseRegions = [regionText(call.binding.statement), play ? play.nodes.map(regionText).join('\n') : '', metaRegion];
    const tests = testsByStory.get(exportName) ?? [];
    if (tests.length > 0) {
      emit(`${storyName}   base story`, baseRegions);
      for (const test of tests) {
        emit(`${storyName}   ${test.name}`, [...baseRegions, regionText(test.statement)]);
      }
    } else if (play) {
      emit(storyName, baseRegions);
    }
  }

  return lines;
}
