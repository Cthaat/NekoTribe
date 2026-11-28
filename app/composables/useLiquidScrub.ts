import { computed, ref, type Ref } from 'vue';

export function resistedIndex(index: number, last: number, reduced: boolean) {
  const edge = Math.max(0, Math.min(last, index));
  const excess = index - edge;
  return edge + (reduced ? 0 : 0.24 * Math.tanh(excess));
}

export function snapIndex(position: number, speed: number, enabled: number[]) {
  const predicted = position + Math.max(-0.7, Math.min(0.7, speed * 75));
  return enabled.reduce((best, index) =>
    Math.abs(predicted - index) < Math.abs(predicted - best) ? index : best, enabled[0] ?? -1);
}

export function useLiquidScrub(active: Ref<number>, select: (index: number) => void) {
  const preview = ref<number | null>(null);
  const speed = ref(0);
  const position = computed(() => preview.value ?? active.value);
  let drag: { id: number; x: number; y: number; left: number; width: number; count: number;
    lastX: number; time: number; moved: boolean; reduced: boolean; items: HTMLElement[] } | undefined;
  let suppressClick = false;

  function pointerdown(e: PointerEvent) {
    if (drag || !e.isPrimary || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const root = e.currentTarget as HTMLElement;
    const items = Array.from(root.querySelectorAll<HTMLElement>('[data-scrub-item]'));
    const target = (e.target as Element).closest<HTMLElement>('[data-scrub-item]');
    if (!target || target.matches(':disabled')) return;
    const { left, width } = items[0]!.getBoundingClientRect();
    if (!width) return;
    suppressClick = false;
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, left, width, count: items.length,
      lastX: e.clientX, time: e.timeStamp, moved: false, items, reduced: matchMedia('(prefers-reduced-motion: reduce)').matches };
    target.setPointerCapture(e.pointerId);
    preview.value = items.indexOf(target);
  }

  function clear() {
    drag = undefined;
    preview.value = null;
    speed.value = 0;
  }

  function cancel(e: PointerEvent) {
    if (drag?.id !== e.pointerId) return;
    suppressClick = true;
    clear();
  }

  function pointermove(e: PointerEvent) {
    if (!drag || drag.id !== e.pointerId) return;
    if (!drag.moved) {
      const dx = Math.abs(e.clientX - drag.x), dy = Math.abs(e.clientY - drag.y);
      if (dy > 6 && dy > dx) return cancel(e);
      if (dx < 5) return;
      drag.moved = true;
    }
    speed.value = (e.clientX - drag.lastX) / drag.width / Math.max(8, e.timeStamp - drag.time);
    preview.value = resistedIndex((e.clientX - drag.left) / drag.width - 0.5, drag.count - 1, drag.reduced);
    drag.lastX = e.clientX;
    drag.time = e.timeStamp;
  }

  function pointerup(e: PointerEvent) {
    if (!drag || drag.id !== e.pointerId) return;
    if (drag.moved) {
      const enabled = drag.items.flatMap((item, i) => item.isConnected && !item.matches(':disabled') ? [i] : []);
      const index = snapIndex((e.clientX - drag.left) / drag.width - 0.5,
        e.timeStamp - drag.time < 90 ? speed.value : 0, enabled);
      suppressClick = true;
      if (index >= 0) select(index);
    }
    clear();
  }

  function clickCapture(e: MouseEvent) {
    if (suppressClick && e.detail > 0) {
      e.preventDefault();
      e.stopPropagation();
    }
    suppressClick = false;
  }

  const pillStyle = computed(() => {
    const stretch = 1 + Math.min(0.16, Math.abs(speed.value) * 12);
    return { '--scrub-x': position.value * 100 + '%', '--stretch-x': stretch,
      '--stretch-y': 1 / stretch, '--glint-x': 50 + Math.max(-18, Math.min(18, speed.value * 2000)) + '%' };
  });
  function itemStyle(index: number) {
    if (preview.value === null) return;
    const proximity = Math.max(0, 1 - Math.abs(index - position.value));
    return { '--proximity': proximity, '--active-mix': proximity * 100 + '%' };
  }
  return { events: { pointerdown, pointermove, pointerup, pointercancel: cancel, lostpointercapture: cancel,
    clickCapture, dragstart: (e: DragEvent) => { if (drag) e.preventDefault(); } },
    pressed: computed(() => preview.value !== null), pillStyle, itemStyle };
}
