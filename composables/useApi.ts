// composables/apiFetch.ts

// 1. 我们不需要从任何地方导入选项类型了！
//    我们将直接从全局的 $fetch 函数推导出它的类型。
import { getCurrentInstance } from 'vue';

/**
 * 直接从全局 $fetch 函数的类型定义中提取出其第二个参数（options 对象）的类型。
 * 这是最精确、最不会出错的做法。
 */
type ApiFetchOptions = Parameters<typeof $fetch>[1];

/**
 * 封装了 $fetch，并自动添加 baseURL。
 * 这是用于事件驱动请求（如表单提交）的工具。
 *
 * @param path 你要请求的 API 路径
 * @param options 与 $fetch 完全兼容的选项对象
 */
export const apiFetch = <T>(
  path: string,
  // 2. 使用我们刚刚推导出的精确类型
  options: ApiFetchOptions = {}
) => {
  // 3. 获取运行时配置
  const config = useRuntimeConfig();

  // 4. 创建默认选项，同样使用这个精确的类型
  const defaults: ApiFetchOptions = {
    baseURL: config.public.apiBase

    // 如果需要全局添加 headers 或拦截器，这里是最佳位置
    // onRequest({ options }) { ... }
  };

  // 追加来源追踪头，帮助服务端定位发起请求的前端“来源”
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
    const line = stack
      .split('\n')
      .find(
        l =>
          /https?:\/\//.test(l) &&
          !/node_modules|nuxt\//i.test(l)
      );
    if (line) stackSource = line.trim();
  }

  const traceHeaders: Record<string, string> = {};
  if (route?.fullPath)
    traceHeaders['x-client-route'] = String(route.fullPath);
  if (compName)
    traceHeaders['x-client-component'] = String(compName);
  if (stackSource)
    traceHeaders['x-client-source'] = String(stackSource);
  if (!isServer && typeof location !== 'undefined')
    traceHeaders['x-client-referer'] = String(
      location.href
    );
  traceHeaders['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  // 合并 headers（调用方的 headers 优先）
  const mergedHeaders: Record<string, any> = {
    ...traceHeaders,
    ...((options as any).headers || {})
  };

  // 5. 合并选项，TypeScript 现在可以正确推断出 mergedOptions 的类型
  const mergedOptions: ApiFetchOptions = {
    ...defaults,
    ...options,
    headers: mergedHeaders
  };

  // 6. 调用 $fetch，现在类型完美匹配，不会再有任何错误
  return $fetch<T>(path, mergedOptions);
};
