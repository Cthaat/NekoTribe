import { nextTick, reactive, watch } from 'vue';

export function useMediaGallery() {
  let opener: HTMLElement | null = null;
  let strip: HTMLElement | null = null;
  const gallery = reactive({
    open: false,
    startIndex: 0,
    show(index: number, event: MouseEvent) {
      opener = event.currentTarget as HTMLElement;
      strip = opener.parentElement;
      gallery.startIndex = index;
      gallery.open = true;
    },
    originRect(url: string) {
      const thumb = Array.from(strip?.querySelectorAll<HTMLElement>('[data-media-url]') ?? [])
        .find(el => el.dataset.mediaUrl === url);
      return thumb?.isConnected ? thumb.getBoundingClientRect() : null;
    }
  });
  watch(() => gallery.open, async open => {
    if (!open) {
      await nextTick();
      if (opener?.isConnected) opener.focus({ preventScroll: true });
    }
  });
  return gallery;
}
