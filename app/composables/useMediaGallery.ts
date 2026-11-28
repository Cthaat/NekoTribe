import { reactive } from 'vue';

export function useMediaGallery() {
  let strip: HTMLElement | null = null;
  const gallery = reactive({
    open: false,
    startIndex: 0,
    show(index: number, event: MouseEvent) {
      strip = (event.currentTarget as HTMLElement).parentElement;
      gallery.startIndex = index;
      gallery.open = true;
    },
    originRect(url: string) {
      const thumb = Array.from(strip?.querySelectorAll<HTMLElement>('[data-media-url]') ?? [])
        .find(el => el.dataset.mediaUrl === url);
      return thumb?.isConnected ? thumb.getBoundingClientRect() : null;
    }
  });
  return gallery;
}
