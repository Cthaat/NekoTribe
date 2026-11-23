import {
  apiFetch,
  type ApiFetchBody
} from '@/composables/useApi';
import type {
  V2ApiResponse,
  V2ApiMeta,
  V2PagedResult,
  V2Primitive
} from '@/types/v2';
import { readAiStream, type GenerationDelta } from './ai-stream';

export type V2QueryValue =
  | V2Primitive
  | undefined
  | ReadonlyArray<V2Primitive>;

export type V2QueryParams = Record<string, V2QueryValue>;
export type V2RequestBody = ApiFetchBody;

export interface V2RequestOptions<
  TBody extends V2RequestBody = undefined,
  TQuery extends V2QueryParams = Record<never, never>
> {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: TBody;
  query?: TQuery;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  redirect?: RequestRedirect;
  onDelta?: GenerationDelta;
}

export async function v2Request<
  TData,
  TBody extends V2RequestBody = undefined,
  TQuery extends V2QueryParams = Record<never, never>
>(
  path: string,
  options: V2RequestOptions<TBody, TQuery> = {}
): Promise<V2ApiResponse<TData>> {
  return await apiFetch<V2ApiResponse<TData>>(path, {
    method: options.method,
    body: options.body,
    query: options.query,
    headers: options.headers,
    signal: options.signal,
    redirect: options.redirect
  });
}

export async function v2RequestData<
  TData,
  TBody extends V2RequestBody = undefined,
  TQuery extends V2QueryParams = Record<never, never>
>(
  path: string,
  options: V2RequestOptions<TBody, TQuery> = {}
): Promise<TData> {
  if (options.onDelta) {
    const stream = await apiFetch<ReadableStream<Uint8Array>, 'stream'>(path, {
      method: options.method, body: options.body, query: options.query,
      signal: options.signal, headers: { ...options.headers, Accept: 'text/event-stream' },
      responseType: 'stream', cache: 'no-store', redirect: 'error'
    });
    return readAiStream<TData>(stream, options.onDelta);
  }
  const response = await v2Request<TData, TBody, TQuery>(
    path,
    options
  );
  return response.data;
}

export function toV2PagedResult<T>(
  response: V2ApiResponse<T[]>
): V2PagedResult<T> {
  return {
    items: response.data,
    meta: response.meta
  };
}

export function v2SummaryMeta(
  meta: V2ApiMeta | null
): V2ApiMeta {
  return meta ?? {};
}

