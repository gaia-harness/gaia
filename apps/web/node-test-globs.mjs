// The vitest node project's test globs, shared with the lint config's
// nodeFiles option so the two cannot drift.
export const nodeTestInclude = ['app/**/*.test.ts', 'test/**/*.test.ts'];

export const nodeTestExclude = ['app/**/hooks/**'];
