import { onBeforeUnmount, onMounted, ref } from 'vue';

export type ScrollDirection = 'up' | 'down' | 'idle';

export interface ScrollMetrics {
  scrollY: number;
  maxScroll: number;
  progress: number;
}

export interface ScrollDirectionState {
  lastY: number;
  direction: ScrollDirection;
  hidden: boolean;
}

export interface ScrollDirectionOptions {
  threshold?: number;
  hysteresis?: number;
  topRevealOffset?: number;
}

export function computeScrollMetrics(
  scrollY: number,
  docHeight: number,
  viewportHeight: number
): ScrollMetrics {
  const safeY = Math.max(0, Number.isFinite(scrollY) ? scrollY : 0);
  const safeDoc = Math.max(0, Number.isFinite(docHeight) ? docHeight : 0);
  const safeView = Math.max(0, Number.isFinite(viewportHeight) ? viewportHeight : 0);
  const maxScroll = Math.max(0, safeDoc - safeView);
  const progress = maxScroll > 0 ? Math.min(1, Math.max(0, safeY / maxScroll)) : 0;
  return {
    scrollY: Math.min(safeY, maxScroll > 0 ? maxScroll : safeY),
    maxScroll,
    progress
  };
}

export function updateScrollDirection(
  prev: ScrollDirectionState,
  nextY: number,
  maxScroll: number,
  options: ScrollDirectionOptions = {}
): ScrollDirectionState {
  const threshold = options.threshold ?? 48;
  const hysteresis = options.hysteresis ?? 16;
  const topRevealOffset = options.topRevealOffset ?? 24;
  const y = Math.max(0, Number.isFinite(nextY) ? nextY : 0);

  if (maxScroll <= threshold || y <= topRevealOffset) {
    return {
      lastY: y,
      direction: y === prev.lastY ? prev.direction : 'up',
      hidden: false
    };
  }

  // Reveal dock near bottom so footer/pagination stays reachable
  if (maxScroll > 0 && y >= maxScroll - 24) {
    return {
      lastY: y,
      direction: 'down',
      hidden: false
    };
  }

  const delta = y - prev.lastY;
  if (Math.abs(delta) < hysteresis) {
    return prev;
  }

  if (delta > 0) {
    return {
      lastY: y,
      direction: 'down',
      hidden: y > threshold
    };
  }

  return {
    lastY: y,
    direction: 'up',
    hidden: false
  };
}

export function useScrollDirection(options: ScrollDirectionOptions = {}) {
  const scrollY = ref(0);
  const maxScroll = ref(0);
  const progress = ref(0);
  const direction = ref<ScrollDirection>('idle');
  const isHidden = ref(false);
  const prefersReducedMotion = ref(false);

  let rafId: number | null = null;
  let state: ScrollDirectionState = { lastY: 0, direction: 'idle', hidden: false };
  let mediaQuery: MediaQueryList | null = null;
  let onMotionChange: ((event: MediaQueryListEvent) => void) | null = null;

  function sample(): void {
    rafId = null;
    if (typeof window === 'undefined' || typeof document === 'undefined') return;
    const doc = document.documentElement;
    const y = window.scrollY || doc.scrollTop || 0;
    const metrics = computeScrollMetrics(y, doc.scrollHeight, window.innerHeight);
    scrollY.value = metrics.scrollY;
    maxScroll.value = metrics.maxScroll;
    progress.value = metrics.progress;

    if (prefersReducedMotion.value) {
      isHidden.value = false;
      state = { lastY: metrics.scrollY, direction: 'idle', hidden: false };
      return;
    }

    state = updateScrollDirection(state, metrics.scrollY, metrics.maxScroll, options);
    direction.value = state.direction;
    isHidden.value = state.hidden;
  }

  function onScroll(): void {
    if (rafId !== null) return;
    rafId = requestAnimationFrame(sample);
  }

  function reset(): void {
    isHidden.value = false;
    state = { lastY: 0, direction: 'idle', hidden: false };
    sample();
  }

  onMounted(() => {
    if (typeof window === 'undefined') return;
    if (window.matchMedia) {
      mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
      prefersReducedMotion.value = mediaQuery.matches;
      onMotionChange = event => {
        prefersReducedMotion.value = event.matches;
        if (event.matches) isHidden.value = false;
      };
      mediaQuery.addEventListener?.('change', onMotionChange);
    }
    sample();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll, { passive: true });
  });

  onBeforeUnmount(() => {
    if (rafId !== null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
    if (typeof window !== 'undefined') {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
    }
    if (mediaQuery && onMotionChange) {
      mediaQuery.removeEventListener?.('change', onMotionChange);
    }
  });

  return {
    scrollY,
    maxScroll,
    progress,
    direction,
    isHidden,
    prefersReducedMotion,
    reset
  };
}
