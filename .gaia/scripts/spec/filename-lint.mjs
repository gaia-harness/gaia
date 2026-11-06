#!/usr/bin/env node
// Lint planned test file names with a package's own eslint config, before the
// files exist, so a name the render commit's lint-staged eslint would refuse is
// caught while planning.
//
// Usage:
//   node .gaia/scripts/spec/filename-lint.mjs --package <dir> <path relative to package>...
//
// Output (stdout): one `<path>\t<rule>: <eslint message>` line per refusal.
// Exit codes, which plan-verify.sh maps:
//   0  every name is clean
//   1  one or more refusals
//   2  eslint does not resolve from the package (dependencies not installed);
//      the caller may warn and skip
//   3  usage error, or eslint resolved but its config failed to load or lint
//      threw; never a skip, since a broken config must not pass silently
//
// Why the API and not `eslint --stdin --stdin-filename`: the type-aware parser
// refuses a path that does not exist ("not found by the project service")
// before any rule runs. Here the project service is switched off and every rule
// but the filename rules is turned off, so only the name is judged, on empty
// text.
//
// The scope is deliberately the path-based filename rules below, a rule-id list
// rather than a word list: the project's configured options for each rule
// (replacements, allowList, case) decide. Any other rule could fire on the
// empty text (unicorn/no-empty-file would), so none is let through. Folder
// names are not judged, matching the render commit, where eslint lints files.
import {createRequire} from 'node:module';
import path from 'node:path';

const filenameRuleIds = ['unicorn/prevent-abbreviations', 'unicorn/filename-case'];

const commandArguments = process.argv.slice(2);
if (commandArguments[0] !== '--package' || !commandArguments[1] || commandArguments.length < 3) {
  process.stderr.write(
    'usage: filename-lint.mjs --package <dir> <path relative to package>...\n',
  );
  process.exit(3);
}
const packageDirectory = path.resolve(commandArguments[1]);
const relativePaths = commandArguments.slice(2);

const require = createRequire(path.join(packageDirectory, 'package.json'));
let eslintPath;
try {
  eslintPath = require.resolve('eslint');
} catch {
  process.stderr.write(
    `filename-lint: eslint does not resolve from ${packageDirectory}; install the dependencies to lint file names\n`,
  );
  process.exit(2);
}
let ESLint;
try {
  ({ESLint} = require(eslintPath));
} catch (error) {
  process.stderr.write(`filename-lint: eslint failed to load: ${error?.message ?? error}\n`);
  process.exit(3);
}

let refusals = 0;
try {
  const base = new ESLint({cwd: packageDirectory});
  // Each ESLint instance loads the whole config, so paths whose rule sets
  // match (usually all of them) share one.
  const linters = new Map();
  for (const relativePath of relativePaths) {
    const filePath = path.join(packageDirectory, relativePath);
    const config = await base.calculateConfigForFile(filePath);
    const rules = Object.fromEntries(
      Object.keys(config?.rules ?? {}).map((ruleId) => [ruleId, 'off']),
    );
    for (const ruleId of filenameRuleIds) {
      if (config?.rules?.[ruleId]) rules[ruleId] = config.rules[ruleId];
    }
    const rulesKey = JSON.stringify(rules);
    if (!linters.has(rulesKey)) {
      linters.set(
        rulesKey,
        new ESLint({
          cwd: packageDirectory,
          overrideConfig: {
            languageOptions: {parserOptions: {projectService: false, project: null}},
            rules,
          },
        }),
      );
    }
    const [result] = await linters.get(rulesKey).lintText('', {filePath});
    for (const message of result?.messages ?? []) {
      if (message.fatal) throw new Error(`${relativePath}: ${message.message}`);
      if (!filenameRuleIds.includes(message.ruleId)) continue;
      refusals += 1;
      process.stdout.write(`${relativePath}\t${message.ruleId}: ${message.message}\n`);
    }
  }
} catch (error) {
  process.stderr.write(`filename-lint: eslint failed: ${error?.message ?? error}\n`);
  process.exit(3);
}
process.exit(refusals > 0 ? 1 : 0);
