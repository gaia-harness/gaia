import {ACTION_PATHS} from '../../app/action-paths';
import common from '../../app/languages/en/common';
import {expect, test} from '../fixtures';
import {parseHtml} from '../html';

type PageHeading = {
  heading: string;
  path: string;
};

// Each check asserts the heading the page component itself owns, so a route that
// imports the wrong page fails here even when the status is still 200.
const PAGES: readonly PageHeading[] = [
  {heading: common.meta.siteName, path: '/'},
];

for (const {heading, path} of PAGES) {
  test(`${path} responds 200 and renders its own page`, async ({request}) => {
    const response = await request.get(path);
    expect(response.status()).toBe(200);
    const root = parseHtml(await response.text());
    expect(root.querySelector('h1')?.text.trim()).toBe(heading);
  });
}

test('set-language action redirects and sets the language cookie', async ({
  request,
}) => {
  const response = await request.post(ACTION_PATHS.setLanguage, {
    form: {language: 'en', redirectUrl: '/'},
    maxRedirects: 0,
  });
  expect(response.status()).toBe(302);
  expect(response.headers().location).toBe('/');
  expect(response.headers()['set-cookie']).toMatch(/^lng=/);
});

test('set-language action refuses a redirect target on another host', async ({
  request,
}) => {
  const response = await request.post(ACTION_PATHS.setLanguage, {
    form: {language: 'en', redirectUrl: '//example.com'},
    maxRedirects: 0,
  });
  expect(response.status()).toBe(400);
  expect(response.headers().location).toBeUndefined();
});
