const DEV_ONLY_PAGE_SEGMENTS = new Set([
  'test',
  'test-token-refresh',
  'ws'
]);
const LOCALE_SEGMENTS = new Set(['zh', 'en']);

export default defineNuxtRouteMiddleware(to => {
  if (import.meta.dev) {
    return;
  }

  const segments = to.path.split('/').filter(Boolean);
  const firstAppSegment = LOCALE_SEGMENTS.has(segments[0] ?? '')
    ? segments[1]
    : segments[0];

  if (
    firstAppSegment &&
    DEV_ONLY_PAGE_SEGMENTS.has(firstAppSegment)
  ) {
    return abortNavigation(
      createError({
        statusCode: 404,
        statusMessage: 'Not Found'
      })
    );
  }
});
