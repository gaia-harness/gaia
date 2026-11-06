import {http, passthrough} from 'msw';
import {
  FORWARD_METHOD_HEADER,
  FORWARD_URL_HEADER,
  MSW_SEED_PREFIX,
  UNHANDLED_HEADER,
} from './protocol';

declare global {
  // eslint-disable-next-line @typescript-eslint/consistent-type-definitions, unicorn/prevent-abbreviations -- augments Vite's own `ImportMetaEnv`, which needs an interface of that name to merge
  interface ImportMetaEnv {
    /** Defined `true` by the seed plugin, so only on a seed-enabled dev server. */
    readonly GAIA_MSW_SEED?: boolean;
  }
}

/**
 * The browser's one handler on a seed-enabled dev server: every request not
 * addressed to the page's own origin goes to the dev server, which answers it
 * from the same handlers and store the server side uses, so a record a Given
 * builder seeded reaches client loaders and client fetches too. Same-origin
 * requests (Vite assets, `.data`, the forward call itself) fall through.
 */
const forwardToDevelopmentServer = http.all('*', async ({request}) => {
  if (new URL(request.url).origin === globalThis.location.origin) return;

  const headers = new Headers(request.headers);

  headers.set(FORWARD_METHOD_HEADER, request.method);
  headers.set(FORWARD_URL_HEADER, request.url);

  const answer = await fetch(`${MSW_SEED_PREFIX}/forward`, {
    body:
      request.method === 'GET' || request.method === 'HEAD' ?
        undefined
      : await request.arrayBuffer(),
    headers,
    method: 'POST',
  });

  if (answer.headers.get(UNHANDLED_HEADER) === 'true') return passthrough();

  return answer;
});

export default [forwardToDevelopmentServer];
