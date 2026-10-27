import {lookupOwn, takeValue} from '../util/argv.js';

export type Flags = {
  absentPaths: string[];
  backupDir: string | undefined;
  conflicted: string[];
  json: boolean;
  manifest: string;
  root: string;
  skipRegions: string[];
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

type ParseState = {
  absentPaths: string[];
  backupDir: string | undefined;
  conflicted: string[];
  json: boolean;
  manifest: string | undefined;
  root: string | undefined;
  skipRegions: string[];
};

type ValueFlagHandler = (state: ParseState, value: string) => void;

const VALUE_FLAGS: Readonly<Record<string, ValueFlagHandler>> = {
  '--absent-path': (state, value) => {
    state.absentPaths.push(value);
  },
  '--backup-dir': (state, value) => {
    state.backupDir = value;
  },
  '--conflicted': (state, value) => {
    state.conflicted.push(value);
  },
  '--manifest': (state, value) => {
    state.manifest = value;
  },
  '--root': (state, value) => {
    state.root = value;
  },
  '--skip-region': (state, value) => {
    state.skipRegions.push(value);
  },
};

type ApplyTokenArgs = {
  argv: readonly string[];
  index: number;
  state: ParseState;
  token: string;
};

type TokenOutcome = {advance: number; ok: true} | {message: string; ok: false};

const applyToken = ({
  argv,
  index,
  state,
  token,
}: ApplyTokenArgs): TokenOutcome => {
  if (token === '--json') {
    state.json = true;

    return {advance: 0, ok: true};
  }

  const handler = lookupOwn(VALUE_FLAGS, token);

  if (handler === undefined)
    return {message: `unknown flag: ${token}`, ok: false};

  const taken = takeValue(argv, index + 1, token);

  if (!taken.ok) return taken;
  handler(state, taken.value);

  return {advance: 1, ok: true};
};

export const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const state: ParseState = {
    absentPaths: [],
    backupDir: undefined,
    conflicted: [],
    json: false,
    manifest: undefined,
    root: undefined,
    skipRegions: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== undefined) {
      const outcome = applyToken({argv, index, state, token});

      if (!outcome.ok) return outcome;
      index += outcome.advance;
    }
  }

  const {
    absentPaths,
    backupDir,
    conflicted,
    json,
    manifest,
    root,
    skipRegions,
  } = state;

  if (manifest === undefined)
    return {message: '--manifest is required', ok: false};

  if (root === undefined) return {message: '--root is required', ok: false};

  return {
    flags: {
      absentPaths,
      backupDir,
      conflicted,
      json,
      manifest,
      root,
      skipRegions,
    },
    ok: true,
  };
};
