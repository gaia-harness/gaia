// Shared by the dev server's seed plugin, the browser forward handler and the
// Playwright seed helper, so the three agree on the wire format.

/** The reserved path prefix the seed surface answers under. */
export const MSW_SEED_PREFIX = '/__gaia/msw';

/** The original method and URL of a request sent to the forward endpoint. */
export const FORWARD_METHOD_HEADER = 'x-gaia-msw-method';

export const FORWARD_URL_HEADER = 'x-gaia-msw-url';

/** The seed endpoint's error body: an unknown collection, or a bad record. */
export type SeedFailure = {
  collection?: string;
  error?: string;
  index?: number;
  issues?: SeedIssue[];
};

export type SeedIssue = {message: string; path: string};

/** Set on the forward endpoint's 204 when no handler matched the request. */
export const UNHANDLED_HEADER = 'x-gaia-msw-unhandled';
