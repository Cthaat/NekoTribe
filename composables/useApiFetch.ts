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

  // 3. 追加来源追踪头，帮助服务端定位发起请求的前端"来源"
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

  const headers: Record<string, string> = {
    ...(options.headers || {})
  };
  if (route?.fullPath)
    headers['x-client-route'] = toSafeHeaderValue(
      String(route.fullPath)
    );
  if (compName)
    headers['x-client-component'] = toSafeHeaderValue(
      String(compName)
    );
  if (stackSource)
    headers['x-client-source'] = toSafeHeaderValue(
      String(stackSource)
    );
  if (!isServer && typeof location !== 'undefined')
    headers['x-client-referer'] = toSafeHeaderValue(
      String(location.href)
    );
  headers['x-client-platform'] = isServer
    ? 'server'
    : 'client';

  options.headers = headers;

  // 确保客户端请求携带Cookie
  // 这对于httpOnly Cookie的认证至关重要
  options.credentials = 'include';

  // 添加请求拦截器 - 在发送请求前检查token
  const originalOnRequest = options.onRequest;
  options.onRequest = async (context: any) => {
    // 调用用户自定义的请求处理（如果有）
    if (originalOnRequest) {
      await originalOnRequest(context);
    }

    // 在客户端且不是刷新token接口时，检查token状态
    if (!isServer && !path.includes('/auth/refresh')) {
      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();

        // 如果正在刷新token，等待完成
        if (preferenceStore.isRefreshingToken) {
          console.log(
            '[useApiFetch] 等待token刷新完成后再发送请求'
          );
          // 等待最多3秒
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

  // 添加响应错误拦截器处理token过期
  const originalOnResponseError = options.onResponseError;

  // 添加onResponse拦截器来处理成功的响应
  const originalOnResponse = options.onResponse;
  options.onResponse = async (context: any) => {
    // 调用用户自定义的响应处理（如果有）
    if (originalOnResponse) {
      await originalOnResponse(context);
    }
  };

  options.onResponseError = async (context: any) => {
    const { response, options: fetchOptions } = context;

    // 检测401错误且不是刷新token接口本身
    if (
      response.status === 401 &&
      !path.includes('/auth/refresh')
    ) {
      console.log(
        '[useApiFetch] 检测到401错误，阻止错误传播'
      );

      // 标记这是一个401错误，供watch处理
      context._is401 = true;

      // 不抛出错误，不调用原始错误处理器
      // 这样可以阻止错误显示给用户
      return;
    }

    // 非401错误，调用用户自定义的错误处理（如果有）
    if (originalOnResponseError) {
      await originalOnResponseError(context);
    }
  };

  // 禁用服务端渲染时的请求，只在客户端执行
  // 这样可以避免SSR期间的认证问题
  if (options.server === undefined) {
    options.server = false;
  }

  // 4. 调用原始的 useFetch
  const result = useFetch<T>(path, options);

  // 5. 在客户端环境下，监听错误并自动处理401
  if (!isServer && result) {
    const originalError = result.error;
    const originalRefresh = result.refresh;
    const originalStatus = result.status;

    // 使用ref跟踪是否正在刷新token，避免重复刷新
    const isRefreshing = ref(false);
    const isProcessing401 = ref(false); // 标记是否正在处理401
    let refreshAttempts = 0;
    const MAX_REFRESH_ATTEMPTS = 2;

    // 使用watch处理401错误 - 先处理，再清除
    watch(
      [originalError, originalStatus],
      async ([newError, newStatus]) => {
        // 检测401错误
        const is401 =
          (newError &&
            (newError as any).statusCode === 401) ||
          (newError && (newError as any).status === 401) ||
          (newError &&
            (newError as any).data?.code === 401);

        if (
          is401 &&
          !path.includes('/auth/refresh') &&
          !isRefreshing.value &&
          refreshAttempts < MAX_REFRESH_ATTEMPTS
        ) {
          console.log(
            '[useApiFetch] 检测到401错误，开始处理'
          );

          // 标记正在处理
          isProcessing401.value = true;

          // 立即清除错误，防止UI显示
          result.error.value = null;

          isRefreshing.value = true;
          refreshAttempts++;

          try {
            const { usePreferenceStore } = await import(
              '~/stores/user'
            );
            const preferenceStore = usePreferenceStore();

            // 刷新token
            await preferenceStore.refreshAccessToken();

            console.log(
              '[useApiFetch] Token刷新成功，重新请求数据'
            );

            // token刷新成功后，自动重新请求
            if (originalRefresh) {
              await originalRefresh();
            }
          } catch (error) {
            console.error(
              '[useApiFetch] Token刷新失败:',
              error
            );

            // 刷新失败后，恢复错误显示并跳转登录页
            if (refreshAttempts >= MAX_REFRESH_ATTEMPTS) {
              result.error.value = newError;
              const router = useRouter();
              const localePath = useLocalePath();
              await router.push(localePath('/auth/login'));
            }
          } finally {
            isRefreshing.value = false;
            isProcessing401.value = false;
          }
        }
      },
      {
        deep: true,
        immediate: false,
        flush: 'sync' // 同步执行，确保立即处理
      }
    );
  }

  return result;
}
