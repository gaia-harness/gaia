/* eslint-disable no-underscore-dangle -- `_tag` is Storybook's own property name */
import {isEqual} from 'lodash-es';
import {
  combineTags,
  getStoryChildren,
  storyNameFromExport,
  toId,
  toTestId,
} from 'storybook/internal/csf';
import {combineParameters} from 'storybook/preview-api';

export type StoryOptOut = {id: string; isOptedOut: boolean};

type A11yDefaults = {config: unknown; options: unknown};

type A11yParameters = {
  config?: unknown;
  context?: unknown;
  disable?: boolean;
  options?: unknown;
  test?: string;
};

type ComposedStory = {
  globals?: StoryGlobals;
  id: string;
  parameters: StoryParameters;
  tags: string[];
};

type CsfStory = {
  _tag: 'Story';
  composed: ComposedStory;
  meta: {input: {title?: string}};
};

type StoryGlobals = {a11y?: {manual?: boolean}};

type StoryParameters = {a11y?: A11yParameters};

type TestChild = {
  input: {
    globals?: StoryGlobals;
    name: string;
    parameters?: StoryParameters;
    tags?: string[];
  };
};

const isCsfStory = (value: unknown): value is CsfStory =>
  typeof value === 'object' &&
  value !== null &&
  '_tag' in value &&
  value._tag === 'Story' &&
  'composed' in value &&
  'meta' in value;

const hasA11yOptOut = (story: ComposedStory, defaults: A11yDefaults) => {
  const {
    config,
    context,
    disable,
    options,
    test: testMode,
  } = story.parameters.a11y ?? {};

  return (
    testMode !== 'error' ||
    disable === true ||
    story.globals?.a11y?.manual === true ||
    !story.tags.includes('test') ||
    context !== undefined ||
    !isEqual(config, defaults.config) ||
    !isEqual(options, defaults.options)
  );
};

// Each `.test()` call is an extended story whose `input` holds the test's name
// and overrides; Storybook's own typing does not expose those fields.
const getTestChildren = (story: CsfStory) =>
  getStoryChildren(story as never) as unknown as TestChild[];

const applyTestOverrides = (
  parent: ComposedStory,
  child: TestChild
): ComposedStory => ({
  globals: {...parent.globals, ...child.input.globals},
  id: toTestId(parent.id, child.input.name),
  parameters: combineParameters(parent.parameters, child.input.parameters),
  tags: combineTags(...parent.tags, ...(child.input.tags ?? [])),
});

// A story imported as a plain module, outside Storybook's indexer, is composed
// without its export name and so reports an `--unnamed-story` id. Storybook
// names a story from its meta title and its export key (its own `name` does not
// change the id), so the id is rebuilt that way.
const resolveStoryId = (exportName: string, story: CsfStory): string => {
  const {title} = story.meta.input;

  if (title === undefined) {
    throw new Error(
      `Story "${exportName}" has no meta title, so its id cannot be resolved`
    );
  }

  return toId(title, storyNameFromExport(exportName));
};

/**
 * Every story and every `.test()` child of the given CSF4 story modules, with
 * whether its axe check has been loosened from the shared defaults.
 */
export const resolveStoryA11yOptOuts = (
  storyModules: Record<string, Record<string, unknown>>,
  defaults: A11yDefaults
): StoryOptOut[] =>
  Object.values(storyModules).flatMap((storyModule) =>
    Object.entries(storyModule)
      .filter((entry): entry is [string, CsfStory] => isCsfStory(entry[1]))
      .flatMap(([exportName, story]) => {
        const parent = {
          ...story.composed,
          id: resolveStoryId(exportName, story),
        };

        return [
          {id: parent.id, isOptedOut: hasA11yOptOut(parent, defaults)},
          ...getTestChildren(story)
            .map((child) => applyTestOverrides(parent, child))
            .map((child) => ({
              id: child.id,
              isOptedOut: hasA11yOptOut(child, defaults),
            })),
        ];
      })
  );
