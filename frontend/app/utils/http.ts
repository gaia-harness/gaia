import {z} from 'zod';

export const toHeadersObject = (
  headers?: Headers | Record<string, string>
): Record<string, string> | undefined =>
  headers ?
    headers instanceof Headers ?
      Object.fromEntries(headers)
    : headers
  : undefined;

// A reserved .invalid host, so no real origin can equal it.
const LOCAL_ORIGIN = 'https://local.invalid';

/*
  The same-origin path a redirect target resolves to, or undefined when it
  leaves this origin. The target is resolved the way a browser resolves a
  Location header, so the consumer redirects to the returned path, never the
  raw input. A resolved path starting with "//" is rejected too, because a
  browser reads it as another host.
*/
export const resolveLocalRedirect = (
  url: null | string | undefined
): string | undefined => {
  if (!url?.startsWith('/')) return undefined;

  const resolved = new URL(url, LOCAL_ORIGIN);

  if (resolved.origin !== LOCAL_ORIGIN || resolved.pathname.startsWith('//')) {
    return undefined;
  }

  return resolved.pathname + resolved.search + resolved.hash;
};

/** A form field that parses to the resolved same-origin path, or fails. */
export const LocalRedirectSchema = z
  .string()
  .transform(resolveLocalRedirect)
  .pipe(z.string({error: 'Redirect must stay on this site'}));
