type IndexEntryKind = {subtype?: string; type: string};

/**
 * True for an index entry that is a visual state. Storybook indexes each
 * `.test()` as `type: 'story'` with `subtype: 'test'`; it renders its parent's
 * state, so scanning it again would repeat the parent's scan.
 */
export const isVisualStoryEntry = (entry: IndexEntryKind): boolean =>
  entry.type === 'story' && entry.subtype !== 'test';
