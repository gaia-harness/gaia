import {useSuspenseQuery} from '@tanstack/react-query';
import {ssrQueryOptions} from './query';

// The SSR check searches the HTML for this marker; it is not UI text.
const DATA_MARKER = 'query-data-rendered';

const SsrQueryPage = () => {
  const {data} = useSuspenseQuery(ssrQueryOptions());

  return <p>
      {DATA_MARKER} {data.label}
    </p>;
};

export default SsrQueryPage;
