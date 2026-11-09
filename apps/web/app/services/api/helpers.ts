import {
  HTTPError,
  isNetworkError,
  isTimeoutError,
  SchemaValidationError,
} from 'ky';
import {ZodError} from 'zod';
import {tryCatch} from '~/utils/function';

type ApiError = {
  /** No full answer arrived, so whether the API acted on it is unknown. */
  isNetworkFailure?: true;
  status: number;
  statusText: string;
};

// Callers pass status to `new Response`, which throws a RangeError on 0, so a
// network failure carries a real status. The text is constant because
// statusText reaches the client and Ky's own message contains the request URL.
const NETWORK_FAILURE: ApiError = {
  isNetworkFailure: true,
  status: 503,
  statusText: 'Network error',
};

const TIMEOUT_FAILURE: ApiError = {
  isNetworkFailure: true,
  status: 504,
  statusText: 'Request timed out',
};

const isHTTPError = (error: unknown): error is HTTPError =>
  error instanceof HTTPError;

const handleHTTPError = (error: HTTPError): ApiError => ({
  status: error.response.status,
  statusText: error.response.statusText,
});

const isSchemaValidationError = (
  error: unknown
): error is SchemaValidationError => error instanceof SchemaValidationError;

// The issues can echo response data, so they are logged on the server only
// and never placed in statusText, which reaches the client.
const handleSchemaValidationError = (
  error: SchemaValidationError
): ApiError => {
  if (typeof window === 'undefined') {
    // eslint-disable-next-line no-console -- schema issues are logged on the server only
    console.error('Response failed schema validation', error.issues);
  }

  return {status: 500, statusText: 'Response failed schema validation'};
};

const isZodError = (error: unknown): error is ZodError =>
  error instanceof ZodError;

const handleZodError = (error: ZodError): ApiError => ({
  status: 500,
  statusText: error.message,
});

const handleResponseError = (error: unknown): ApiError => {
  if (isHTTPError(error)) {
    return handleHTTPError(error);
  }

  if (isSchemaValidationError(error)) {
    return handleSchemaValidationError(error);
  }

  if (isZodError(error)) {
    return handleZodError(error);
  }

  if (isNetworkError(error)) {
    return NETWORK_FAILURE;
  }

  if (isTimeoutError(error)) {
    return TIMEOUT_FAILURE;
  }

  // A cancellation or a programming error is no API failure, so it propagates.
  if (error instanceof Error) {
    throw error;
  }

  return {status: 500, statusText: 'Unknown error'};
};

type AttemptError = [error: ApiError, result: undefined];
type AttemptResult<T> = AttemptError | AttemptSuccess<T>;
type AttemptSuccess<T> = [error: undefined, result: T];

export const attempt = async <T>(
  operation: () => Promise<T>
): Promise<AttemptResult<T>> => {
  const [error, result] = await tryCatch(operation);

  if (error !== undefined) {
    return [handleResponseError(error), undefined];
  }

  return [undefined, result];
};
