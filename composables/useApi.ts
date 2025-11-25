// composables/apiFetch.ts

// 1. 我们不需要从任何地方导入选项类型了！
//    我们将直接从全局的 $fetch 函数推导出它的类型。
import { getCurrentInstance } from 'vue';
import type { FetchError } from 'ofetch';

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
    baseURL: config.public.apiBase,

    // 响应拦截器：处理token过期错误
    async onResponseError({
      response,
      options: requestOptions
    }) {
      // 检测401错误且不是刷新token接口本身
      if (
        response.status === 401 &&
        !path.includes('/auth/refresh')
      ) {
        console.log(
          '[apiFetch] 检测到401错误，尝试刷新token'
        );

        try {
          // 获取store并刷新token
          const { usePreferenceStore } = await import(
            '~/stores/user'
          );
          const preferenceStore = usePreferenceStore();

          // 调用store的刷新方法
          await preferenceStore.refreshAccessToken();

          console.log(
            '[apiFetch] Token刷新成功，重试原始请求'
          );

          // 重试原始请求
          return $fetch(path, {
            ...(requestOptions as any),
            baseURL: config.public.apiBase
          } as any);
        } catch (error) {
          console.error('[apiFetch] Token刷新失败:', error);
          // 刷新失败，让错误继续传播
          throw error;
        }
      }
    }
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

  // 辅助函数：将字符串转换为安全的 ASCII header 值（处理中文等非 ASCII 字符）
  const toSafeHeaderValue = (value: string): string => {
    try {
      // 检测是否包含非 ASCII 字符（字符码 > 255）
      if (/[^\x00-\xFF]/.test(value)) {
        // 使用 encodeURIComponent 编码，然后标记为已编码
        return 'utf8:' + encodeURIComponent(value);
      }
      return value;
    } catch (e) {
      // 编码失败时返回安全的占位符
      return 'encoded-error';
    }
  };

  const traceHeaders: Record<string, string> = {};
  if (route?.fullPath)
    traceHeaders['x-client-route'] = toSafeHeaderValue(
      String(route.fullPath)
    );
  if (compName)
    traceHeaders['x-client-component'] = toSafeHeaderValue(
      String(compName)
    );
  if (stackSource)
    traceHeaders['x-client-source'] = toSafeHeaderValue(
      String(stackSource)
    );
  if (!isServer && typeof location !== 'undefined')
    traceHeaders['x-client-referer'] = toSafeHeaderValue(
      String(location.href)
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
