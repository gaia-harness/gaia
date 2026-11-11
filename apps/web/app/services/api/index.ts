import ky from 'ky';
import type {Options, StandardSchemaV1, StandardSchemaV1InferOutput} from 'ky';
import {buildRequestHeaders, getBaseUrl, getHooks, getUri} from './utils';
import type {SearchParamsOptions, UriOptions} from './utils';

export type RequestFunction = {
  <S extends StandardSchemaV1>(
    uri: string,
    options: RequestOptions & {schema: S}
  ): Promise<StandardSchemaV1InferOutput<S>>;
  (uri: string, options?: RequestOptions & {schema?: undefined}): Promise<void>;
};

// A Pick, not Omit<SearchParamsOptions, 'searchParams'>: a new key would
// otherwise type-check here yet land in ky.create's options and never reach
// getUri.
type CreateOptions = Omit<Options, 'prefix'> &
  Pick<SearchParamsOptions, 'arrayFormat' | 'isSnakeCaseEnabled'> & {
    /** Base URL; resolved per request from getBaseUrl() when omitted. */
    prefix?: string;
  };

type RequestOptions = Options &
  Pick<UriOptions, 'pathParams' | 'searchParams'> & {
    language?: string;
    token?: string;
  };

// arrayFormat and isSnakeCaseEnabled take their defaults in appendSearchParams.
export const create = ({
  arrayFormat,
  hooks,
  isSnakeCaseEnabled,
  prefix,
  ...apiOptions
}: CreateOptions = {}): RequestFunction => {
  const kyInstance = ky.create({
    hooks: getHooks(isSnakeCaseEnabled, hooks),
    ...apiOptions,
  });

  const request = async (
    uri: string,
    {
      language,
      pathParams,
      schema,
      searchParams,
      token,
      ...options
    }: RequestOptions & {schema?: StandardSchemaV1} = {}
  ): Promise<unknown> => {
    const response = kyInstance(
      getUri(uri, {arrayFormat, isSnakeCaseEnabled, pathParams, searchParams}),
      {
        ...options,
        headers: buildRequestHeaders(options.headers, token, language),
        // Resolved per request: the base URL is unknown at module import.
        prefix: options.prefix ?? prefix ?? (getBaseUrl() || '/'),
      }
    );

    if (schema) {
      return response.json(schema);
    }

    // Read the body even though it is discarded: on Node, an unread body keeps
    // its connection out of the keep-alive pool until garbage collection.
    await response.arrayBuffer();
  };

  return request as RequestFunction;
};
