// The vitest node project's test globs, shared so the ESLint override that
// turns off require-css-escape for Node code cannot drift from them.
export const nodeTestInclude = ['app/**/*.test.ts', 'test/**/*.test.ts'];

export const nodeTestExclude = ['app/**/hooks/**'];
