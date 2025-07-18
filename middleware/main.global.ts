export default defineNuxtRouteMiddleware(to => {
  const preferenceStore = usePreferenceStore();
  const localePath = useLocalePath();
  const userId = preferenceStore.preferences.user.userId;
  const homePath = localePath(`/tweet/home/${userId}`);
  if (to.path === '/') {
    return navigateTo(homePath, { replace: true });
  }
});
