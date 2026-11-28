export default defineNuxtPlugin(() => {
  function loaded(event: Event) {
    if (event.target instanceof HTMLImageElement && event.target.naturalWidth) {
      const image = event.target;
      if (matchMedia('(prefers-reduced-motion: reduce), (prefers-reduced-transparency: reduce)').matches) return;
      image.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: 'ease-out' });
    }
  }
  document.addEventListener('load', loaded, true);
  if (import.meta.hot) import.meta.hot.dispose(() => document.removeEventListener('load', loaded, true));
});
