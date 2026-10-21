import {useRouteLoaderData} from 'react-router';
import type {Theme} from '~/utils/theme.server';

export type RequestInfo = {
  origin: string;
  path: string;
  userPreferences: {theme?: Theme};
};

type RootLoaderShape = {requestInfo: RequestInfo};

export const useOptionalRequestInfo = (): RequestInfo | undefined => {
  const rootLoaderData = useRouteLoaderData<RootLoaderShape>('root');

  return rootLoaderData?.requestInfo;
};
