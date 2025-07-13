export default defineNuxtRouteMiddleware(to => {
  if (
    to.path !== '/auth/login' &&
    to.path !== '/auth/sign-up'
  ) {
    return navigateTo('/auth/login');
  }
});
