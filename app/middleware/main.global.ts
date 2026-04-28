export default defineNuxtRouteMiddleware(to => {
  const preferenceStore = usePreferenceStore();
  const localePath = useLocalePath();
  const userId = preferenceStore.preferences.user.id;
  const homePath = localePath(`/tweet/home/${userId}`);
  if (to.path === '/' || to.path === '/cn') {
    return navigateTo(homePath, { replace: true });
  }
});
