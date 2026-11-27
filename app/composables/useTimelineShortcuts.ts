import type { Ref } from 'vue';
import { useEventListener } from '@vueuse/core';
import { readAppShortcut } from '@/utils/app-shortcuts';

const textControls = 'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="combobox"], [role="listbox"], [role="menu"], [role="slider"]';
const postSelector = '[data-timeline-post]';

export function useTimelineShortcuts(
  timeline: Ref<HTMLElement | null>,
  enabled: Readonly<Ref<boolean>>,
  actions: { compose: () => void; help: () => void }
) {
  useEventListener('keydown', event => {
    if (!enabled.value) return;
    const focused = document.activeElement;
    const action = readAppShortcut(event, {
      editable: !!focused?.closest(textControls),
      modalOpen: !!document.querySelector('[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"]')
    });
    if (!timeline.value || !action || action === 'palette') return;
    if (action === 'compose' || action === 'help') {
      event.preventDefault();
      actions[action]();
      return;
    }
    const posts = Array.from(timeline.value.querySelectorAll<HTMLElement>(postSelector));
    if (posts.length === 0) return;
    const current = focused?.closest<HTMLElement>(postSelector);
    const index = current ? posts.indexOf(current) : -1;
    if (action === 'next' || action === 'previous') {
      const nextIndex = index < 0
        ? action === 'next' ? 0 : posts.length - 1
        : index + (action === 'next' ? 1 : -1);
      const next = posts[nextIndex];
      if (!next) return;
      event.preventDefault();
      next.focus({ preventScroll: true });
      next.scrollIntoView({ block: 'nearest' });
      return;
    }
    const button = posts[index]?.querySelector<HTMLButtonElement>(`button[data-timeline-action="${action}"]:not(:disabled)`);
    if (!button) return;
    event.preventDefault();
    button.click();
  });
}
