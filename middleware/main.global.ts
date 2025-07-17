export default defineNuxtRouteMiddleware(to => {
  const localePath = useLocalePath();
  const homePath = localePath('/tweet/home');
  if (to.path === '/') {
    return navigateTo(homePath, { replace: true });
  }
});
