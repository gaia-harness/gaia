import type {ModelFamily} from './types.js';

const FAMILIES: readonly Exclude<ModelFamily, 'unresolved'>[] = [
  'opus',
  'sonnet',
  'fable',
  'haiku',
];

/** The model family a `model:` value names, or undefined for `inherit` and anything else. */
export const familyOf = (value: unknown): ModelFamily | undefined => {
  if (typeof value !== 'string') return undefined;

  const lowered = value.toLowerCase();

  return FAMILIES.find((family) => lowered.includes(family));
};

/** A file's own `model:` first, then the project's, then `unresolved`. */
export const resolveModel = (
  fileModel: unknown,
  projectModel: ModelFamily
): ModelFamily => familyOf(fileModel) ?? projectModel;

/** The project model from the root settings file's text; `unresolved` when absent or unreadable. */
export const projectModelFromSettings = (
  settingsText: string | undefined
): ModelFamily => {
  if (settingsText === undefined) return 'unresolved';

  try {
    const parsed: unknown = JSON.parse(settingsText);

    if (parsed === null || typeof parsed !== 'object') return 'unresolved';

    return familyOf((parsed as {model?: unknown}).model) ?? 'unresolved';
  } catch {
    return 'unresolved';
  }
};
