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

interface ApiErrorResponse {
  status?: number;
  statusText?: string;
  _data?: unknown;
}

interface ApiErrorCarrier {
  name?: string;
  message?: string;
  stack?: string;
  statusCode?: number;
  statusMessage?: string;
  data?: unknown;
  response?: ApiErrorResponse;
  cause?: unknown;
  originalMessage?: string;
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
  const candidate = error as ApiErrorCarrier;

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

type CommonErrorKey =
  | 'operationFailed'
  | 'unknownError'
  | 'networkError';

const commonErrorFallbacks: Record<CommonErrorKey, string> = {
  operationFailed: 'Operation failed',
  unknownError: 'Unknown error',
  networkError: 'Network error'
};

function translateCommonError(key: CommonErrorKey): string {
  const fallback = commonErrorFallbacks[key];
  try {
    const nuxtApp = tryUseNuxtApp();
    const i18n = nuxtApp?.$i18n as
      | { t?: (messageKey: string) => unknown }
      | undefined;
    if (typeof i18n?.t !== 'function') {
      return fallback;
    }
    const translated = i18n.t(`common.${key}`);
    if (
      typeof translated === 'string' &&
      translated.trim().length > 0
    ) {
      return translated;
    }
  } catch {
    return fallback;
  }
  return fallback;
}

function readMessageField(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function collectPayloadMessage(
  payload: unknown,
  maxDepth = 4
): string | null {
  const queue: Array<{ value: unknown; depth: number }> = [
    { value: payload, depth: 0 }
  ];
  const visited = new Set<unknown>();

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current || current.depth > maxDepth) {
      continue;
    }
    const candidate = current.value;
    if (
      candidate === null ||
      candidate === undefined ||
      visited.has(candidate)
    ) {
      continue;
    }
    visited.add(candidate);

    if (typeof candidate === 'string') {
      const message = readMessageField(candidate);
      if (message) {
        return message;
      }
      continue;
    }

    if (Array.isArray(candidate)) {
      candidate.forEach(item => {
        queue.push({
          value: item,
          depth: current.depth + 1
        });
      });
      continue;
    }

    if (typeof candidate !== 'object') {
      continue;
    }

    const record = candidate as Record<string, unknown>;
    const directMessageKeys = [
      'message',
      'detail',
      'error',
      'errorMessage',
      'statusMessage',
      'reason'
    ];
    for (const key of directMessageKeys) {
      const message = readMessageField(record[key]);
      if (message) {
        return message;
      }
    }

    if (record.data !== undefined) {
      queue.push({
        value: record.data,
        depth: current.depth + 1
      });
    }
    if (record.error !== undefined) {
      queue.push({
        value: record.error,
        depth: current.depth + 1
      });
    }
    if (record.errors !== undefined) {
      queue.push({
        value: record.errors,
        depth: current.depth + 1
      });
    }
  }

  return null;
}

function isTechnicalErrorMessage(message: string): boolean {
  const normalized = message.trim();
  if (!normalized) {
    return true;
  }

  if (normalized.length > 240) {
    return true;
  }

  if (
    /^(unauthorized|forbidden|not found|bad request|internal server error)$/i.test(
      normalized
    )
  ) {
    return true;
  }

  return (
    /\[(GET|POST|PUT|PATCH|DELETE)\]\s*"/i.test(normalized) ||
    /request failed/i.test(normalized) ||
    /failed to fetch/i.test(normalized) ||
    /network ?error/i.test(normalized) ||
    /timeout/i.test(normalized) ||
    /ecconn|econnrefused|enotfound|etimedout/i.test(normalized) ||
    /cannot read properties/i.test(normalized) ||
    /unexpected token/i.test(normalized) ||
    /json parse/i.test(normalized) ||
    /at\s+\S+\s+\(.+\)/i.test(normalized)
  );
}

function isNetworkErrorMessage(message: string): boolean {
  return (
    /failed to fetch/i.test(message) ||
    /network ?error/i.test(message) ||
    /timeout/i.test(message) ||
    /ecconn|econnrefused|enotfound|etimedout/i.test(message)
  );
}

function resolveApiErrorMessage(
  details: SerializedApiError
): string {
  const payloadMessage = collectPayloadMessage(details.data);
  if (payloadMessage && !isTechnicalErrorMessage(payloadMessage)) {
    return payloadMessage;
  }

  const baseMessage = readMessageField(details.message);
  if (baseMessage) {
    if (isNetworkErrorMessage(baseMessage)) {
      return translateCommonError('networkError');
    }
    if (!isTechnicalErrorMessage(baseMessage)) {
      return baseMessage;
    }
  }

  const statusMessage = readMessageField(details.statusMessage);
  if (statusMessage && !isTechnicalErrorMessage(statusMessage)) {
    return statusMessage;
  }

  if (details.statusCode && details.statusCode >= 500) {
    return translateCommonError('operationFailed');
  }

  if (details.statusCode) {
    return translateCommonError('operationFailed');
  }

  if (
    (baseMessage && isNetworkErrorMessage(baseMessage)) ||
    (statusMessage && isNetworkErrorMessage(statusMessage))
  ) {
    return translateCommonError('networkError');
  }

  return translateCommonError('unknownError');
}

function normalizeApiError(error: unknown): Error {
  const details = serializeApiError(error);
  const message = resolveApiErrorMessage(details);
  if (error instanceof Error && error.message === message) {
    return error;
  }

  const candidate = error as ApiErrorCarrier;
  const normalized = new Error(message) as Error & ApiErrorCarrier;
  normalized.name = details.name ?? candidate?.name ?? 'ApiError';
  if (error instanceof Error && error.stack) {
    normalized.stack = error.stack;
  }
  normalized.statusCode = details.statusCode;
  normalized.statusMessage = details.statusMessage;
  normalized.data = details.data;
  normalized.response = candidate?.response;
  normalized.cause = error;
  normalized.originalMessage = details.message;
  return normalized;
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
        throw normalizeApiError(retryError);
      }
    }

    logApiError({
      ...requestLogPayload,
      durationMs: Date.now() - startAt,
      phase: 'request',
      error: serializeApiError(error)
    });
    throw normalizeApiError(error);
  }
};
