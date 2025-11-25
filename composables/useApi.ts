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
  // 用于防止重复刷新的Promise缓存
  let refreshingPromise: Promise<void> | null = null;

  const defaults: ApiFetchOptions = {
    baseURL: config.public.apiBase,
    credentials: 'include', // 默认发送Cookie，这是关键！

    // 响应拦截器：记录错误（实际的401处理在外层catch中）
    async onResponseError({
      response,
      options: requestOptions
    }): Promise<void> {
      // 只记录非401错误
      if (response.status !== 401) {
        console.log(
          `[apiFetch] 请求失败: ${response.status} ${response.statusText}`
        );
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
    headers: mergedHeaders,
    credentials: 'include' // 确保每次请求都发送Cookie
  };

  // 6. 包装$fetch调用，处理401错误的自动重试
  const executeFetch = async () => {
    try {
      return await $fetch<T>(path, mergedOptions as any);
    } catch (error: any) {
      // 如果是401错误且不是刷新token接口，尝试刷新后重试
      if (
        (error?.response?.status === 401 ||
          error?.statusCode === 401) &&
        !path.includes('/auth/refresh')
      ) {
        console.log(
          '[apiFetch] 捕获到401错误，刷新token后重试一次'
        );

        try {
          const { usePreferenceStore } = await import(
            '~/stores/user'
          );
          const preferenceStore = usePreferenceStore();
          await preferenceStore.refreshAccessToken();

          // 等待Cookie更新
          await new Promise(resolve =>
            setTimeout(resolve, 100)
          );

          console.log('[apiFetch] Token刷新完成，重试请求');

          // 重试请求 - 这次应该成功
          return await $fetch<T>(
            path,
            mergedOptions as any
          );
        } catch (retryError) {
          console.error('[apiFetch] 重试失败:', retryError);
          throw retryError;
        }
      }

      // 非401错误或刷新失败，直接抛出
      throw error;
    }
  };

  return executeFetch();
};
