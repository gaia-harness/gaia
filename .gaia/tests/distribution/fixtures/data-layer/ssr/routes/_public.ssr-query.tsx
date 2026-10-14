import SsrQueryPage from '~/pages/ssr-query/page';
import {ssrQueryOptions} from '~/pages/ssr-query/query';
import {getQueryClient} from '~/query-client';

// The SSR check searches the HTML for these markers; they are not UI text.
const FALLBACK_TITLE = 'Query probe loading';
const FALLBACK_MARKER = 'hydrate-fallback-rendered';

// No server loader: React Router runs the clientLoader at hydration and
// server-renders HydrateFallback in place of the page.
export const clientLoader = async () => {
  await getQueryClient().query(ssrQueryOptions());
};

export const HydrateFallback = () => (
  <>
    <title>{FALLBACK_TITLE}</title>
    <p>{FALLBACK_MARKER}</p>
  </>
);

const SsrQueryRoute = () => <SsrQueryPage />;

export default SsrQueryRoute;
