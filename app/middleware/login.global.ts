// middleware/auth.ts
import { usePreferenceStore } from '~/stores/user';
import { useI18n } from 'vue-i18n';
import { toast } from 'vue-sonner';

export default defineNuxtRouteMiddleware((to, from) => {
  const preferenceStore = usePreferenceStore();
  const localePath = useLocalePath();

  const AUTH_ROUTE_NAMES = [
    'auth-login',
    'auth-sign-up',
    'auth-forgot-password',
    'auth-terms'
  ];

  // 如果目标已经是登录页，直接放行
  if (to.name === 'auth-login') {
    return; // 什么都不做，让导航继续
  }

  const isAuthRoute = AUTH_ROUTE_NAMES.some(routeName =>
    (to.name as string)?.startsWith(routeName)
  );

  // ✨ 2. 你的原始逻辑保持不变
  //    判断条件：
  //    a. 检查目标路由的名称是否不在白名单中
  //    b. 检查用户是否未登录
  //    c. 确保不在刷新token过程中（避免干扰token刷新）
  if (!isAuthRoute && !preferenceStore.isLoggedIn) {
    // 如果正在刷新token，暂时不跳转，等待刷新完成
    if (preferenceStore.isRefreshingToken) {
      console.log(
        '[Middleware] 正在刷新token，暂不跳转登录页'
      );
      return;
    }

    toast.error(
      'User is not logged in, redirecting to localized login page'
    );

    const loginPath = localePath('auth-login');

    // ✨ 3. 增加一个判断，避免在已经前往登录页时再次重定向
    //    这是一个额外的保险措施。
    if (to.fullPath !== loginPath) {
      return navigateTo(loginPath, { replace: true });
    }
  }
});
