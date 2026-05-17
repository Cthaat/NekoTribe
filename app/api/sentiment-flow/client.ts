import {
  apiFetch,
  type ApiFetchBody
} from '@/composables/useApi';
import type {
  SentimentFlowApiResponse,
  SentimentFlowPrimitive
} from '@/types/sentiment-flow';

export const SENTIMENT_FLOW_PROXY_BASE =
  '/api/v2/integrations/sentiment-flow';

export type SentimentFlowQueryValue =
  | SentimentFlowPrimitive
  | undefined
  | ReadonlyArray<SentimentFlowPrimitive>;
export type SentimentFlowQueryParams = Record<
  string,
  SentimentFlowQueryValue
>;
export type SentimentFlowRequestBody = ApiFetchBody;

export interface SentimentFlowRequestOptions<
  TBody extends SentimentFlowRequestBody = undefined,
  TQuery extends SentimentFlowQueryParams = Record<never, never>
> {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: TBody;
  query?: TQuery;
  headers?: Record<string, string>;
}

function proxyPath(path: string): string {
  const normalizedPath = path.startsWith('/')
    ? path
    : `/${path}`;
  return `${SENTIMENT_FLOW_PROXY_BASE}${normalizedPath}`;
}

export async function sentimentFlowRequest<
  TData,
  TBody extends SentimentFlowRequestBody = undefined,
  TQuery extends SentimentFlowQueryParams = Record<never, never>
>(
  path: string,
  options: SentimentFlowRequestOptions<TBody, TQuery> = {}
): Promise<SentimentFlowApiResponse<TData> | TData> {
  return await apiFetch<SentimentFlowApiResponse<TData> | TData>(
    proxyPath(path),
    {
      method: options.method,
      body: options.body,
      query: options.query,
      headers: options.headers
    }
  );
}

export async function sentimentFlowRequestData<
  TData,
  TBody extends SentimentFlowRequestBody = undefined,
  TQuery extends SentimentFlowQueryParams = Record<never, never>
>(
  path: string,
  options: SentimentFlowRequestOptions<TBody, TQuery> = {}
): Promise<TData> {
  const response = await sentimentFlowRequest<
    TData,
    TBody,
    TQuery
  >(path, options);
  if (
    response &&
    typeof response === 'object' &&
    'data' in response
  ) {
    return (response as SentimentFlowApiResponse<TData>).data;
  }
  return response as TData;
}
