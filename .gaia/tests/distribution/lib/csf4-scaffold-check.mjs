// Structural checks over scaffolded story files, using the staged tree's own
// TypeScript. Usage: node csf4-scaffold-check.mjs <frontend dir> <kind> <file>...
// Kinds: plain (any scaffolded story), data (also installs handlers in a
// beforeEach and uses no parameters.msw).
// Prints one problem per line and exits 1 when any check fails.
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import path from 'node:path';

const [frontendDirectory, kind, ...files] = process.argv.slice(2);
const ts = createRequire(path.join(frontendDirectory, 'package.json'))(
  'typescript'
);
const problems = [];

const isCallNamed = (node, name) =>
  ts.isCallExpression(node) &&
  ((ts.isIdentifier(node.expression) && node.expression.text === name) ||
    (ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === name));

const anyNode = (root, predicate) => {
  let found = false;
  const visit = (node) => {
    if (found) return;
    if (predicate(node)) {
      found = true;
      return;
    }
    ts.forEachChild(node, visit);
  };

  visit(root);

  return found;
};

const isPropertyNamed = (node, name) =>
  ts.isPropertyAssignment(node) || ts.isMethodDeclaration(node) ?
    node.name.getText() === name
  : false;

const checkFile = (file) => {
  const source = ts.createSourceFile(
    file,
    readFileSync(path.join(frontendDirectory, file), 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  );

  if (!/from '#\.storybook\/preview'/u.test(source.text)) {
    problems.push(`${file}: does not import #.storybook/preview`);
  }
  if (!anyNode(source, (node) => isCallNamed(node, 'test'))) {
    problems.push(`${file}: holds no .test( call`);
  }

  // Every `play` property, wherever it sits (meta or story).
  const plays = [];
  const collect = (node) => {
    if (isPropertyNamed(node, 'play')) plays.push(node);
    ts.forEachChild(node, collect);
  };

  collect(source);
  plays.forEach((play) => {
    if (anyNode(play, (node) => isCallNamed(node, 'expect'))) {
      problems.push(`${file}: an expect( sits inside a play`);
    }
  });

  if (kind === 'data') {
    if (!anyNode(source, (node) => isPropertyNamed(node, 'beforeEach'))) {
      problems.push(`${file}: no beforeEach installs the handlers`);
    }
    if (anyNode(source, (node) => isPropertyNamed(node, 'msw'))) {
      problems.push(`${file}: parameters.msw remains`);
    }
  }
};

files.forEach(checkFile);
problems.forEach((problem) => console.log(problem));
process.exit(problems.length > 0 ? 1 : 0);
