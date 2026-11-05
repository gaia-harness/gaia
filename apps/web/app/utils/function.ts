// Based on proposed Safe Assignment Operator ?=
// https://github.com/arthurfiorette/proposal-try-operator/tree/old/proposal-safe-assignment-operator
type TryCatchError = [error: Error, returnValue: undefined];
type TryCatchResult<T> =
  T extends Promise<unknown> ?
    Promise<TryCatchError | TryCatchSuccess<Awaited<T>>>
  : TryCatchError | TryCatchSuccess<T>;
type TryCatchSuccess<T> = [error: undefined, returnValue: Awaited<T>];

export const tryCatch = <T, A extends readonly unknown[]>(
  operation: (...args: A) => T,
  ...args: A
): TryCatchResult<T> => {
  let returnValue;

  try {
    returnValue = operation(...args);
  } catch (caughtError) {
    return [caughtError as Error, undefined] as TryCatchResult<T>;
  }

  if (returnValue instanceof Promise) {
    return returnValue
      .then((resolvedValue: T) => [undefined, resolvedValue])
      .catch((caughtError: Error) => [
        caughtError,
        undefined,
      ]) as TryCatchResult<T>;
  }

  return [undefined, returnValue] as TryCatchResult<T>;
};
