import {RouterContextProvider} from 'react-router';
import {describe, expect, test} from 'vitest';
import {action} from '~/routes/resources.theme-switch';

const runAction = async (fields: {redirectTo: string; theme?: string}) => {
  const url = new URL('http://localhost/resources/theme-switch');
  const request = new Request(url, {
    body: new URLSearchParams(fields),
    method: 'POST',
  });

  return action({
    context: new RouterContextProvider(),
    params: {},
    pattern: '/resources/theme-switch',
    request,
    url,
  });
};

describe('theme-switch action', () => {
  test.each([
    {cookie: /^__theme=dark;/, theme: 'dark'},
    {cookie: /^__theme=light;/, theme: 'light'},
    // `system` expires the cookie so the OS color scheme decides again
    {cookie: /^__theme=;.*Max-Age=-1/i, theme: 'system'},
  ])(
    'a $theme submission sets the theme cookie and redirects to the local target',
    async ({cookie, theme}) => {
      const response = (await runAction({
        redirectTo: '/about?x=1',
        theme,
      })) as Response;

      expect(response.status).toBe(302);
      expect(response.headers.get('location')).toBe('/about?x=1');
      expect(response.headers.get('set-cookie')).toMatch(cookie);
    }
  );

  test.each([
    {
      fields: {redirectTo: '//example.com', theme: 'dark'},
      label: 'an off-site redirectTo',
    },
    {fields: {redirectTo: '/', theme: 'sepia'}, label: 'an unknown theme'},
    {fields: {redirectTo: '/'}, label: 'a missing theme'},
  ])('$label is refused with a 400 and no cookie', async ({fields}) => {
    const response = (await runAction(fields)) as {
      data: {result: string};
      init: ResponseInit;
    };

    expect(response.init.status).toBe(400);
    expect(response.data.result).toBe('error');
    expect(new Headers(response.init.headers).get('set-cookie')).toBeNull();
  });
});
