import {describe, expect, test} from 'vitest';

// Runs in the node project and pins that its worker keeps the real environment.
// A setup file that loads `.storybook/preview`, or a DOM emulation environment
// on the project, lets a preview module that assigns to `window.process.env`
// replace the worker's environment for the whole suite, silently dropping every
// variable it does not name. `PATH` is the witness: always present in a real
// environment, and never a key a preview shim has any reason to inline.

describe('node project environment', () => {
  test('the worker keeps its real process.env', () => {
    expect(
      process.env.PATH,
      'PATH is absent, so something replaced process.env rather than adding to it'
    ).toBeTruthy();
  });
});
