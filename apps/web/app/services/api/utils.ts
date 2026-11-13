import type {BeforeRequestState, Hooks, Options} from 'ky';
import type {StringifyOptions} from 'query-string';
import queryString from 'query-string';
import {tryCatch} from '~/utils/function';
import {toCamelCase, toSnakeCase} from '~/utils/object';

const requestToSnakeCase = async ({options, request}: BeforeRequestState) => {
  if (options.body && !(options.body instanceof FormData)) {
    const [error, parsed] = tryCatch(
      () => JSON.parse(options.body as string) as unknown
    );

    // A non-JSON body (plain string, URLSearchParams, etc.) is forwarded
    // unchanged rather than failing the request.
    if (error) {
      return;
    }

    const body = JSON.stringify(toSnakeCase(parsed));

    // eslint-disable-next-line unicorn/no-invalid-fetch-options -- only reached when the request already carries a body
    return new Request(request, {body});
  }
};

type ParseJson = NonNullable<Options['parseJson']>;

/**
 * Wraps a layer's JSON parsing in the camelCase conversion when snake_case is
 * enabled.
 */
// Converting in parseJson, not an afterResponse hook, keeps the body read
// inside Ky's own body-read race, which applies `timeout`: Ky bounds an
// afterResponse hook only by `totalTimeout` and a caller's `signal`, so a
// hook's read of a stalled body would ignore `timeout`. Only the default
// JSON.parse path is lenient: a body that fails to parse resolves to null on a
// 2xx, so the schema validates null instead of the parse error escaping; on an
// error status the rethrow leaves Ky's HTTPError without data. An empty body
// resolves to undefined, as Ky does when it has no parseJson. A caller's
// parseJson keeps its own errors.
export const getParseJson = (
  isSnakeCaseEnabled?: boolean,
  parseJson?: ParseJson
): ParseJson | undefined =>
  isSnakeCaseEnabled ?
    async (text, context) => {
      if (parseJson) return toCamelCase(await parseJson(text, context));

      if (text === '') return undefined;

      const [error, parsed] = tryCatch(() => JSON.parse(text) as unknown);

      if (error) {
        if (context.response.ok) return null;

        throw error;
      }

      return toCamelCase(parsed);
    }
  : parseJson;

export const getHooks = (
  isSnakeCaseEnabled?: boolean,
  hooks?: Hooks
): Hooks | undefined =>
  isSnakeCaseEnabled ?
    {
      ...hooks,
      beforeRequest: [requestToSnakeCase, ...(hooks?.beforeRequest ?? [])],
    }
  : hooks;

/** A request's search params and how appendSearchParams serializes them. */
export type SearchParamsOptions = {
  arrayFormat?: NonNullable<StringifyOptions['arrayFormat']>;
  /**
   * Sends search params as snake_case. On create(), also converts outgoing
   * JSON bodies to snake_case and incoming response keys to camelCase.
   */
  isSnakeCaseEnabled?: boolean;
  searchParams?: Record<string, unknown>;
};

/** SearchParamsOptions plus the values getUri substitutes into `:name` placeholders. */
export type UriOptions = SearchParamsOptions & {
  pathParams?: Record<string, number | string>;
};

export const appendSearchParams = (
  uri: string,
  options?: SearchParamsOptions
): string => {
  const {
    arrayFormat = 'comma',
    isSnakeCaseEnabled = false,
    searchParams,
  } = options ?? {};

  if (!searchParams) {
    return uri;
  }

  const casedParams =
    isSnakeCaseEnabled ?
      (toSnakeCase(searchParams) as Record<string, unknown>)
    : searchParams;

  const safeParams = queryString.stringify(casedParams, {arrayFormat});
  const searchSeparator = uri.includes('?') ? '&' : '?';
  const search = safeParams ? `${searchSeparator}${safeParams}` : '';

  return `${uri}${search}`;
};

// Each rejected value sends the request to a different path: URL parsing
// resolves `.` and `..` segments, percent-encoded or not, and an empty
// segment collapses `items/:id` into the collection path `items/`.
const encodePathParam = (value: number | string): string => {
  const segment = String(value);

  if (segment === '') {
    throw new TypeError('Path param cannot be empty');
  }

  if (segment === '.' || segment === '..') {
    throw new TypeError(`Path param cannot be a dot segment: "${segment}"`);
  }

  return encodeURIComponent(segment);
};

// One pass over the placeholders, so a key that prefixes another (`:user`
// and `:userId`) cannot rewrite part of the longer one.
export const setPathParams = (
  url: string,
  pathParams?: Record<string, number | string>
): string =>
  pathParams ?
    url.replaceAll(/:(\w+)/g, (placeholder, key: string) =>
      Object.hasOwn(pathParams, key) ?
        encodePathParam(pathParams[key])
      : placeholder
    )
  : url;

export const getUri = (
  uri: string,
  {pathParams, ...options}: UriOptions = {}
): string => appendSearchParams(setPathParams(uri, pathParams), options);

export const getBaseUrl = (): string => {
  // server api call; API_URL is validated at startup in env.server
  if (typeof window === 'undefined') return process.env.API_URL ?? '';

  // client api call; window.process is injected by the root loader and absent
  // in some browser contexts, though the global Window type declares it
  const injectedProcess = (window as Partial<Pick<Window, 'process'>>).process;

  return injectedProcess?.env.API_URL ?? '';
};

// Merges per-request auth/language onto caller-supplied headers; never stored module-side to prevent SSR token cross-contamination.
export const buildRequestHeaders = (
  headers: Options['headers'],
  token?: string,
  language?: string
): Headers => {
  const merged = new Headers(headers as HeadersInit | undefined);

  if (token) {
    merged.set('Authorization', `Bearer ${token}`);
  }

  if (language) {
    merged.set('Accept-Language', language);
  }

  return merged;
};
