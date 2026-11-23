export default defineNuxtRouteMiddleware(to => {
  if (!String(to.name ?? '').startsWith('tweet-type-user')) return;
  const type = to.params.type;
  if (type === 'home' || type === 'trending') {
    const localePath = useLocalePath();
    return navigateTo({
      path: localePath('index'),
      query: type === 'trending' ? { ...to.query, feed: 'trending' } : to.query,
    }, { replace: true });
  }
});
