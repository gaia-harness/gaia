import ky from 'ky';
import type {Options, StandardSchemaV1, StandardSchemaV1InferOutput} from 'ky';
import {
  buildRequestHeaders,
  getBaseUrl,
  getHooks,
  getParseJson,
  getUri,
} from './utils';
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
// getUri. A key added to this Pick must also be destructured in create(), and
// keep ky's own searchParams out: they would reach every request without
// snake_case conversion.
type CreateOptions = Omit<Options, 'prefix' | 'searchParams'> &
  Pick<SearchParamsOptions, 'arrayFormat' | 'isSnakeCaseEnabled'> & {
    /** Base URL; resolved per request from getBaseUrl() when omitted. */
    prefix?: string;
  };

type RequestOptions = Omit<Options, 'searchParams'> &
  Pick<UriOptions, 'pathParams' | 'searchParams'> & {
    language?: string;
    token?: string;
  };

// arrayFormat takes its default in appendSearchParams; an omitted
// isSnakeCaseEnabled is off for search params, the request hook and the
// response parser.
export const create = ({
  arrayFormat,
  hooks,
  isSnakeCaseEnabled,
  prefix,
  ...apiOptions
}: CreateOptions = {}): RequestFunction => {
  const layerParseJson = getParseJson(isSnakeCaseEnabled, apiOptions.parseJson);
  const kyInstance = ky.create({
    hooks: getHooks(isSnakeCaseEnabled, hooks),
    ...apiOptions,
    parseJson: layerParseJson,
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
        // A request's own parseJson is wrapped too, rather than replacing the
        // layer's conversion.
        parseJson:
          options.parseJson ?
            getParseJson(isSnakeCaseEnabled, options.parseJson)
          : layerParseJson,
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
