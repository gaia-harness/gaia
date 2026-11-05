/* eslint-disable no-console -- the setup wraps console.error to fail a story that logs one */
import {afterEach, beforeEach, expect} from 'vitest';

// The checks the dark story project adds to each story's own play, tests and
// axe scan: no console or page error while it ran, the dark theme really
// applied, and (for a base story) something rendered, since an empty story
// scans as a clean page.

type StoryUnderTest = {
  id: string;
  parameters: {storyScan?: {rendersDocument?: boolean}};
  tags: string[];
};

// Toast stories render into a portal on the body, so they are held to a
// visible toast instead of canvas content.
const TOAST_STORY_IDS = new Set([
  'components-ui-toast--default',
  'components-ui-toast--with-action',
  'utils-notify--error-toast',
  'utils-notify--info',
  'utils-notify--success',
  'utils-notify--warning',
  'utils-notify--with-stack',
]);
// Stories whose subject renders nothing in this project: the language select
// hides itself in a single-language project.
const RENDERS_NOTHING_BY_DESIGN = new Set([
  'components-languageselect--default',
]);

// Development React warns when a story renders a whole Document, since the
// story nests it in a <div> on a live page: <html> inside a <div>, an inline
// script that never runs, and the route stub's empty asset hrefs. None of these
// reach the real app, where the Document is the page. A story that renders one
// sets `storyScan: {rendersDocument: true}` and only these warnings pass.
const NESTED_DOCUMENT_WARNINGS = [
  'Encountered a script tag while rendering React component.',
  'An empty string ("") was passed to the %s attribute.',
  'In HTML, %s cannot be a child of <%s>.',
];

const problems: string[] = [];
// The story runner sets `story` on the test context inside the test body,
// after beforeEach, so the context is kept and read when a warning arrives.
let currentContext: {story?: StoryUnderTest} = {};
const bodyChildrenBeforeStory = new Set<Element>();
const originalConsoleError = console.error;

const recordPageError = (event: ErrorEvent) => {
  problems.push(`pageerror: ${event.message}`);
};

const hasContent = (root: Element): boolean =>
  root.textContent.trim() !== '' ||
  root.querySelector(
    'svg, img, input, select, textarea, button, canvas, video, hr, [role]'
  ) !== null;

const isVisible = (element: Element): boolean =>
  element.checkVisibility({opacityProperty: true, visibilityProperty: true});

// The story's canvas is the first element its run appends to the body: the
// story runner creates it before anything renders, so it precedes any portal.
const findCanvas = (): Element | undefined =>
  [...document.body.children].find(
    (child) => !bodyChildrenBeforeStory.has(child)
  );

const expectStoryHasContent = ({id}: StoryUnderTest) => {
  if (TOAST_STORY_IDS.has(id)) {
    const toasts = [...document.querySelectorAll('[data-slot="toast"]')];

    expect(toasts.some(isVisible), `story ${id} shows a toast`).toBe(true);

    return;
  }

  if (RENDERS_NOTHING_BY_DESIGN.has(id)) return;

  const canvas = findCanvas();

  expect(
    canvas !== undefined && hasContent(canvas),
    `story ${id} rendered no content. If it renders nothing by design, add '${id}' to RENDERS_NOTHING_BY_DESIGN in test/setup.story-dark.ts`
  ).toBe(true);
};

beforeEach((context: {story?: StoryUnderTest}) => {
  currentContext = context;
  problems.length = 0;
  bodyChildrenBeforeStory.clear();

  for (const child of document.body.children) {
    bodyChildrenBeforeStory.add(child);
  }

  console.error = (...messages: unknown[]) => {
    const [format] = messages;
    const isNestedDocumentWarning =
      currentContext.story?.parameters.storyScan?.rendersDocument === true &&
      typeof format === 'string' &&
      NESTED_DOCUMENT_WARNINGS.some((warning) => format.startsWith(warning));

    if (!isNestedDocumentWarning)
      problems.push(`console error: ${messages.map(String).join(' ')}`);
    originalConsoleError(...messages);
  };
  window.addEventListener('error', recordPageError);
});

const expectStoryRanCleanInDark = (story: StoryUnderTest) => {
  expect(document.documentElement, 'dark class on <html>').toHaveClass('dark');
  expect(problems, 'errors while the story rendered').toEqual([]);

  // A `.test()` child may close or replace what its story rendered.
  if (!story.tags.includes('test-fn')) expectStoryHasContent(story);
};

afterEach(({story}: {story?: StoryUnderTest}) => {
  console.error = originalConsoleError;
  window.removeEventListener('error', recordPageError);

  if (story) expectStoryRanCleanInDark(story);
});
