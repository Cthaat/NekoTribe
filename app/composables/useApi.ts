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
  const config = useRuntimeConfig();
  const isServer = typeof window === 'undefined';
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
      String(route.fullPath)
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
      stackSource
    );
  }
  if (!isServer && typeof location !== 'undefined') {
    traceHeaders['x-client-referer'] = toSafeHeaderValue(
      String(location.href)
    );
  }
  traceHeaders['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  const mergedOptions: ApiFetchOptions = {
    baseURL: config.public.apiBase,
    credentials: 'include',
    ...options,
    headers: {
      ...getForwardedRequestHeaders(isServer),
      ...traceHeaders,
      ...headersToRecord(options.headers)
    }
  };

  try {
    return await $fetch<T>(path, mergedOptions);
  } catch (error) {
    const maybeError = error as FetchError;
    if (
      (maybeError.response?.status === 401 ||
        maybeError.statusCode === 401) &&
      !isRefreshPath(path)
    ) {
      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();
        await preferenceStore.refreshAccessToken();
        await new Promise(resolve =>
          setTimeout(resolve, 100)
        );
        return await $fetch<T>(path, mergedOptions);
      } catch (retryError) {
        console.error('[apiFetch] 重试失败:', retryError);
        throw retryError;
      }
    }

    throw error;
  }
};
