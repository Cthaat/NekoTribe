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

  // ✨ 1. 新增的出口条件：如果目标已经是登录页，直接放行
  //    这是打破循环的关键。
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
  if (!isAuthRoute && !preferenceStore.isLoggedIn) {
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
