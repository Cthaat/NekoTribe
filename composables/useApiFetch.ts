// composables/useApiFetch.ts
import { useFetch } from '#app';
import { getCurrentInstance, watch } from 'vue';

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
    headers['x-client-route'] = encodeURI(String(route.fullPath));
  if (compName)
    headers['x-client-component'] = String(compName);
  if (stackSource)
    headers['x-client-source'] = encodeURIComponent(String(stackSource));
  if (!isServer && typeof location !== 'undefined')
    headers['x-client-referer'] = encodeURI(String(location.href));
  headers['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  options.headers = headers;

  // 添加响应错误拦截器处理token过期
  const originalOnResponseError = options.onResponseError;
  options.onResponseError = async (context: any) => {
    const { response } = context;

    // 先调用用户自定义的错误处理（如果有）
    if (originalOnResponseError) {
      await originalOnResponseError(context);
    }

    // 检测401错误且不是刷新token接口本身
    if (
      response.status === 401 &&
      !path.includes('/auth/refresh')
    ) {
      console.log(
        '[useApiFetch] 检测到401错误，尝试刷新token'
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
          '[useApiFetch] Token刷新成功，将在下次组件更新时自动重试'
        );
      } catch (error) {
        console.error(
          '[useApiFetch] Token刷新失败:',
          error
        );
        throw error;
      }
    }
  };

  // 4. 调用原始的 useFetch
  const result = useFetch<T>(path, options);

  // 5. 在客户端环境下，监听错误并自动重试
  if (!isServer && result) {
    const originalError = result.error;
    const originalRefresh = result.refresh;

    // 监听错误变化
    watch(originalError, async newError => {
      if (
        newError &&
        (newError as any).statusCode === 401 &&
        !path.includes('/auth/refresh')
      ) {
        console.log(
          '[useApiFetch] 监听到401错误，token刷新后自动重试'
        );
        try {
          const { usePreferenceStore } = await import(
            '~/stores/user'
          );
          const preferenceStore = usePreferenceStore();
          await preferenceStore.refreshAccessToken();

          // token刷新成功后，自动重新请求
          if (originalRefresh) {
            console.log(
              '[useApiFetch] 执行refresh重新请求'
            );
            await originalRefresh();
          }
        } catch (error) {
          console.error(
            '[useApiFetch] 自动重试失败:',
            error
          );
        }
      }
    });
  }

  return result;
}
