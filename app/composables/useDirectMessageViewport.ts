import { onBeforeUnmount, watch, type Ref } from 'vue';

export function useDirectMessageViewport(
  list: Ref<HTMLElement | null>,
  messageKey: () => string,
  enabled: () => boolean,
  report: (messageId: number) => void,
) {
  let observer: IntersectionObserver | null = null;
  let previousList: HTMLElement | null = null;

  const observe = () => {
    observer?.disconnect();
    const body = list.value;
    if (!body || !enabled() || typeof IntersectionObserver === 'undefined') {
      previousList = null;
      return;
    }
    const viewport = body.closest('[data-slot="scroll-area-viewport"]');
    if (!viewport) return;
    if (previousList !== body) viewport.scrollTop = viewport.scrollHeight;
    previousList = body;
    observer = new IntersectionObserver(entries => {
      if (list.value !== body || !enabled()) return;
      const last = Math.max(0, ...entries.filter(item => item.isIntersecting && item.intersectionRatio > 0)
        .map(item => Number((item.target as HTMLElement).dataset.incomingDirectMessageId)));
      if (last > 0) report(last);
    }, { root: viewport });
    body.querySelectorAll('[data-incoming-direct-message-id]').forEach(row => observer?.observe(row));
  };

  watch([list, messageKey, enabled], observe, { flush: 'post' });
  onBeforeUnmount(() => observer?.disconnect());
}
