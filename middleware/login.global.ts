export default defineNuxtRouteMiddleware(to => {
  if (
    to.path !== '/auth/login' &&
    to.path !== '/auth/sign-up' &&
    to.path !== '/auth/forgot-password' &&
    !useCookie('access_token').value
  ) {
    return navigateTo('/auth/login');
  }
});
