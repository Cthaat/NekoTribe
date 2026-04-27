import { useFetch } from '#app';
import { getCurrentInstance, watch } from 'vue';

type UseApiFetchOptions = NonNullable<
  Parameters<typeof useFetch>[1]
>;
type UseApiFetchHeaders =
  UseApiFetchOptions extends { headers?: infer THeaders }
    ? THeaders
    : HeadersInit;
type OnRequestContext = Parameters<
  NonNullable<UseApiFetchOptions['onRequest']>
>[0];
type OnResponseContext = Parameters<
  NonNullable<UseApiFetchOptions['onResponse']>
>[0];
type OnResponseErrorContext = Parameters<
  NonNullable<UseApiFetchOptions['onResponseError']>
>[0] & { _is401?: boolean };

interface ComponentDescriptor {
  name?: string;
  __name?: string;
}

interface StatusCarrier {
  statusCode?: number;
  status?: number;
  data?: { code?: number };
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
  headers: UseApiFetchHeaders | undefined
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

export function useApiFetch<T>(
  path: string,
  options: UseApiFetchOptions = {} as UseApiFetchOptions
) {
  const resolvedOptions = {
    ...options
  } as UseApiFetchOptions;
  const config = useRuntimeConfig();
  resolvedOptions.baseURL = config.public.apiBase;

  const isServer = typeof window === 'undefined';
  const route = (() => {
    try {
      return useRoute();
    } catch {
      return undefined;
    }
  })();
  const componentName = getComponentName();
  const stackSource = buildStackSource();

  const headers: Record<string, string> = {
    ...headersToRecord(resolvedOptions.headers)
  };
  if (route?.fullPath) {
    headers['x-client-route'] = toSafeHeaderValue(
      String(route.fullPath)
    );
  }
  if (componentName) {
    headers['x-client-component'] = toSafeHeaderValue(
      componentName
    );
  }
  if (stackSource) {
    headers['x-client-source'] = toSafeHeaderValue(
      stackSource
    );
  }
  if (!isServer && typeof location !== 'undefined') {
    headers['x-client-referer'] = toSafeHeaderValue(
      String(location.href)
    );
  }
  headers['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  resolvedOptions.headers = headers;
  resolvedOptions.credentials = 'include';

  const originalOnRequest = resolvedOptions.onRequest;
  resolvedOptions.onRequest = async (
    context: OnRequestContext
  ) => {
    if (originalOnRequest) {
      await originalOnRequest(context);
    }

    if (!isServer && !isRefreshPath(path)) {
      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();
        if (preferenceStore.isRefreshingToken) {
          let waitTime = 0;
          while (
            preferenceStore.isRefreshingToken &&
            waitTime < 3000
          ) {
            await new Promise(resolve =>
              setTimeout(resolve, 100)
            );
            waitTime += 100;
          }
        }
      } catch (error) {
        console.error(
          '[useApiFetch] onRequest检查token失败:',
          error
        );
      }
    }
  };

  const originalOnResponse = resolvedOptions.onResponse;
  resolvedOptions.onResponse = async (
    context: OnResponseContext
  ) => {
    if (originalOnResponse) {
      await originalOnResponse(context);
    }
  };

  const originalOnResponseError =
    resolvedOptions.onResponseError;
  resolvedOptions.onResponseError = async (
    context: OnResponseErrorContext
  ) => {
    if (
      context.response.status === 401 &&
      !isRefreshPath(path)
    ) {
      context._is401 = true;
      return;
    }

    if (originalOnResponseError) {
      await originalOnResponseError(context);
    }
  };

  if (resolvedOptions.server === undefined) {
    resolvedOptions.server = false;
  }

  const result = useFetch<T>(path, resolvedOptions);

  if (!isServer) {
    const isRefreshing = ref(false);
    let refreshAttempts = 0;
    const maxRefreshAttempts = 2;

    watch(
      [result.error, result.status],
      async ([newError]) => {
        const statusCarrier = newError as
          | StatusCarrier
          | null
          | undefined;
        const is401 =
          statusCarrier?.statusCode === 401 ||
          statusCarrier?.status === 401 ||
          statusCarrier?.data?.code === 401;

        if (
          is401 &&
          !isRefreshPath(path) &&
          !isRefreshing.value &&
          refreshAttempts < maxRefreshAttempts
        ) {
          result.error.value = null;
          isRefreshing.value = true;
          refreshAttempts += 1;

          try {
            const { usePreferenceStore } = await import(
              '~/stores/user'
            );
            const preferenceStore = usePreferenceStore();
            await preferenceStore.refreshAccessToken();
            await result.refresh();
          } catch (error) {
            console.error(
              '[useApiFetch] Token刷新失败:',
              error
            );

            if (refreshAttempts >= maxRefreshAttempts) {
              result.error.value = newError;
              const router = useRouter();
              const localePath = useLocalePath();
              await router.push(localePath('/auth/login'));
            }
          } finally {
            isRefreshing.value = false;
          }
        }
      },
      {
        deep: true,
        immediate: false,
        flush: 'sync'
      }
    );
  }

  return result;
}
