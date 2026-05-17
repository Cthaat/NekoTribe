import { useFetch } from '#app';
import { getCurrentInstance, watch } from 'vue';

type UseApiFetchOptions<T> = NonNullable<
  Parameters<typeof useFetch<T>>[1]
>;

interface ComponentDescriptor {
  name?: string;
  __name?: string;
}

interface StatusCarrier {
  statusCode?: number;
  status?: number;
  data?: { code?: number };
}

type AsyncHook<TContext> = (
  context: TContext
) => void | Promise<void>;

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

function headersToRecord(headers: unknown): Record<string, string> {
  if (!headers) {
    return {};
  }

  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }

  if (Array.isArray(headers)) {
    return Object.fromEntries(
      headers.map(entry => [
        String(entry[0]),
        String(entry[1])
      ])
    );
  }

  if (typeof headers === 'object') {
    return Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [
        key,
        String(value)
      ])
    );
  }

  return {};
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

function getResponseStatus(context: unknown): number | undefined {
  if (!context || typeof context !== 'object') {
    return undefined;
  }

  if (!('response' in context)) {
    return undefined;
  }

  const response = (
    context as { response?: { status?: number } }
  ).response;
  return response?.status;
}

async function runHook<TContext>(
  hook: unknown,
  context: TContext
): Promise<void> {
  if (typeof hook === 'function') {
    await (hook as AsyncHook<TContext>)(context);
    return;
  }

  if (Array.isArray(hook)) {
    for (const item of hook) {
      if (typeof item === 'function') {
        await (item as AsyncHook<TContext>)(context);
      }
    }
  }
}

export function useApiFetch<T>(
  path: string,
  options: UseApiFetchOptions<T> = {} as UseApiFetchOptions<T>
) {
  const resolvedOptions = {
    ...options
  } as UseApiFetchOptions<T>;

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
      sanitizeUrlLikeForHeader(String(route.fullPath))
    );
  }
  if (componentName) {
    headers['x-client-component'] = toSafeHeaderValue(
      componentName
    );
  }
  if (stackSource) {
    headers['x-client-source'] = toSafeHeaderValue(
      sanitizeUrlLikeForHeader(stackSource)
    );
  }
  if (!isServer && typeof location !== 'undefined') {
    headers['x-client-referer'] = toSafeHeaderValue(
      sanitizeUrlLikeForHeader(String(location.href))
    );
  }
  headers['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  resolvedOptions.headers = headers;
  resolvedOptions.credentials = 'include';

  const originalOnRequest = resolvedOptions.onRequest;
  resolvedOptions.onRequest = async context => {
    await runHook(originalOnRequest, context);

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
  resolvedOptions.onResponse = async context => {
    await runHook(originalOnResponse, context);
  };

  const originalOnResponseError =
    resolvedOptions.onResponseError;
  resolvedOptions.onResponseError = async context => {
    if (getResponseStatus(context) === 401 && !isRefreshPath(path)) {
      return;
    }

    await runHook(originalOnResponseError, context);
  };

  if (resolvedOptions.server === undefined) {
    resolvedOptions.server = false;
  }

  const result = useFetch<T>(
    path,
    resolvedOptions as Parameters<typeof useFetch<T>>[1]
  );

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
          result.error.value = undefined;
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
