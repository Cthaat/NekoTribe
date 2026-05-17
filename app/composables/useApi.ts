import { getCurrentInstance } from 'vue';
import type { FetchError } from 'ofetch';

export type ApiFetchOptions = NonNullable<
  Parameters<typeof $fetch>[1]
>;
export type ApiFetchBody =
  ApiFetchOptions extends { body?: infer TBody }
    ? TBody | undefined
    : never;
type ApiFetchHeaders =
  ApiFetchOptions extends { headers?: infer THeaders }
    ? THeaders
    : HeadersInit;

interface ComponentDescriptor {
  name?: string;
  __name?: string;
}

interface SerializedApiError {
  name?: string;
  message: string;
  statusCode?: number;
  statusMessage?: string;
  data?: unknown;
  stack?: string;
}

type NuxtAppContext = ReturnType<typeof tryUseNuxtApp>;

function toSerializable(value: unknown): unknown {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }

  if (Array.isArray(value)) {
    return value.map(toSerializable);
  }

  if (typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(
        ([key, item]) => [key, toSerializable(item)]
      )
    );
  }

  return String(value);
}

function serializeApiError(error: unknown): SerializedApiError {
  const candidate = error as {
    name?: string;
    message?: string;
    statusCode?: number;
    statusMessage?: string;
    data?: unknown;
    response?: {
      status?: number;
      statusText?: string;
      _data?: unknown;
    };
    stack?: string;
  };

  return {
    name: candidate.name,
    message: candidate.message ?? String(error),
    statusCode:
      candidate.statusCode ?? candidate.response?.status,
    statusMessage:
      candidate.statusMessage ??
      candidate.response?.statusText,
    data: toSerializable(
      candidate.data ?? candidate.response?._data
    ),
    stack: candidate.stack
  };
}

function createClientRequestId(): string {
  if (
    typeof crypto !== 'undefined' &&
    typeof crypto.randomUUID === 'function'
  ) {
    return crypto.randomUUID();
  }

  return `client_${Date.now()}_${Math.random()
    .toString(16)
    .slice(2)}`;
}

function queryPayload(
  options: ApiFetchOptions
): unknown {
  const candidate = options as { query?: unknown };
  return sanitizeLogPayload(candidate.query);
}

function isSensitiveLogKey(key: string): boolean {
  const normalized = key.trim().toLowerCase();
  return (
    normalized === 'token' ||
    normalized === 'access_token' ||
    normalized === 'refresh_token' ||
    normalized === 'authorization' ||
    normalized === 'password' ||
    normalized === 'new_password' ||
    normalized === 'confirm_password' ||
    normalized.endsWith('_token') ||
    normalized.endsWith('_secret') ||
    normalized.includes('password')
  );
}

function sanitizeLogPayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeLogPayload);
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(
        ([key, item]) => [
          key,
          isSensitiveLogKey(key)
            ? '[redacted]'
            : sanitizeLogPayload(item)
        ]
      )
    );
  }

  return toSerializable(value);
}

function logApiRequest(
  payload: Record<string, unknown>
): void {
  console.info('[api:request]', payload);
}

function logApiResponse(
  payload: Record<string, unknown>
): void {
  console.info('[api:response]', payload);
}

function logApiError(
  payload: Record<string, unknown>
): void {
  console.error('[api:error]', payload);
}

function getApiBase(nuxtApp: NuxtAppContext): string {
  if (nuxtApp) {
    return String(nuxtApp.$config.public.apiBase ?? '');
  }

  try {
    return String(useRuntimeConfig().public.apiBase ?? '');
  } catch {
    return '';
  }
}

async function runWithNuxtContext<T>(
  nuxtApp: NuxtAppContext,
  callback: () => Promise<T>
): Promise<T> {
  if (nuxtApp) {
    return await nuxtApp.runWithContext(callback);
  }

  const currentNuxtApp = tryUseNuxtApp();
  if (currentNuxtApp) {
    return await currentNuxtApp.runWithContext(callback);
  }

  return await callback();
}

function getComponentName(): string | undefined {
  const inst = getCurrentInstance();
  const component = inst?.type as
    | ComponentDescriptor
    | undefined;
  return component?.name || component?.__name;
}

function buildStackSource(): string {
  try {
    throw new Error('trace');
  } catch (error) {
    const stack =
      error instanceof Error ? error.stack || '' : '';
    const line = stack
      .split('\n')
      .find(
        item =>
          /https?:\/\//.test(item) &&
          !/node_modules|nuxt\//i.test(item)
      );
    return line ? line.trim() : '';
  }
}

function headersToRecord(
  headers: ApiFetchHeaders | undefined
): Record<string, string> {
  if (!headers) {
    return {};
  }

  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }

  if (Array.isArray(headers)) {
    return Object.fromEntries(
      headers.map(([key, value]) => [key, String(value)])
    );
  }

  return Object.fromEntries(
    Object.entries(headers).map(([key, value]) => [
      key,
      String(value)
    ])
  );
}

function getForwardedRequestHeaders(
  isServer: boolean
): Record<string, string> {
  if (!isServer) {
    return {};
  }

  try {
    return useRequestHeaders([
      'cookie',
      'authorization'
    ]) as Record<string, string>;
  } catch {
    return {};
  }
}

function toSafeHeaderValue(value: string): string {
  try {
    if (/[^\x00-\xFF]/.test(value)) {
      return 'utf8:' + encodeURIComponent(value);
    }
    return value;
  } catch {
    return 'encoded-error';
  }
}

function sanitizeUrlLikeForHeader(value: string): string {
  return value.replace(
    /([?&](?:access_token|refresh_token|token|password|new_password|confirm_password|authorization|secret|client_secret|code)=)[^&#\s]*/gi,
    '$1[redacted]'
  );
}

function isRefreshPath(path: string): boolean {
  return (
    path.includes('/auth/refresh') ||
    path.includes('/auth/tokens/current')
  );
}

export const apiFetch = async <T>(
  path: string,
  options: ApiFetchOptions = {}
): Promise<T> => {
  const nuxtApp = tryUseNuxtApp();
  const isServer = typeof window === 'undefined';
  const requestId = createClientRequestId();
  const startAt = Date.now();
  const route = (() => {
    try {
      return useRoute();
    } catch {
      return undefined;
    }
  })();

  const traceHeaders: Record<string, string> = {};
  if (route?.fullPath) {
    traceHeaders['x-client-route'] = toSafeHeaderValue(
      sanitizeUrlLikeForHeader(String(route.fullPath))
    );
  }
  const componentName = getComponentName();
  if (componentName) {
    traceHeaders['x-client-component'] = toSafeHeaderValue(
      componentName
    );
  }
  const stackSource = buildStackSource();
  if (stackSource) {
    traceHeaders['x-client-source'] = toSafeHeaderValue(
      sanitizeUrlLikeForHeader(stackSource)
    );
  }
  if (!isServer && typeof location !== 'undefined') {
    traceHeaders['x-client-referer'] = toSafeHeaderValue(
      sanitizeUrlLikeForHeader(String(location.href))
    );
  }
  traceHeaders['x-client-platform'] = isServer
    ? 'server'
    : 'client';
  traceHeaders['x-request-id'] = requestId;

  const mergedOptions: ApiFetchOptions = {
    baseURL: getApiBase(nuxtApp),
    credentials: 'include',
    ...options,
    headers: {
      ...getForwardedRequestHeaders(isServer),
      ...traceHeaders,
      ...headersToRecord(options.headers)
    }
  };

  const requestLogPayload = {
    requestId,
    method: String(options.method ?? 'GET'),
    path,
    query: queryPayload(options),
    route: route?.fullPath ?? null,
    component: componentName ?? null,
    platform: isServer ? 'server' : 'client'
  };

  logApiRequest(requestLogPayload);

  try {
    const response = await $fetch<T>(path, mergedOptions);
    logApiResponse({
      ...requestLogPayload,
      durationMs: Date.now() - startAt,
      retried: false
    });
    return response;
  } catch (error) {
    const maybeError = error as FetchError;
    if (
      (maybeError.response?.status === 401 ||
        maybeError.statusCode === 401) &&
      !isRefreshPath(path)
    ) {
      try {
        await runWithNuxtContext(
          nuxtApp,
          async (): Promise<void> => {
            const { usePreferenceStore } = await import(
              '~/stores/user'
            );
            const preferenceStore = usePreferenceStore();
            await preferenceStore.refreshAccessToken();
          }
        );
        await new Promise(resolve =>
          setTimeout(resolve, 100)
        );
        const response = await $fetch<T>(path, mergedOptions);
        logApiResponse({
          ...requestLogPayload,
          durationMs: Date.now() - startAt,
          retried: true
        });
        return response;
      } catch (retryError) {
        logApiError({
          ...requestLogPayload,
          durationMs: Date.now() - startAt,
          phase: 'refresh-retry',
          error: serializeApiError(retryError)
        });
        throw retryError;
      }
    }

    logApiError({
      ...requestLogPayload,
      durationMs: Date.now() - startAt,
      phase: 'request',
      error: serializeApiError(error)
    });
    throw error;
  }
};
