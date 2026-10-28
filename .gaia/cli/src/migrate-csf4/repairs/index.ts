/**
 * The migration's source-to-source repairs over what Storybook's
 * csf-factories codemod produces. Every function is pure (no filesystem, no
 * process) and takes the adopter package's own TypeScript module as `ts`.
 */
import type {Ts} from './ast.js';
import type {StoryFormat} from './classify.js';
import {classifyStoryFile as classify} from './classify.js';
import type {PreCodemodFacts} from './facts.js';
import {capturePreCodemodFacts as captureFacts} from './facts.js';
import {restoreLeadingComment as restoreComment} from './leading-comment.js';
import {mainAddonSpecifiers as readMainAddons} from './main-addons.js';
import {setTestSyntaxFlag as setFlag} from './main-flag.js';
import {ensurePreviewImportsSubpath as ensureSubpath} from './package-imports.js';
import {repairStoryFile as repairStory} from './repair-story.js';
import {rewirePreview as rewire} from './rewire-preview.js';

export type {Ts} from './ast.js';

export type {StoryFormat} from './classify.js';

export type {PreCodemodFacts} from './facts.js';

/** The repair surface the migration command receives as a parameter. */
export type Repairs = {
  capturePreCodemodFacts: (
    ts: Ts,
    source: string,
    filePath: string
  ) => PreCodemodFacts;
  classifyStoryFile: (ts: Ts, source: string, filePath: string) => StoryFormat;
  ensurePreviewImportsSubpath: (packageJsonText: string) => {
    changed: boolean;
    text: string;
  };
  mainAddonSpecifiers: (ts: Ts, mainSource: string) => string[];
  // eslint-disable-next-line max-params -- the frozen repair contract the migration command codes against
  repairStoryFile: (
    ts: Ts,
    codemodOutput: string,
    original: string,
    facts: PreCodemodFacts,
    filePath: string
  ) => {notes: readonly string[]; source: string};
  restoreLeadingComment: (before: string, after: string) => string;
  rewirePreview: (
    ts: Ts,
    source: string,
    mainAddons?: readonly string[]
  ) => {changed: boolean; source: string; unknownAddons: readonly string[]};
  setTestSyntaxFlag: (
    ts: Ts,
    mainSource: string
  ) => {changed: boolean; source: string};
};

export const classifyStoryFile: Repairs['classifyStoryFile'] = classify;

export const capturePreCodemodFacts: Repairs['capturePreCodemodFacts'] =
  captureFacts;

export const repairStoryFile: Repairs['repairStoryFile'] = repairStory;

export const rewirePreview: Repairs['rewirePreview'] = rewire;

export const mainAddonSpecifiers: Repairs['mainAddonSpecifiers'] =
  readMainAddons;

export const setTestSyntaxFlag: Repairs['setTestSyntaxFlag'] = setFlag;

export const restoreLeadingComment: Repairs['restoreLeadingComment'] =
  restoreComment;

export const ensurePreviewImportsSubpath: Repairs['ensurePreviewImportsSubpath'] =
  ensureSubpath;
