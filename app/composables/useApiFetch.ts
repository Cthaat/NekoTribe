import { useFetch, useNuxtApp } from '#app';
import { apiFetch, type ApiFetchOptions } from './useApi';

type UseApiFetchOptions<T> = NonNullable<
  Parameters<typeof useFetch<T>>[1]
>;

/** Nuxt owns reactive data/refresh; apiFetch exclusively owns auth recovery. */
export function useApiFetch<T>(
  path: string,
  options: UseApiFetchOptions<T> = {} as UseApiFetchOptions<T>
) {
  const app = useNuxtApp();
  // Nuxt useFetch invokes only the callable $fetch contract with this string
  // path and resolved options; raw/create are not exposed by this adapter.
  const guardedFetch = (<TData>(request: string, requestOptions: ApiFetchOptions = {}) => {
    const { baseURL: _publicBase, ...transportOptions } = requestOptions;
    return app.runWithContext(() => apiFetch<TData>(request, transportOptions));
  }) as typeof globalThis.$fetch;

  return useFetch<T>(path, {
    ...options,
    // Keep Nuxt's hydration key stable while apiFetch selects the transport address.
    baseURL: String(app.$config.public.apiBase ?? ''),
    server: options.server ?? false,
    // A custom transport must not bypass the common identity/recovery policy.
    $fetch: guardedFetch
  } as UseApiFetchOptions<T>);
}
