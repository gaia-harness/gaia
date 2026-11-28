// Mirrors ky's prefix-join normalization (see ky/distribution/core/Ky.js:285).
// Without this, MSW handler URLs built via raw template literal break whenever
// API_URL is supplied without a trailing slash (handler pattern becomes
// `<URL>things` while ky requests `<URL>/things`; no match → passthrough).
import {DEFAULT_API_URL} from '../default-api-url';

export const url = (path: string): string => {
  // Handlers are built while test/setup.ts's imports load, before its body sets
  // API_URL, so Node falls back to the same default. A browser with no injected
  // env stays origin-relative, as getBaseUrl does.
  const fallback = typeof window === 'undefined' ? DEFAULT_API_URL : '';
  // eslint-disable-next-line sonarjs/super-linear-regex -- the pattern is anchored to the end of a short env value
  const prefix = (process.env.API_URL ?? fallback).replace(/\/+$/, '');
  const input = path.replace(/^\/+/, '');

  return `${prefix}/${input}`;
};
