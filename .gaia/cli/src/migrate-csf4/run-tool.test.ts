import {describe, expect, test} from 'vitest';
import {runTool} from './run-tool.js';

describe('runTool', () => {
  test('tells pnpm not to install before running a script', () => {
    const result = runTool(
      'node',
      ['-p', 'process.env.pnpm_config_verify_deps_before_run'],
      {cwd: process.cwd()}
    );

    expect(result.stdout.trim()).toBe('false');
  });

  test('keeps the caller environment', () => {
    process.env.MIGRATE_TOOL_PROBE = 'kept';
    const result = runTool('node', ['-p', 'process.env.MIGRATE_TOOL_PROBE'], {
      cwd: process.cwd(),
    });

    delete process.env.MIGRATE_TOOL_PROBE;
    expect(result.stdout.trim()).toBe('kept');
  });
});
