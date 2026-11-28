export default defineNuxtPlugin(() => {
  const faded = new WeakMap<HTMLImageElement, string>();
  const reduced = matchMedia('(prefers-reduced-motion: reduce), (prefers-reduced-transparency: reduce)');

  function fade(image: HTMLImageElement) {
    const src = image.currentSrc;
    if (!src || !image.complete || !image.naturalWidth || reduced.matches || faded.get(image) === src) return;
    faded.set(image, src);
    image.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: 'ease-out' });
  }

  function loaded(event: Event) {
    if (event.target instanceof HTMLImageElement) fade(event.target);
  }
  document.addEventListener('load', loaded, true);
  for (const image of Array.from(document.images)) fade(image);
  if (import.meta.hot) import.meta.hot.dispose(() => document.removeEventListener('load', loaded, true));
});
