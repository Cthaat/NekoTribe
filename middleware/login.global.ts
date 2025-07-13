import { usePreferenceStore } from '~/stores/user';

export default defineNuxtRouteMiddleware((to, from) => {
  const preferenceStore = usePreferenceStore();

  if (
    to.path !== '/auth/login' &&
    to.path !== '/auth/sign-up' &&
    to.path !== '/auth/forgot-password' &&
    !preferenceStore.isLoggedIn
  ) {
    return navigateTo('/auth/login', { replace: true });
  }
});
