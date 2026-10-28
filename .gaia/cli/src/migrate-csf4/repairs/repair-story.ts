/**
 * Repairs one story file's codemod output into the CSF4 form the project
 * loads. Every step is a no-op on a file already in that form, which is what
 * makes a re-run change nothing.
 */
import type {Ts} from './ast.js';
import {classifyStoryFile} from './classify.js';
import {convertCsf3StoryFile, removeUnusedCsf3Types} from './convert-csf3.js';
import type {PreCodemodFacts} from './facts.js';
import {foldStoryAssignments} from './fold-assignments.js';
import {inlineFactoryExports} from './inline-factories.js';
import {restoreLeadingComment} from './leading-comment.js';
import {restoreMetaArgsType, stabilizePreviewImport} from './story-rewrites.js';

/** Repairs a story's codemod output; `notes` names each repair applied. */
/* eslint-disable max-params -- the frozen repair contract the migration command codes against */
export const repairStoryFile = (
  ts: Ts,
  codemodOutput: string,
  original: string,
  facts: PreCodemodFacts,
  filePath: string
): {notes: readonly string[]; source: string} => {
  const notes: string[] = [];
  let source = codemodOutput;

  if (
    facts.factoryExports.length > 0 &&
    classifyStoryFile(ts, source, filePath) === 'csf3'
  ) {
    const converted = convertCsf3StoryFile(ts, source, filePath);

    if (converted === undefined) {
      notes.push(
        'could not convert the file the codemod skipped: its meta is not a plain object'
      );
    } else {
      source = converted;
      notes.push('converted the factory-built story file the codemod skipped');
    }
  }

  if (facts.factoryExports.length > 0) {
    const inlined = inlineFactoryExports(ts, source, {
      exportNames: facts.factoryExports,
      filePath,
    });

    source = inlined.source;
    notes.push(...inlined.notes);
    if (inlined.source !== codemodOutput)
      source = removeUnusedCsf3Types(ts, source, filePath);
  }
  const folded = foldStoryAssignments(ts, source, filePath);

  source = folded.source;
  notes.push(...folded.notes);

  if (facts.metaArgsType !== undefined) {
    const typed = restoreMetaArgsType(ts, source, {
      argsType: facts.metaArgsType,
      filePath,
    });

    if (typed.changed) {
      source = typed.source;
      notes.push(`restored the meta's custom args type ${facts.metaArgsType}`);
    }
  }
  const stable = stabilizePreviewImport(ts, source, filePath);

  if (stable.changed) {
    source = stable.source;
    notes.push('replaced the relative preview import with #.storybook/preview');
  }

  if (facts.leadingComment !== undefined) {
    const restored = restoreLeadingComment(original, source);

    if (restored !== source) {
      source = restored;
      notes.push('restored the opening comment the codemod dropped');
    }
  }

  return {notes, source};
};
/* eslint-enable max-params */
