// composables/useApiFetch.ts
import { useFetch } from '#app';
import { getCurrentInstance } from 'vue';

// T 是你期望的响应数据类型
export function useApiFetch<T>(
  path: string,
  options: any = {}
) {
  // 1. 获取运行时配置
  const config = useRuntimeConfig();

  // 2. 利用 useFetch 的 baseURL 选项，自动拼接 URL
  options.baseURL = config.public.apiBase;

  // 3. 追加来源追踪头，帮助服务端定位发起请求的前端“来源”
  //    - x-client-route: 当前路由
  //    - x-client-component: 组件名（若可获取）
  //    - x-client-source: 通过堆栈粗略解析到的来源（可能是打包后的 chunk）
  //    - x-client-referer: 浏览器地址（客户端）
  //    - x-client-platform: client/server 标识
  const isServer = typeof window === 'undefined';
  const route = (() => {
    try {
      return useRoute();
    } catch {
      return undefined;
    }
  })();

  const inst = getCurrentInstance();
  const compName =
    (inst?.type as any)?.name ||
    (inst?.type as any)?.__name;

  let stackSource = '';
  try {
    throw new Error('trace');
  } catch (e: any) {
    const stack: string = e?.stack || '';
    // 取首个包含 http 的帧，排除 node_modules 与 nuxt 内部（尽力而为，生产可能只有 _nuxt/xxx.js）
    const line = stack
      .split('\n')
      .find(
        l =>
          /https?:\/\//.test(l) &&
          !/node_modules|nuxt\//i.test(l)
      );
    if (line) stackSource = line.trim();
  }

  const headers: Record<string, string> = {
    ...(options.headers || {})
  };
  if (route?.fullPath)
    headers['x-client-route'] = String(route.fullPath);
  if (compName)
    headers['x-client-component'] = String(compName);
  if (stackSource)
    headers['x-client-source'] = String(stackSource);
  if (!isServer && typeof location !== 'undefined')
    headers['x-client-referer'] = String(location.href);
  headers['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  options.headers = headers;

  // 4. 调用原始的 useFetch
  return useFetch<T>(path, options);
}
