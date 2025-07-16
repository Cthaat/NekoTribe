import { usePreferenceStore } from '~/stores/user';

export default defineNuxtRouteMiddleware((to, from) => {
  const preferenceStore = usePreferenceStore();

  if (
    to.path !== '/auth/login' &&
    to.path !== '/auth/sign-up' &&
    to.path !== '/auth/forgot-password' &&
    to.path !== '/auth/terms' &&
    !preferenceStore.isLoggedIn
  ) {
    console.log(
      'User is not logged in, redirecting to login page'
    );
    return navigateTo('/auth/login', { replace: true });
  }
});
