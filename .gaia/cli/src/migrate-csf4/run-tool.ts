import {run} from '../util/run-process.js';
import type {CommandRunner} from './types.js';

/**
 * Runs a package-manager or third-party tool. pnpm would otherwise reinstall
 * dependencies before running a script, and in `work/` that install reaches
 * the adopter's `node_modules` through the symlink and rewrites its layout.
 */
export const runTool: CommandRunner = (command, args, options) =>
  run(command, args, {
    cwd: options.cwd,
    env: {...process.env, pnpm_config_verify_deps_before_run: 'false'},
  });
