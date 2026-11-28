export default defineNuxtPlugin(app => {
  const unregister = useTabTransitionDirection(useRouter());
  app.vueApp.onUnmount(unregister);
  if (import.meta.hot) import.meta.hot.dispose(unregister);
});
