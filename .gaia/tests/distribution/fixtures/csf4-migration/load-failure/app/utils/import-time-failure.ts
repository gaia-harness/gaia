// A module that throws when it is first imported, so a story file importing it
// converts fine and typechecks but cannot load.
if ((globalThis as {isLoaded?: boolean}).isLoaded !== true) {
  throw new Error('import-time failure');
}

export const FRAGILE_LABEL = 'Fragile';
