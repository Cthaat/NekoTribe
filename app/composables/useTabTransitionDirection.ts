import type { Router } from 'vue-router';

function tabIndex(path: string) {
  const local = path.replace(/^\/(?:en|zh)(?=\/|$)/, '').replace(/\/$/, '');
  if (!local) return 0;
  if (local === '/groups/discover') return 1;
  if (/^\/user\/[^/]+\/notifications$/.test(local)) return 2;
  if (local === '/chat') return 3;
  if (local === '/account/overview' || /^\/user\/[^/]+\/profile$/.test(local)) return 4;
  return -1;
}

export function tabDirection(from: string, to: string) {
  const a = tabIndex(from), b = tabIndex(to);
  return a < 0 || b < 0 || a === b ? 'fade' : b > a ? 'forward' : 'back';
}

export function useTabTransitionDirection(router: Router) {
  const before = router.beforeEach(to => {
    if (typeof document.startViewTransition === 'function' || matchMedia('(prefers-reduced-motion: reduce)').matches) {
      to.meta.pageTransition = false;
      to.meta.layoutTransition = false;
    }
  });
  const after = router.afterEach((to, from, failure) => {
    if (!failure) document.documentElement.dataset.tabDirection = tabDirection(from.path, to.path);
  });
  return () => { before(); after(); };
}
