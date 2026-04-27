/**
 * 全局错误处理插件 - 处理401错误的token刷新（后备方案）
 * 这个插件作为最后一道防线，处理未被useApiFetch捕获的401错误
 */
interface ErrorWithStatus {
  statusCode?: number;
  response?: { status?: number };
  data?: { code?: number };
}

function isUnauthorizedError(error: unknown): boolean {
  const candidate = error as ErrorWithStatus;
  return (
    candidate?.statusCode === 401 ||
    candidate?.response?.status === 401 ||
    candidate?.data?.code === 401
  );
}

export default defineNuxtPlugin(nuxtApp => {
  // 用于防止重复刷新的标志
  let isHandling401 = false;

  // Hook into Nuxt's error handling
  nuxtApp.hook('vue:error', async (error: unknown) => {
    // 检查是否是401错误
    const is401Error = isUnauthorizedError(error);

    if (is401Error && !isHandling401) {
      isHandling401 = true;

      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();

        // 尝试刷新token
        await preferenceStore.refreshAccessToken();

        // 清除错误，不显示给用户
        clearError();

        // 不刷新页面，让组件自己重试
      } catch (refreshError) {
        console.error(
          '[ErrorHandler] Token刷新失败:',
          refreshError
        );
        // 刷新失败，让错误继续传播
      } finally {
        isHandling401 = false;
      }
    }
  });

  // Hook into app error
  nuxtApp.hook('app:error', async (error: unknown) => {
    // 检查是否是401错误
    const is401Error = isUnauthorizedError(error);

    if (is401Error && !isHandling401) {
      isHandling401 = true;

      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();

        // 尝试刷新token
        await preferenceStore.refreshAccessToken();

        // 清除错误，不显示给用户
        clearError();

        // 不刷新页面，让组件自己重试
      } catch (refreshError) {
        console.error(
          '[ErrorHandler] Token刷新失败:',
          refreshError
        );
        // 刷新失败，让错误继续传播
      } finally {
        isHandling401 = false;
      }
    }
  });
});
