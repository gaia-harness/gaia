import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {findMainPath, findPreviewPath} from './inventory.js';
import type {Repairs, StoryFormat, Ts} from './repairs/index.js';

export type ClassifiedStories = {
  csf2: string[];
  csf3: string[];
  csf4: string[];
  unknown: string[];
};

export type ConfigEdit = {
  /** Package-relative. */
  relative: string;
  text: string;
};

export type WritePlan = {
  configEdits: ConfigEdit[];
  /** Package-relative story files to convert. */
  stories: string[];
  unknownAddons: string[];
};

export const classifyStories = ({
  packageDir,
  repairs,
  storyFiles,
  ts,
}: {
  packageDir: string;
  repairs: Repairs;
  storyFiles: readonly string[];
  ts: Ts;
}): ClassifiedStories => {
  const grouped: Record<StoryFormat, string[]> = {
    csf2: [],
    csf3: [],
    csf4: [],
    unknown: [],
  };

  storyFiles.forEach((relative) => {
    const absolute = path.join(packageDir, relative);

    grouped[
      repairs.classifyStoryFile(ts, readFileSync(absolute, 'utf8'), absolute)
    ].push(relative);
  });

  return grouped;
};

/**
 * What the run would write, computed without writing: each CSF3 story, and the
 * preview, main and package.json only when their (pure) repair changes the
 * adopter's original.
 */
export const computeWritePlan = ({
  csf3Stories,
  packageDir,
  repairs,
  ts,
}: {
  csf3Stories: readonly string[];
  packageDir: string;
  repairs: Repairs;
  ts: Ts;
}): WritePlan => {
  const configEdits: ConfigEdit[] = [];
  let unknownAddons: string[] = [];
  const previewPath = findPreviewPath(packageDir);
  const mainPath = findMainPath(packageDir);
  const packageJsonPath = path.join(packageDir, 'package.json');
  const mainSource =
    mainPath === undefined ? undefined : readFileSync(mainPath, 'utf8');

  if (previewPath !== undefined) {
    const result = repairs.rewirePreview(
      ts,
      readFileSync(previewPath, 'utf8'),
      mainSource === undefined ?
        []
      : repairs.mainAddonSpecifiers(ts, mainSource)
    );

    unknownAddons = [...result.unknownAddons];

    if (result.changed) {
      configEdits.push({
        relative: path.relative(packageDir, previewPath),
        text: result.source,
      });
    }
  }

  if (mainPath !== undefined && mainSource !== undefined) {
    const result = repairs.setTestSyntaxFlag(ts, mainSource);

    if (result.changed) {
      configEdits.push({
        relative: path.relative(packageDir, mainPath),
        text: result.source,
      });
    }
  }

  if (existsSync(packageJsonPath)) {
    const result = repairs.ensurePreviewImportsSubpath(
      readFileSync(packageJsonPath, 'utf8')
    );

    if (result.changed) {
      configEdits.push({relative: 'package.json', text: result.text});
    }
  }

  return {configEdits, stories: [...csf3Stories], unknownAddons};
};

export const writeSetOf = (plan: WritePlan): string[] => [
  ...plan.stories,
  ...plan.configEdits.map((edit) => edit.relative),
];
