/**
 * 全局错误处理插件 - 处理401错误的token刷新
 * 这个插件会拦截所有Nuxt的错误，在显示给用户之前尝试刷新token
 */
export default defineNuxtPlugin(nuxtApp => {
  // 用于防止重复刷新的标志
  let isHandling401 = false;

  // Hook into Nuxt's error handling
  nuxtApp.hook('vue:error', async (error: any) => {
    console.log('[ErrorHandler] 捕获到错误:', error);

    // 检查是否是401错误
    const is401Error =
      error?.statusCode === 401 ||
      error?.response?.status === 401 ||
      error?.data?.code === 401;

    if (is401Error && !isHandling401) {
      console.log(
        '[ErrorHandler] 检测到401错误，尝试刷新token'
      );
      isHandling401 = true;

      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();

        // 尝试刷新token
        await preferenceStore.refreshAccessToken();

        console.log(
          '[ErrorHandler] Token刷新成功，请重新操作'
        );

        // 清除错误，不显示给用户
        clearError();

        // 刷新当前页面以重新获取数据
        if (process.client) {
          // 使用router重新加载当前路由
          const router = useRouter();
          router.go(0);
        }
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
  nuxtApp.hook('app:error', async (error: any) => {
    console.log('[ErrorHandler] App捕获到错误:', error);

    // 检查是否是401错误
    const is401Error =
      error?.statusCode === 401 ||
      error?.response?.status === 401 ||
      error?.data?.code === 401;

    if (is401Error && !isHandling401) {
      console.log(
        '[ErrorHandler] App检测到401错误，尝试刷新token'
      );
      isHandling401 = true;

      try {
        const { usePreferenceStore } = await import(
          '~/stores/user'
        );
        const preferenceStore = usePreferenceStore();

        // 尝试刷新token
        await preferenceStore.refreshAccessToken();

        console.log(
          '[ErrorHandler] Token刷新成功，请重新操作'
        );

        // 清除错误，不显示给用户
        clearError();

        // 刷新当前页面以重新获取数据
        if (process.client) {
          const router = useRouter();
          await router.replace(
            router.currentRoute.value.fullPath
          );
        }
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
