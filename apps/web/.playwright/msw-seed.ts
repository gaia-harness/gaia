import type {SeedFailure} from '../test/msw-seed/protocol';
import {MSW_SEED_PREFIX} from '../test/msw-seed/protocol';

const describeFailure = async (
  response: Response,
  collection: string
): Promise<Error> => {
  const failure = (await response.json().catch(() => ({}))) as SeedFailure;

  if (failure.issues !== undefined) {
    const details = failure.issues
      .map(({message, path}) => `${path}: ${message}`)
      .join('; ');

    return new Error(
      `Seed ${failure.collection}[${failure.index}] does not match the server schema: ${details}`
    );
  }

  return new Error(
    failure.error ??
      `Seeding ${collection} failed with ${response.status}; is the server a worker server started with MSW_SEED=true?`
  );
};

/**
 * Creates records in a collection of the worker server's MSW store, through
 * the collection's server schema, and returns them as created. A Given
 * builder calls it; a spec never does, so a project's own end-to-end run
 * changes its builders and its server, never its specs.
 */
export const seedRecords = async <Created>(
  baseURL: string,
  collection: string,
  records: readonly unknown[]
): Promise<Created[]> => {
  const response = await fetch(`${baseURL}${MSW_SEED_PREFIX}/seed`, {
    body: JSON.stringify({collection, records}),
    headers: {'content-type': 'application/json'},
    method: 'POST',
  });

  if (!response.ok) throw await describeFailure(response, collection);

  return (await response.json()) as Created[];
};
