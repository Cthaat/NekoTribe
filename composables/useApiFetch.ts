// composables/useApiFetch.ts
import { useFetch } from '#app';

// T 是你期望的响应数据类型
export function useApiFetch<T>(
  path: string,
  options: any = {}
) {
  // 1. 获取运行时配置
  const config = useRuntimeConfig();

  // 2. 利用 useFetch 的 baseURL 选项，自动拼接 URL
  options.baseURL = config.public.apiBase;

  // 3. 可以在这里添加通用的请求头，例如认证 token
  //    options.headers = { ... }

  // 4. 调用原始的 useFetch
  return useFetch<T>(path, options);
}
