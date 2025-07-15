// 您的所有 import 语句保持不变
import { ofetch, type FetchContext } from 'ofetch';
import { usePreferenceStore } from '~/stores/user'; // 使用您自己的 store

// OnResponseErrorHook 类型定义可以保留，它有助于代码可读性
type OnResponseErrorHook = (
  context: FetchContext & { response: Response }
) => Promise<void> | void;

// --- 文件级注释 ---
// 本插件用于全局封装 API 请求，自动注入 Token，处理 401 自动刷新，统一错误处理。
// 支持自动重试、刷新令牌、登出等高级功能。
// 适用于 NekoTribe 项目所有前端 API 调用场景。
// 作者：NekoTribe团队

export default defineNuxtPlugin(nuxtApp => {
  const config = useRuntimeConfig();
  // 这样在 onResponseError 中就不需要重复获取了。
  const preferenceStore = usePreferenceStore();
  let refreshTokenPromise: Promise<void> | null = null;

  const apiFetch = ofetch.create({
    baseURL: config.public.apiBase,

    // 请求前自动注入 Token
    async onRequest({ options }) {
      const accessToken =
        preferenceStore.preferences.access_token;

      console.log('[api.ts] 请求头:', accessToken);
      console.log(
        '[api.ts] 请求头:',
        preferenceStore.preferences
      );

      if (accessToken) {
        options.headers = new Headers(options.headers);
        options.headers.set(
          'Authorization',
          `Bearer ${accessToken}`
        );

        // 调试信息：请求头已注入 Token
        console.log(
          '[api.ts] 已注入Token到请求头:',
          accessToken
        );
      } else {
        // 调试信息：未检测到 Token
        console.log('[api.ts] 未检测到Token，跳过注入');
      }
      // 调试信息：请求参数
      console.log('[api.ts] 请求参数:', options);
    },

    // 响应错误处理（自动刷新Token）
    async onResponseError({
      request,
      options,
      error,
      response
    }) {
      // 先判断 error 是否为 FetchError 类型
      console.log('[api.ts] 响应错误:', response.status);
      if (response.status !== 401) {
        // 调试信息：非401错误，直接返回
        console.log(
          '[api.ts] 非401错误，直接返回:',
          error,
          response
        );
        return;
      }

      // 注意：这里我将 authStore 改为了 preferenceStore 以匹配您的代码
      // 请确保 refreshAccessToken 和 logout 方法确实存在于您的 usePreferenceStore 中。
      const store = preferenceStore;

      // if (
      //   options.headers &&
      //   (options.headers as Headers)
      //     .get('Authorization')
      //     ?.includes(store.preferences.access_token ?? '')
      // ) {
      //   // 调试信息：已尝试刷新，避免死循环
      //   console.log('[api.ts] 已尝试刷新Token，避免死循环');
      //   return;
      // }

      if (!refreshTokenPromise) {
        refreshTokenPromise = new Promise(
          async (resolve, reject) => {
            try {
              console.log(
                '[api.ts] Token已过期，尝试刷新...'
              );
              // 确保 store 上有 refreshAccessToken 方法
              await store.refreshAccessToken();
              console.log('[api.ts] Token刷新成功');
              resolve();
            } catch (e) {
              console.log(
                '[api.ts] Token刷新失败，即将登出。',
                e
              );
              // 确保 store 上有 logout 方法
              store.setAuthTokens('', '');
              store.resetToDefaults();
              reject(e);
            } finally {
              refreshTokenPromise = null;
              console.log('[api.ts] 刷新流程结束');
            }
          }
        );
      }

      try {
        await refreshTokenPromise;

        await refreshTokenPromise;

        // 🔥🔥🔥 最终的解决方案：使用原始 ofetch 手动重试 🔥🔥🔥

        console.log(
          '[api.ts] 刷新成功，准备使用【原始ofetch】进行重试:',
          request
        );

        // 1. 从 store 中获取【刚刚刷新好的】最新 Token
        const newAccessToken =
          store.preferences.access_token;

        // 2. 创建一个全新的 Headers 对象
        const newHeaders = new Headers(options.headers);
        if (newAccessToken) {
          newHeaders.set(
            'Authorization',
            `Bearer ${newAccessToken}`
          );
        }

        // 3. 创建全新的 options 对象，并确保 baseURL 被正确设置
        const retryOptions = {
          ...options,
          headers: newHeaders,
          baseURL: config.public.apiBase // 明确再次提供 baseURL
        };

        // 4. 🔥 调用【原始的 ofetch】，而不是 apiFetch 实例。
        //    这创建了一个完全干净、无状态污染的新请求。
        //    我们返回它的结果，并用 `as any` 来满足 TypeScript。
        console.log(
          '[api.ts] 正在重试请求:',
          request,
          retryOptions
        );

        return ofetch(request, retryOptions) as any;
      } catch (refreshError) {
        // 调试信息：刷新失败，错误抛出
        console.error(
          '[api.ts] 刷新失败，错误抛出:',
          refreshError
        );
        throw refreshError;
      }
    }
  });

  // 提供给整个应用的逻辑保持不变
  // 调试信息：插件已初始化
  console.log(
    '[api.ts] apiFetch插件已初始化，baseURL:',
    config.public.apiBase
  );

  return {
    provide: {
      api: apiFetch
    }
  };
});
