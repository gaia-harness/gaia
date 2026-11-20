import {describe, expect, test} from 'vitest';
import {resolveStoryA11yOptOuts} from './story-a11y-opt-outs';

// The shapes below mirror what the installed Storybook gives a CSF4 story:
// `defineStory` in `node_modules/storybook/dist/csf/index.js` returns an object
// with `_tag: 'Story'`, the story's own `input`, a `composed` getter, and a
// `__children` array that `.test()` pushes one extended story onto, whose
// `input` carries the test's `name`, `tags`, `parameters` and `globals`. A
// test's id is `toTestId(parentId, name)`. A story imported as a plain module is
// composed without its export name (`composed.id` ends `--unnamed-story`), so
// the fake copies that and the walker must name each story from its export key
// and its meta title instead.
const defaults = {config: {rules: []}, options: {runOnly: {type: 'tag'}}};

type FakeChild = {name: string; parameters?: object; tags?: string[]};

const createStory = (title: string, children: FakeChild[] = []) => ({
  __children: children.map((child) => ({
    _tag: 'Story',
    input: {
      globals: {},
      name: child.name,
      parameters: child.parameters ?? {},
      tags: ['test-fn', '!autodocs', ...(child.tags ?? [])],
    },
  })),
  _tag: 'Story',
  composed: {
    globals: {},
    id: 'a--unnamed-story',
    parameters: {a11y: {...defaults, test: 'error'}},
    tags: ['test', 'autodocs'],
  },
  meta: {input: {title}},
});

const walk = (children: FakeChild[]) =>
  resolveStoryA11yOptOuts(
    {'a.stories.tsx': {Default: createStory('A', children)}},
    defaults
  );

describe('resolveStoryA11yOptOuts names stories by export key and flags a lost test tag', () => {
  test.each([
    [
      'reports a test child that loses the test tag',
      () => walk([{name: 'untagged', tags: ['!test']}])[1],
      {id: 'a--default:untagged', isOptedOut: true},
    ],
    [
      'names a story from its export key, not from its own name',
      () =>
        resolveStoryA11yOptOuts(
          {
            'a.stories.tsx': {
              WithLongName: {
                ...createStory('Group/Thing', [{name: 'safe'}]),
                input: {name: 'Renamed'},
              },
            },
          },
          defaults
        ).map(({id}) => id),
      ['group-thing--with-long-name', 'group-thing--with-long-name:safe'],
    ],
  ])('%s', (_name, resolve, expected) => {
    expect(resolve()).toEqual(expected);
  });
});
